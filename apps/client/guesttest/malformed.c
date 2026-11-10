// guesttest's broken files: copies of the toy, each with one thing in its header, load commands, or bind
// opcodes broken, which spguest must refuse with its reason rather than crash on. The launcher parses
// Library/spgames/wow-<flavor> at every start, before the start screen (sp_slice_retire), so a corrupt or
// hostile file there that crashed the parse would crash every launch. Our own toy only, never a Blizzard file.
// Each copy is tried in a child process, so a crash fails its case by name. Exits with the failures' count.
// Usage: malformed <toy> <scratch dir>, from build.sh mac.
#include "spguest.h"
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// Which step refuses a case: the start's check (spguest_check_file, the parse the load also runs), or the
// link (the bind and rebase opcodes are read only there).
enum { TAKEN, CHECK, LOAD, LINK };
static const char *const step_names[] = {"nothing", "the check", "the load", "the link"};

static void die(const char *what) {
    fprintf(stderr, "malformed: %s\n", what);
    exit(2);
}

// The load command of type `cmd` (and segment `segname`) in the copy `f`, and its index.
static struct load_command *command(uint8_t *f, uint32_t cmd, const char *segname, uint32_t *index) {
    const struct mach_header_64 *mh = (const void *)f;
    uint8_t *p = f + sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct load_command *lc = (void *)p;
        if (lc->cmd != cmd || (segname && strcmp(((struct segment_command_64 *)lc)->segname, segname))) continue;
        if (index) *index = i;
        return lc;
    }
    die("the toy is missing a load command a case breaks");
    return NULL;
}

static uint32_t offset_in_commands(uint8_t *f, const void *lc) {
    return (uint32_t)((const uint8_t *)lc - f - sizeof(struct mach_header_64));
}

// __TEXT's cmdsize set so that, added to its offset in 32 bits, it wraps back to the first command, with a
// section count it seems to cover: read as given, the sections run 4 GB past the end of the commands.
static int wrapping_cmdsize(uint8_t *f, char *expect, size_t es) {
    uint32_t i;
    struct segment_command_64 *s = (void *)command(f, LC_SEGMENT_64, "__TEXT", &i);
    s->cmdsize = (uint32_t)(0x100000000ull - offset_in_commands(f, s));
    s->nsects = 50000000;  // 72 + 50,000,000 x 80 bytes is under that cmdsize
    snprintf(expect, es, "its load command %u is malformed", i);
    return CHECK;
}

// LC_MAIN cut to the 8 bytes every command has, and made the last command: its entry point would be read
// from past the end of the commands.
static int short_command(uint8_t *f, char *expect, size_t es) {
    uint32_t i;
    struct mach_header_64 *mh = (void *)f;
    struct load_command *lc = command(f, LC_MAIN, NULL, &i);
    lc->cmdsize = sizeof *lc;
    mh->ncmds = i + 1;
    mh->sizeofcmds = offset_in_commands(f, lc) + lc->cmdsize;
    snprintf(expect, es, "its load command %u is malformed", i);
    return CHECK;
}

// __DATA_CONST's bytes in the file twice its size in memory (still inside the file): read as given, the load
// writes past its mapping.
static int file_larger_than_memory(uint8_t *f, char *expect, size_t es) {
    struct segment_command_64 *s = (void *)command(f, LC_SEGMENT_64, "__DATA_CONST", NULL);
    s->filesize = s->vmsize * 2;
    snprintf(expect, es, "its segment __DATA_CONST is larger in the file than in memory");
    return CHECK;
}

// The bind opcodes cut off two bytes into their first symbol's name (the weak binds' opcodes follow in the
// file): read to the name's NUL, the opcodes would run on past their end.
static int truncated_bind(uint8_t *f, char *expect, size_t es) {
    struct dyld_info_command *d = (void *)command(f, LC_DYLD_INFO_ONLY, NULL, NULL);
    const uint8_t *b = f + d->bind_off;
    uint32_t i = 0;
    while (i + 3 < d->bind_size && !((b[i] & BIND_OPCODE_MASK) == BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM && b[i + 1] == '_')) i++;
    if (i + 3 >= d->bind_size) die("the toy's bind opcodes name no symbol");
    d->bind_size = i + 3;  // the opcode, "_", and the name's first letter
    snprintf(expect, es, "bind: its opcodes are cut short");
    return LINK;
}

