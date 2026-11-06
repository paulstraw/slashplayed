#include "spguest.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PAGE 0x4000
#define MAX_SEG 16
#define MAX_LIB 128

typedef struct {
    char name[17];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t prot;
} Seg;

struct SPGuest {
    SPGuestOptions opt;
    char *path;
    int fd;
    uint64_t slice;  // offset of the arm64 slice in the file
    Seg seg[MAX_SEG];
    int nseg;
    uint64_t low, span;  // lowest mapped vmaddr, bytes from there to the end of the last segment
    uint8_t *base;       // where `low` landed
    intptr_t slide;
    const struct mach_header_64 *header;
    uint64_t text_off, text_size;  // __TEXT, relative to base
    uint8_t *text_w;               // writable alias of __TEXT
    uint64_t entry;                // LC_MAIN offset from the header
    char *libs[MAX_LIB];
    uint8_t weak_lib[MAX_LIB];
    int nlibs;
    struct dyld_info_command dyld;
    uint32_t exp_off, exp_size;
    uint8_t *linkedit_copy;  // the dyld-info streams and export trie, read from the file
    uint64_t init_addr, init_size;
    bool init_offsets;
    uint64_t unwind_addr, unwind_size, eh_addr, eh_size;
    uint64_t tls_addr, tls_size, tls_vars, tls_vars_size;
    size_t tls_align;
    double t_load, t_link, t_init;
    bool linked;
};

static SPGuest *the_guest;  // one guest per process: dyld queries, dladdr and dlsym hooks answer for it

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void glog(SPGuest *g, const char *fmt, ...) {
    if (!g->opt.log) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    g->opt.log(buf);
}

static bool fail(char *error, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(error, size, fmt, ap);
    va_end(ap);
    return false;
}

// ---- loading

