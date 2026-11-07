// libspSystem: the client's libSystem on visionOS and iOS. Re-exports the real libSystem and adds what the
// client needs to rewrite its own code at startup under TXM: the shim services that through an alias
// mapping (research/jittest).
//
// The client looks up its memory functions for that rewrite with dlsym(RTLD_DEFAULT, ...). This dlsym:
// - returns NULL for pthread_jit_write_protect_np (no MAP_JIT here), so the client falls back to
//   mprotect and memcpy. The symbol is still exported, because the client also binds it directly.
// - hands out sp_mprotect and sp_memcpy, which turn that into the pattern proven on device: a debugger
//   prepares the client's __TEXT once (pages stay r-x, max rwx), the debugger detaches, and every write
//   goes through an RW alias made with vm_remap. __TEXT is never writable in place, which would kill
//   execute for good.
//
// The launcher's loader (apps/client/spguest.c, spguestlaunch.m) does the prepare, in one stop of the
// on-device JIT helper's before it copies __TEXT in, and names the client and its alias here
// (sp_set_client), so mprotects inside __TEXT just return 0 and memcpys into it go through the alias.
#include <dirent.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <sys/mman.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/utsname.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <TargetConditionals.h>
#include <time.h>
#include <unistd.h>

#define PAGE 0x4000

extern void *sp_real_dlsym(void *handle, const char *sym);  // libspdl.dylib

static void vlog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    os_log(OS_LOG_DEFAULT, "[sp:System] %{public}s", buf);
    write(2, "[sp:System] ", 12);
    write(2, buf, n);
}

// The client's __TEXT, and the RW alias it was copied in through. The client is the game's unchanged
// executable, which the launcher's loader maps itself (apps/client/spguest.c): dyld never lists it, so the
// loader says where it is (sp_set_client), with __TEXT already prepared by the on-device JIT helper.
static uintptr_t text, text_len, text_w;
static int tracing;  // SP_SYSTEM_TRACE=1

static void find_text(const struct mach_header *h, intptr_t slide) {
    const struct mach_header_64 *mh = (const void *)h;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        const struct segment_command_64 *seg = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(seg->segname, "__TEXT")) {
            text = seg->vmaddr + slide;
            text_len = seg->vmsize;
        }
    }
}

// For the other shims' caller offsets.
__attribute__((visibility("default"))) uintptr_t sp_client_text(void) { return text; }

// The client, from the loader that maps it (apps/client/spguest.c), before its first call into a shim. Its
// __TEXT was prepared before the loader copied it in, and `alias` is the RW alias it copied through, so
// sp_mprotect has nothing to prepare and sp_memcpy writes there.
static const char *client_name;  // for crash reports, which list only dyld's images otherwise
__attribute__((visibility("default"))) void sp_set_client(const struct mach_header *h, intptr_t slide, const char *name,
                                                          uintptr_t alias) {
    find_text(h, slide);
    text_w = alias;
    client_name = name;
    vlog("client image %p (not dyld's), __TEXT %p+0x%lx, alias %p\n", (void *)h, (void *)text, text_len, (void *)alias);
}

// dladdr that also knows that client: dyld's dladdr has no image for its frames, so stall stacks, crash
// lines, and exception backtraces showed them as bare addresses. Named by its file, offset from its header
// (__TEXT's start), as dyld names a dlopened client (wow-<flavor>+0x...). The other shims link the real
// libSystem, so they look this up with dlsym and fall back to dladdr.
__attribute__((visibility("default"))) int sp_dladdr(const void *addr, Dl_info *info) {
    if (client_name && (uintptr_t)addr - text < text_len) {
        *info = (Dl_info){.dli_fname = client_name, .dli_fbase = (void *)text};
        return 1;
    }
    return dladdr(addr, info);
}

static int in_text(uintptr_t a, size_t len) { return a >= text && len <= text_len && a - text <= text_len - len; }

static int traced(void) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && (kp.kp_proc.p_flag & P_TRACED);
}

static unsigned long long fnv(const void *p, size_t len) {
    uint64_t h = 0xcbf29ce484222325;
    for (const uint64_t *q = p, *e = (const void *)((const char *)p + (len & ~7ul)); q < e; q++)
        h = (h ^ *q) * 0x100000001b3;
    return h;
}

// Handed out by dlsym as "mprotect".
static int sp_mprotect(void *addr, size_t len, int prot) {
    if (!in_text((uintptr_t)addr, len)) return mprotect(addr, len, prot);
    // No alias: the loader didn't name the client (sp_set_client), so there's nothing to write through.
    if (prot & PROT_WRITE && !text_w) {
        vlog("mprotect(%p, 0x%zx) for writing in __TEXT, but no alias: refused\n", addr, len);
        errno = EACCES;
        return -1;
    }
    // __TEXT stays r-x; writes go through the alias (sp_memcpy).
    vlog("mprotect(%p, 0x%zx, %c%c%c) in __TEXT: no-op\n", addr, len, prot & PROT_READ ? 'r' : '-',
         prot & PROT_WRITE ? 'w' : '-', prot & PROT_EXEC ? 'x' : '-');
    // SP_SYSTEM_CHECKSUM=1: FNV-1a of each range as it's finished, to compare runs.
    if (!(prot & PROT_WRITE) && len > PAGE && getenv("SP_SYSTEM_CHECKSUM")) {
        vlog("checksum %p+0x%zx = %016llx (first page %016llx, rest %016llx)\n", addr, len, fnv(addr, len),
             fnv(addr, PAGE), fnv((char *)addr + PAGE, len - PAGE));
    }
    return 0;
}

// Handed out by dlsym as "memcpy". Writes into __TEXT go to the same offset in the alias.
static void *sp_memcpy(void *dst, const void *src, size_t n) {
    if (text_w && in_text((uintptr_t)dst, n)) {
        memcpy((void *)(text_w + ((uintptr_t)dst - text)), src, n);
        return dst;
    }
    return memcpy(dst, src, n);
}

// The client binds this directly; dlsym hides it. There's no MAP_JIT memory to toggle on visionOS.
void pthread_jit_write_protect_np(int enabled) {
    static int logged;
    if (!logged++) vlog("pthread_jit_write_protect_np(%d) called directly: ignored\n", enabled);
}

// Caveat: the real dlsym sees libspdl as its caller, so RTLD_SELF and RTLD_NEXT would resolve
// relative to libspdl. The client only uses RTLD_DEFAULT and real handles.
void *dlsym(void *handle, const char *sym) {
    if (tracing && sym)
        vlog("+0x%lx dlsym(%s, \"%s\")\n", (uintptr_t)__builtin_return_address(0) - text,
             handle == RTLD_DEFAULT ? "RTLD_DEFAULT" : "handle", sym);
    if (handle == RTLD_DEFAULT) {
        if (!strcmp(sym, "pthread_jit_write_protect_np")) return NULL;
        if (!strcmp(sym, "mprotect")) return (void *)sp_mprotect;
        if (!strcmp(sym, "memcpy")) return (void *)sp_memcpy;
    }
    void *r = sp_real_dlsym(handle, sym);
    if (tracing && sym && !r) vlog("+0x%lx dlsym(\"%s\") -> NULL\n", (uintptr_t)__builtin_return_address(0) - text, sym);
    return r;
}

// ---- Path redirection, and SP_SYSTEM_TRACE=1: log the client's path and file calls and how it exits,
// with the caller's offset in the main executable. The wrappers forward to the real functions,
// looked up by handle: a call to open() from in here would bind to the wrapper itself.

static void *real(const char *name) {
    static const char *paths[] = {"/usr/lib/system/libsystem_kernel.dylib", "/usr/lib/system/libsystem_c.dylib",
                                  "/usr/lib/system/libdyld.dylib", "/usr/lib/system/libsystem_info.dylib"};
    static void *libs[4];
    for (int i = 0; i < 4; i++) {
        if (!libs[i]) libs[i] = dlopen(paths[i], RTLD_NOLOAD | RTLD_LAZY);
        void *p = libs[i] ? sp_real_dlsym(libs[i], name) : NULL;
        if (p) return p;
    }
    __builtin_trap();
}

