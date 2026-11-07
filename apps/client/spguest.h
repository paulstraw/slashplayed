// spguest: loads an unchanged, unsigned arm64 macOS executable (MH_EXECUTE) into this process without
// dyld, for the launcher (guesttest/ is its test, research/guestloadtest the research). Modelled on
// Tolkara's loader (MIT, github.com/tolkara/tolkara, runtime/GuestImage.c, GuestFixups.c, GuestTLS.c,
// GuestUnwind.c, NativeGuest.m), reduced to what a native, non-emulated guest needs: map, rebase, bind,
// register with Objective-C and the unwinder, serve thread-locals, run initializers, call main.
#pragma once
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SPGuest SPGuest;

typedef struct {
    // Where the guest's code goes. NULL: the loader maps its own span, writes __TEXT while the
    // mapping is writable, then makes it executable (macOS; the device has TXM and can't).
    // Set: the loader reserves the span, calls this with __TEXT's address and size, and expects it to
    // leave that range executable (debugger-prepared) and return a writable alias of it, or NULL.
    void *(*prepare_text)(void *text, size_t size, void *context);
    void *context;
    // Maps a library path the guest names to the one to open (the shims' rewrite map); NULL: as is.
    const char *(*rewrite)(const char *install_name, void *context);
    // Answers an import (its name, leading underscore included) before the libraries do, or NULL: for a host
    // without the shims (the Mac) that stands in for what they serve. NULL: the libraries answer.
    void *(*symbol)(const char *name, void *context);
    void (*log)(const char *line);
} SPGuestOptions;

// Loads `path`. On failure returns NULL and writes a reason into `error`.
SPGuest *spguest_load(const char *path, const SPGuestOptions *options, char *error, size_t error_size);

// Everything after the load: fixups, registration, initializers. Returns false with a reason.
bool spguest_link(SPGuest *g, char *error, size_t error_size);

// Runs initializers, then main(argc, argv, envp, apple). Returns main's result.
int spguest_run(SPGuest *g, int argc, const char **argv, const char **envp, const char **apple);

// Timings in seconds: load (read and place segments), link (rebase, bind, register), init (initializers).
void spguest_times(const SPGuest *g, double *load, double *link, double *init);

const struct mach_header *spguest_header(const SPGuest *g);
intptr_t spguest_slide(const SPGuest *g);
bool spguest_contains(const SPGuest *g, const void *address);
// The writable alias of __TEXT's start, or NULL: for services that write into the guest's code.
void *spguest_text_alias(const SPGuest *g, uintptr_t *text, size_t *size);
