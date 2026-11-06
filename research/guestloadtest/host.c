// The launcher side of guestloadtest on the Mac: loads the toy with spguest and runs it.
// Usage: host <toy> [args]. The device host (host.m) shares spguest.c.
#include "spguest.h"
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static void say(const char *line) { fprintf(stderr, "[spguest] %s\n", line); }

// The device's pattern without a debugger: __TEXT stays r-x and is written through a vm_remap alias, which
// macOS allows (a debugger-prepared region on the device).
static void *alias(void *text, size_t size, void *context) {
    vm_address_t w = 0;
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &w, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)text,
                                FALSE, &cur, &max, VM_INHERIT_NONE);
    if (!kr) kr = vm_protect(mach_task_self(), w, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    return kr ? NULL : (void *)w;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: host <guest> [args]\n"); return 2; }
    char err[512];
    SPGuestOptions o = {.log = say, .prepare_text = alias};
    SPGuest *g = spguest_load(argv[1], &o, err, sizeof err);
    if (!g) { fprintf(stderr, "load: %s\n", err); return 3; }
    if (!spguest_link(g, err, sizeof err)) { fprintf(stderr, "link: %s\n", err); return 4; }
    const char *apple[] = {argv[1], NULL};
    int r = spguest_run(g, argc - 1, (const char **)argv + 1, (const char **)environ, apple);
    double l, k, i;
    spguest_times(g, &l, &k, &i);
    fprintf(stderr, "[spguest] guest returned %d (load %.3f s, link %.3f s, initializers %.3f s)\n", r, l, k, i);
    return r;
}