#define REAL(type, name) \
    static __typeof__(type) fn; \
    if (!fn) fn = (type)real(name)
#define CALLER ((uintptr_t)__builtin_return_address(0) - text)
// Logs one call; keeps errno intact for the caller.
#define TRACE(fmt, ...) \
    do { \
        if (tracing) { \
            int e_ = errno; \
            vlog("+0x%lx " fmt "\n", CALLER, __VA_ARGS__); \
            errno = e_; \
        } \
    } while (0)
#define ERR(failed) ((failed) ? strerror(errno) : "ok")

// The client's install root (Logs/, WTF/, .flavor.info ...) is the parent of its executable's
// directory, and the game data is beside it, in ../.build.info and ../Data. On visionOS the root is
// the read-only bundle container, so paths under it, except inside the bundle itself, are rewritten
// to $SP_SYSTEM_ROOT, by default the app's Documents/<flavor folder> (visible in Files through
// UIFileSharingEnabled), which puts the data in Documents/. The folder (_classic_era_, _anniversary_)
// is $SP_SYSTEM_FLAVOR, set by the flavor launcher (apps/client/launcher.m) before it loads the
// client. That includes chdir, so relative paths follow. The Mac redirects only if SP_SYSTEM_ROOT is
// set. Only the client's own libSystem calls are redirected, not Foundation's.
static char from[PATH_MAX], bundle[PATH_MAX], to[PATH_MAX];
static size_t from_len, bundle_len;

static void login_setup(void);

static void init_redirect(void) {
    const char *env = getenv("SP_SYSTEM_ROOT");
#if TARGET_OS_OSX
    if (!env) return;
#endif
    uint32_t len = sizeof bundle;
    if (((int (*)(char *, uint32_t *))real("_NSGetExecutablePath"))(bundle, &len)) return;
    char *slash = strrchr(bundle, '/');
    if (!slash) return;
    *slash = 0;
    bundle_len = strlen(bundle);
    if (env) strlcpy(to, env, sizeof to);
    else {
        const char *flavor = getenv("SP_SYSTEM_FLAVOR");
        snprintf(to, sizeof to, "%s/Documents/%s", getenv("HOME"), flavor ? flavor : "_classic_era_");
    }
    ((int (*)(const char *, mode_t))real("mkdir"))(to, 0777);
    strlcpy(from, bundle, sizeof from);
    if (!(slash = strrchr(from, '/'))) return;
    *slash = 0;
    from_len = strlen(from);
    vlog("redirecting %s/* (except %s) to %s\n", from, bundle, to);
    login_setup();
}

static const char *redirect(const char *p, char *buf) {
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, (void (*)(void *))init_redirect);
    if (!from_len || !p || strncmp(p, from, from_len) || (p[from_len] && p[from_len] != '/')) return p;
    if (!strncmp(p, bundle, bundle_len) && (!p[bundle_len] || p[bundle_len] == '/')) return p;
    snprintf(buf, PATH_MAX, "%s%s", to, p + from_len);
    return buf;
}

#if !TARGET_OS_OSX
// A stand-in for the Blizzard Agent. With -launcherlogin the client reads the Agent's port from
// /Users/Shared/Battle.net/Agent/Agent.dat (on visionOS the prefix comes out empty) and polls
// GET /agent on 127.0.0.1 about once a second. The real Agent answers every poll from the client
// with 401 and an empty body, and the client logs in anyway; with no Agent
// it never tries. So the first open of Agent.dat starts a loopback listener that gives the same
// answer, and the open gets a file in the container holding its port.
#define AGENT_DAT "/Battle.net/Agent/Agent.dat"
static char agent_dat[PATH_MAX];

static void *agent_serve(void *arg) {
    int ls = (int)(intptr_t)arg;
    ssize_t (*rd)(int, void *, size_t) = real("read");
    ssize_t (*wr)(int, const void *, size_t) = real("write");
    int (*cl)(int) = real("close");
    for (unsigned n = 0;; n++) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) continue;
        char req[2048];
        ssize_t len = rd(c, req, sizeof req - 1);
        if (len > 0 && n < 3) {  // the request line, for the first few
            req[len] = 0;
            req[strcspn(req, "\r\n")] = 0;
            vlog("agent: %s -> 401\n", req);
        }
        // Byte for byte what the Mac's Agent sends (104 B): 401 with a Date header.
        char reply[160], date[64];
        time_t now = time(NULL);
        struct tm tm;
        strftime(date, sizeof date, "%a, %d %b %Y %H:%M:%S GMT", gmtime_r(&now, &tm));
        int rl = snprintf(reply, sizeof reply,
                          "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nDate: %s\r\nConnection: close\r\n\r\n", date);
        wr(c, reply, rl);
        cl(c);
    }
    return NULL;
}

static void agent_start(void *unused) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET,
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t sl = sizeof sa;
    if (ls < 0 || bind(ls, (struct sockaddr *)&sa, sizeof sa) || listen(ls, 8) ||
        getsockname(ls, (struct sockaddr *)&sa, &sl)) {
        vlog("agent: listen failed: %s\n", strerror(errno));
        return;
    }
    snprintf(agent_dat, sizeof agent_dat, "%s/tmp/Agent.dat", getenv("HOME"));
    FILE *(*fo)(const char *, const char *) = real("fopen");
    FILE *f = fo(agent_dat, "w");
    if (!f) {
        vlog("agent: can't write %s: %s\n", agent_dat, strerror(errno));
        agent_dat[0] = 0;
        return;
    }
    fprintf(f, "%u", ntohs(sa.sin_port));
    fclose(f);
    pthread_t t;
    pthread_create(&t, NULL, agent_serve, (void *)(intptr_t)ls);
    pthread_detach(t);
    vlog("agent: stand-in on 127.0.0.1:%u\n", ntohs(sa.sin_port));
}

static const char *agent_redirect(const char *p) {
    if (strcmp(p, AGENT_DAT)) return p;
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, agent_start);
    return agent_dat[0] ? agent_dat : p;
}
#endif

// login.txt (apps/client/splogin.m): the launcher writes it just before the client loads, with the
// Battle.net email and password, and the client never deletes it. So the shim does, zeroed first (best
// effort: flash storage may keep the old blocks), at whichever comes first: the client's close of it (the
// same second it read it), or the process's exit. The exit matters because a client that quits before it
// reads the file (a damaged install's dialog, exit 255 a few seconds in) never opens it, and each such
// launch used to leave one behind. Only the install root's login.txt, found by the open file's path, so a
// relative open after chdir counts too. Its contents are never read here, and nothing about them (not even
// the size) is logged. A signal or SIGKILL ends the process with no exit to hook: the launcher deletes any
// leftover, every game's, at its next start (sp_login_clear).
static char login_txt[PATH_MAX];  // the real path of <install root>/login.txt, once redirecting
static _Atomic int login_fd = -1;
static FILE *_Atomic login_file;
// Set while a delete is under way or done, so the close and the exits after it don't zero or unlink twice
// (and log once). Cleared again when a delete fails, so a later exit tries again.
static atomic_flag login_done = ATOMIC_FLAG_INIT;
// The real calls the delete makes, looked up while the shim learns the install root, not at the delete:
// the crash path (crash_end) runs it with every other thread suspended, maybe one inside dyld holding its
// lock, which a lookup (dlopen, dlsym) would wait on forever. fstat and fsync aren't wrapped here, so they
// bind straight to libSystem.
static int (*login_open)(const char *, int, ...);
static ssize_t (*login_write)(int, const void *, size_t);
static int (*login_close)(int);
static int (*login_unlink)(const char *);

