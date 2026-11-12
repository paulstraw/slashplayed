// The developer disk image the JIT helper mounts when the device has none mounted (debugserver is in it;
// apps/client/spjit.m), into Library/spddi/ as the Mac's DeveloperDiskImage.swift puts Xcode's. Owner
// decision (2026-11-01): with no Xcode on the host, the iOS cryptex comes from the doronz88/DeveloperDiskImage
// mirror at run time, from a pinned commit, each file checked against a SHA-256 pinned here; Slashplayed never
// hosts it. The mount itself is still personalized for the device by Apple's TSS server (the helper's
// helper/Device.swift), so Apple's signature, not this pin, is what the device trusts; the pin keeps the
// download what was reviewed.
//
// The image is chip-independent and its version is Xcode's, not the device's: one image mounts on every OS
// version that Xcode supports. Library/spddi/version.txt names the copy and goes last, so an interrupted copy
// or a new pin is copied again.

use rootcause::prelude::*;
use sha2::{Digest, Sha256};

use crate::{
    device,
    flow::Frontend,
    kit::{http_client, http_error},
};

pub const DEVICE_DIR: &str = "Library/spddi";

/// The mirror's commit. Raw URLs at a commit don't change.
pub const MIRROR_COMMIT: &str = "e2aaeac89ca8fa56c2fa1f144d182994e07a525b";
const MIRROR_DIR: &str = "PersonalizedImages/Xcode_iOS_DDI_Cryptex";
/// Xcode's build of the image (the manifest's ProductBuildVersion), for version.txt and the log.
pub const IMAGE_BUILD: &str = "27A5228h";

pub struct File {
    /// Relative to Restore/, as the image's BuildManifest.plist names it (DeveloperDiskImage.cryptexFiles).
    pub path: &'static str,
    pub size: usize,
    pub sha256: &'static str,
}

/// BuildManifest.plist and the four Cryptex1 payloads its "Developer Disk Image Cryptex" identity names.
pub const FILES: &[File] = &[
    File { path: "BuildManifest.plist", size: 804946, sha256: "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012" },
    File { path: "Image.dmg", size: 15895040, sha256: "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176" },
    File { path: "Image.dmg.trustcache", size: 1895, sha256: "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0" },
    File { path: "Image.dmg.cryptex_info", size: 430, sha256: "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c" },
    File { path: "Image.dmg.root_hash", size: 229, sha256: "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302" },
];

pub fn version() -> String {
    format!("doronz88/DeveloperDiskImage {}, image {IMAGE_BUILD}", &MIRROR_COMMIT[..12])
}

fn url(f: &File) -> String {
    format!("https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/{MIRROR_COMMIT}/{MIRROR_DIR}/{}", f.path)
}

/// Checks a downloaded file against its pin.
pub fn verify(f: &File, data: &[u8]) -> Result<(), Report> {
    let got = hex::encode(Sha256::digest(data));
    if data.len() != f.size || got != f.sha256 {
        bail!(
            "the developer disk image's {} from the mirror isn't the pinned one ({} bytes, SHA-256 {got}): nothing was copied",
            f.path,
            data.len()
        );
    }
    Ok(())
}

/// Copies the image into the container unless it holds this version already. Returns whether it copied.
pub async fn send_if_needed(afc: &mut idevice::afc::AfcClient, ui: &dyn Frontend) -> Result<bool, Report> {
    let want = version();
    if let Some(have) = device::get(afc, &format!("{DEVICE_DIR}/version.txt")).await
        && String::from_utf8_lossy(&have).trim() == want
    {
        return Ok(false);
    }
    // All of it downloaded and checked before anything goes to the device.
    let client = http_client()?;
    let mut files = Vec::new();
    for f in FILES {
        let data = client
            .get(url(f))
            .send()
            .await
            .and_then(|r| r.error_for_status())
            .map_err(|e| report!("couldn't download the developer disk image's {} ({})", f.path, http_error(&e)))?
            .bytes()
            .await
            .map_err(|e| report!("the developer disk image's {} download broke off ({})", f.path, http_error(&e)))?;
        verify(f, &data)?;
        files.push((f, data));
    }
    for (f, data) in &files {
        ui.say(&format!("copying the developer disk image's {} ({} bytes)", f.path, data.len()));
        device::put(afc, &format!("{DEVICE_DIR}/Restore/{}", f.path), data).await?;
    }
    let list: String = FILES.iter().map(|f| format!("{}\n", f.path)).collect();
    device::put(afc, &format!("{DEVICE_DIR}/files.txt"), list.as_bytes()).await?;
    device::put(afc, &format!("{DEVICE_DIR}/version.txt"), format!("{want}\n").as_bytes()).await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_are_well_formed() {
        assert_eq!(MIRROR_COMMIT.len(), 40);
        assert_eq!(FILES[0].path, "BuildManifest.plist");
        for f in FILES {
            assert_eq!(f.sha256.len(), 64);
            assert!(!f.path.starts_with('/') && !f.path.contains(".."));
        }
    }

    #[test]
    fn verify_checks_size_and_hash() {
        let f = File { path: "x", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" };
        verify(&f, b"abc").unwrap();
        assert!(verify(&f, b"abd").is_err());
        assert!(verify(&f, b"abcd").is_err());
    }
}