static uint32_t be32(const uint8_t *p) { return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static bool rd(int fd, uint64_t off, void *out, size_t n) { return pread(fd, out, n, off) == (ssize_t)n; }

static void spguest_free(SPGuest *g) {
    for (int i = 0; i < g->nlibs; i++) free(g->libs[i]);
    free(g->linkedit_copy);
    free(g->path);
    if (g->fd >= 0) close(g->fd);
    free(g);
}

SPGuest *spguest_load(const char *path, const SPGuestOptions *options, char *error, size_t error_size) {
    if (the_guest) return fail(error, error_size, "one guest per process"), NULL;
    SPGuest *g = calloc(1, sizeof *g);
    g->fd = -1;
    if (options) g->opt = *options;
    g->path = strdup(path);
    double t0 = now();
#define BAD(...) do { fail(error, error_size, __VA_ARGS__); spguest_free(g); return NULL; } while (0)
    g->fd = open(path, O_RDONLY);
    if (g->fd < 0) BAD("cannot open %s: %s", path, strerror(errno));
    uint8_t head[8];
    if (!rd(g->fd, 0, head, 8)) BAD("cannot read %s", path);
    if (be32(head) == 0xcafebabe) {  // universal: find the plain arm64 slice
        uint32_t n = be32(head + 4);
        bool found = false;
        for (uint32_t i = 0; i < n && n < 16; i++) {
            uint8_t a[20];
            if (!rd(g->fd, 8 + i * 20, a, 20)) BAD("truncated fat header");
            if (be32(a) == CPU_TYPE_ARM64 && (be32(a + 4) & 0xffffff) == CPU_SUBTYPE_ARM64_ALL) {
                g->slice = be32(a + 8);
                found = true;
            }
        }
        if (!found) BAD("no plain arm64 slice");
    }
    struct mach_header_64 mh;
    if (!rd(g->fd, g->slice, &mh, sizeof mh)) BAD("truncated Mach-O header");
    if (mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64 || mh.filetype != MH_EXECUTE)
        BAD("not an arm64 MH_EXECUTE");
    if ((mh.cpusubtype & 0xffffff) != CPU_SUBTYPE_ARM64_ALL) BAD("arm64e is not supported");
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds || !rd(g->fd, g->slice + sizeof mh, cmds, mh.sizeofcmds)) BAD("cannot read load commands");

    bool have_main = false;
    uint64_t text_vm = 0;
    g->low = UINT64_MAX;
    uint64_t end = 0;
    for (uint32_t c = 0, off = 0; c < mh.ncmds; c++) {
        const struct load_command *lc = (const void *)(cmds + off);
        if (off + sizeof *lc > mh.sizeofcmds || lc->cmdsize < 8 || off + lc->cmdsize > mh.sizeofcmds) {
            free(cmds);
            BAD("bad load command %u", c);
        }
        switch (lc->cmd) {
        case LC_SEGMENT_64: {
            const struct segment_command_64 *s = (const void *)lc;
            if (!strcmp(s->segname, "__PAGEZERO") || !strcmp(s->segname, "__LINKEDIT")) break;
            if (g->nseg == MAX_SEG) { free(cmds); BAD("too many segments"); }
            Seg *d = &g->seg[g->nseg++];
            memcpy(d->name, s->segname, 16);
            d->vmaddr = s->vmaddr; d->vmsize = s->vmsize; d->fileoff = s->fileoff; d->filesize = s->filesize;
            d->prot = s->initprot;
            if (s->vmaddr < g->low) g->low = s->vmaddr;
            if (s->vmaddr + s->vmsize > end) end = s->vmaddr + s->vmsize;
            if (!strcmp(s->segname, "__TEXT")) text_vm = s->vmaddr;
            const struct section_64 *sec = (const void *)(s + 1);
            for (uint32_t i = 0; i < s->nsects; i++) {
                unsigned type = sec[i].flags & SECTION_TYPE;
                if (type == S_MOD_INIT_FUNC_POINTERS || type == S_INIT_FUNC_OFFSETS) {
                    g->init_addr = sec[i].addr; g->init_size = sec[i].size; g->init_offsets = type == S_INIT_FUNC_OFFSETS;
                }
                if (!strncmp(sec[i].sectname, "__unwind_info", 16)) { g->unwind_addr = sec[i].addr; g->unwind_size = sec[i].size; }
                if (!strncmp(sec[i].sectname, "__eh_frame", 16)) { g->eh_addr = sec[i].addr; g->eh_size = sec[i].size; }
                if (type == S_THREAD_LOCAL_REGULAR || type == S_THREAD_LOCAL_ZEROFILL) {
                    size_t al = (size_t)1 << sec[i].align;
                    if (al > g->tls_align) g->tls_align = al;
                    uint64_t a = g->tls_size ? g->tls_addr : sec[i].addr, e = g->tls_size ? g->tls_addr + g->tls_size : 0;
                    if (sec[i].addr < a) a = sec[i].addr;
                    if (sec[i].addr + sec[i].size > e) e = sec[i].addr + sec[i].size;
                    g->tls_addr = a; g->tls_size = e - a;
                }
                if (type == S_THREAD_LOCAL_VARIABLES) { g->tls_vars = sec[i].addr; g->tls_vars_size = sec[i].size; }
            }
            break;
        }
        case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LOAD_UPWARD_DYLIB: {
            const struct dylib_command *d = (const void *)lc;
            if (g->nlibs == MAX_LIB) { free(cmds); BAD("too many libraries"); }
            g->weak_lib[g->nlibs] = lc->cmd == LC_LOAD_WEAK_DYLIB;
            g->libs[g->nlibs++] = strndup((const char *)lc + d->dylib.name.offset, lc->cmdsize - d->dylib.name.offset);
            break;
        }
        case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY:
            memcpy(&g->dyld, lc, sizeof g->dyld);
            if (g->dyld.export_size) { g->exp_off = g->dyld.export_off; g->exp_size = g->dyld.export_size; }
            break;
        case LC_DYLD_EXPORTS_TRIE: {
            const struct linkedit_data_command *l = (const void *)lc;
            g->exp_off = l->dataoff; g->exp_size = l->datasize;
            break;
        }
        case LC_DYLD_CHAINED_FIXUPS: free(cmds); BAD("chained fixups are not supported (the client uses dyld-info opcodes)");
        case LC_MAIN: g->entry = ((const struct entry_point_command *)lc)->entryoff; have_main = true; break;
        case LC_ENCRYPTION_INFO_64: if (((const struct encryption_info_command_64 *)lc)->cryptid) { free(cmds); BAD("encrypted"); } break;
        }
        off += lc->cmdsize;
    }
    free(cmds);
    if (!have_main || !g->nseg || g->low != text_vm) BAD("no LC_MAIN or __TEXT is not the first segment");
    g->span = (end - g->low + PAGE - 1) & ~(uint64_t)(PAGE - 1);

    // Streams and the export trie come from the file; __LINKEDIT is never mapped.
    uint32_t lo = UINT32_MAX, hi = 0;
    uint32_t spans[][2] = {{g->dyld.rebase_off, g->dyld.rebase_size}, {g->dyld.bind_off, g->dyld.bind_size},
                           {g->dyld.weak_bind_off, g->dyld.weak_bind_size}, {g->dyld.lazy_bind_off, g->dyld.lazy_bind_size},
                           {g->exp_off, g->exp_size}};
    for (int i = 0; i < 5; i++) {
        if (!spans[i][1]) continue;
        if (spans[i][0] < lo) lo = spans[i][0];
        if (spans[i][0] + spans[i][1] > hi) hi = spans[i][0] + spans[i][1];
    }
    if (hi > lo) {
        g->linkedit_copy = malloc(hi - lo);
        if (!g->linkedit_copy || !rd(g->fd, g->slice + lo, g->linkedit_copy, hi - lo)) BAD("cannot read dyld info");
        // Rewrite the offsets as offsets into linkedit_copy.
        g->dyld.rebase_off -= lo; g->dyld.bind_off -= lo; g->dyld.weak_bind_off -= lo; g->dyld.lazy_bind_off -= lo;
        g->exp_off -= lo;
    }

    // Reserve the whole span, so every segment keeps its offset from __TEXT (code reaches data with adrp).
    void *p = mmap(NULL, g->span, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) BAD("cannot reserve 0x%llx bytes: %s", (unsigned long long)g->span, strerror(errno));
    g->base = p;
    g->slide = (intptr_t)(g->base - g->low);
    g->header = (const void *)g->base;
    for (int i = 0; i < g->nseg; i++) {
        Seg *s = &g->seg[i];
        uint8_t *at = g->base + (s->vmaddr - g->low);
        bool text = !strcmp(s->name, "__TEXT");
        if (text) { g->text_off = s->vmaddr - g->low; g->text_size = s->vmsize; }
        // __TEXT is the one region the device must prepare and write through an alias.
        int prot = text && g->opt.prepare_text ? PROT_READ | PROT_EXEC : PROT_READ | PROT_WRITE;
        if (mmap(at, s->vmsize, prot, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) == MAP_FAILED)
            BAD("cannot map %s: %s", s->name, strerror(errno));
        if (text && g->opt.prepare_text) {
            g->text_w = g->opt.prepare_text(at, s->vmsize, g->opt.context);
            if (!g->text_w) BAD("prepare_text failed");
        } else if (text) {
            g->text_w = at;
        }
        uint8_t *w = text ? g->text_w : at;
        for (uint64_t o = 0; o < s->filesize;) {
            size_t n = s->filesize - o > (1 << 22) ? (1 << 22) : s->filesize - o;
            if (!rd(g->fd, g->slice + s->fileoff + o, w + o, n)) BAD("cannot read %s", s->name);
            o += n;
        }
    }
    g->t_load = now() - t0;
    the_guest = g;
    glog(g, "loaded %s: %d segments, span 0x%llx at %p (slide %#lx), __TEXT 0x%llx", path, g->nseg,
         (unsigned long long)g->span, g->base, (long)g->slide, (unsigned long long)g->text_size);
    return g;
#undef BAD
}