static void login_at_exit(void);

// From init_redirect, once, the first time the client's calls are redirected: after the launcher wrote the
// file and set $SP_SYSTEM_FLAVOR, so the root is the right game's. The launcher itself loads this library
// at its start, long before, and its own exits (a launch that stops before the client loads) are the
// launcher's to clean up after, so the exit hook goes in only here. Registered this late, it also runs
// before the handlers the client registered while it loaded (atexit runs them last in, first out), so one
// of the client's C++ destructors crashing at exit can't skip it.
static void login_setup(void) {
    char root[PATH_MAX];
    if (!((char *(*)(const char *, char *))real("realpath$DARWIN_EXTSN"))(to, root)) return;
    login_open = real("open");
    login_write = real("write");
    login_close = real("close");
    login_unlink = real("unlink");
    snprintf(login_txt, sizeof login_txt, "%s/login.txt", root);
    atexit(login_at_exit);
}

// Zeroes and deletes login.txt. 0 when this call deleted it; an errno when it couldn't (ENOENT: there was
// none: a launch with a relayed token writes none); -1 when there's nothing to do (not redirecting, or
// already deleted). Async-signal-safe apart from the vlog its callers add, for crash_end.
static int login_scrub(void) {
    if (!login_txt[0] || atomic_flag_test_and_set(&login_done)) return -1;
    int fd = login_open(login_txt, O_WRONLY | O_NOFOLLOW);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < (1 << 16)) {
            char zeros[1024] = {0};
            for (off_t left = st.st_size; left > 0; left -= sizeof zeros)
                login_write(fd, zeros, left < (off_t)sizeof zeros ? (size_t)left : sizeof zeros);
            fsync(fd);
        }
        login_close(fd);
    }
    if (login_unlink(login_txt) == 0) return 0;
    int e = errno;
    if (e != ENOENT) atomic_flag_clear(&login_done);
    return e;
}

static int is_login(const char *path, int fd) {
    if (fd < 0 || !path || !login_txt[0]) return 0;  // login_txt: set by redirect(), which the caller ran
    const char *base = strrchr(path, '/');
    if (strcmp(base ? base + 1 : path, "login.txt")) return 0;
    char p[PATH_MAX];
    return ((int (*)(int, int, ...))real("fcntl"))(fd, F_GETPATH, p) == 0 && !strcmp(p, login_txt);
}

static void login_opened(const char *how) { vlog("login.txt: the client opened it (%s)\n", how); }

static void login_closed(void) {
    int e = login_scrub();
    if (e == 0) vlog("login.txt: the client closed it; deleted\n");
    else if (e > 0 && e != ENOENT) vlog("login.txt: the client closed it; couldn't delete it: %s\n", strerror(e));
}

// At the client's exit, _exit, or _Exit (EXIT_CALL), and at any exit of the process (atexit). Silent when
// there was nothing to delete, the usual case: the close got there first.
static void login_exiting(const char *how) {
    int e = login_scrub();
    if (e == 0) vlog("login.txt: still there at %s; deleted\n", how);
    else if (e > 0 && e != ENOENT) vlog("login.txt: still there at %s; couldn't delete it: %s\n", how, strerror(e));
}

static void login_at_exit(void) { login_exiting("the process's exit"); }

int sp_open(const char *path, int flags, ...) __asm__("_open");
int sp_open(const char *path, int flags, ...) {
    REAL(int (*)(const char *, int, ...), "open");
    int mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    char b[PATH_MAX];
    path = redirect(path, b);
#if !TARGET_OS_OSX
    if (path) path = agent_redirect(path);
#endif
    int r = fn(path, flags, mode);
    TRACE("open(\"%s\", 0x%x) = %d %s", path, flags, r, ERR(r < 0));
    if (is_login(path, r)) {
        login_fd = r;
        login_opened("open");
    }
    return r;
}

#define FOPEN(cname, sym) \
    FILE *cname(const char *path, const char *mode) __asm__("_" sym); \
    FILE *cname(const char *path, const char *mode) { \
        REAL(FILE * (*)(const char *, const char *), sym); \
        char b[PATH_MAX]; \
        path = redirect(path, b); \
        FILE *r = fn(path, mode); \
        TRACE("fopen(\"%s\", \"%s\") = %p %s", path, mode, r, ERR(!r)); \
        if (r && is_login(path, fileno(r))) { \
            login_file = r; \
            login_opened("fopen"); \
        } \
        return r; \
    }
FOPEN(sp_fopen, "fopen")
FOPEN(sp_fopen_ext, "fopen$DARWIN_EXTSN")

int sp_fclose(FILE *f) __asm__("_fclose");
int sp_fclose(FILE *f) {
    REAL(int (*)(FILE *), "fclose");
    FILE *login = f;
    int was = f && atomic_compare_exchange_strong(&login_file, &login, NULL);
    int r = fn(f);
    if (was) login_closed();
    return r;
}

