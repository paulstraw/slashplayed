// The spike's one store of login material: a generic-password item per Apple ID in the Mac's login
// keychain, service SERVICE, holding a binary plist (Stored). Nothing else the spike writes holds a token,
// anisette state, or key; `forget` deletes the item.
//
// The login keychain is the legacy file keychain: its items never sync to iCloud (only data-protection
// keychain items marked synchronizable do), so this is "this device only" in effect. The data-protection
// keychain and its kSecAttrAccessible...ThisDeviceOnly classes need a keychain-access-groups entitlement,
// which an unsigned CLI doesn't have (errSecMissingEntitlement). The item's ACL trusts the binary that
// wrote it, so a rebuilt binary makes macOS ask before reading it: build once, then log in.
//
// Never printed or logged, not even sizes (the owner's rule for Apple ID tokens): callers say only
// whether an item exists.

use base64::prelude::*;
use rootcause::prelude::*;
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

pub const SERVICE: &str = "com.strawdynamics.slashplayed.spike.isideload";
// errSecItemNotFound: no item for that account.
const NOT_FOUND: i32 = -25300;

/// What a login leaves for later runs. Binary fields are base64 strings so the whole thing zeroes on drop.
#[derive(Serialize, Deserialize, Default)]
pub struct Stored {
    pub version: u32,
    /// The anisette server this login was made with: its provisioning state (below) only works there.
    pub anisette_url: String,
    /// Whether login sent the server's client identity rather than session.rs's override: later runs
    /// must claim the same machine.
    #[serde(default)]
    pub server_client_info: bool,
    /// When login finished (Unix seconds): check-session measures the tokens' lifetime from it.
    pub logged_in_at: u64,
    /// The remote-v3 anisette provisioning state (the virtual machine identity GSA saw at login), base64
    /// of isideload's XML plist. A token is tied to it; a new state looks like a new Mac to Apple.
    pub anisette_state: String,
    /// From GSA's SPD after login: what mints app tokens (get_app_token's inputs, nothing else of the SPD).
    pub adsid: String,
    pub gs_idms_token: String,
    pub sk: String,
    pub c: String,
    /// The com.apple.gs.xcode.auth token login minted. Kept unchanged so check-session can tell how long
    /// that first token lasts, apart from how long the GS token above can mint new ones.
    pub xcode_token: String,
    pub xcode_token_expiry: u64,
    pub xcode_token_duration: u64,
    /// The development certificate's RSA key (PKCS#8 DER, base64), made by provision the first time and
    /// reused on every run so the team's certificate is reused too (free teams get few). Per Apple ID: a
    /// key can back a certificate on each of its teams.
    pub signing_key: String,
}

impl Drop for Stored {
    fn drop(&mut self) {
        for s in [
            &mut self.anisette_state,
            &mut self.adsid,
            &mut self.gs_idms_token,
            &mut self.sk,
            &mut self.c,
            &mut self.xcode_token,
            &mut self.signing_key,
        ] {
            s.zeroize();
        }
    }
}

impl Stored {
    pub fn bytes(field: &str) -> Result<Vec<u8>, Report> {
        Ok(BASE64_STANDARD
            .decode(field)
            .map_err(|_| report!("the stored login is damaged; run forget, then login"))?)
    }
    pub fn encode(data: &[u8]) -> String {
        BASE64_STANDARD.encode(data)
    }
}

pub fn load(apple_id: &str) -> Result<Option<Stored>, Report> {
    match get_generic_password(SERVICE, apple_id) {
        Ok(mut data) => {
            let parsed = plist::from_bytes::<Stored>(&data);
            data.zeroize();
            Ok(Some(parsed.map_err(|_| {
                report!("the stored login is damaged; run forget, then login")
            })?))
        }
        Err(e) if e.code() == NOT_FOUND => Ok(None),
        Err(e) => bail!("couldn't read the login keychain item ({})", e.code()),
    }
}

pub fn save(apple_id: &str, stored: &Stored) -> Result<(), Report> {
    let mut data = Vec::new();
    plist::to_writer_binary(&mut data, stored)
        .map_err(|_| report!("couldn't encode the login for the keychain"))?;
    let result = set_generic_password(SERVICE, apple_id, &data);
    data.zeroize();
    result.map_err(|e| report!("couldn't write the login keychain item ({})", e.code()))?;
    Ok(())
}

/// True when there was an item to delete.
pub fn forget(apple_id: &str) -> Result<bool, Report> {
    match delete_generic_password(SERVICE, apple_id) {
        Ok(()) => Ok(true),
        Err(e) if e.code() == NOT_FOUND => Ok(false),
        Err(e) => bail!("couldn't delete the login keychain item ({})", e.code()),
    }
}