// ---- export trie

static bool uleb(const uint8_t **p, const uint8_t *end, uint64_t *v) {
    *v = 0;
    for (unsigned s = 0; *p < end && s < 64; s += 7) {
        uint8_t b = *(*p)++;
        *v |= (uint64_t)(b & 0x7f) << s;
        if (!(b & 0x80)) return true;
    }
    return false;
}

// Looks `name` (with its leading underscore) up in the guest's own exports. 0 when absent.
static uintptr_t own_export(const SPGuest *g, const char *name, bool *weak) {
    if (!g->exp_size || !g->linkedit_copy) return 0;
    const uint8_t *t = g->linkedit_copy + g->exp_off, *end = t + g->exp_size;
    const uint8_t *node = t;
    for (int steps = 0; steps < 100000; steps++) {
        const uint8_t *c = node;
        uint64_t tsize;
        if (!uleb(&c, end, &tsize) || tsize > (uint64_t)(end - c)) return 0;
        const uint8_t *children = c + tsize;
        if (!*name && tsize) {
            uint64_t flags, value;
            if (!uleb(&c, children, &flags)) return 0;
            if ((flags & EXPORT_SYMBOL_FLAGS_REEXPORT) || (flags & EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER)) return 0;
            if (!uleb(&c, children, &value)) return 0;
            if (weak) *weak = (flags & EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION) != 0;
            return (flags & EXPORT_SYMBOL_FLAGS_KIND_MASK) == EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE
                       ? (uintptr_t)value : (uintptr_t)g->base + (uintptr_t)value;  // from the header, which is __TEXT's start
        }
        if (children >= end) return 0;
        c = children;
        unsigned n = *c++;
        const uint8_t *next = NULL;
        size_t used = 0;
        for (unsigned i = 0; i < n; i++) {
            size_t len = strnlen((const char *)c, end - c);
            const uint8_t *edge = c;
            c += len + 1;
            uint64_t off;
            if (!uleb(&c, end, &off)) return 0;
            if (!next && !strncmp((const char *)edge, name, len)) { next = t + off; used = len; }
        }
        if (!next) return 0;
        node = next;
        name += used;
    }
    return 0;
}