// Calls taking one path and returning int. ARGS: the parameters after the path; CALL: those names.
#define PATH_CALL(name, ARGS, CALL, fmt, ...) \
    int sp_##name(const char *p ARGS) __asm__("_" #name); \
    int sp_##name(const char *p ARGS) { \
        REAL(int (*)(const char *p ARGS), #name); \
        char b[PATH_MAX]; \
        p = redirect(p, b); \
        int r = fn(p CALL); \
        TRACE(#name "(\"%s\"" fmt ") = %d %s", p, ##__VA_ARGS__, r, ERR(r < 0)); \
        return r; \
    }
#define COMMA ,
PATH_CALL(mkdir, COMMA mode_t m, COMMA m, ", 0%o", m)
PATH_CALL(stat, COMMA struct stat *st, COMMA st, "")
PATH_CALL(access, COMMA int m, COMMA m, ", %d", m)
PATH_CALL(chdir, , , "")
PATH_CALL(unlink, , , "")
PATH_CALL(rmdir, , , "")

int sp_rename(const char *a, const char *b) __asm__("_rename");
int sp_rename(const char *a, const char *b) {
    REAL(int (*)(const char *, const char *), "rename");
    char ba[PATH_MAX], bb[PATH_MAX];
    a = redirect(a, ba);
    b = redirect(b, bb);
    int r = fn(a, b);
    TRACE("rename(\"%s\", \"%s\") = %d %s", a, b, r, ERR(r < 0));
    return r;
}

DIR *sp_opendir(const char *path) __asm__("_opendir");
DIR *sp_opendir(const char *path) {
    REAL(DIR * (*)(const char *), "opendir");
    char b[PATH_MAX];
    path = redirect(path, b);
    DIR *r = fn(path);
    TRACE("opendir(\"%s\") = %p %s", path, r, ERR(!r));
    return r;
}

char *sp_getcwd(char *buf, size_t len) __asm__("_getcwd");
char *sp_getcwd(char *buf, size_t len) {
    REAL(char *(*)(char *, size_t), "getcwd");
    char *r = fn(buf, len);
    TRACE("getcwd() = \"%s\"", r ? r : "(null)");
    return r;
}

char *sp_realpath(const char *path, char *out) __asm__("_realpath$DARWIN_EXTSN");
char *sp_realpath(const char *path, char *out) {
    REAL(char *(*)(const char *, char *), "realpath$DARWIN_EXTSN");
    char b[PATH_MAX];
    path = redirect(path, b);
    char *r = fn(path, out);
    TRACE("realpath(\"%s\") = \"%s\" %s", path, r ? r : "(null)", ERR(!r));
    return r;
}

int sp_NSGetExecutablePath(char *buf, uint32_t *len) __asm__("__NSGetExecutablePath");
int sp_NSGetExecutablePath(char *buf, uint32_t *len) {
    REAL(int (*)(char *, uint32_t *), "_NSGetExecutablePath");
    int r = fn(buf, len);
    TRACE("_NSGetExecutablePath() = %d \"%s\"", r, r ? "" : buf);
    return r;
}

// POSIX shared memory: the visionOS sandbox refuses shm_open (EPERM). The client only shares these
// regions with itself (ftruncate + mmap MAP_SHARED), which a regular file supports just as well, so
// on EPERM the name becomes a file in $TMPDIR/spshm/ (the app's tmp/ on visionOS).
static const char *shm_path(const char *name, char *buf) {
    snprintf(buf, PATH_MAX, "%s/spshm", getenv("TMPDIR") ?: "/tmp");
    REAL(int (*)(const char *, mode_t), "mkdir");
    fn(buf, 0700);
    size_t n = strlen(buf);
    snprintf(buf + n, PATH_MAX - n, "/%s", name + (*name == '/'));
    for (char *c = buf + n + 1; *c; c++)
        if (*c == '/') *c = '_';
    return buf;
}

int sp_shm_open(const char *name, int flags, ...) __asm__("_shm_open");
int sp_shm_open(const char *name, int flags, ...) {
    REAL(int (*)(const char *, int, ...), "shm_open");
    int mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    int r = fn(name, flags, mode);
    if (r < 0 && errno == EPERM) {
        int (*open_fn)(const char *, int, ...) = real("open");
        char path[PATH_MAX];
        r = open_fn(shm_path(name, path), flags | O_CLOEXEC, mode);
        TRACE("shm_open(\"%s\", 0x%x, 0%o) = %d %s (EPERM; file %s)", name, flags, mode, r, ERR(r < 0), path);
        return r;
    }
    TRACE("shm_open(\"%s\", 0x%x, 0%o) = %d %s", name, flags, mode, r, ERR(r < 0));
    return r;
}

int sp_shm_unlink(const char *name) __asm__("_shm_unlink");
int sp_shm_unlink(const char *name) {
    REAL(int (*)(const char *), "shm_unlink");
    int r = fn(name);
    if (r < 0) {  // EPERM, or ENOENT because shm_open made a file instead
        int (*unlink_fn)(const char *) = real("unlink");
        char path[PATH_MAX];
        int e = errno;
        if (!unlink_fn(shm_path(name, path))) r = 0;
        else errno = e;
    }
    TRACE("shm_unlink(\"%s\") = %d %s", name, r, ERR(r < 0));
    return r;
}

int sp_ftruncate(int fd, off_t len) __asm__("_ftruncate");
int sp_ftruncate(int fd, off_t len) {
    REAL(int (*)(int, off_t), "ftruncate");
    int r = fn(fd, len);
    TRACE("ftruncate(%d, %lld) = %d %s", fd, (long long)len, r, ERR(r < 0));
    return r;
}

int sp_flock(int fd, int op) __asm__("_flock");
int sp_flock(int fd, int op) {
    REAL(int (*)(int, int), "flock");
    int r = fn(fd, op);
    TRACE("flock(%d, 0x%x) = %d %s", fd, op, r, ERR(r < 0));
    return r;
}

// The client's own mmap calls (its startup code rewrite gets the real one from dlsym). Only file-backed and
// shared mappings are logged.
void *sp_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) __asm__("_mmap");
void *sp_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    REAL(void *(*)(void *, size_t, int, int, int, off_t), "mmap");
    void *r = fn(addr, len, prot, flags, fd, off);
    if (fd >= 0 || flags & MAP_SHARED)
        TRACE("mmap(%p, 0x%zx, %d, 0x%x, %d, 0x%llx) = %p %s", addr, len, prot, flags, fd, (long long)off, r,
              ERR(r == MAP_FAILED));
    return r;
}

// msync: the client syncs its game data index (the key mapping of Data/data) in 4 KB ranges, and a range
// that doesn't start on a 16 KB page is refused (EINVAL) on every Apple silicon system, the Mac included.
// The Mac's complete store rarely needs it (Tact.log's "Failed to synchronize KMT data" a few dozen times a
// session); a device streaming into an empty store syncs constantly, every sync failed, and Retail on an
// iPhone never got past its download bar (53 minutes, 15 GB). Start the range at its page: syncing
// the rest of that page is harmless.
int sp_msync(void *addr, size_t len, int flags) __asm__("_msync");
int sp_msync(void *addr, size_t len, int flags) {
    REAL(int (*)(void *, size_t, int), "msync");
    uintptr_t off = (uintptr_t)addr & vm_page_mask;
    int r = fn((char *)addr - off, len + off, flags);
    if (r < 0 || off) TRACE("msync(%p, 0x%zx, 0x%x) = %d %s (rounded by 0x%lx)", addr, len, flags, r, ERR(r < 0), (unsigned long)off);
    return r;
}

// While tracing, the client's signal handlers are wrapped so a delivered signal is logged (with the
// fault address and pc/lr offsets) before the client's handler runs.
// Then pc, lr and a frame-pointer walk, each as image+offset (and the nearest exported symbol), so
// faults in system libraries can be read without device symbols. dladdr isn't async-signal-safe;
// this is diagnostics on the way to a crash.
static struct sigaction client_act[NSIG];

static void log_frame(int i, uintptr_t pc) {
    Dl_info info;
    if (sp_dladdr((void *)pc, &info) && info.dli_fname)
        vlog("    %2d %s+0x%lx (%s)\n", i, strrchr(info.dli_fname, '/') + 1, pc - (uintptr_t)info.dli_fbase,
             info.dli_sname ? info.dli_sname : "?");
    else
        vlog("    %2d 0x%lx\n", i, pc);
}

static void trace_signal(int sig, siginfo_t *si, void *ctx) {
    _STRUCT_MCONTEXT64 *mc = ((ucontext_t *)ctx)->uc_mcontext;
    vlog("signal %d (code %d) addr %p at pc +0x%lx lr +0x%lx\n", sig, si->si_code, si->si_addr,
         (unsigned long)(__darwin_arm_thread_state64_get_pc(mc->__ss) - text),
         (unsigned long)(__darwin_arm_thread_state64_get_lr(mc->__ss) - text));
    log_frame(0, __darwin_arm_thread_state64_get_pc(mc->__ss));
    log_frame(1, __darwin_arm_thread_state64_get_lr(mc->__ss) & 0x0000000fffffffffUL);
    uintptr_t *fp = (uintptr_t *)__darwin_arm_thread_state64_get_fp(mc->__ss);
    for (int i = 2; fp && !((uintptr_t)fp & 7) && i < 40; i++) {
        uintptr_t frame[2];
        vm_size_t got;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame, (vm_address_t)frame, &got) ||
            !frame[1])
            break;
        log_frame(i, frame[1] & 0x0000000fffffffffUL);  // strip the PAC signature
        if (frame[0] <= (uintptr_t)fp) break;
        fp = (uintptr_t *)frame[0];
    }
    struct sigaction *a = &client_act[sig];
    if (a->sa_flags & SA_SIGINFO) a->sa_sigaction(sig, si, ctx);
    else if (a->sa_handler != SIG_DFL && a->sa_handler != SIG_IGN) a->sa_handler(sig);
}

int sp_sigaction(int sig, const struct sigaction *act, struct sigaction *old) __asm__("_sigaction");
int sp_sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    REAL(int (*)(int, const struct sigaction *, struct sigaction *), "sigaction");
    struct sigaction prev = sig > 0 && sig < NSIG ? client_act[sig] : (struct sigaction){0};
    struct sigaction wrapped;
    int wrap = tracing && act && sig > 0 && sig < NSIG && act->sa_handler != SIG_DFL && act->sa_handler != SIG_IGN;
    if (wrap) {
        wrapped = *act;
        wrapped.sa_sigaction = trace_signal;
        wrapped.sa_flags |= SA_SIGINFO;
    }
    int r = fn(sig, wrap ? &wrapped : act, old);
    if (!r && act && sig > 0 && sig < NSIG) client_act[sig] = *act;
    if (!r && old && old->sa_sigaction == trace_signal) *old = prev;
    if (act) TRACE("sigaction(%d, handler %p, flags 0x%x) = %d", sig, (void *)act->sa_handler, act->sa_flags, r);
    return r;
}

