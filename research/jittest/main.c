// On-device JIT experiments (E1-E7): can a get-task-allow app on visionOS execute
// code it wrote, with a debugger preparing the pages? One experiment per launch, chosen by argv[1]
// (or Documents/spjit-which when launched with none), because a code-signing violation kills the
// process outright.
//
// Debugger protocol (StikDebug-compatible): `brk #0xf00d` with x16 = command.
//   x16 = 1: prepare region x0 (0 = debugger allocates) of x1 bytes; returns the address in x0.
//            Extension: x2, if nonzero, points at the first byte of each page of the region.
//   x16 = 0: detach.
// Results go to stdout and Documents/spjit.log (fetch with devicectl copy from).
//
// H experiments: the on-device JIT helper, an app extension bundled in this app (apps/client/helper/, helper_host.swift)
// that will do the debugger's side of the protocol from the device itself.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define PAGE 0x4000
#define REGION (1u << 20)
#define FIXED_ADDR 0x200000000ull

static int logfd = -1;

static void say(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    write(1, buf, n);
    if (logfd >= 0) {
        write(logfd, buf, n);
        fsync(logfd);
    }
}

__attribute__((noinline)) static uintptr_t jit_cmd(uintptr_t cmd, uintptr_t a, uintptr_t b, uintptr_t c) {
    register uintptr_t x0 __asm__("x0") = a;
    register uintptr_t x1 __asm__("x1") = b;
    register uintptr_t x2 __asm__("x2") = c;
    register uintptr_t x16 __asm__("x16") = cmd;
    __asm__ volatile("brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x16) : "memory");
    return x0;
}

static int traced(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && (kp.kp_proc.p_flag & P_TRACED);
}

static void *prepare(void *addr, size_t len) {
    say("  prepare(%p, 0x%zx)\n", addr, len);
    // Extension: x2 points at the first byte of each page, so the debugger needn't read them.
    unsigned char *firsts = NULL;
    if (addr) {
        firsts = malloc(len / PAGE);
        for (size_t i = 0; i < len / PAGE; i++) firsts[i] = ((unsigned char *)addr)[i * PAGE];
    }
    void *r = (void *)jit_cmd(1, (uintptr_t)addr, len, (uintptr_t)firsts);
    free(firsts);
    say("  prepare -> %p\n", r);
    return r;
}

static void detach(void) {
    jit_cmd(0, 0, 0, 0);
    // The debugger finishes detaching after we resume; wait for it (up to 5 s).
    int ms = 0;
    while (traced() && ms < 5000) {
        usleep(10000);
        ms += 10;
    }
    say("  detached, traced=%d after %d ms\n", traced(), ms);
}

// mov w0, #42 ; ret
static const uint32_t code42[] = {0x52800540, 0xd65f03c0};

static void region_info(const char *what, void *p) {
    vm_address_t a = (vm_address_t)p;
    vm_size_t sz;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                      &cnt, &obj);
    if (kr) {
        say("  %s: vm_region(%p) kr=%d\n", what, p, kr);
        return;
    }
    say("  %s: region %p+0x%llx prot=%d max=%d shared=%d\n", what, (void *)a, (unsigned long long)sz,
        info.protection, info.max_protection, info.shared);
}

// RW alias of [p, p+len), as JIT arenas do.
static void *rw_alias(void *p, size_t len) {
    vm_address_t alias = 0;
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &alias, len, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                (vm_address_t)p, FALSE, &cur, &max, VM_INHERIT_NONE);
    say("  vm_remap alias kr=%d -> %p cur=%d max=%d\n", kr, (void *)alias, cur, max);
    if (kr) return NULL;
    kr = vm_protect(mach_task_self(), alias, len, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    say("  alias protect RW kr=%d\n", kr);
    return kr ? NULL : (void *)alias;
}

static void run(void *code, size_t len) {
    sys_icache_invalidate(code, len);
    say("  calling %p ...\n", code);
    int r = ((int (*)(void))code)();
    say("  RESULT %d (%s)\n", r, r == 42 ? "PASS" : "FAIL");
}

