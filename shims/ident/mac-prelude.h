// What the generated shims provide to EXTRA_INCLUDES files, for the Mac probe build (build-mac.sh).
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>

static void sp_stub_log(const char *what) { fprintf(stderr, "[sp:ident] %s\n", what); }

// The client's load address: libspSystem knows it (the launcher's loader maps the client, and dyld never lists it).
static unsigned long sp_client_base(void) {
    static unsigned long (*f)(void);
    if (!f) f = (unsigned long (*)(void))dlsym(RTLD_DEFAULT, "sp_client_text");
    unsigned long base = f ? f() : 0;
    return base ? base : (unsigned long)_dyld_get_image_header(0);
}

#define SP_CALLER ((unsigned long)__builtin_return_address(0) - sp_client_base())