int sp_proc_pidpath(int pid, void *buf, uint32_t len) __asm__("_proc_pidpath");
int sp_proc_pidpath(int pid, void *buf, uint32_t len) {
    REAL(int (*)(int, void *, uint32_t), "proc_pidpath");
    int r = fn(pid, buf, len);
    TRACE("proc_pidpath(%d) = %d \"%s\"", pid, r, r > 0 ? (char *)buf : "");
    return r;
}

// Network: name lookups and connects, to see how far the Battle.net login gets.
static const char *sa_str(const struct sockaddr *sa, char *buf, size_t len) {
    char host[INET6_ADDRSTRLEN] = "?";
    int port = 0;
    if (sa && sa->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const void *)sa;
        inet_ntop(AF_INET, &in->sin_addr, host, sizeof host);
        port = ntohs(in->sin_port);
    } else if (sa && sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in = (const void *)sa;
        inet_ntop(AF_INET6, &in->sin6_addr, host, sizeof host);
        port = ntohs(in->sin6_port);
    } else {
        snprintf(buf, len, "(family %d)", sa ? sa->sa_family : -1);
        return buf;
    }
    snprintf(buf, len, "%s port %d", host, port);
    return buf;
}

int sp_getaddrinfo(const char *host, const char *serv, const struct addrinfo *hints, struct addrinfo **res)
    __asm__("_getaddrinfo");
int sp_getaddrinfo(const char *host, const char *serv, const struct addrinfo *hints, struct addrinfo **res) {
    REAL(int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **), "getaddrinfo");
    int r = fn(host, serv, hints, res);
    char a[80] = "";
    if (!r && res && *res) sa_str((*res)->ai_addr, a, sizeof a);
    TRACE("getaddrinfo(\"%s\", \"%s\") = %d %s %s", host ?: "", serv ?: "", r, r ? gai_strerror(r) : "ok", a);
    return r;
}

// Sockets the client connected: their next calls are logged too, up to a limit per connection.
static _Atomic unsigned char watched[1024];  // calls left to log, per fd
#define WATCH_CALLS 40

static int watching(int fd) {
    if (!tracing || fd < 0 || fd >= 1024 || !watched[fd]) return 0;
    watched[fd]--;
    return 1;
}

int sp_connect(int fd, const struct sockaddr *sa, socklen_t len) __asm__("_connect");
int sp_connect(int fd, const struct sockaddr *sa, socklen_t len) {
    REAL(int (*)(int, const struct sockaddr *, socklen_t), "connect");
    int r = fn(fd, sa, len);
    char a[80];
    TRACE("connect(%d, %s) = %d %s", fd, sa_str(sa, a, sizeof a), r, ERR(r < 0));
    if (fd >= 0 && fd < 1024) watched[fd] = WATCH_CALLS;
    return r;
}

// Options are set before connect, so these are all logged (up to a limit).
int sp_setsockopt(int fd, int level, int name, const void *val, socklen_t len) __asm__("_setsockopt");
int sp_setsockopt(int fd, int level, int name, const void *val, socklen_t len) {
    REAL(int (*)(int, int, int, const void *, socklen_t), "setsockopt");
    int r = fn(fd, level, name, val, len);
    static _Atomic int n;
    if (n++ < 100)
        TRACE("setsockopt(%d, 0x%x, 0x%x, %d bytes: %d) = %d %s", fd, level, name, len,
              val && len >= 4 ? *(const int *)val : -1, r, ERR(r < 0));
    return r;
}

int sp_getsockopt(int fd, int level, int name, void *val, socklen_t *len) __asm__("_getsockopt");
int sp_getsockopt(int fd, int level, int name, void *val, socklen_t *len) {
    REAL(int (*)(int, int, int, void *, socklen_t *), "getsockopt");
    int r = fn(fd, level, name, val, len);
    if (watching(fd))
        TRACE("getsockopt(%d, 0x%x, 0x%x) = %d %s, value %d", fd, level, name, r, ERR(r < 0),
              !r && val && len && *len >= 4 ? *(int *)val : -1);
    return r;
}

#define IO_CALL(name, ...) \
    ssize_t sp_##name(int fd, __VA_ARGS__) __asm__("_" #name); \
    ssize_t sp_##name(int fd, __VA_ARGS__)
IO_CALL(send, const void *buf, size_t len, int flags) {
    REAL(ssize_t (*)(int, const void *, size_t, int), "send");
    ssize_t r = fn(fd, buf, len, flags);
    if (watching(fd)) TRACE("send(%d, %zu, 0x%x) = %zd %s", fd, len, flags, r, ERR(r < 0));
    return r;
}
IO_CALL(recv, void *buf, size_t len, int flags) {
    REAL(ssize_t (*)(int, void *, size_t, int), "recv");
    ssize_t r = fn(fd, buf, len, flags);
    if (watching(fd)) TRACE("recv(%d, %zu, 0x%x) = %zd %s", fd, len, flags, r, ERR(r < 0));
    return r;
}
IO_CALL(sendto, const void *buf, size_t len, int flags, const struct sockaddr *sa, socklen_t salen) {
    REAL(ssize_t (*)(int, const void *, size_t, int, const struct sockaddr *, socklen_t), "sendto");
    ssize_t r = fn(fd, buf, len, flags, sa, salen);
    if (watching(fd)) TRACE("sendto(%d, %zu, 0x%x) = %zd %s", fd, len, flags, r, ERR(r < 0));
    return r;
}
IO_CALL(recvfrom, void *buf, size_t len, int flags, struct sockaddr *sa, socklen_t *salen) {
    REAL(ssize_t (*)(int, void *, size_t, int, struct sockaddr *, socklen_t *), "recvfrom");
    ssize_t r = fn(fd, buf, len, flags, sa, salen);
    if (watching(fd)) TRACE("recvfrom(%d, %zu, 0x%x) = %zd %s", fd, len, flags, r, ERR(r < 0));
    return r;
}

IO_CALL(read, void *buf, size_t len) {
    REAL(ssize_t (*)(int, void *, size_t), "read");
    ssize_t r = fn(fd, buf, len);
    if (watching(fd)) TRACE("read(%d, %zu) = %zd %s", fd, len, r, ERR(r < 0));
    return r;
}
IO_CALL(write, const void *buf, size_t len) {
    REAL(ssize_t (*)(int, const void *, size_t), "write");
    ssize_t r = fn(fd, buf, len);
    if (watching(fd)) TRACE("write(%d, %zu) = %zd %s", fd, len, r, ERR(r < 0));
    return r;
}

IO_CALL(writev, const struct iovec *iov, int n) {
    REAL(ssize_t (*)(int, const struct iovec *, int), "writev");
    ssize_t r = fn(fd, iov, n);
    if (watching(fd)) TRACE("writev(%d, %d iovecs) = %zd %s", fd, n, r, ERR(r < 0));
    return r;
}
IO_CALL(sendmsg, const struct msghdr *msg, int flags) {
    REAL(ssize_t (*)(int, const struct msghdr *, int), "sendmsg");
    ssize_t r = fn(fd, msg, flags);
    if (watching(fd)) TRACE("sendmsg(%d, 0x%x) = %zd %s", fd, flags, r, ERR(r < 0));
    return r;
}
IO_CALL(recvmsg, struct msghdr *msg, int flags) {
    REAL(ssize_t (*)(int, struct msghdr *, int), "recvmsg");
    ssize_t r = fn(fd, msg, flags);
    if (watching(fd)) TRACE("recvmsg(%d, 0x%x) = %zd %s", fd, flags, r, ERR(r < 0));
    return r;
}