// ---- E1: debugger allocates RX, app writes via alias.
static void e1(void) {
    void *p = prepare(NULL, REGION);
    region_info("prepared", p);
    void *w = rw_alias(p, REGION);
    if (!w) return;
    memcpy(w, code42, sizeof code42);
    detach();
    run(p, REGION);
}

static void *fixed_rx(void) {
    void *p = mmap((void *)FIXED_ADDR, REGION, PROT_READ | PROT_EXEC, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0);
    say("  mmap fixed RX %p -> %p (%s)\n", (void *)FIXED_ADDR, p, p == MAP_FAILED ? strerror(errno) : "ok");
    if (p == MAP_FAILED) {
        // Fall back to RW then RX, in case RX anon mappings are refused outright.
        p = mmap((void *)FIXED_ADDR, REGION, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0);
        say("  mmap fixed RW -> %p (%s)\n", p, p == MAP_FAILED ? strerror(errno) : "ok");
        if (p == MAP_FAILED) return NULL;
        int r = mprotect(p, REGION, PROT_READ | PROT_EXEC);
        say("  mprotect RX = %d (%s)\n", r, r ? strerror(errno) : "ok");
    }
    region_info("fixed", p);
    return p;
}

// ---- E2: app-chosen fixed address, debugger prepares it, app writes via alias.
static void e2(void) {
    void *p = fixed_rx();
    if (!p) return;
    void *q = prepare(p, REGION);
    if (q != p) say("  prepare returned a different address!\n");
    region_info("prepared", p);
    void *w = rw_alias(p, REGION);
    if (!w) return;
    memcpy(w, code42, sizeof code42);
    detach();
    run(p, REGION);
}

// ---- E3: fixed address, prepared, then mprotect RW -> write -> RX (no alias).
static void e3(void) {
    void *p = fixed_rx();
    if (!p) return;
    prepare(p, REGION);
    detach();
    int r = mprotect(p, REGION, PROT_READ | PROT_WRITE);
    say("  mprotect RW = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after RW", p);
    if (r) return;
    memcpy(p, code42, sizeof code42);
    r = mprotect(p, REGION, PROT_READ | PROT_EXEC);
    say("  mprotect RX = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after RX", p);
    run(p, REGION);
}

// ---- E4: the app's own signed __TEXT. 1 MB of filler code that returns 7 until patched.
__asm__(".section __TEXT,__spfill,regular,pure_instructions\n"
        ".p2align 14\n"
        ".globl _sp_fill\n"
        "_sp_fill:\n"
        "mov w0, #7\n"
        "ret\n"
        ".rept 262142\n"
        "nop\n"
        ".endr\n"
        ".text\n");
extern int sp_fill(void);

static int patch_text(void *p) {
    // Mirrors the client's startup code rewrite: the whole range, not just the entry.
    uint32_t *w = p;
    for (size_t i = 0; i < REGION / 4; i++) w[i] = 0xd503201f;  // nop
    memcpy(p, code42, sizeof code42);
    return 0;
}

static kern_return_t copy_rw(void *p) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)p, REGION, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    say("  vm_protect(RW|COPY) kr=%d (%s)\n", kr, mach_error_string(kr));
    return kr;
}

// E4a: app VM_PROT_COPY -> write -> mprotect RX -> debugger prepare -> run.
static void e4a(void) {
    void *p = (void *)sp_fill;
    say("  sp_fill=%p returns %d\n", p, sp_fill());
    region_info("text", p);
    if (copy_rw(p)) return;
    region_info("after COPY", p);
    patch_text(p);
    int r = mprotect(p, REGION, PROT_READ | PROT_EXEC);
    say("  mprotect RX = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after RX", p);
    prepare(p, REGION);
    detach();
    run(p, REGION);
}

