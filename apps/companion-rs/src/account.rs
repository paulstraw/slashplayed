// The Apple ID sign-in (GSA over SRP, 2FA, anisette from a remote-v3 server) and the developer session it
// gives, through isideload. Owner decisions (2026-11-01): the password is typed by the person, used once for
// the login, and held only in memory; nothing about it is logged, not even its length; the whole login lives
// in this process and is gone when it exits. So a run asks for the password (and usually a 2FA code) every
// time: the session it mints is used within minutes, well inside the hour a fresh login's token can mint for
// (research/isideload/README.md, "Token lifetime").
//
// No tracing subscriber is installed anywhere in this tool, so nothing isideload logs reaches any output; and
// DEBUG_SENSITIVE, which makes it put whole plists and the full email into errors, is cleared before the
// runtime starts (lib.rs, init).

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use isideload::{
    anisette::{
        AnisetteClientInfo,
        remote_v3::{ANISETTE_STATE_KEY, RemoteV3AnisetteProvider},
    },
    auth::apple_account::{AppToken, AppleAccount},
    dev::developer_session::DeveloperSession,
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use zeroize::Zeroizing;

use crate::flow::Frontend;

/// iloader 2.4.1's default: a server backed by Apple's Mac ADI. The Android-ADI servers (ani.sidestore.io,
/// ani.stikstore.app, ani.jkcoxson.com) have been refused with GSA -80045 since about 2026-10-12
/// (research/isideload/README.md, "Anisette"). --anisette names another, such as one you run yourself.
pub const DEFAULT_ANISETTE: &str = "https://mac-ani.jkcoxson.com";

/// The client identity iloader 2.4.1 sends in place of the server's (its fix for SMS 2FA 403s), which
/// every request of the login must then claim.
fn client_info_override() -> AnisetteClientInfo {
    AnisetteClientInfo {
        client_info: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>".into(),
        user_agent: "akd/1.0 CFNetwork/811.5.4".into(),
    }
}

/// isideload's storage, in memory only: the anisette provisioning state lives as long as the run.
#[derive(Clone, Default)]
struct MemoryStorage(Arc<Mutex<HashMap<String, String>>>);

impl SideloadingStorage for MemoryStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).insert(key.into(), value.into());
        Ok(())
    }
    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self.0.lock().unwrap_or_else(|p| p.into_inner()).get(key).cloned())
    }
    fn delete(&self, key: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).remove(key);
        Ok(())
    }
}

/// What the device keeps of this sign-in, as the launcher's spapple.m stores it and spapple's Token reads it
/// (apps/client/spapple/src/lib.rs): the xcode.auth app token, the adsid it goes with, and the anisette
/// server and machine identity it was made on. Pushed as Library/spappletoken.json, so the device can get its
/// own renewed profiles from Apple with no computer. A credential: never logged, not even its size.
pub fn device_token(token: &AppToken, adsid: &str, anisette_url: &str, anisette_state: &str) -> Result<Zeroizing<Vec<u8>>, Report> {
    Ok(Zeroizing::new(serde_json::to_vec(&serde_json::json!({
        "token": token.token, "expiry": token.expiry, "duration": token.duration, "adsid": adsid,
        "anisette_url": anisette_url, "anisette_state": anisette_state,
    }))?))
}

/// Signs in and returns a developer session, and the device's token (device_token). The password comes from
/// the Frontend here, once the anisette server has provisioned, and is dropped (zeroed) as soon as the login
/// call returns; the Frontend answers the 2FA step. With the server's client
/// identity (--server-client-info) there's no device token: the device always claims the override's.
pub async fn sign_in(
    apple_id: &str,
    anisette_url: &str,
    server_client_info: bool,
    ui: &dyn Frontend,
) -> Result<(DeveloperSession, Option<Zeroizing<Vec<u8>>>), Report> {
    let storage = MemoryStorage::default();
    let provider = RemoteV3AnisetteProvider::new(anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override((!server_client_info).then(client_info_override));
    let mut account = AppleAccount::builder(apple_id).anisette_provider(provider).build().await?;
    let password = ui.password(apple_id).await?;
    if password.is_empty() {
        bail!("no password typed");
    }
    let result = account.login(&password, |params| ui.two_factor(params)).await;
    drop(password);
    result.context("Apple didn't accept the sign-in")?;
    let token = account.get_app_token("xcode.auth").await?;
    let adsid = account
        .spd
        .as_ref()
        .and_then(|s| s.get("adsid"))
        .and_then(|v| v.as_string())
        .ok_or_else(|| report!("signed in, but Apple sent no session data"))?
        .to_string();
    let device = if server_client_info {
        None
    } else {
        let state = Zeroizing::new(storage.retrieve(ANISETTE_STATE_KEY)?.unwrap_or_default());
        Some(device_token(&token, &adsid, anisette_url, &state)?)
    };
    Ok((DeveloperSession::new(token, adsid, account.grandslam_client.clone(), account.anisette_generator.clone()), device))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pushed file has exactly the fields spapple's Token reads (apps/client/spapple/src/lib.rs), with
    /// Apple's numbers as numbers: the launcher (spapple.m) refuses one that doesn't.
    #[test]
    fn device_token_is_spapples_token() {
        let t = AppToken { token: "t".into(), duration: 31_536_000, expiry: 1_825_113_229_999 };
        let v: serde_json::Value = serde_json::from_slice(&device_token(&t, "a", "https://anisette.example", "s").unwrap()).unwrap();
        let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        assert_eq!(keys, ["adsid", "anisette_state", "anisette_url", "duration", "expiry", "token"]);
        assert!(v["expiry"].is_u64() && v["duration"].is_u64());
    }
}