// Export values are offsets from the header (__TEXT's vmaddr). Wrapped so call sites read plainly.
static uintptr_t guest_symbol(const SPGuest *g, const char *name) {
    bool weak;
    return own_export(g, name, &weak);
}

// ---- thread-locals (the Darwin TLV ABI: x0 descriptor -> x0 storage)

static struct {
    uint8_t *tmpl;
    size_t size, align;
    uintptr_t vars, vars_size;
    pthread_key_t key;
    pthread_once_t once;
} tls;

static void tls_free(void *p) { free(p); }
static void tls_init_key(void) { pthread_key_create(&tls.key, tls_free); }

void *spguest_tlv_address(const uint64_t d[3]);
void *spguest_tlv_address(const uint64_t d[3]) {
    pthread_once(&tls.once, tls_init_key);
    uint8_t *s = pthread_getspecific(tls.key);
    if (!s) {
        if (posix_memalign((void **)&s, tls.align < sizeof(void *) ? sizeof(void *) : tls.align, tls.size)) abort();
        memcpy(s, tls.tmpl, tls.size);
        pthread_setspecific(tls.key, s);
    }
    return s + d[2];
}
extern void spguest_tlv_bootstrap(void);

// ---- unwinding: the finder libunwind consults for code dyld doesn't know (Darwin SPI)

typedef struct {
    uintptr_t header, dwarf;
    size_t dwarf_size;
    uintptr_t compact;
    size_t compact_size;
} UnwindSections;

static UnwindSections unwind_sections;
static uintptr_t unwind_lo, unwind_hi;

static int unwind_find(uintptr_t pc, UnwindSections *out) {
    if (pc < unwind_lo || pc >= unwind_hi) return 0;
    *out = unwind_sections;
    return 1;
}

// ---- binding

static const char *pick_path(SPGuest *g, const char *install) {
    return g->opt.rewrite ? g->opt.rewrite(install, g->opt.context) : install;
}

static void *lib_handle(SPGuest *g, int ordinal) {
    static void *handles[MAX_LIB + 1];
    if (ordinal < 1 || ordinal > g->nlibs) return NULL;
    if (!handles[ordinal]) {
        handles[ordinal] = dlopen(pick_path(g, g->libs[ordinal - 1]), RTLD_LAZY | RTLD_NOLOAD);
        if (!handles[ordinal]) handles[ordinal] = dlopen(pick_path(g, g->libs[ordinal - 1]), RTLD_LAZY);
    }
    return handles[ordinal];
}