// E4b: debugger prepare first -> app RW (plain, then COPY if refused) -> write -> RX -> run.
static void e4b(void) {
    void *p = (void *)sp_fill;
    say("  sp_fill=%p returns %d\n", p, sp_fill());
    prepare(p, REGION);
    region_info("prepared", p);
    detach();
    int r = mprotect(p, REGION, PROT_READ | PROT_WRITE);
    say("  mprotect RW = %d (%s)\n", r, r ? strerror(errno) : "ok");
    if (r && copy_rw(p)) return;
    region_info("after RW", p);
    patch_text(p);
    r = mprotect(p, REGION, PROT_READ | PROT_EXEC);
    say("  mprotect RX = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after RX", p);
    run(p, REGION);
}

// E4d: the shim plan for the client's startup code rewrite. Debugger prepares own __TEXT (pages
// stay RX, max RWX), the app writes through an RW alias (as a dlsym-supplied memcpy would), then runs it.
static void e4d(void) {
    void *p = (void *)sp_fill;
    say("  sp_fill=%p returns %d\n", p, sp_fill());
    prepare(p, REGION);
    region_info("prepared", p);
    void *w = rw_alias(p, REGION);
    if (!w) return;
    patch_text(w);
    region_info("after alias write", p);
    detach();
    run(p, REGION);
}

// ---- E5: timing at the client's scale. A ~44 MB filler in own __TEXT (on the order of the client's
// __TEXT, ~2,800 16 KB pages): prepare, alias write of everything, detach, run.
#define BIG 0x2c10000u
__asm__(".section __TEXT,__spbig,regular,pure_instructions\n"
        ".p2align 14\n"
        ".globl _sp_big\n"
        "_sp_big:\n"
        "mov w0, #7\n"
        "ret\n"
        ".fill 0xb03ffe, 4, 0xd503201f\n"  // BIG / 4 - 2 nops
        ".text\n");
extern int sp_big(void);

static uint64_t fnv(const void *p, size_t len) {
    uint64_t h = 0xcbf29ce484222325;
    for (const uint64_t *q = p, *e = (const void *)((const char *)p + len); q < e; q++) h = (h ^ *q) * 0x100000001b3;
    return h;
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void e5(void) {
    void *p = (void *)sp_big;
    say("  sp_big=%p returns %d\n", p, sp_big());
    uint64_t before = fnv(p, BIG);
    double t = now();
    { time_t w = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&w)); say("  [%s] prepare requested\n", ts); }
    prepare(p, BIG);
    { time_t w = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&w)); say("  [%s] prepare returned\n", ts); }
    say("  prepare took %.2fs (%u pages)\n", now() - t, BIG / PAGE);
    say("  contents %s by prepare\n", fnv(p, BIG) == before ? "unchanged" : "CHANGED");
    region_info("first page", p);
    region_info("middle page", (char *)p + BIG / 2);
    region_info("last page", (char *)p + BIG - PAGE);
    void *w = rw_alias(p, BIG);
    if (!w) return;
    t = now();
    uint32_t *q = w;
    for (size_t i = 0; i < BIG / 4; i++) q[i] = 0xd503201f;
    memcpy(w, code42, sizeof code42);
    // Last instruction pair too, so a stale page at the far end would show up.
    q[BIG / 4 - 2] = code42[0];
    q[BIG / 4 - 1] = code42[1];
    say("  alias write took %.2fs\n", now() - t);
    detach();
    run(p, BIG);
    run((char *)p + BIG - 8, 8);
}

// ---- E6: can the alias be written after detach? Decides whether the shim can detach right after
// its single prepare. E6: prepare, detach, then create the alias and write. E6b: alias before detach.
static void e6(int alias_first) {
    void *p = (void *)sp_fill;
    say("  sp_fill=%p returns %d\n", p, sp_fill());
    prepare(p, REGION);
    void *w = alias_first ? rw_alias(p, REGION) : NULL;
    detach();
    if (!alias_first) w = rw_alias(p, REGION);
    if (!w) return;
    patch_text(w);
    region_info("after alias write", p);
    run(p, REGION);
}

