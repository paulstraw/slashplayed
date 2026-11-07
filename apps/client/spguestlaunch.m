// A dev switch for research/guestloadtest: $SP_GUEST_CLIENT=<path in the app's home> loads that file, the
// game's client unchanged and unsigned (no thin needed, no load-command rewrite, retype, or signature), with
// the launcher's own loader (research/guestloadtest/spguest.c) instead of dlopen'ing the bundled image.
// Everything before it is the launcher's as for any start (the flavor, the region, the game data's checks,
// the sign-in, the helper's attach, the loading screen); only the load differs:
// - the helper prepares the region spguest reserved for the client's __TEXT in one brk #0xf00d stop and
//   detaches, and the file's __TEXT is copied in through a read-write alias (the toy's pattern, device.c);
// - the client's libraries are opened through the app's rewrite-map.txt, so the shims take them, as the
//   assembled image's rewritten load commands do;
// - libspSystem is told where the client is (sp_set_client), since dyld never lists it, so its stubs'
//   caller offsets, the __TEXT services (the client's dlsym'd mprotect and memcpy), and crash reports name it;
// - the client is known by its file's path (dladdr, image 0's name), not the bundled image's: once, early in
//   main, the client dlopens (RTLD_NOW) the path dladdr gives for its own code. Under dyld that's the loaded
//   image's handle; for the guest's own file, an MH_EXECUTE, dyld refuses ("cannot dlopen a main
//   executable") and the client goes on with NULL, as every game does through the world. Named by the
//   bundled image's path, that dlopen loaded a second client.
// Never set by the companion or a person; nothing here runs without it.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "spguest.h"

void sp_launch_say(NSString *s);  // launcher.m
int sp_traced(void);  // spjit.m

#define PAGE 0x4000

extern char **environ;
static double t_prepare, t_detach;

static void say(NSString *s) { sp_launch_say([@"guest: " stringByAppendingString:s]); }
static void say_line(const char *line) { say(@(line)); }

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

__attribute__((noinline)) static uintptr_t jit_cmd(uintptr_t cmd, uintptr_t a, uintptr_t b, uintptr_t c) {
    register uintptr_t x0 __asm__("x0") = a;
    register uintptr_t x1 __asm__("x1") = b;
    register uintptr_t x2 __asm__("x2") = c;
    register uintptr_t x16 __asm__("x16") = cmd;
    __asm__ volatile("brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x16) : "memory");
    return x0;
}

// spguest's prepare_text: `text` is a fresh anonymous r-x mapping, so every page's first byte is 0, which
// is what the helper writes back (x2). One stop for all of __TEXT, the detach, then the alias it's copied
// in through. A brk without a debugger kills the process: the helper's attach was waited for, but checked.
static void *prepare_text(void *text, size_t size, void *context) {
    if (!sp_traced()) {
        say(@"no debugger attached to prepare the client's code");
        return NULL;
    }
    unsigned char *firsts = calloc(size / PAGE, 1);
    double t = now();
    uintptr_t r = jit_cmd(1, (uintptr_t)text, size, (uintptr_t)firsts);
    t_prepare = now() - t;
    free(firsts);
    say([NSString stringWithFormat:@"prepared %p+0x%zx (%zu pages) in %.3f s%@", text, size, size / PAGE, t_prepare,
                                   r == (uintptr_t)text ? @"" : @" (the helper returned another address)"]);
    t = now();
    jit_cmd(0, 0, 0, 0);
    for (int ms = 0; sp_traced() && ms < 5000; ms += 10) usleep(10000);
    t_detach = now() - t;
    // run.sh follows the launch to this line, as to libspSystem's for the dyld-loaded client.
    say([NSString stringWithFormat:@"detached (traced=%d) in %.3f s", sp_traced(), t_detach]);
    vm_address_t w = 0;
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &w, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)text,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    if (!kr) kr = vm_protect(mach_task_self(), w, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr) say([NSString stringWithFormat:@"alias failed: kr=%d (%s)", kr, mach_error_string(kr)]);
    return kr ? NULL : (void *)w;
}

// The app's rewrite-map.txt, the map the assembled image's load commands were rewritten with.
static NSDictionary<NSString *, NSString *> *map;

static const char *rewrite(const char *install, void *context) {
    NSString *to = map[@(install)];
    return to ? to.fileSystemRepresentation : install;
}

int sp_guest_main(NSString *relative, int argc, char **argv) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:relative];
    NSString *text = [NSString stringWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"rewrite-map.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange arrow = [line rangeOfString:@" -> "];
        if (arrow.location != NSNotFound) m[[line substringToIndex:arrow.location]] = [line substringFromIndex:NSMaxRange(arrow)];
    }
    map = m;
    say([NSString stringWithFormat:@"loading %@ (%.1f MB), %lu libraries in the rewrite map", relative,
                                   [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize / 1e6,
                                   (unsigned long)map.count]);
    double t0 = now();
    char err[512];
    SPGuestOptions o = {.prepare_text = prepare_text, .rewrite = rewrite, .log = say_line};
    SPGuest *g = spguest_load(path.fileSystemRepresentation, &o, err, sizeof err);
    if (!g) { say([NSString stringWithFormat:@"FAIL load: %s", err]); return 1; }
    // libspSystem is loaded (launcher.m's first line), so it knows before the client's first call into a shim.
    void (*set_client)(const struct mach_header *, intptr_t, const char *, uintptr_t) = dlsym(RTLD_DEFAULT, "sp_set_client");
    if (!set_client) { say(@"FAIL: libspSystem has no sp_set_client"); return 1; }
    set_client(spguest_header(g), spguest_slide(g), path.fileSystemRepresentation, (uintptr_t)spguest_text_alias(g, NULL, NULL));
    if (!spguest_link(g, err, sizeof err)) { say([NSString stringWithFormat:@"FAIL link: %s", err]); return 1; }
    // As launcher.m does after the dlopen: every image the client links is initialized now.
    void (*no_mic)(void) = dlsym(RTLD_DEFAULT, "sp_audio_no_microphone");
    if (no_mic) no_mic();
    else say(@"audio: can't refuse the microphone: voice chat settings may stop the app");
    double load, link, init;
    spguest_times(g, &load, &link, &init);
    say([NSString stringWithFormat:@"loaded and linked in %.3f s (prepare %.3f s, detach %.3f s, load %.3f s with both, link %.3f s); "
                                   @"initializers, then main", now() - t0, t_prepare, t_detach, load, link]);
    const char *apple[] = {path.fileSystemRepresentation, NULL};
    return spguest_run(g, argc, (const char **)argv, (const char **)environ, apple);
}