// The guest's dyld queries. Image 0 is the guest, as for a main executable; the host is not listed.
static uint32_t guest_dyld_image_count(void) { return _dyld_image_count(); }
static const struct mach_header *guest_dyld_get_image_header(uint32_t i) {
    return i == 0 ? (const struct mach_header *)the_guest->header : _dyld_get_image_header(i);
}
static const char *guest_dyld_get_image_name(uint32_t i) { return i == 0 ? the_guest->path : _dyld_get_image_name(i); }
static intptr_t guest_dyld_get_image_vmaddr_slide(uint32_t i) {
    return i == 0 ? the_guest->slide : _dyld_get_image_vmaddr_slide(i);
}
static int guest_NSGetExecutablePath(char *buf, uint32_t *size) {
    uint32_t need = strlen(the_guest->path) + 1;
    if (*size < need) { *size = need; return -1; }
    memcpy(buf, the_guest->path, need);
    return 0;
}
static int guest_dladdr(const void *addr, Dl_info *info) {
    if (spguest_contains(the_guest, addr)) {
        *info = (Dl_info){.dli_fname = the_guest->path, .dli_fbase = (void *)the_guest->header};
        return 1;
    }
    return dladdr(addr, info);
}
// The services the client's startup rewrite looks up with dlsym (shims/system/spsystem.c does the same for
// the dyld-loaded client): __TEXT is prepared and aliased already, so mprotect on it is a no-op and
// memcpy into it goes through the writable alias. Nothing makes __TEXT writable in place.
static int guest_mprotect(void *addr, size_t len, int prot) {
    SPGuest *g = the_guest;
    uintptr_t a = (uintptr_t)addr, t = (uintptr_t)g->base + g->text_off;
    if (a >= t && a < t + g->text_size) return 0;
    return mprotect(addr, len, prot);
}
static void *guest_memcpy(void *dst, const void *src, size_t n) {
    SPGuest *g = the_guest;
    uintptr_t a = (uintptr_t)dst, t = (uintptr_t)g->base + g->text_off;
    if (a >= t && a + n <= t + g->text_size) {
        memcpy(g->text_w + (a - t), src, n);
        return dst;
    }
    return memcpy(dst, src, n);
}
static void *guest_dlsym(void *handle, const char *name) {
    if (the_guest->opt.prepare_text && (handle == RTLD_DEFAULT || handle == RTLD_NEXT)) {
        if (!strcmp(name, "mprotect")) return (void *)guest_mprotect;
        if (!strcmp(name, "memcpy")) return (void *)guest_memcpy;
        if (!strcmp(name, "pthread_jit_write_protect_np")) return NULL;  // no MAP_JIT memory under TXM
    }
    // RTLD_MAIN_ONLY (-5) and RTLD_SELF (-3) mean the guest, for a program that was the main executable.
    if (handle == RTLD_MAIN_ONLY || handle == RTLD_SELF) {
        char u[512];
        snprintf(u, sizeof u, "_%s", name);
        void *r = (void *)guest_symbol(the_guest, u);
        if (r) return r;
    }
    return dlsym(handle, name);
}
static void guest_stub_binder(void) {
    static const char m[] = "spguest: dyld_stub_binder called; lazy pointers are bound at load\n";
    write(2, m, sizeof m - 1);
    abort();
}

static void *hook(const char *n) {
#define H(s, f) if (!strcmp(n, s)) return (void *)f
    H("__tlv_bootstrap", spguest_tlv_bootstrap);
    H("dyld_stub_binder", guest_stub_binder);
    H("__dyld_image_count", guest_dyld_image_count);
    H("__dyld_get_image_header", guest_dyld_get_image_header);
    H("__dyld_get_image_name", guest_dyld_get_image_name);
    H("__dyld_get_image_vmaddr_slide", guest_dyld_get_image_vmaddr_slide);
    H("__NSGetExecutablePath", guest_NSGetExecutablePath);
    H("_dladdr", guest_dladdr);
    H("_dlsym", guest_dlsym);
    return NULL;
#undef H
}

typedef struct {
    int ordinal;
    char symbol[1024];
    uint8_t flags;
    int64_t addend;
    uint64_t addr;  // guest address (unslid) being bound
    int seg;
    uint8_t type;
    bool lazy, weak_stream;
    size_t bound, unresolved;
} BindState;

static uint8_t *at(SPGuest *g, uint64_t vmaddr) { return g->base + (vmaddr - g->low); }

