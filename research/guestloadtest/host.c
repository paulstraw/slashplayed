// The launcher side of guestloadtest on the Mac: loads the toy with spguest and runs it.
// Usage: host <toy> [args]. The device host (device.c) shares spguest.c.
#include "spguest.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/mman.h>
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

// What libspSystem's dlsym does for the client on the device (sp_set_client), which the Mac host has no shims
// for: mprotect on the guest's __TEXT is a no-op, and memcpy into it goes through the alias.
static SPGuest *guest;

static bool in_text(const void *a, size_t n, uintptr_t *off) {
    uintptr_t t;
    size_t size;
    spguest_text_alias(guest, &t, &size);
    *off = (uintptr_t)a - t;
    return (uintptr_t)a >= t && n <= size && *off <= size - n;
}
static int host_mprotect(void *a, size_t n, int prot) {
    uintptr_t off;
    return in_text(a, n, &off) ? 0 : mprotect(a, n, prot);
}
static void *host_memcpy(void *dst, const void *src, size_t n) {
    uintptr_t off;
    if (in_text(dst, n, &off)) {
        memcpy((char *)spguest_text_alias(guest, NULL, NULL) + off, src, n);
        return dst;
    }
    return memcpy(dst, src, n);
}
static void *host_dlsym(void *handle, const char *name) {
    if (handle == RTLD_DEFAULT && !strcmp(name, "mprotect")) return (void *)host_mprotect;
    if (handle == RTLD_DEFAULT && !strcmp(name, "memcpy")) return (void *)host_memcpy;
    return dlsym(handle, name);
}
static void *symbol(const char *name, void *context) { return strcmp(name, "_dlsym") ? NULL : (void *)host_dlsym; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: host <guest> [args]\n"); return 2; }
    char err[512];
    SPGuestOptions o = {.log = say, .prepare_text = alias, .symbol = symbol};
    SPGuest *g = guest = spguest_load(argv[1], &o, err, sizeof err);
    if (!g) { fprintf(stderr, "load: %s\n", err); return 3; }
    if (!spguest_link(g, err, sizeof err)) { fprintf(stderr, "link: %s\n", err); return 4; }
    const char *apple[] = {argv[1], NULL};
    int r = spguest_run(g, argc - 1, (const char **)argv + 1, (const char **)environ, apple);
    double l, k, i;
    spguest_times(g, &l, &k, &i);
    fprintf(stderr, "[spguest] guest returned %d (load %.3f s, link %.3f s, initializers %.3f s)\n", r, l, k, i);
    return r;
}
