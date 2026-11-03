// The device kit: the device app, unsigned, as the release built it (scripts/release/device-kit.sh, from what
// apps/companion/bundle-resources.sh stages: the launcher, the JIT helper, the shims, the icon, the licenses,
// the font, the addons, flavors.plist, the root CAs), one per platform. Nothing in it is Blizzard's: there are
// no game images, and the device installs games itself (sppatch.m). Its Info.plists are filled in for the
// platform and version already; only the bundle ID is left, as @BUNDLE_ID@, and the entitlements are the
// templates (@TEAM@, @BUNDLE_ID@). This file fills those in, as the Mac's ClientAssembly does
// (infoPlist, entitlements, removing), so the host needs no copy of the assembly itself.
//
// A release build has the kit's SHA-256 compiled in (build.rs, SP_KIT_SHA256) and downloads it from its own
// GitHub Release; any other kit is named with --kit and taken as it is.

use std::{
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

use rootcause::prelude::*;
use sha2::{Digest, Sha256};

/// The release the kit comes from: the tag this build was made for (SP_RELEASE_TAG at build time, as the
/// release workflow sets it for a prerelease), else v<version>.
pub fn release_tag() -> String {
    option_env!("SP_RELEASE_TAG")
        .map(str::to_string)
        .unwrap_or_else(|| format!("v{}", env!("CARGO_PKG_VERSION")))
}

pub const ASSET: &str = "slashplayed-device-kit.zip";
const REPO: &str = "paulstraw/slashplayed";
/// The platform this tool installs for: iPad and iPhone. Vision Pro stays Mac-only (docs).
pub const PLATFORM: &str = "ios";
/// The JIT helper's bundle, inside the app (ClientAssembly.helperName).
pub const HELPER: &str = "PlugIns/SPJitHelper.appex";
/// The memory entitlement a free team's profile can't have (Signing.freeTeamDropped).
pub const FREE_TEAM_DROPPED: &[&str] = &["com.apple.developer.kernel.extended-virtual-addressing"];

/// How long a connection may take to open, and how long a download may go without a byte before it's
/// given up on (the read timeout resets on every read, so a slow but moving download of the tens-of-MB kit
/// never trips it, where a total timeout would on a slow link).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const STALL_TIMEOUT: Duration = Duration::from_secs(60);

/// The one HTTP client for every download (the kit, ddi.rs's disk image): bare `reqwest::get` has no
/// timeout at all, so a stalled connection hung the run forever. TLS is rustls with the ring provider
/// main.rs installs as the process default (reqwest is built with rustls-no-provider), so this is only
/// called after that, never from a unit test.
pub fn http_client() -> Result<reqwest::Client, Report> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(STALL_TIMEOUT)
        .build()
        .map_err(|e| report!("couldn't set up HTTPS: {e}"))
}

/// A download error in words, saying plainly when it was one of http_client's timeouts: reqwest's own
/// Display for one ("error sending request for url (…)") doesn't.
pub fn http_error(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        format!(
            "it timed out (no connection in {} s, or no data for {} s)",
            CONNECT_TIMEOUT.as_secs(),
            STALL_TIMEOUT.as_secs()
        )
    } else {
        e.to_string()
    }
}

pub fn pinned_sha256() -> Option<&'static str> {
    option_env!("SP_KIT_SHA256")
}

/// The kit's bytes: `path` when given, else the release's asset, checked against the pinned hash.
pub async fn fetch(path: Option<&Path>) -> Result<(Vec<u8>, String), Report> {
    if let Some(p) = path {
        let bytes = std::fs::read(p).map_err(|e| report!("couldn't read the kit {}: {e}", p.display()))?;
        let sha = hex::encode(Sha256::digest(&bytes));
        return Ok((bytes, format!("{} (SHA-256 {sha})", p.display())));
    }
    let Some(want) = pinned_sha256() else {
        bail!("this build of slashplayed-companion has no device kit pinned: name one with --kit <{ASSET}>");
    };
    let tag = release_tag();
    let url = format!("https://github.com/{REPO}/releases/download/{tag}/{ASSET}");
    let bytes = http_client()?
        .get(&url)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| report!("couldn't download the device kit from {url}: {}", http_error(&e)))?
        .bytes()
        .await
        .map_err(|e| report!("the device kit's download from {url} broke off: {}", http_error(&e)))?
        .to_vec();
    let got = hex::encode(Sha256::digest(&bytes));
    if got != want {
        bail!("the device kit from {url} isn't the one this build was made with (SHA-256 {got}, not {want})");
    }
    Ok((bytes, format!("{tag}'s {ASSET}")))
}

