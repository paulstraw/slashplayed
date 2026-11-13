// The Windows programs' icon and version resource, and SP_KIT_SHA256, the device kit's SHA-256 a release
// build checks its download against (src/kit.rs); a build without it only takes a kit named with --kit.
// Both are quick, so this can rerun on any build. zsign and OpenSSL, which take minutes, are spzsign's
// (zsign/build.rs): a build script here reruns on every version bump, since cargo fingerprints it by the
// package's version.
use std::{env, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    println!("cargo:rerun-if-env-changed=SP_KIT_SHA256");

    // The icon Explorer shows for both programs (icons/make-icons.sh makes it from art/icon.svg), and the
    // name and version its Properties show.
    println!("cargo:rerun-if-changed=icons/slashplayed.ico");
    if env::var("TARGET").unwrap().contains("windows") {
        let mut res = winresource::WindowsResource::new();
        res.set_icon(manifest.join("icons/slashplayed.ico").to_str().expect("a UTF-8 path"))
            .set("ProductName", "Slashplayed Companion")
            .set("FileDescription", "Slashplayed Companion");
        res.compile().expect("couldn't compile the Windows resources (rc.exe, from the Windows SDK)");
    }

    if let Ok(h) = env::var("SP_KIT_SHA256") {
        let h = h.trim().to_ascii_lowercase();
        if h.len() != 64 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
            panic!("SP_KIT_SHA256 isn't a SHA-256 in hex");
        }
        println!("cargo:rustc-env=SP_KIT_SHA256={h}");
    }
}
