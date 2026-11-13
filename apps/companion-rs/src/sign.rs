// Signing the kit's app with zsign (the spzsign crate, zsign/, links it; spzsign_host.cpp is its entry point):
// the app and its JIT helper each with its own profile and the entitlements the Mac signs them with (the kit's
// templates, filled in by kit.rs), not the profiles' (which carry keychain-access-groups and more:
// research/isideload/README.md). The key is passed as PKCS#8 PEM in a Zeroizing buffer and never written.

use std::{ffi::CString, path::Path};

use rootcause::prelude::*;
use spzsign::spz_sign_app;
use zeroize::Zeroizing;

pub struct Inputs<'a> {
    pub key_pem: &'a Zeroizing<String>,
    pub cert_der: &'a [u8],
    pub app_profile: &'a [u8],
    pub app_entitlements: &'a str,
    pub helper_profile: &'a [u8],
    pub helper_entitlements: &'a str,
}

pub fn sign_app(app: &Path, i: &Inputs) -> Result<(), Report> {
    let dir = CString::new(app.to_string_lossy().as_bytes()).map_err(|_| report!("the app's path has a NUL"))?;
    let mut err = [0 as std::ffi::c_char; 256];
    let rc = unsafe {
        spz_sign_app(
            dir.as_ptr(),
            i.key_pem.as_ptr(),
            i.key_pem.len(),
            i.cert_der.as_ptr(),
            i.cert_der.len(),
            i.app_profile.as_ptr(),
            i.app_profile.len(),
            i.app_entitlements.as_ptr(),
            i.app_entitlements.len(),
            i.helper_profile.as_ptr(),
            i.helper_profile.len(),
            i.helper_entitlements.as_ptr(),
            i.helper_entitlements.len(),
            err.as_mut_ptr(),
            err.len(),
        )
    };
    if rc != 0 {
        let msg = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }.to_string_lossy().into_owned();
        bail!("{msg}");
    }
    Ok(())
}
