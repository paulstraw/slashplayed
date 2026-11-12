// spapple (apps/client/spapple, a Rust static library: scripts/build-spapple.sh): Apple's developer services
// for the launcher. One call, JSON in and out; its ops and their fields are in spapple/src/lib.rs.
#pragma once

// Runs one request (NUL-terminated JSON) and returns its reply (NUL-terminated JSON, always with "ok"),
// which the caller frees with spapple_free. Blocks on the network for up to 2 minutes (a sign-in's step): never call it on
// the main thread. NULL only if the reply couldn't be made into a C string.
char *spapple_call(const char *request);
void spapple_free(char *reply);