int sp_shutdown(int fd, int how) __asm__("_shutdown");
int sp_shutdown(int fd, int how) {
    REAL(int (*)(int, int), "shutdown");
    int r = fn(fd, how);
    if (watching(fd)) TRACE("shutdown(%d, %d) = %d %s", fd, how, r, ERR(r < 0));
    return r;
}

int sp_close(int fd) __asm__("_close");
int sp_close(int fd) {
    REAL(int (*)(int), "close");
    int w = watching(fd);
    int login = fd;
    int was = fd >= 0 && atomic_compare_exchange_strong(&login_fd, &login, -1);
    int r = fn(fd);
    if (was) login_closed();
    if (w) {
        TRACE("close(%d) = %d %s", fd, r, ERR(r < 0));
        watched[fd] = 0;
    }
    return r;
}

// Machine identity calls, logged while tracing to compare what the client reads on the Mac and on
// the headset. Observation only: values pass through unchanged.
// Logged as size + hash; plain only for numbers and a few model/OS strings. Calls from the client
// only (traced() uses sysctl too).
#define FROM_CLIENT in_text((uintptr_t)__builtin_return_address(0), 1)

static unsigned ihash(const void *p, size_t len) {
    unsigned h = 2166136261u;
    for (size_t i = 0; i < len; i++) h = (h ^ ((const unsigned char *)p)[i]) * 16777619u;
    return h;
}

static const char *plain_sysctls[] = {"hw.model", "hw.machine", "hw.product", "hw.target", "kern.ostype",
                                      "kern.osrelease", "kern.osversion", "kern.osproductversion",
                                      "kern.version", "machdep.cpu.brand_string", NULL};

static void sysctl_value(char *out, size_t outlen, const char *name, const void *val, size_t len) {
    if (!val) {
        snprintf(out, outlen, "size %zu", len);
        return;
    }
    for (const char **n = plain_sysctls; *n; n++)
        if (!strcmp(name, *n)) {
            snprintf(out, outlen, "\"%.*s\"", (int)strnlen(val, len), (const char *)val);
            return;
        }
    int str = len > 1 && ((const char *)val)[len - 1] == 0 && strlen(val) == len - 1;
    if (!str && len == 4) snprintf(out, outlen, "%d", *(const int *)val);
    else if (!str && len == 8 && strcmp(name, "kern.uuid")) snprintf(out, outlen, "%lld", *(const long long *)val);
    else snprintf(out, outlen, "%s %zu B #%08x", str ? "string" : "data", len, ihash(val, len));
}

// "a.b.c" for a MIB, through the kernel's undocumented {0, 1} name lookup; numbers if that fails.
static void mib_name(const int *mib, u_int n, char *out, size_t outlen) {
    REAL(int (*)(int *, u_int, void *, size_t *, void *, size_t), "sysctl");
    int q[CTL_MAXNAME + 2] = {0, 1};
    size_t len = outlen;
    if (n <= CTL_MAXNAME) {
        memcpy(q + 2, mib, n * sizeof *mib);
        if (fn(q, n + 2, out, &len, NULL, 0) == 0) return;
    }
    size_t o = 0;
    for (u_int i = 0; i < n && o < outlen; i++) o += snprintf(out + o, outlen - o, "%s%d", i ? "." : "", mib[i]);
}

int sp_sysctl(int *mib, u_int n, void *old, size_t *oldlen, void *new, size_t newlen) __asm__("_sysctl");
int sp_sysctl(int *mib, u_int n, void *old, size_t *oldlen, void *new, size_t newlen) {
    REAL(int (*)(int *, u_int, void *, size_t *, void *, size_t), "sysctl");
    int r = fn(mib, n, old, oldlen, new, newlen);
    if (tracing && FROM_CLIENT) {
        int e = errno;
        char name[128], v[160] = "";
        mib_name(mib, n, name, sizeof name);
        if (!r && oldlen) sysctl_value(v, sizeof v, name, old, *oldlen);
        TRACE("ident: sysctl(%s) = %d %s %s", name, r, ERR(r < 0), v);
        errno = e;
    }
    return r;
}

int sp_sysctlbyname(const char *name, void *old, size_t *oldlen, void *new, size_t newlen) __asm__("_sysctlbyname");
int sp_sysctlbyname(const char *name, void *old, size_t *oldlen, void *new, size_t newlen) {
    REAL(int (*)(const char *, void *, size_t *, void *, size_t), "sysctlbyname");
    int r = fn(name, old, oldlen, new, newlen);
    if (tracing && FROM_CLIENT) {
        int e = errno;
        char v[160] = "";
        if (!r && oldlen) sysctl_value(v, sizeof v, name, old, *oldlen);
        TRACE("ident: sysctlbyname(\"%s\") = %d %s %s", name, r, ERR(r < 0), v);
        errno = e;
    }
    return r;
}

// Interface names and address families; addresses (incl. link-layer/MAC) as hashes.
int sp_getifaddrs(struct ifaddrs **out) __asm__("_getifaddrs");
int sp_getifaddrs(struct ifaddrs **out) {
    REAL(int (*)(struct ifaddrs **), "getifaddrs");
    int r = fn(out);
    if (tracing && FROM_CLIENT) {
        int e = errno, count = 0;
        for (struct ifaddrs *i = r ? NULL : *out; i; i = i->ifa_next) count++;
        TRACE("ident: getifaddrs() = %d %s, %d entries", r, ERR(r < 0), count);
        for (struct ifaddrs *i = r ? NULL : *out; i; i = i->ifa_next) {
            const struct sockaddr *a = i->ifa_addr;
            const void *bytes = NULL;
            size_t len = 0;
            if (a && a->sa_family == AF_INET) bytes = &((const struct sockaddr_in *)(const void *)a)->sin_addr, len = 4;
            else if (a && a->sa_family == AF_INET6) bytes = &((const struct sockaddr_in6 *)(const void *)a)->sin6_addr, len = 16;
            else if (a && a->sa_family == AF_LINK) {
                const struct sockaddr_dl *d = (const void *)a;
                bytes = LLADDR(d), len = d->sdl_alen;
            }
            vlog("  ident: if %s flags 0x%x family %d addr %zu B #%08x\n", i->ifa_name, i->ifa_flags,
                 a ? a->sa_family : -1, len, len ? ihash(bytes, len) : 0);
        }
        errno = e;
    }
    return r;
}

int sp_gethostname(char *name, size_t len) __asm__("_gethostname");
int sp_gethostname(char *name, size_t len) {
    REAL(int (*)(char *, size_t), "gethostname");
    int r = fn(name, len);
    if (FROM_CLIENT)
        TRACE("ident: gethostname() = %d %s, %zu chars #%08x", r, ERR(r < 0), r ? 0 : strnlen(name, len),
              r ? 0 : ihash(name, strnlen(name, len)));
    return r;
}

int sp_uname(struct utsname *u) __asm__("_uname");
int sp_uname(struct utsname *u) {
    REAL(int (*)(struct utsname *), "uname");
    int r = fn(u);
    if (!r && FROM_CLIENT)
        TRACE("ident: uname() = %s %s %s, nodename %zu chars #%08x", u->sysname, u->release, u->machine,
              strlen(u->nodename), ihash(u->nodename, strlen(u->nodename)));
    return r;
}

int sp_statfs(const char *path, struct statfs *b) __asm__("_statfs");
int sp_statfs(const char *path, struct statfs *b) {
    REAL(int (*)(const char *, struct statfs *), "statfs");
    int r = fn(path, b);
    if (FROM_CLIENT)
        TRACE("ident: statfs(\"%s\") = %d %s, %s on %s, fsid #%08x", path, r, ERR(r < 0), r ? "" : b->f_fstypename,
              r ? "" : b->f_mntonname, r ? 0 : ihash(&b->f_fsid, sizeof b->f_fsid));
    return r;
}

