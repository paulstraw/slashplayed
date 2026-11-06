// The guest: a macOS program of our own, built like the game client (MH_EXECUTE, dyld-info fixups,
// -mmacosx-version-min=11.0) and loaded unchanged, unsigned, by spguest instead of dyld. It exercises
// what a loader has to get right and logs ok/FAIL for each. The client is never touched.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
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
extern "C" __attribute__((noinline, optnone, used, section("__TEXT,__sppatch"))) int patch_me(void) { return 1; }

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

        say("=== done, %d failure(s)\n", failures);
    }
    return failures ? 1 : 0;
}