// Writes go to the right view: __TEXT through its alias, everything else in place.
static void *wr(SPGuest *g, uint64_t vmaddr) {
    uint64_t off = vmaddr - g->low;
    if (off >= g->text_off && off < g->text_off + g->text_size) return g->text_w + (off - g->text_off);
    return g->base + off;
}

static bool resolve(SPGuest *g, BindState *b, uintptr_t *out) {
    const char *name = b->symbol;
    void *p = hook(name);
    if (!p && b->weak_stream) {  // weak definitions coalesce: the guest's own wins, then any other image's
        p = (void *)guest_symbol(g, name);
        if (!p) p = dlsym(RTLD_DEFAULT, name + 1);
    }
    if (!p && b->ordinal == BIND_SPECIAL_DYLIB_SELF) p = (void *)guest_symbol(g, name);
    if (!p && b->ordinal == BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE) p = (void *)guest_symbol(g, name);
    if (!p && b->ordinal > 0) {
        void *h = lib_handle(g, b->ordinal);
        if (h) p = dlsym(h, name + 1);
    }
    if (!p && b->ordinal != BIND_SPECIAL_DYLIB_SELF) p = dlsym(RTLD_DEFAULT, name + 1);
    if (!p && b->ordinal > 0 && !b->weak_stream) {
        // A re-exported symbol lives in a library the named one pulls in; dlsym on the named one finds
        // those already, so reaching here means the symbol is absent.
    }
    *out = (uintptr_t)p;
    return p != NULL;
}

static bool bind_one(SPGuest *g, BindState *b, char *error, size_t es) {
    uintptr_t v = 0;
    bool ok = resolve(g, b, &v);
    if (!ok) {
        bool weak = b->flags & BIND_SYMBOL_FLAGS_WEAK_IMPORT;
        if (!weak && !b->weak_stream) {
            glog(g, "unresolved %s (ordinal %d)", b->symbol, b->ordinal);
            b->unresolved++;
            return true;  // keep going and report them all; link() fails after the pass
        }
        v = 0;
        if (b->weak_stream) return true;  // no other definition: the guest's own pointer stays
    }
    *(uintptr_t *)wr(g, b->addr) = v + b->addend;
    b->bound++;
    return true;
}

static bool run_bind(SPGuest *g, const uint8_t *s, size_t size, bool lazy, bool weak_stream, size_t *unresolved,
                     char *error, size_t es) {
    BindState b = {.lazy = lazy, .weak_stream = weak_stream};
    const uint8_t *p = s, *end = s + size;
    uint64_t v;
    while (p < end) {
        uint8_t op = *p & BIND_OPCODE_MASK, imm = *p & BIND_IMMEDIATE_MASK;
        p++;
        switch (op) {
        case BIND_OPCODE_DONE:
            if (lazy) { b.flags = 0; b.addend = 0; break; }  // each lazy entry ends with one
            goto done;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: b.ordinal = imm; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: uleb(&p, end, &v); b.ordinal = (int)v; break;
        case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: b.ordinal = imm ? (int8_t)(BIND_OPCODE_MASK | imm) : 0; break;
        case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
            b.flags = imm;
            strlcpy(b.symbol, (const char *)p, sizeof b.symbol);
            p += strlen((const char *)p) + 1;
            break;
        case BIND_OPCODE_SET_TYPE_IMM: b.type = imm; break;
        case BIND_OPCODE_SET_ADDEND_SLEB: {
            int64_t r = 0; unsigned sh = 0; uint8_t c;
            do { c = *p++; r |= (int64_t)(c & 0x7f) << sh; sh += 7; } while (c & 0x80);
            if (sh < 64 && (c & 0x40)) r |= -((int64_t)1 << sh);
            b.addend = r;
            break;
        }
        case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: {
            uleb(&p, end, &v);
            if (imm >= g->nseg + 1) return fail(error, es, "bind: bad segment %u", imm);
            // Segment indexes count __PAGEZERO as 0 and __LINKEDIT last; g->seg skips both.
            b.seg = imm - 1;
            if (b.seg < 0 || b.seg >= g->nseg) return fail(error, es, "bind: segment index %u", imm);
            b.addr = g->seg[b.seg].vmaddr + v;
            break;
        }
        case BIND_OPCODE_ADD_ADDR_ULEB: uleb(&p, end, &v); b.addr += v; break;
        case BIND_OPCODE_DO_BIND: bind_one(g, &b, error, es); b.addr += 8; break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: bind_one(g, &b, error, es); uleb(&p, end, &v); b.addr += 8 + v; break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: bind_one(g, &b, error, es); b.addr += 8 + imm * 8; break;
        case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
            uint64_t count, skip;
            uleb(&p, end, &count); uleb(&p, end, &skip);
            for (uint64_t i = 0; i < count; i++) { bind_one(g, &b, error, es); b.addr += 8 + skip; }
            break;
        }
        default: return fail(error, es, "bind: unsupported opcode %#x", op);
        }
    }
