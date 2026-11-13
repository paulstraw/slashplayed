// zsign, linked in by build.rs: the entry point spzsign_host.cpp defines, which src/sign.rs calls.

use std::ffi::{c_char, c_int};

unsafe extern "C" {
    /// Signs the unsigned app folder `app_dir` in place, the app and its JIT helper each with its own
    /// profile and entitlements. 0 on success; otherwise `err` holds why, NUL-terminated.
    pub fn spz_sign_app(
        app_dir: *const c_char,
        key: *const u8,
        key_len: usize,
        cert: *const u8,
        cert_len: usize,
        app_prov: *const u8,
        app_prov_len: usize,
        app_ents: *const u8,
        app_ents_len: usize,
        helper_prov: *const u8,
        helper_prov_len: usize,
        helper_ents: *const u8,
        helper_ents_len: usize,
        err: *mut c_char,
        err_len: usize,
    ) -> c_int;
}
