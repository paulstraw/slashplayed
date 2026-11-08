// Credentials on the way to the device. The owner's rule (CLAUDE.md, "Pairing records are credentials"): a
// pairing record goes from memory to the device's container, never through a log; where one has to touch
// the disk it's a file only this user can read, zeroed, then deleted. This tool pushes it straight from
// memory over AFC (src/device.rs), so the disk is touched only by the scratch folder below, which never
// holds a credential: the unsigned app, the IPA, and the kit.

use std::path::{Path, PathBuf};

use rootcause::prelude::*;

/// A private scratch folder (0700 on Unix; on Windows under the user's own %TEMP%, which only they and
/// administrators can read), deleted with everything in it when dropped.
pub struct Scratch(PathBuf);

impl Scratch {
    pub fn new(label: &str) -> Result<Self, Report> {
        let mut bytes = [0u8; 8];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut bytes);
        let dir = std::env::temp_dir().join(format!("slashplayed-{label}-{}", hex::encode(bytes)));
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&dir)
                .map_err(|e| report!("couldn't make a scratch folder in {}: {e}", std::env::temp_dir().display()))?;
        }
        #[cfg(not(unix))]
        std::fs::create_dir(&dir)
            .map_err(|e| report!("couldn't make a scratch folder in {}: {e}", std::env::temp_dir().display()))?;
        Ok(Self(dir))
    }
    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An error as the chain of what failed, without the attachments isideload hangs on its reports (raw
/// response bodies, plists), which can hold account data.
pub fn safe_error(e: &Report) -> String {
    e.iter_reports()
        .map(|n| n.format_current_context().to_string().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(": ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scratch_is_private_and_goes_away() {
        let s = Scratch::new("test").unwrap();
        let p = s.path().to_path_buf();
        std::fs::write(p.join("f"), b"x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o700);
        }
        drop(s);
        assert!(!p.exists());
    }
}