done:
    *unresolved += b.unresolved;
    glog(g, "%s: %zu bound, %zu unresolved", lazy ? "lazy" : weak_stream ? "weak" : "bind", b.bound, b.unresolved);
    return true;
}

static bool run_rebase(SPGuest *g, const uint8_t *s, size_t size, char *error, size_t es) {
    const uint8_t *p = s, *end = s + size;
    uint64_t addr = 0, v;
    uint8_t type = REBASE_TYPE_POINTER;
    size_t n = 0;
#define REBASE() do { uintptr_t *loc = wr(g, addr); *loc += g->slide; n++; } while (0)
    while (p < end) {
        uint8_t op = *p & REBASE_OPCODE_MASK, imm = *p & REBASE_IMMEDIATE_MASK;
        p++;
        switch (op) {
        case REBASE_OPCODE_DONE: goto done;
        case REBASE_OPCODE_SET_TYPE_IMM: type = imm; break;
        case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            uleb(&p, end, &v);
            if (imm < 1 || imm > g->nseg) return fail(error, es, "rebase: segment index %u", imm);
            addr = g->seg[imm - 1].vmaddr + v;
            break;
        case REBASE_OPCODE_ADD_ADDR_ULEB: uleb(&p, end, &v); addr += v; break;
        case REBASE_OPCODE_ADD_ADDR_IMM_SCALED: addr += imm * 8; break;
        case REBASE_OPCODE_DO_REBASE_IMM_TIMES: for (int i = 0; i < imm; i++) { REBASE(); addr += 8; } break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES: uleb(&p, end, &v); for (uint64_t i = 0; i < v; i++) { REBASE(); addr += 8; } break;
        case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: REBASE(); uleb(&p, end, &v); addr += 8 + v; break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: {
            uint64_t count, skip;
            uleb(&p, end, &count); uleb(&p, end, &skip);
            for (uint64_t i = 0; i < count; i++) { REBASE(); addr += 8 + skip; }
            break;
        }
        default: return fail(error, es, "rebase: unsupported opcode %#x", op);
        }
    }
done:
    (void)type;
    glog(g, "rebased %zu pointers", n);
    return true;
#undef REBASE
}