// The control: the toy as it is, taken by all three.
static int unchanged(uint8_t *f, char *expect, size_t es) {
    snprintf(expect, es, "it was taken");
    return TAKEN;
}

static int attempt(const char *path, char *err, size_t es) {
    SPGuestOptions o = {0};
    SPGuest *g;
    if (!spguest_check_file(path, err, es)) return CHECK;
    if (!(g = spguest_load(path, &o, err, es))) return LOAD;
    if (!spguest_link(g, err, es)) return LINK;
    snprintf(err, es, "it was taken");
    return TAKEN;
}

static bool write_file(const char *path, const uint8_t *bytes, size_t n) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    for (size_t o = 0; o < n;) {
        ssize_t w = write(fd, bytes + o, n - o);
        if (w <= 0) { close(fd); return false; }
        o += w;
    }
    return !close(fd);
}

int main(int argc, char **argv) {
    if (argc != 3) die("usage: malformed <toy> <scratch dir>");
    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) die("can't read the toy");
    size_t size = st.st_size;
    uint8_t *toy = malloc(size), *copy = malloc(size);
    if (!toy || !copy || pread(fd, toy, size, 0) != (ssize_t)size) die("can't read the toy");
    close(fd);
    static const struct {
        const char *name;
        int (*make)(uint8_t *, char *, size_t);
    } cases[] = {
        {"the toy as it is", unchanged},
        {"a cmdsize that wraps", wrapping_cmdsize},
        {"a command shorter than its struct", short_command},
        {"a segment larger in the file than in memory", file_larger_than_memory},
        {"bind opcodes cut short", truncated_bind},
    };
    int failures = 0;
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        memcpy(copy, toy, size);
        char expect[256], path[1024], got[512] = "";
        int step = cases[c].make(copy, expect, sizeof expect);
        snprintf(path, sizeof path, "%s/malformed-%zu", argv[2], c);
        if (!write_file(path, copy, size)) die("can't write a broken copy");
        int fds[2];
        if (pipe(fds)) die("no pipe");
        pid_t pid = fork();
        if (pid < 0) die("no fork");
        if (!pid) {
            close(fds[0]);
            char err[512] = "";
            int r = attempt(path, err, sizeof err);
            write(fds[1], err, strlen(err));
            _exit(r);
        }
        close(fds[1]);
        for (size_t n = 0; n < sizeof got - 1;) {
            ssize_t r = read(fds[0], got + n, sizeof got - 1 - n);
            if (r <= 0) break;
            n += r;
        }
        close(fds[0]);
        int status;
        waitpid(pid, &status, 0);
        unlink(path);
        if (WIFSIGNALED(status)) {
            printf("FAIL %s: crashed (signal %d)\n", cases[c].name, WTERMSIG(status));
            failures++;
        } else if (WEXITSTATUS(status) != step || !strstr(got, expect)) {
            int by = WEXITSTATUS(status);
            printf("FAIL %s: %s%s%s; expected %s\n", cases[c].name, by == TAKEN ? "" : by <= LINK ? step_names[by] : "the child",
                   by == TAKEN ? "" : " refused it: ", got, step == TAKEN ? "it to be taken" : step_names[step]);
            if (step != TAKEN) printf("     to refuse it: %s\n", expect);
            failures++;
        } else {
            printf("ok   %s: %s%s%s\n", cases[c].name, step == TAKEN ? "" : step_names[step], step == TAKEN ? "" : " refused it: ", got);
        }
    }
    printf("=== malformed: %d failure(s)\n", failures);
    return failures;
}