int sp_ioctl(int fd, unsigned long req, ...) __asm__("_ioctl");
int sp_ioctl(int fd, unsigned long req, ...) {
    REAL(int (*)(int, unsigned long, ...), "ioctl");
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    int r = fn(fd, req, arg);
    if (FROM_CLIENT) TRACE("ident: ioctl(%d, 0x%lx) = %d %s", fd, req, r, ERR(r < 0));
    return r;
}

unsigned sp_if_nametoindex(const char *name) __asm__("_if_nametoindex");
unsigned sp_if_nametoindex(const char *name) {
    REAL(unsigned (*)(const char *), "if_nametoindex");
    unsigned r = fn(name);
    if (FROM_CLIENT) TRACE("ident: if_nametoindex(\"%s\") = %u", name, r);
    return r;
}

// The client's exits. Each deletes a login.txt still there first: _exit and _Exit skip atexit handlers,
// and exit (the client's own fatal-error path, its "damaged installation" dialog's) gets it gone before
// the client's destructors, any of which could crash or hang, run.
#define EXIT_CALL(name, sym) \
    __attribute__((noreturn)) void sp_##name(int status) __asm__(sym); \
    void sp_##name(int status) { \
        REAL(void (*)(int), #name); \
        TRACE(#name "(%d)", status); \
        login_exiting("the client's " #name "()"); \
        fn(status); \
        __builtin_unreachable(); \
    }
EXIT_CALL(exit, "_exit")
EXIT_CALL(_exit, "__exit")
EXIT_CALL(_Exit, "__Exit")

// Crash reports. The client's own Mach exception handler catches a crash, suspends every thread and
// then never finishes on visionOS: the app freezes (and its audio with it) with nothing logged, since
// a suspended thread may hold stdio's or dyld's lock. The handler's first step is task_threads, so
// that call, if another thread is stopped on a fault, logs every thread straight to fd 2 (registers,
// fault address, stack as image + offset from an image list snapshot), then ends the process 10 s later.
// Each image is listed by its __TEXT's range, and a frame is named by the image whose __TEXT holds it, or
// as a bare address. Taking the nearest image start below a frame instead named the client's frames
// libspAppKit+<hundreds of MB> (an iPad's report): the client wasn't in the snapshot. Dlopened after
// every system library, it's last in dyld's list, which the old 1024 entries may not have reached, so
// it's named from `text` (found when it loaded) before the list is looked at, and the list is longer.
#define CRASH_IMAGES 4096
static struct { uintptr_t start, len; const char *name; } crash_images[CRASH_IMAGES];
static uint32_t crash_nimages;

// An image's __TEXT, as its address and size. The header is __TEXT's first bytes (file offset 0), so the
// slide is the header's address less the segment's vmaddr, for a shared-cache library too. Reads only
// the load commands: async-signal-safe.
static int image_text(const struct mach_header *h, uintptr_t *start, uintptr_t *len) {
    const struct mach_header_64 *mh = (const void *)h;
    if (!mh || mh->magic != MH_MAGIC_64) return 0;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        const struct segment_command_64 *seg = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(seg->segname, "__TEXT")) {
            *start = (uintptr_t)h;
            *len = seg->vmsize;
            return 1;
        }
    }
    return 0;
}

static void crash_say(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    write(2, buf, n < (int)sizeof buf ? n : (int)sizeof buf - 1);
}

// A frame as client+offset (into its __TEXT, as the handler's own line and the other shims' caller
// offsets are), image+offset (into the image's __TEXT, its header), or a bare address when no image
// holds it (generated code, a stale frame pointer).
static void crash_frame(int i, uintptr_t pc) {
    if (text_len && pc - text < text_len) {
        crash_say("    %2d client+0x%lx\n", i, pc - text);
        return;
    }
    for (uint32_t k = 0; k < crash_nimages; k++)
        if (pc - crash_images[k].start < crash_images[k].len) {
            const char *slash = strrchr(crash_images[k].name, '/');
            crash_say("    %2d %s+0x%lx\n", i, slash ? slash + 1 : crash_images[k].name, pc - crash_images[k].start);
            return;
        }
    crash_say("    %2d 0x%lx\n", i, pc);
}

// ESR of a thread stopped on a fault (exception class other than a syscall), else 0.
static uint32_t crash_fault(thread_act_t t, uint64_t *far) {
    arm_exception_state64_t ex;
    mach_msg_type_number_t count = ARM_EXCEPTION_STATE64_COUNT;
    if (thread_get_state(t, ARM_EXCEPTION_STATE64, (thread_state_t)&ex, &count) || !ex.__esr) return 0;
    if (ex.__esr >> 26 == 0x15) return 0;  // SVC: a thread waiting in the kernel
    *far = ex.__far;
    return ex.__esr;
}

static void crash_stack(thread_act_t t) {
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_suspend(t) != KERN_SUCCESS) return;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        uint64_t far;
        uint32_t esr = crash_fault(t, &far);
        if (esr) crash_say("    FAULT: far 0x%llx esr 0x%x\n", far, esr);
        // x1 as a string too: in objc_msgSend it's the selector.
        char sel[64];
        vm_size_t got;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)st.__x[1], sizeof sel - 1, (vm_address_t)sel, &got)) sel[0] = 0;
        sel[sizeof sel - 1] = 0;
        for (int i = 0; sel[i]; i++)
            if (sel[i] < 0x20 || sel[i] > 0x7e) { sel[0] = 0; break; }
        crash_say("    x0 0x%llx x1 0x%llx '%s' x2 0x%llx\n", st.__x[0], st.__x[1], sel, st.__x[2]);
        int n = 0;
        crash_frame(n++, (uintptr_t)arm_thread_state64_get_pc(st));
        crash_frame(n++, (uintptr_t)arm_thread_state64_get_lr(st));
        uintptr_t *fp = (uintptr_t *)arm_thread_state64_get_fp(st);
        for (; fp && n < 40 && !((uintptr_t)fp & 7); fp = (uintptr_t *)fp[0]) {
            uintptr_t frame[2];
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame, (vm_address_t)frame, &got)) break;
            if (!frame[1]) break;
            crash_frame(n++, frame[1]);
            if (frame[0] <= (uintptr_t)fp) break;
        }
    }
    thread_resume(t);
}

static void *crash_end(void *arg) {
    sleep(10);
    // A crash before the client read login.txt would leave it: no exit, so no atexit. Errno as a number,
    // since strerror isn't safe here.
    int e = login_scrub();
    if (e == 0) crash_say("[sp:System] crash: login.txt was still there; deleted\n");
    else if (e > 0 && e != ENOENT) crash_say("[sp:System] crash: login.txt was still there; couldn't delete it: errno %d\n", e);
    crash_say("[sp:System] crash: ending the process\n");
    REAL(void (*)(int), "_exit");
    fn(1);
    return NULL;
}

kern_return_t sp_task_threads(task_t task, thread_act_array_t *list, mach_msg_type_number_t *count)
    __asm__("_task_threads");