bool spguest_link(SPGuest *g, char *error, size_t es) {
    double t0 = now();
    const uint8_t *le = g->linkedit_copy;
    if (g->dyld.rebase_size && !run_rebase(g, le + g->dyld.rebase_off, g->dyld.rebase_size, error, es)) return false;
    size_t unresolved = 0;
    if (g->dyld.bind_size && !run_bind(g, le + g->dyld.bind_off, g->dyld.bind_size, false, false, &unresolved, error, es)) return false;
    if (g->dyld.lazy_bind_size && !run_bind(g, le + g->dyld.lazy_bind_off, g->dyld.lazy_bind_size, true, false, &unresolved, error, es)) return false;
    if (g->dyld.weak_bind_size) {
        size_t ignored = 0;
        if (!run_bind(g, le + g->dyld.weak_bind_off, g->dyld.weak_bind_size, false, true, &ignored, error, es)) return false;
    }
    if (unresolved) return fail(error, es, "%zu imports unresolved", unresolved);

    // Thread-locals: the template is the image's thread-data and thread-bss as fixups left them.
    if (g->tls_size) {
        tls.size = g->tls_size;
        tls.align = g->tls_align;
        tls.tmpl = malloc(tls.size);
        memcpy(tls.tmpl, at(g, g->tls_addr), tls.size);
        glog(g, "TLS template %zu bytes, %llu descriptors", tls.size, (unsigned long long)(g->tls_vars_size / 24));
    }

    // Segment protections: __TEXT executable, the rest as the image asks.
    for (int i = 0; i < g->nseg; i++) {
        Seg *s = &g->seg[i];
        bool text = !strcmp(s->name, "__TEXT");
        uint8_t *p = at(g, s->vmaddr);
        if (text) {
            sys_icache_invalidate(p, s->vmsize);
            if (!g->opt.prepare_text && mprotect(p, s->vmsize, PROT_READ | PROT_EXEC))
                return fail(error, es, "mprotect __TEXT: %s", strerror(errno));
        } else if (mprotect(p, s->vmsize, s->prot & 7)) {
            return fail(error, es, "mprotect %s: %s", s->name, strerror(errno));
        }
    }

    // The unwinder: C++ exceptions through guest frames need its __unwind_info and __eh_frame.
    unwind_sections = (UnwindSections){(uintptr_t)g->header, g->eh_size ? (uintptr_t)at(g, g->eh_addr) : 0, g->eh_size,
                                       g->unwind_size ? (uintptr_t)at(g, g->unwind_addr) : 0, g->unwind_size};
    unwind_lo = (uintptr_t)g->base + g->text_off;
    unwind_hi = unwind_lo + g->text_size;
    int (*add)(int (*)(uintptr_t, UnwindSections *)) = dlsym(RTLD_DEFAULT, "__unw_add_find_dynamic_unwind_sections");
    if (!add) return fail(error, es, "no __unw_add_find_dynamic_unwind_sections");
    if (add(unwind_find)) return fail(error, es, "unwinder refused the finder");

    // Objective-C: the SPI dyld itself uses for images it maps.
    void (*map_images)(unsigned, const char *const *, const struct mach_header *const *) = dlsym(RTLD_DEFAULT, "_objc_map_images");
    void (*load_image)(const char *, const struct mach_header *) = dlsym(RTLD_DEFAULT, "_objc_load_image");
    if (!map_images || !load_image) return fail(error, es, "no _objc_map_images/_objc_load_image");
    const char *names[] = {g->path};
    const struct mach_header *hs[] = {(const void *)g->header};
    map_images(1, names, hs);
    g->linked = true;
    g->t_link = now() - t0;
    glog(g, "linked in %.3f s", g->t_link);
    return true;
}

int spguest_run(SPGuest *g, int argc, const char **argv, const char **envp, const char **apple) {
    double t0 = now();
    void (*load_image)(const char *, const struct mach_header *) = dlsym(RTLD_DEFAULT, "_objc_load_image");
    load_image(g->path, (const void *)g->header);  // +load methods, before static initializers as in dyld
    if (g->init_size) {
        uint64_t n = g->init_size / (g->init_offsets ? 4 : 8);
        for (uint64_t i = 0; i < n; i++) {
            uintptr_t f = g->init_offsets ? (uintptr_t)g->header + ((const uint32_t *)at(g, g->init_addr))[i]
                                          : ((const uintptr_t *)at(g, g->init_addr))[i];
            ((void (*)(int, const char **, const char **, const char **))f)(argc, argv, envp, apple);
        }
        glog(g, "ran %llu initializers", (unsigned long long)n);
    }
    g->t_init = now() - t0;
    int (*m)(int, const char **, const char **, const char **) = (void *)((uintptr_t)g->header + g->entry);
    return m(argc, argv, envp, apple);
}

void spguest_times(const SPGuest *g, double *load, double *link, double *init) {
    *load = g->t_load; *link = g->t_link; *init = g->t_init;
}
const struct mach_header *spguest_header(const SPGuest *g) { return (const void *)g->header; }
intptr_t spguest_slide(const SPGuest *g) { return g->slide; }
bool spguest_contains(const SPGuest *g, const void *a) {
    return g && (const uint8_t *)a >= g->base && (const uint8_t *)a < g->base + g->span;
}
void *spguest_text_alias(const SPGuest *g, uintptr_t *text, size_t *size) {
    if (text) *text = (uintptr_t)g->base + g->text_off;
    if (size) *size = g->text_size;
    return g->text_w;
}
