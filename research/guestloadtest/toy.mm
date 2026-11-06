// The guest: a macOS program of our own, built like the game client (MH_EXECUTE, dyld-info fixups,
// -mmacosx-version-min=11.0) and loaded unchanged, unsigned, by spguest instead of dyld. It exercises
// what a loader has to get right and logs ok/FAIL for each. The client is never touched.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <atomic>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

extern "C" const struct mach_header_64 _mh_execute_header;
extern "C" __attribute__((visibility("default"), used)) int sp_toy_exported(void) { return 4242; }
extern "C" void sp_missing_weak(void) __attribute__((weak_import));

static int logfd = -1, failures;
static void say(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    write(1, buf, n);
    if (logfd >= 0) { write(logfd, buf, n); fsync(logfd); }
}
static void check(bool ok, const char *what) { say("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) failures++; }

// 1. Constructors run in order, before main: C++ statics and __attribute__((constructor)).
static int order[8], norder;
struct Ctor { Ctor(int n) { order[norder++] = n; } };
static Ctor c1(1), c2(2);
__attribute__((constructor)) static void c3(void) { order[norder++] = 3; }
static Ctor c4(4);

// 2. Objective-C: a subclass, a category on a framework class, a protocol, and +load.
static int loaded;
@protocol SPPing <NSObject>
- (int)ping;
@end
@interface SPToy : NSObject <SPPing>
@end
@implementation SPToy
+ (void)load { loaded++; }
- (int)ping { return 7; }
@end
@interface NSString (SPToy)
- (int)spToyLength;
@end
@implementation NSString (SPToy)
- (int)spToyLength { return (int)self.length; }
@end

// 4. Thread-locals: one with a constructor-free initial value, one zero-initialised, one with a destructor.
static thread_local int tl_data = 5;
static thread_local int tl_bss;
static std::atomic<int> dtors;
struct WithDtor { int v = 9; ~WithDtor() { dtors++; } };
static thread_local WithDtor tl_dtor;

static void *tl_thread(void *arg) {
    tl_data += (int)(intptr_t)arg; tl_bss = (int)(intptr_t)arg * 2; tl_dtor.v += 1;
    return (void *)(intptr_t)(tl_data * 1000 + tl_bss * 10 + tl_dtor.v);
}

// 3. Exceptions through guest frames, and into libc++abi.
static void thrower(int n) { if (n == 0) throw std::runtime_error("boom"); thrower(n - 1); }

// 7. The game's startup rewrite: a code page of the guest changed through the memory functions it gets
// from dlsym, then called. `patch_me` returns 1 until patched to return 2.
extern "C" __attribute__((noinline, optnone, used, section("__TEXT,__sppatch,regular,pure_instructions"))) int patch_me(void) { return 1; }

// 8. A client-sized __TEXT: ~44 MB of filler (Classic Era's __TEXT is about that), so the prepare and the
// load are timed at the client's scale. The first pair returns 7, the last 8: a page left unprepared or
// uncopied at either end shows up.
#define SP_FILL 0x2c10000u
__asm__(".section __TEXT,__spfill,regular,pure_instructions\n"
        ".p2align 14\n"
        ".globl _sp_fill\n"
        "_sp_fill:\n"
        "mov w0, #7\n"
        "ret\n"
        ".fill 0xb03ffc, 4, 0xd503201f\n"  // SP_FILL / 4 - 4 nops
        "mov w0, #8\n"
        "ret\n"
        ".text\n");
extern "C" int sp_fill(void);

// 9. With the client's imports (build.sh's SP_GUEST_REFS: gen_refs.py's refs.c, names only, from the local
// recon): every symbol the client imports, from the same library, so the binds go through the shims at the
// client's breadth; and a subclass of an AppKit class, which on the device is the AppKit shim's.
#ifdef SP_REFS
#import <AppKit/AppKit.h>
extern "C" const void *const sp_refs[];
extern "C" const char *const sp_ref_names[];
extern "C" const size_t sp_ref_count;
@interface SPToyView : NSView
+ (int)spToyKind;
@end
@implementation SPToyView
+ (int)spToyKind { return 11; }
@end
#endif

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *path = getenv("SP_GUEST_LOG");
        if (path) logfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        say("=== toy (pid %d) argc=%d\n", getpid(), argc);

        say("     constructor order: %d %d %d %d (%d ran)\n", order[0], order[1], order[2], order[3], norder);
        check(norder == 4 && order[0] == 3 && order[1] == 1 && order[2] == 2 && order[3] == 4, "constructors ran in dyld's order (as the native run)");
        check(loaded == 1, "+load ran once");

        SPToy *t = [SPToy new];
        check([t ping] == 7 && [t conformsToProtocol:@protocol(SPPing)], "subclass dispatches, conforms to its protocol");
        check([@"abcd" spToyLength] == 4, "category on NSString");
        check([NSStringFromClass([t class]) isEqual:@"SPToy"], "class name registered");

        // 3
        bool caught = false;
        try { thrower(5); } catch (const std::runtime_error &e) { caught = !strcmp(e.what(), "boom"); }
        check(caught, "C++ exception thrown and caught across guest frames");
        caught = false;
        try { (void)std::stoi("not a number"); } catch (const std::invalid_argument &) { caught = true; }
        check(caught, "C++ exception thrown inside libc++, caught in the guest");
        caught = false;
        @try { [@[] objectAtIndex:3]; } @catch (NSException *e) { caught = true; }
        check(caught, "NSException raised in Foundation, caught in the guest");

        // 4
        check(tl_data == 5 && tl_bss == 0 && tl_dtor.v == 9, "thread-local initial values (data, zero-fill, constructed)");
        tl_data = 50;
        pthread_t th[3];
        for (int i = 0; i < 3; i++) pthread_create(&th[i], NULL, tl_thread, (void *)(intptr_t)(i + 1));
        bool ok = true;
        for (int i = 0; i < 3; i++) {
            void *r; pthread_join(th[i], &r);
            int want = (5 + i + 1) * 1000 + (i + 1) * 2 * 10 + 10;
            if ((int)(intptr_t)r != want) { ok = false; say("     thread %d got %d want %d\n", i, (int)(intptr_t)r, want); }
        }
        check(ok && tl_data == 50, "thread-locals are per thread and start from the template");
        usleep(100000);
        check(dtors == 3, "thread-local destructors ran at thread exit");

        // 5. Weak and lazy binds.
        check(sp_missing_weak == NULL, "missing weak import is NULL");
        check(strlen("lazy") == 4 && getpid() == getpid(), "lazy-bound libSystem calls");

        // 6. The guest knows itself.
        void *self = dlsym(RTLD_MAIN_ONLY, "sp_toy_exported");
        check(self == (void *)sp_toy_exported, "dlsym(RTLD_MAIN_ONLY) finds the guest's own export");
        Dl_info info;
        check(dladdr((void *)sp_toy_exported, &info) && info.dli_fbase == (void *)&_mh_execute_header, "dladdr names the guest's header");
        check(_dyld_get_image_header(0) == (const struct mach_header *)&_mh_execute_header, "_dyld_get_image_header(0) is the guest");
        char exe[1024]; uint32_t sz = sizeof exe;
        check(_NSGetExecutablePath(exe, &sz) == 0 && argc > 0 && strstr(exe, "toy") != NULL, "_NSGetExecutablePath is the guest's path");
        say("     image 0 name: %s, slide %#lx\n", _dyld_get_image_name(0), (long)_dyld_get_image_vmaddr_slide(0));
        void *bt[8];
        check(backtrace(bt, 8) > 0, "backtrace works from guest frames");

        // 7. Patch own code.
        int (*mp)(void *, size_t, int) = (int (*)(void *, size_t, int))dlsym(RTLD_DEFAULT, "mprotect");
        void *(*cp)(void *, const void *, size_t) = (void *(*)(void *, const void *, size_t))dlsym(RTLD_DEFAULT, "memcpy");
        check(mp && cp, "dlsym(mprotect/memcpy)");
        uintptr_t page = (uintptr_t)patch_me & ~(uintptr_t)0x3fff;
        uint32_t code[2] = {0x52800040 /* mov w0,#2 */, 0xd65f03c0 /* ret */};
        int r = mp((void *)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC);
        if (r) r = mp((void *)page, 0x4000, PROT_READ | PROT_WRITE);  // macOS refuses rwx outside MAP_JIT
        if (r == 0) {
            cp((void *)patch_me, code, sizeof code);
            sys_icache_invalidate((void *)patch_me, sizeof code);
            mp((void *)page, 0x4000, PROT_READ | PROT_EXEC);
        }
        say("     mprotect(rwx) = %d, mprotect %p memcpy %p, patch_me %p\n", r, (void *)mp, (void *)cp, (void *)patch_me);
        int (*volatile call)(void) = patch_me;  // volatile: the compiler knows what patch_me returned at build time
        check(r == 0 && call() == 2, "own code rewritten through mprotect/memcpy, then called");

        // 8
        int (*volatile last)(void) = (int (*)(void))((char *)sp_fill + SP_FILL - 8);
        check(sp_fill() == 7 && last() == 8, "both ends of a 44 MB __TEXT section run");

#ifdef SP_REFS
        // 9. A weak import may be absent (NULL); the link already failed on any other unresolved one.
        size_t absent = 0;
        for (size_t i = 0; i < sp_ref_count; i++)
            if (!sp_refs[i]) { absent++; say("     absent: %s\n", sp_ref_names[i]); }
        say("     %zu client imports, %zu absent\n", sp_ref_count, absent);
        check(absent == 0, "every client import bound");
        check([SPToyView superclass] == objc_getClass("NSView") && [SPToyView spToyKind] == 11 &&
                  [SPToyView instancesRespondToSelector:@selector(resetCursorRects)],
              "subclass of AppKit's NSView: registered, dispatches, inherits");
        // The shims' base for their caller offsets (libspSystem's sp_client_text, told by the loader): the guest.
        uintptr_t (*client_text)(void) = (uintptr_t (*)(void))dlsym(RTLD_DEFAULT, "sp_client_text");
        if (client_text) check(client_text() == (uintptr_t)&_mh_execute_header, "libspSystem's client __TEXT is the guest");
#endif

        say("=== done, %d failure(s)\n", failures);
    }
    return failures ? 1 : 0;
}
