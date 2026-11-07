// The load step (launcher.m's last): the game's client, Library/spgames/wow-<flavor>, unchanged and unsigned
// (the arm64 slice of Blizzard's file: no load-command rewrite, retype, or signature), loaded with the
// launcher's own loader (spguest.c), since dyld won't dlopen an MH_EXECUTE and the system wouldn't run an
// unsigned image. Everything before it is the launcher's (the flavor, the region, the game data's checks,
// the sign-in, the helper's attach, the loading screen):
// - sp_guest_preflight, before the sign-in: the private hooks spguest registers the client with, and the
//   file itself, so a new OS that took a hook away, or a client the device can't load, says why before
//   anyone types a password, not after the attach;
// - the helper prepares the region spguest reserved for the client's __TEXT in one brk #0xf00d stop and
//   detaches ("guest: detached", the line the companion's ClientLauncher and run.sh follow), and the file's
//   __TEXT is copied in through a read-write alias (the toy's pattern, guesttest/device.c);
// - the client's libraries are opened through the app's rewrite-map.txt, so the shims take them;
// - libspSystem is told where the client is (sp_set_client), since dyld never lists it, so its stubs'
//   caller offsets, the __TEXT services (the client's dlsym'd mprotect and memcpy), and crash reports name it;
// - the client is known by its file's path (dladdr, image 0's name): once, early in main, the client dlopens
//   (RTLD_NOW) the path dladdr gives for its own code, and spguest answers that with NULL, as dyld does for an
//   MH_EXECUTE ("cannot dlopen a main executable"); every game plays into the world with it.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>
#import <UIKit/UIKit.h>
#import "spcdn.h"  // sp_slice_problem, sp_slice_retire
#include "spguest.h"

void sp_launch_say(NSString *s);  // launcher.m
NSString *sp_flavor_name(NSString *flavor);  // launcher.m
NSDictionary *sp_flavor_entry(NSString *flavor);  // launcher.m
NSString *sp_device_noun(void);  // spjit.m
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
    // The companion (ClientLauncher.Marker.detached) and run.sh follow the launch to this line.
    say([NSString stringWithFormat:@"detached (traced=%d) in %.3f s", sp_traced(), t_detach]);
    vm_address_t w = 0;
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &w, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)text,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    if (!kr) kr = vm_protect(mach_task_self(), w, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr) say([NSString stringWithFormat:@"alias failed: kr=%d (%s)", kr, mach_error_string(kr)]);
    return kr ? NULL : (void *)w;
}

// The app's rewrite-map.txt: each library the client names, to the shim that stands in for it.
static NSDictionary<NSString *, NSString *> *map;

static const char *rewrite(const char *install, void *context) {
    NSString *to = map[@(install)];
    return to ? to.fileSystemRepresentation : install;
}

NSString *sp_guest_preflight(NSString *path) {
    char err[256];
    if (!spguest_check_hooks(err, sizeof err)) {
        say([NSString stringWithFormat:@"FAIL preflight: %s", err]);
        return [NSString stringWithFormat:@"This version of %@ doesn't have what Slashplayed needs to load the game (%s). Check for "
                                          @"a Slashplayed update.", UIDevice.currentDevice.systemName, err];
    }
    NSString *problem = sp_slice_problem(path);
    if (!problem) return nil;
    NSString *flavor = [path.lastPathComponent substringFromIndex:4];
    say([NSString stringWithFormat:@"FAIL preflight: Library/spgames/%@: %@", path.lastPathComponent, problem]);
    NSString *retired = sp_slice_retire(path.stringByDeletingLastPathComponent, flavor, sp_flavor_entry(flavor)[@"product"] ?: flavor);
    if (retired) sp_launch_say([@"update: " stringByAppendingString:retired]);
    return [NSString stringWithFormat:@"%@'s client on this %@ can't be loaded: %@. It's deleted, so the next start gets it again.",
                                      sp_flavor_name(flavor), sp_device_noun(), problem];
}

int sp_guest_main(NSString *path, int argc, char **argv, NSString **problem) {
    *problem = nil;
    NSString *text = [NSString stringWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"rewrite-map.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange arrow = [line rangeOfString:@" -> "];
        if (arrow.location != NSNotFound) m[[line substringToIndex:arrow.location]] = [line substringFromIndex:NSMaxRange(arrow)];
    }
    map = m;
    if (!map.count) {
        *problem = @"the app has no rewrite-map.txt";
        return 1;
    }
    say([NSString stringWithFormat:@"loading Library/spgames/%@ (%.1f MB), %lu libraries in the rewrite map", path.lastPathComponent,
                                   [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize / 1e6,
                                   (unsigned long)map.count]);
    double t0 = now();
    char err[512];
    SPGuestOptions o = {.prepare_text = prepare_text, .rewrite = rewrite, .log = say_line};
    SPGuest *g = spguest_load(path.fileSystemRepresentation, &o, err, sizeof err);
    if (!g) {
        say([NSString stringWithFormat:@"FAIL load: %s", err]);
        // The file itself (it changed since the preflight): deleted, so the next Play or start replaces it.
        NSString *flavor = [path.lastPathComponent substringFromIndex:4];
        NSString *retired = sp_slice_retire(path.stringByDeletingLastPathComponent, flavor, sp_flavor_entry(flavor)[@"product"] ?: flavor);
        if (retired) sp_launch_say([@"update: " stringByAppendingString:retired]);
        *problem = retired ? [NSString stringWithFormat:@"%s; it's deleted, so the next start gets it again", err] : @(err);
        return 1;
    }
    // libspSystem is loaded (launcher.m's first line), so it knows before the client's first call into a shim.
    void (*set_client)(const struct mach_header *, intptr_t, const char *, uintptr_t) = dlsym(RTLD_DEFAULT, "sp_set_client");
    if (!set_client) {
        say(@"FAIL: libspSystem has no sp_set_client");
        *problem = @"the app's libspSystem has no sp_set_client";
        return 1;
    }
    set_client(spguest_header(g), spguest_slide(g), path.fileSystemRepresentation, (uintptr_t)spguest_text_alias(g, NULL, NULL));
    if (!spguest_link(g, err, sizeof err)) {
        say([NSString stringWithFormat:@"FAIL link: %s", err]);
        *problem = @(err);
        return 1;
    }
    // Every image the client links is initialized now. No microphone: the app has no
    // NSMicrophoneUsageDescription (voice chat can't work on the device), so a capture permission request
    // would get the process killed; the AudioToolbox shim makes AVCaptureDevice answer "denied"
    // (spaudiotoolbox.m says why).
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