/// What extract leaves: the unsigned app and the two entitlements templates.
pub struct Kit {
    pub app: PathBuf,
    pub entitlements: String,
    pub helper_entitlements: String,
    pub version: String,
}

/// Unpacks the platform's part of the kit into `dir`. Paths are checked (no absolute path, no ..), and
/// nothing outside `<platform>/` and kit.json is written.
pub fn extract(bytes: &[u8], dir: &Path) -> Result<Kit, Report> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|e| report!("the device kit isn't a zip: {e}"))?;
    let mut version = None;
    for i in 0..zip.len() {
        let mut f = zip.by_index(i).map_err(|e| report!("the device kit is damaged: {e}"))?;
        let Some(rel) = f.enclosed_name() else {
            bail!("the device kit has an unsafe path: {}", f.name());
        };
        if rel == Path::new("kit.json") {
            let mut s = String::new();
            f.read_to_string(&mut s)?;
            let v: serde_json::Value = serde_json::from_str(&s).map_err(|_| report!("the kit's kit.json isn't JSON"))?;
            version = v["version"].as_str().map(str::to_string);
            continue;
        }
        if !rel.starts_with(PLATFORM) {
            continue;
        }
        let out = dir.join(&rel);
        if f.is_dir() {
            std::fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(p) = out.parent() {
            std::fs::create_dir_all(p)?;
        }
        let mut data = Vec::with_capacity(f.size() as usize);
        f.read_to_end(&mut data)?;
        std::fs::write(&out, data)?;
    }
    let root = dir.join(PLATFORM);
    let app = root.join("Slashplayed.app");
    for need in ["slashplayed", "Info.plist", "flavors.plist", "SPJitHelper"] {
        let p = if need == "SPJitHelper" { app.join(HELPER).join(need) } else { app.join(need) };
        if !p.is_file() {
            bail!("the device kit has no {}", p.strip_prefix(dir).unwrap_or(&p).display());
        }
    }
    let read = |name: &str| {
        std::fs::read_to_string(root.join(name)).map_err(|_| report!("the device kit has no {PLATFORM}/{name}"))
    };
    Ok(Kit {
        entitlements: read("entitlements.plist")?,
        helper_entitlements: read("helper-entitlements.plist")?,
        app,
        version: version.ok_or_else(|| report!("the device kit has no version in kit.json"))?,
    })
}

/// The helper's bundle ID (ClientAssembly.helperBundleID).
pub fn helper_id(bundle_id: &str) -> String {
    format!("{bundle_id}.helper")
}

/// A bundle ID this tool accepts: dot-separated letters, digits, and hyphens (the Mac's isValidBundlePrefix
/// plus .slashplayed), so it can go into a plist as it is.
pub fn valid_bundle_id(id: &str) -> bool {
    !id.is_empty()
        && id.split('.').all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
}

/// Fills @BUNDLE_ID@ in a kit Info.plist: exactly one, as the template has.
pub fn fill_info_plist(text: &str, bundle_id: &str) -> Result<String, Report> {
    if text.matches("@BUNDLE_ID@").count() != 1 {
        bail!("a kit Info.plist doesn't have exactly one @BUNDLE_ID@");
    }
    Ok(text.replace("@BUNDLE_ID@", bundle_id))
}

/// The entitlements from a template (ClientAssembly.entitlements), less `dropped` (ClientAssembly.removing:
/// the text as it is when nothing is dropped, else re-written as an XML plist).
pub fn entitlements(template: &str, team: &str, bundle_id: &str, dropped: &[&str]) -> Result<String, Report> {
    let filled = template.replace("@TEAM@", team).replace("@BUNDLE_ID@", bundle_id);
    if filled.contains('@') {
        bail!("an entitlements template has a placeholder this tool doesn't fill");
    }
    if dropped.is_empty() {
        return Ok(filled);
    }
    let mut dict: plist::Dictionary =
        plist::from_bytes(filled.as_bytes()).map_err(|_| report!("an entitlements template isn't a plist"))?;
    for k in dropped {
        dict.remove(k);
    }
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &dict)?;
    Ok(String::from_utf8(out).map_err(|_| report!("plist wrote invalid UTF-8"))?)
}