// ---- E7: the real libspSystem shim (shims/system), linked as this app's libSystem the way the
// client's will be. Rewrites the big filler through dlsym-supplied calls, the way the client rewrites
// its own code at startup (the shim services that through an alias mapping), then calls the first and
// last instruction pairs. The shim prepares all of __TEXT in one debugger stop and detaches by itself.
static void e7(void) {
    void *p = (void *)sp_big;
    say("  sp_big=%p returns %d\n", p, sp_big());
    int (*mp)(void *, size_t, int) = dlsym(RTLD_DEFAULT, "mprotect");
    void *(*mc)(void *, const void *, size_t) = dlsym(RTLD_DEFAULT, "memcpy");
    void (*ic)(void *, size_t) = dlsym(RTLD_DEFAULT, "sys_icache_invalidate");
    void *jw = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    say("  dlsym: mprotect=%p (real %p) memcpy=%p (real %p) jit_wp=%p\n", mp, mprotect, mc, memcpy, jw);
    if (jw) say("  FAIL: pthread_jit_write_protect_np visible to dlsym\n");
    uint32_t *src = malloc(BIG);
    for (size_t i = 0; i < BIG / 4; i++) src[i] = 0xd503201f;
    memcpy(src, code42, sizeof code42);
    src[BIG / 4 - 2] = code42[0];
    src[BIG / 4 - 1] = code42[1];
    double t = now();
    int r = mp(p, BIG, PROT_READ | PROT_WRITE | PROT_EXEC);
    say("  mprotect rwx = %d (%s), took %.2fs\n", r, r ? strerror(errno) : "ok", now() - t);
    if (r) return;
    say("  traced=%d after the shim's prepare\n", traced());
    region_info("first page", p);
    mc(p, src, BIG);
    r = mp(p, BIG, PROT_READ | PROT_EXEC);
    say("  mprotect r-x = %d\n", r);
    ic(p, BIG);
    say("  contents %s\n", fnv(p, BIG) == fnv(src, BIG) ? "match" : "DIFFER");
    free(src);
    region_info("first page", p);
    run(p, BIG);
    run((char *)p + BIG - 8, 8);
}

// ---- H1: start the bundled helper extension and ping it (helper_host.swift). Passes when the
// reply comes from another process; also logs whether the helper's sandbox reaches 10.7.0.1:49152.
extern int sp_helper_ping(void (*log)(const char *));

static void say_str(const char *s) { say("%s", s); }

static void h1(void) {
    say("  %s\n", sp_helper_ping(say_str) ? "FAIL" : "PASS");
}

// ---- P1: make a RemotePairing record on the device itself (pair_host.swift).
extern int sp_pair(void (*log)(const char *));

static void p1(void) {
    say("  %s\n", sp_pair(say_str) ? "FAIL" : "PASS");
}

// ---- P2: the same through visionOS's manual pairing service (Settings > General > Remote Devices). It
// waits on a person, so it runs under UIKit (ui_host.swift) and never returns.
extern int sp_pair_manual_ui(void (*log)(const char *));

static void p2(void) {
    sp_pair_manual_ui(say_str);
}

// ---- H2: the helper opens the RemotePairing tunnel through the loopback VPN (idevice) and reports the
// endpoint that worked, TXM, and the developer disk image. Needs Documents/pairingFile.plist.
extern int sp_helper_status(void (*log)(const char *));
// ---- H3, H4: e4d and e7 with the helper as the debugger: it mounts the disk image if none is (from
// Documents/DDI), attaches to this process, services the brk requests and detaches (helper_host.swift).
extern int sp_helper_attach(void (*log)(const char *));
extern int sp_helper_finish(void (*log)(const char *));

static void h2(void) {
    say("  %s\n", sp_helper_status(say_str) ? "FAIL" : "PASS");
}

// ---- H5: misagent through the helper's tunnel: lists the device's profiles and installs
// Documents/spjit-profile.mobileprovision if it's there (the device renewing its own profile).
extern int sp_helper_profiles(void (*log)(const char *));

static void h5(void) {
    say("  %s\n", sp_helper_profiles(say_str) ? "FAIL" : "PASS");
}

