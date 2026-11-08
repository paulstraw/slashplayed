// The development certificate's private key, kept between runs so a weekly re-sign reuses the team's
// certificate instead of making another (free teams get few). In the OS's own credential store, never a
// file: the macOS Keychain, Windows Credential Manager, or the Secret Service on Linux (GNOME Keyring,
// KWallet). One item per Apple ID, as the spike kept it: a key can back a certificate on each of its teams.
// Nothing of the Apple ID's login is ever stored (owner decision: the host holds it in memory only).
//
// Where there's no store (a Linux box with no Secret Service running, say), the run still works: a fresh
// key, a new certificate, and the previous Slashplayed certificate revoked if the team is full
// (provision.rs). The key is never printed or logged, and leaves this process only for the store.

use rootcause::prelude::*;
use rsa::{
    RsaPrivateKey,
    pkcs8::{DecodePrivateKey, EncodePrivateKey},
};
use zeroize::{Zeroize, Zeroizing};

pub const SERVICE: &str = "com.strawdynamics.slashplayed.companion-rs";

pub enum Loaded {
    Key(RsaPrivateKey),
    None,
    /// No store to use, and why (for the one line the run says about it).
    Unavailable(String),
}

/// keyring's calls block, and its Secret Service backend runs its own async runtime, which can't start
/// inside this tool's: so each call gets a plain thread.
fn off_runtime<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    std::thread::spawn(f).join().expect("keystore thread panicked")
}

fn unavailable(e: &keyring::Error) -> bool {
    matches!(e, keyring::Error::NoStorageAccess(_) | keyring::Error::PlatformFailure(_))
}

pub fn load(apple_id: &str) -> Loaded {
    let id = apple_id.to_string();
    off_runtime(move || {
        let entry = match keyring::Entry::new(SERVICE, &id) {
            Ok(e) => e,
            Err(e) => return Loaded::Unavailable(e.to_string()),
        };
        match entry.get_secret() {
            Ok(mut der) => {
                let key = RsaPrivateKey::from_pkcs8_der(&der);
                der.zeroize();
                match key {
                    Ok(k) => Loaded::Key(k),
                    // A damaged item is replaced at the next save; the certificate it backed is then unusable.
                    Err(_) => Loaded::None,
                }
            }
            Err(keyring::Error::NoEntry) => Loaded::None,
            Err(e) if unavailable(&e) => Loaded::Unavailable(e.to_string()),
            Err(e) => Loaded::Unavailable(e.to_string()),
        }
    })
}

/// Stores the key. Err means it couldn't be kept: the caller goes on with it for this run.
pub fn save(apple_id: &str, key: &RsaPrivateKey) -> Result<(), Report> {
    let der = Zeroizing::new(key.to_pkcs8_der().map_err(|_| report!("couldn't encode the key"))?.as_bytes().to_vec());
    let id = apple_id.to_string();
    off_runtime(move || {
        keyring::Entry::new(SERVICE, &id)
            .and_then(|e| e.set_secret(&der))
            .map_err(|e| report!("couldn't keep the signing key in this computer's credential store ({e})"))
    })
}

/// Deletes the key (`forget`). True when there was one.
pub fn forget(apple_id: &str) -> Result<bool, Report> {
    let id = apple_id.to_string();
    off_runtime(move || match keyring::Entry::new(SERVICE, &id).and_then(|e| e.delete_credential()) {
        Ok(()) => Ok(true),
        Err(keyring::Error::NoEntry) => Ok(false),
        Err(e) => Err(report!("couldn't delete the signing key from this computer's credential store ({e})")),
    })
}