/// Fills both Info.plists of the kit's app for `bundle_id`.
pub fn set_bundle_id(app: &Path, bundle_id: &str) -> Result<(), Report> {
    for (plist, id) in [
        (app.join("Info.plist"), bundle_id.to_string()),
        (app.join(HELPER).join("Info.plist"), helper_id(bundle_id)),
    ] {
        let text = std::fs::read_to_string(&plist)?;
        std::fs::write(&plist, fill_info_plist(&text, &id)?)?;
    }
    Ok(())
}

/// The signed app as an IPA (Payload/Slashplayed.app/…) for installation_proxy, with Unix modes set here
/// rather than taken from the disk, so it's the same from Windows: 0755 for folders and the two executables
/// and the dylibs, 0644 for the rest. Stored, not compressed: the device unpacks it, and most of it is
/// already-compressed Mach-O and asset data.
pub fn ipa(app: &Path, out: &Path) -> Result<(), Report> {
    use zip::write::SimpleFileOptions;
    let file = std::fs::File::create(out)?;
    let mut zip = zip::ZipWriter::new(file);
    let base = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    let mut stack = vec![app.to_path_buf()];
    let mut entries = Vec::new();
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d)? {
            let p = e?.path();
            if p.is_dir() {
                stack.push(p.clone());
            }
            entries.push(p);
        }
    }
    entries.sort();
    zip.add_directory("Payload/Slashplayed.app/", base.unix_permissions(0o755))?;
    for p in entries {
        let rel = p.strip_prefix(app).unwrap();
        let name = format!(
            "Payload/Slashplayed.app/{}",
            rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/")
        );
        if p.is_dir() {
            zip.add_directory(name + "/", base.unix_permissions(0o755))?;
            continue;
        }
        let exec = matches!(rel.to_str(), Some("slashplayed"))
            || rel.ends_with("SPJitHelper")
            || p.extension().is_some_and(|x| x == "dylib");
        zip.start_file(name, base.unix_permissions(if exec { 0o755 } else { 0o644 }))?;
        std::io::copy(&mut std::fs::File::open(&p)?, &mut zip)?;
    }
    zip.finish()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENTS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>application-identifier</key><string>@TEAM@.@BUNDLE_ID@</string>
  <key>com.apple.developer.team-identifier</key><string>@TEAM@</string>
  <key>get-task-allow</key><true/>
  <key>com.apple.developer.kernel.increased-memory-limit</key><true/>
  <key>com.apple.developer.kernel.extended-virtual-addressing</key><true/>