// E4c (no debugger needed): what plain calls do to own __TEXT. Doesn't execute anything patched.
static void e4c(void) {
    void *p = (void *)sp_fill;
    region_info("text", p);
    int r = mprotect(p, REGION, PROT_READ | PROT_WRITE | PROT_EXEC);
    say("  mprotect RWX = %d (%s)\n", r, r ? strerror(errno) : "ok");
    r = mprotect(p, REGION, PROT_READ | PROT_WRITE);
    say("  mprotect RW = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after mprotects", p);
    void *j = mmap(NULL, REGION, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_JIT | MAP_ANON | MAP_PRIVATE, -1, 0);
    say("  mmap MAP_JIT rwx -> %p (%s)\n", j, j == MAP_FAILED ? strerror(errno) : "ok");
    r = munmap(p, REGION);
    say("  munmap(text) = %d (%s)\n", r, r ? strerror(errno) : "ok");
    region_info("after munmap", p);
    void *m = mmap(p, REGION, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    say("  mmap hint=text -> %p (%s)\n", m, m == p ? "same" : "different");
    m = mmap(p, REGION, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0);
    say("  mmap FIXED at text -> %p (%s)\n", m, m == MAP_FAILED ? strerror(errno) : "ok");
}

int main(int argc, char **argv) {
    char path[1024];
    snprintf(path, sizeof path, "%s/Documents/spjit.log", getenv("HOME"));
    logfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    // An on-device debugger (StikDebug) launches the app with no arguments, so without one the
    // experiment comes from Documents/spjit-which (put there with devicectl copy to).
    char file_which[16] = "none";
    if (argc < 2) {
        snprintf(path, sizeof path, "%s/Documents/spjit-which", getenv("HOME"));
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
            ssize_t n = read(fd, file_which, sizeof file_which - 1);
            file_which[n > 0 ? n : 0] = 0;
            file_which[strcspn(file_which, " \t\r\n")] = 0;
            close(fd);
        }
    }
    const char *which = argc > 1 ? argv[1] : file_which;
    say("=== %s (pid %d, traced=%d)\n", which, getpid(), traced());
    // H3 and H4 bring their own debugger: the helper, asked to attach before the wait below.
    int helper_debugs = !strcmp(which, "h3") || !strcmp(which, "h4");
    if (helper_debugs && sp_helper_attach(say_str)) {
        say("  FAIL: the helper didn't attach\n=== %s done\n", which);
        return 1;
    }
    // Wait (up to 60 s, as the shim does) for a debugger that attaches after launch: StikDebug's
    // suspended launch doesn't hold the app until its attach lands. The E experiments need one (except
    // e4c), and so do H3 and H4; H1 and H2 don't.
    int needs_debugger = (which[0] == 'e' && strcmp(which, "e4c")) || helper_debugs;
    if (needs_debugger && !traced()) {
        double t = now();
        while (!traced() && now() - t < 60) usleep(10000);
        say("  traced=%d after waiting %.2fs\n", traced(), now() - t);
    }
    if (needs_debugger && !traced()) {
        say("  not traced: a brk would kill us, stopping\n");
        return 1;
    }
    if (!strcmp(which, "e1")) e1();
    else if (!strcmp(which, "e2")) e2();
    else if (!strcmp(which, "e3")) e3();
    else if (!strcmp(which, "e4a")) e4a();
    else if (!strcmp(which, "e4b")) e4b();
    else if (!strcmp(which, "e4c")) e4c();
    else if (!strcmp(which, "e4d")) e4d();
    else if (!strcmp(which, "e5")) e5();
    else if (!strcmp(which, "e6")) e6(0);
    else if (!strcmp(which, "e6b")) e6(1);
    else if (!strcmp(which, "e7")) e7();
    else if (!strcmp(which, "h1")) h1();
    else if (!strcmp(which, "h2")) h2();
    else if (!strcmp(which, "h5")) h5();
    else if (!strcmp(which, "p1")) p1();
    else if (!strcmp(which, "p2")) p2();
    else if (!strcmp(which, "h3")) e4d();
    else if (!strcmp(which, "h4")) e7();
    else say("  unknown experiment\n");
    if (helper_debugs) sp_helper_finish(say_str);
    say("=== %s done\n", which);
    return 0;
}
