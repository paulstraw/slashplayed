// Compiles zsign into the tool: its bundle signer (zsign's own sources, at the commit scripts/build-zsign.sh
// pins, with scripts/zsign.patch applied: `scripts/build-zsign.sh source` puts them in work/zsign/src/zsign,
// or SP_ZSIGN_SRC names another copy), our C entry point (zsign/spzsign_host.cpp), the zlib and minizip
// zsign carries, and OpenSSL's libcrypto from source (openssl-src), all linked statically. Never zsign's
// prebuilt Windows OpenSSL (build/windows/vs2022/{include,lib}): only its two Windows helpers, iconv.cpp
// and common_win32.h, which its own Windows build compiles too.
//
// Also takes SP_KIT_SHA256, the device kit's SHA-256 a release build checks its download against
// (src/kit.rs); a build without it only takes a kit named with --kit.
use std::{env, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let zsign = env::var_os("SP_ZSIGN_SRC")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest.join("../../work/zsign/src/zsign"));
    let src = zsign.join("src");
    println!("cargo:rerun-if-env-changed=SP_ZSIGN_SRC");
    println!("cargo:rerun-if-env-changed=SP_KIT_SHA256");
    println!("cargo:rerun-if-changed=zsign/spzsign_host.cpp");
    // The patch's InitData is what the entry point calls; its absence means an unpatched or missing tree.
    let openssl_h = std::fs::read_to_string(src.join("openssl.h")).unwrap_or_default();
    if !openssl_h.contains("InitData") {
        panic!(
            "no patched zsign source at {} (run scripts/build-zsign.sh source, or set SP_ZSIGN_SRC)",
            zsign.display()
        );
    }

    let ssl = openssl_src::Build::new().build();
    let target = env::var("TARGET").unwrap();
    let windows = target.contains("windows");

    // zlib and minizip, as zsign's Makefiles build them (minizip's archive code is linked but unused: the
    // tool signs a folder, never an .ipa).
    let mut c = cc::Build::new();
    c.include(src.join("third-party/zlib")).warnings(false).opt_level(2);
    for f in [
        "adler32", "compress", "crc32", "deflate", "gzclose", "gzlib", "gzread", "gzwrite", "infback",
        "inffast", "inflate", "inftrees", "trees", "uncompr", "zutil",
    ] {
        c.file(src.join(format!("third-party/zlib/{f}.c")));
    }
    for f in ["ioapi", "zip", "unzip"] {
        c.file(src.join(format!("third-party/minizip/{f}.c")));
    }
    if windows {
        c.file(src.join("third-party/minizip/iowin32.c"))
            .define("_CRT_SECURE_NO_WARNINGS", None)
            .define("_CRT_NONSTDC_NO_DEPRECATE", None);
    } else {
        // zlib's gz* files use these POSIX calls; without the declaration they're implicit (an error on
        // newer compilers).
        c.define("HAVE_UNISTD_H", None);
    }
    c.compile("spzlib");

    let mut cpp = cc::Build::new();
    cpp.cpp(true)
        .std("c++14")
        .warnings(false)
        .opt_level(2)
        .include(&src)
        .include(src.join("common"))
        .include(src.join("third-party/zlib"))
        .include(ssl.include_dir())
        .define("ZSIGN_VERSION", "slashplayed");
    for f in [
        "archo", "bundle", "macho", "openssl", "signing", "certcheck", "metadata", "common/archive",
        "common/fs", "common/json", "common/log", "common/sha", "common/timer", "common/util",
    ] {
        cpp.file(src.join(format!("{f}.cpp")));
    }
    if windows {
        let win = zsign.join("build/windows/vs2022/zsign/src");
        cpp.include(&win)
            .file(win.join("iconv.cpp"))
            .define("WIN32", None)
            .define("_CRT_SECURE_NO_WARNINGS", None)
            .define("_CRT_NONSTDC_NO_DEPRECATE", None)
            .flag_if_supported("/EHsc")
            .flag_if_supported("/utf-8");
    }
    cpp.file(manifest.join("zsign/spzsign_host.cpp"));
    cpp.compile("spzsign");

    println!("cargo:rustc-link-search=native={}", ssl.lib_dir().display());
    println!("cargo:rustc-link-lib=static=crypto");
    if windows {
        // libcrypto's own Windows dependencies.
        for l in ["crypt32", "ws2_32", "advapi32", "user32", "bcrypt"] {
            println!("cargo:rustc-link-lib={l}");
        }
    }

    if let Ok(h) = env::var("SP_KIT_SHA256") {
        let h = h.trim().to_ascii_lowercase();
        if h.len() != 64 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
            panic!("SP_KIT_SHA256 isn't a SHA-256 in hex");
        }
        println!("cargo:rustc-env=SP_KIT_SHA256={h}");
    }
}