</dict></plist>"#;

    #[test]
    fn entitlements_fill_and_drop() {
        let paid = entitlements(ENTS, "ABCDE12345", "ABCDE12345.slashplayed", &[]).unwrap();
        assert!(paid.contains("<string>ABCDE12345.ABCDE12345.slashplayed</string>"));
        assert!(paid.contains("extended-virtual-addressing"));
        // Unchanged text but for the placeholders, as the Mac signs a paid team's.
        assert_eq!(paid, ENTS.replace("@TEAM@", "ABCDE12345").replace("@BUNDLE_ID@", "ABCDE12345.slashplayed"));
        let free = entitlements(ENTS, "ABCDE12345", "ABCDE12345.slashplayed", FREE_TEAM_DROPPED).unwrap();
        let d: plist::Dictionary = plist::from_bytes(free.as_bytes()).unwrap();
        assert!(!d.contains_key("com.apple.developer.kernel.extended-virtual-addressing"));
        assert_eq!(d.get("com.apple.developer.kernel.increased-memory-limit").and_then(|v| v.as_boolean()), Some(true));
        assert_eq!(d.get("get-task-allow").and_then(|v| v.as_boolean()), Some(true));
        assert_eq!(
            d.get("application-identifier").and_then(|v| v.as_string()),
            Some("ABCDE12345.ABCDE12345.slashplayed")
        );
    }

    #[test]
    fn unknown_placeholder_fails() {
        assert!(entitlements("<string>@OTHER@</string>", "T", "b", &[]).is_err());
    }

    #[test]
    fn info_plist_needs_one_placeholder() {
        assert_eq!(fill_info_plist("<string>@BUNDLE_ID@</string>", "a.b").unwrap(), "<string>a.b</string>");
        assert!(fill_info_plist("<string>x</string>", "a.b").is_err());
        assert!(fill_info_plist("@BUNDLE_ID@ @BUNDLE_ID@", "a.b").is_err());
    }

    #[test]
    fn bundle_ids() {
        assert!(valid_bundle_id("ABCDE12345.slashplayed"));
        assert!(valid_bundle_id("my-team.slashplayed.spike"));
        assert!(!valid_bundle_id(""));
        assert!(!valid_bundle_id("a..b"));
        assert!(!valid_bundle_id("a.b<"));
        assert_eq!(helper_id("a.slashplayed"), "a.slashplayed.helper");
    }

    /// A kit as device-kit.sh writes one, made here (no Blizzard bytes: empty stand-ins).
    fn fake_kit() -> Vec<u8> {
        use zip::write::SimpleFileOptions;
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        let o = SimpleFileOptions::default();
        let mut add = |name: &str, data: &[u8]| {
            z.start_file(name, o).unwrap();
            std::io::Write::write_all(&mut z, data).unwrap();
        };
        add("kit.json", br#"{"version":"9.9.9"}"#);
        add("ios/Slashplayed.app/slashplayed", b"exe");
        add("ios/Slashplayed.app/Info.plist", b"<string>@BUNDLE_ID@</string>");
        add("ios/Slashplayed.app/flavors.plist", b"f");
        add("ios/Slashplayed.app/Frameworks/libspAppKit.dylib", b"d");
        add("ios/Slashplayed.app/PlugIns/SPJitHelper.appex/SPJitHelper", b"h");
        add("ios/Slashplayed.app/PlugIns/SPJitHelper.appex/Info.plist", b"<string>@BUNDLE_ID@</string>");
        add("ios/entitlements.plist", ENTS.as_bytes());
        add("ios/helper-entitlements.plist", b"<string>@TEAM@.@BUNDLE_ID@</string>");
        add("xros/Slashplayed.app/slashplayed", b"not taken");
        z.finish().unwrap();
        out.into_inner()
    }

    #[test]
    fn extract_fill_and_package() {
        let dir = tempfile::tempdir().unwrap();
        let kit = extract(&fake_kit(), dir.path()).unwrap();
        assert_eq!(kit.version, "9.9.9");
        assert!(!dir.path().join("xros").exists());
        set_bundle_id(&kit.app, "T.slashplayed").unwrap();
        assert_eq!(std::fs::read_to_string(kit.app.join("Info.plist")).unwrap(), "<string>T.slashplayed</string>");
        assert_eq!(
            std::fs::read_to_string(kit.app.join(HELPER).join("Info.plist")).unwrap(),
            "<string>T.slashplayed.helper</string>"
        );
        let ipa_path = dir.path().join("a.ipa");
        ipa(&kit.app, &ipa_path).unwrap();
        let mut z = zip::ZipArchive::new(std::fs::File::open(&ipa_path).unwrap()).unwrap();
        let mode = |z: &mut zip::ZipArchive<std::fs::File>, n: &str| z.by_name(n).unwrap().unix_mode().unwrap() & 0o777;
        assert_eq!(mode(&mut z, "Payload/Slashplayed.app/slashplayed"), 0o755);
        assert_eq!(mode(&mut z, "Payload/Slashplayed.app/PlugIns/SPJitHelper.appex/SPJitHelper"), 0o755);
        assert_eq!(mode(&mut z, "Payload/Slashplayed.app/Frameworks/libspAppKit.dylib"), 0o755);
        assert_eq!(mode(&mut z, "Payload/Slashplayed.app/flavors.plist"), 0o644);
    }

    #[test]
    fn unsafe_paths_are_refused() {
        use zip::write::SimpleFileOptions;
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        z.start_file("../evil", SimpleFileOptions::default()).unwrap();
        z.finish().unwrap();
        let dir = tempfile::tempdir().unwrap();
        assert!(extract(&out.into_inner(), dir.path()).is_err());
    }
}