kern_return_t sp_task_threads(task_t task, thread_act_array_t *list, mach_msg_type_number_t *count) {
    REAL(kern_return_t (*)(task_t, thread_act_array_t *, mach_msg_type_number_t *), "task_threads");
    kern_return_t r = fn(task, list, count);
    static atomic_flag once = ATOMIC_FLAG_INIT;
    if (r || !FROM_CLIENT || task != mach_task_self()) return r;
    thread_act_t self = mach_thread_self();
    int crashed = 0;
    uint64_t far;
    for (mach_msg_type_number_t i = 0; i < *count && !crashed; i++)
        crashed = (*list)[i] != self && crash_fault((*list)[i], &far);
    if (crashed && !atomic_flag_test_and_set(&once)) {
        uint32_t n = _dyld_image_count();
        crash_nimages = 0;
        for (uint32_t k = 0; k < n && crash_nimages < CRASH_IMAGES; k++) {
            const char *name = _dyld_get_image_name(k);
            if (name && image_text(_dyld_get_image_header(k), &crash_images[crash_nimages].start, &crash_images[crash_nimages].len))
                crash_images[crash_nimages++].name = name;
        }
        if (client_name && crash_nimages < CRASH_IMAGES) {
            crash_images[crash_nimages].start = text;
            crash_images[crash_nimages].len = text_len;
            crash_images[crash_nimages++].name = client_name;
        }
        crash_say("[sp:System] crash: the client's exception handler (+0x%lx) is running; %u threads:\n", CALLER, *count);
        if (n > CRASH_IMAGES) crash_say("[sp:System] crash: only the first %u of %u images are listed\n", CRASH_IMAGES, n);
        for (mach_msg_type_number_t i = 0; i < *count; i++) {
            if ((*list)[i] == self) continue;
            crash_say("  thread %u:\n", i);
            crash_stack((*list)[i]);
        }
        pthread_t t;
        pthread_create(&t, NULL, crash_end, NULL);
    }
    mach_port_deallocate(mach_task_self(), self);
    return r;
}

__attribute__((noreturn)) void sp_abort(void) __asm__("_abort");
void sp_abort(void) {
    REAL(void (*)(void), "abort");
    TRACE("abort()%s", "");
    fn();
    __builtin_unreachable();
}

// While tracing, every Objective-C exception is logged as it's thrown (libobjc's preprocessor hook,
// looked up at run time so libspSystem doesn't link libobjc).
typedef void *(*objc_preprocessor)(void *exc);
static objc_preprocessor next_preprocessor;

static void *log_exception(void *exc) {
    static void *(*msg)(void *, void *);
    static void *(*sel)(const char *);
    if (!msg) {
        void *objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOLOAD | RTLD_LAZY);
        msg = sp_real_dlsym(objc, "objc_msgSend");
        sel = sp_real_dlsym(objc, "sel_registerName");
    }
    void *desc = msg(exc, sel("description"));
    const char *s = desc ? ((const char *(*)(void *, void *))msg)(desc, sel("UTF8String")) : NULL;
    vlog("objc exception thrown: %s\n", s ? s : "(no description)");
    // Where from: image + offset per frame (the client's frames show as wow-<flavor>+0x...).
    void *pcs[16];
    int n = backtrace(pcs, 16);
    for (int i = 1; i < n; i++) {
        Dl_info info;
        if (sp_dladdr(pcs[i], &info) && info.dli_fname)
            vlog("    %2d %s+0x%lx %s\n", i, strrchr(info.dli_fname, '/') + 1,
                 (unsigned long)((char *)pcs[i] - (char *)info.dli_fbase), info.dli_sname ? info.dli_sname : "");
        else
            vlog("    %2d %p\n", i, pcs[i]);
    }
    return next_preprocessor ? next_preprocessor(exc) : exc;
}

#if !TARGET_OS_OSX
// stderr also goes to Documents/spconsole.log, so a run's log can be fetched from the device even when
// devicectl's --console capture misses it. Each line in the file starts with the local time. The last
// 5 launches are kept (spconsole.1.log is the one before). A thread copies a pipe that replaces fd 2
// to both the original stderr and the file. A crash can lose what's still in the pipe.
static int console_out = -1, console_file = -1;

static void *console_tee(void *pipe_fd) {
    char buf[4096], stamp[16];
    int line_start = 1;
    for (;;) {
        ssize_t n = read((int)(intptr_t)pipe_fd, buf, sizeof buf);
        if (n <= 0) return NULL;
        write(console_out, buf, n);
        for (ssize_t i = 0; i < n;) {
            if (line_start) {
                time_t now = time(NULL);
                struct tm tm;
                write(console_file, stamp, strftime(stamp, sizeof stamp, "%H:%M:%S ", localtime_r(&now, &tm)));
            }
            char *nl = memchr(buf + i, '\n', n - i);
            ssize_t end = nl ? nl - buf + 1 : n;
            write(console_file, buf + i, end - i);
            line_start = nl != NULL;
            i = end;
        }
    }
}

static void console_tee_start(void) {
    char path[PATH_MAX];
    char from[PATH_MAX];
    for (int i = 4; i >= 0; i--) {
        snprintf(from, sizeof from, i ? "%s/Documents/spconsole.%d.log" : "%s/Documents/spconsole.log", getenv("HOME"), i);
        snprintf(path, sizeof path, "%s/Documents/spconsole.%d.log", getenv("HOME"), i + 1);
        ((int (*)(const char *, const char *))real("rename"))(from, path);
    }
    snprintf(path, sizeof path, "%s/Documents/spconsole.log", getenv("HOME"));
    console_file = ((int (*)(const char *, int, ...))real("open"))(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int fds[2];
    if (console_file < 0 || pipe(fds)) return;
    console_out = dup(2);
    dup2(fds[1], 2);
    close(fds[1]);
    pthread_t t;
    pthread_create(&t, NULL, console_tee, (void *)(intptr_t)fds[0]);
    pthread_detach(t);
}

// Logs the app's memory footprint (what jetsam counts) and what's left before its limit, every
// second while it moves by 128 MB or more: visionOS SIGKILLs an app over its limit without a report.
extern size_t os_proc_available_memory(void);

static void *memory_watch(void *unused) {
    (void)unused;
    uint64_t last = 0;
    for (;;) {
        task_vm_info_data_t vm;
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS &&
            (vm.phys_footprint > last + (128 << 20) || vm.phys_footprint + (128 << 20) < last)) {
            last = vm.phys_footprint;
            vlog("memory: footprint %llu MB, %zu MB available\n", vm.phys_footprint >> 20,
                 os_proc_available_memory() >> 20);
        }
        sleep(1);
    }
}

static void memory_watch_start(void) {
    pthread_t t;
    pthread_create(&t, NULL, memory_watch, NULL);
    pthread_detach(t);
}
#endif

// A copy of libdispatch's dispatch_queue_offsets, for lldb. On every module it adds, lldb asks the
// stub (debugserver) which symbols it wants; debugserver asks for this one, and lldb can't find it in
// libdispatch (read from device memory without symbols), so it repeats the exchange for all ~940
// modules after the prepare attach, ~32 s over Wi-Fi. Once lldb answers one lookup it stops asking,
// and it finds this one in its local copy of this library. The client never imports it.
__attribute__((visibility("default"))) unsigned char dispatch_queue_offsets[64];

__attribute__((constructor)) static void sp_init(void) {
#if !TARGET_OS_OSX
    console_tee_start();
    memory_watch_start();
    // visionOS tears down a backgrounded app's sockets. A few seconds after the window closed, the
    // client closed its TLS connections, the write raised SIGPIPE, and its default action killed the
    // process. Ignored, as iOS apps do, so the write fails with EPIPE instead. A handler the client
    // installs itself still takes over.
    struct sigaction ignore = {.sa_handler = SIG_IGN};
    ((int (*)(int, const struct sigaction *, struct sigaction *))real("sigaction"))(SIGPIPE, &ignore, NULL);
#endif
    void *dispatch = dlopen("/usr/lib/system/libdispatch.dylib", RTLD_NOLOAD | RTLD_LAZY);
    const void *offsets = dispatch ? sp_real_dlsym(dispatch, "dispatch_queue_offsets") : NULL;
    if (offsets) memcpy(dispatch_queue_offsets, offsets, sizeof dispatch_queue_offsets);
    tracing = getenv("SP_SYSTEM_TRACE") != NULL;
    vlog("loaded, traced=%d\n", traced());
    if (tracing) {
        void *objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOLOAD | RTLD_LAZY);
        objc_preprocessor (*set)(objc_preprocessor) = objc ? sp_real_dlsym(objc, "objc_setExceptionPreprocessor") : NULL;
        if (set) next_preprocessor = set(log_exception);
        else vlog("objc_setExceptionPreprocessor not found\n");
    }
}
