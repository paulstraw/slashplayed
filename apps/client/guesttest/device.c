// The launcher side of guesttest on the device: the on-device JIT helper (apps/client/helper, through
// research/jittest/helper_host.swift) attaches, spguest reserves the toy's span and has the helper prepare
// __TEXT in one `brk #0xf00d` stop, the helper detaches, and the toy's unchanged, unsigned __TEXT is
// copied in through a read-write alias (E2 and E6 in research/jittest: memory the app mapped itself,
// prepared, then written through an alias after the detach). Then fixups, registration, initializers, main.
// The toy comes from Documents/toy-guest (run.sh copies it there); everything logs to Documents/guest.log.
#include "spguest.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define PAGE 0x4000

extern char **environ;
static int logfd = -1;
static double t_prepare, t_detach;

static void say(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    write(1, buf, n);
    if (logfd >= 0) { write(logfd, buf, n); fsync(logfd); }
}
static void say_str(const char *s) { say("%s", s); }
static void say_line(const char *s) { say("[spguest] %s\n", s); }

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int traced(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && (kp.kp_proc.p_flag & P_TRACED);
}

__attribute__((noinline)) static uintptr_t jit_cmd(uintptr_t cmd, uintptr_t a, uintptr_t b, uintptr_t c) {
    register uintptr_t x0 __asm__("x0") = a;
    register uintptr_t x1 __asm__("x1") = b;
    register uintptr_t x2 __asm__("x2") = c;
    register uintptr_t x16 __asm__("x16") = cmd;
    __asm__ volatile("brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x16) : "memory");
    return x0;
}

// spguest's prepare_text: `text` is a fresh anonymous r-x mapping, so every page's first byte is 0 and the
// helper writes those back (x2), leaving it zero. One stop for all of __TEXT, then detach, then the alias.
static void *prepare_text(void *text, size_t size, void *context) {
    (void)context;
    unsigned char *firsts = calloc(size / PAGE, 1);
    double t = now();
    uintptr_t r = jit_cmd(1, (uintptr_t)text, size, (uintptr_t)firsts);
    t_prepare = now() - t;
    free(firsts);
    say("  prepared %p+0x%zx (%zu pages) in %.3f s%s\n", text, size, size / PAGE, t_prepare,
        r == (uintptr_t)text ? "" : " (the helper returned another address)");
    t = now();
    jit_cmd(0, 0, 0, 0);
    for (int ms = 0; traced() && ms < 5000; ms += 10) usleep(10000);
    t_detach = now() - t;
    say("  detached (traced=%d) in %.3f s\n", traced(), t_detach);
    vm_address_t w = 0;
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &w, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)text,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    if (!kr) kr = vm_protect(mach_task_self(), w, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr) say("  alias failed: kr=%d (%s)\n", kr, mach_error_string(kr));
    return kr ? NULL : (void *)w;
}

// The libraries the toy names, as the client's are: shims/generated/rewrite-map.txt (bundled beside the
// executable), the same map build.sh's load-command rewrite uses, so the shims in Frameworks/ (@rpath) take
// the client's libraries and the rest go to the device's own. A name not in the map stays as it is.
static struct { char *from, *to; } map[64];
static int nmap;

static void load_map(void) {
    char path[1024];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size)) return;
    strcpy(strrchr(path, '/') + 1, "rewrite-map.txt");
    FILE *f = fopen(path, "r");
    if (!f) { say("  no rewrite-map.txt in the bundle\n"); return; }
    char line[1024];
    while (nmap < 64 && fgets(line, sizeof line, f)) {
        char *arrow = strstr(line, " -> ");
        if (!arrow) continue;
        *arrow = 0;
        arrow[strcspn(arrow + 4, "\r\n") + 4] = 0;
        map[nmap].from = strdup(line);
        map[nmap++].to = strdup(arrow + 4);
    }
    fclose(f);
    say("  rewrite map: %d libraries\n", nmap);
}

static const char *rewrite(const char *install, void *context) {
    (void)context;
    for (int i = 0; i < nmap; i++)
        if (!strcmp(install, map[i].from)) return map[i].to;
    return install;
}

extern int sp_helper_attach(void (*log)(const char *));
extern int sp_helper_finish(void (*log)(const char *));

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    char log[1024], toy[1024];
    snprintf(log, sizeof log, "%s/Documents/guest.log", getenv("HOME"));
    snprintf(toy, sizeof toy, "%s/Documents/toy-guest", getenv("HOME"));
    logfd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    say("=== guest (pid %d, traced=%d)\n", getpid(), traced());
    double t0 = now();
    if (sp_helper_attach(say_str)) { say("  FAIL: the helper didn't attach\n=== guest done\n"); return 1; }
    while (!traced() && now() - t0 < 60) usleep(10000);
    say("  traced=%d %.2f s after launch\n", traced(), now() - t0);
    if (!traced()) { say("  not traced: a brk would kill us, stopping\n=== guest done\n"); return 1; }

    load_map();
    char err[512];
    SPGuestOptions o = {.log = say_line, .prepare_text = prepare_text, .rewrite = rewrite};
    SPGuest *g = spguest_load(toy, &o, err, sizeof err);
    sp_helper_finish(say_str);  // the helper's reply, which comes once it has detached
    if (!g) { say("  FAIL load: %s\n=== guest done\n", err); return 1; }
    // libspSystem's idea of the client (its stubs' caller offsets, the __TEXT services, crash reports):
    // dyld never lists the guest, so it's told. Loaded here, before the binds open it, so its constructor
    // runs and it knows before the guest's first call into a shim.
    void *system = dlopen("@rpath/libspSystem.dylib", RTLD_NOW);
    void (*set_client)(const struct mach_header *, intptr_t, const char *, uintptr_t) =
        system ? dlsym(system, "sp_set_client") : NULL;
    if (!set_client) { say("  FAIL: no sp_set_client in libspSystem: %s\n=== guest done\n", dlerror()); return 1; }
    set_client(spguest_header(g), spguest_slide(g), toy, (uintptr_t)spguest_text_alias(g, NULL, NULL));
    if (!spguest_link(g, err, sizeof err)) { say("  FAIL link: %s\n=== guest done\n", err); return 1; }
    // The toy logs its checks to the same file (it opens SP_GUEST_LOG itself, O_APPEND).
    setenv("SP_GUEST_LOG", log, 1);
    const char *gargv[] = {toy, NULL}, *apple[] = {toy, NULL};
    int r = spguest_run(g, 1, gargv, (const char **)environ, apple);
    double l, k, i;
    spguest_times(g, &l, &k, &i);
    say("  guest returned %d: prepare %.3f s, detach %.3f s, load %.3f s (prepare and detach included), link %.3f s, "
        "initializers %.3f s; %.2f s from launch\n", r, t_prepare, t_detach, l, k, i, now() - t0);
    say("=== guest done\n");
    return r;
}
