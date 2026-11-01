// Signing in (GSA over SRP, 2FA, anisette from a remote-v3 server) and getting a developer session back
// from what store.rs kept. isideload does the protocol; this decides what's kept and for how long.
//
// The password is typed by the person into the controlling terminal with no echo (rpassword reads
// /dev/tty, not stdin or argv or the environment), lives in a Zeroizing buffer for the one login call,
// and is gone after. isideload takes it as &str and copies it into SRP's own buffers, which it doesn't
// zero: a gap a shipping tool should close upstream.

use std::{
    collections::HashMap,
    io::{BufRead, Write},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use isideload::{
    anisette::AnisetteClientInfo,
    anisette::remote_v3::{ANISETTE_STATE_KEY, RemoteV3AnisetteProvider},
    auth::apple_account::{
        AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
    },
    dev::developer_session::DeveloperSession,
    util::storage::SideloadingStorage,
};
use plist::{Dictionary, Value};
use rootcause::prelude::*;
use zeroize::Zeroizing;

use crate::store::{self, Stored};

// iloader's default (v2.4.1): a server backed by Apple's Mac ADI. The Android-ADI servers (ani.sidestore.io,
// ani.stikstore.app, ani.jkcoxson.com) have got GSA's -80045 at login since about 2026-10-12: Apple now
// refuses anisette whose machine doesn't match the X-Mme-Client-Info it's sent with
// (Dadoum/anisette-v3-server#61). README.md, "Anisette".
pub const DEFAULT_ANISETTE: &str = "https://mac-ani.jkcoxson.com";

/// The client identity iloader v2.4.1 sends in place of what the server reports ("temporarily ... while
/// waiting for the anisette servers to update"; its fix for SMS 2FA 403s and other errors). Used unless
/// --server-client-info, and kept with the login: every later request must claim the same machine.
fn client_info_override() -> AnisetteClientInfo {
    AnisetteClientInfo {
        client_info: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>".into(),
        user_agent: "akd/1.0 CFNetwork/811.5.4".into(),
    }
}

/// isideload's storage trait over a map this code can read back after the crate is done with it: the
/// anisette provider owns its storage box, and the state it provisions has to go into store.rs.
#[derive(Clone, Default)]
pub struct SharedStorage(Arc<Mutex<HashMap<String, String>>>);

impl SideloadingStorage for SharedStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.0
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(key.to_string(), value.to_string());
        Ok(())
    }
    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self
            .0
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(key)
            .cloned())
    }
    fn delete(&self, key: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).remove(key);
        Ok(())
    }
}

impl SharedStorage {
    /// The anisette state as isideload stored it (base64 of an XML plist), or empty.
    fn anisette_state(&self) -> String {
        self.retrieve(ANISETTE_STATE_KEY)
            .ok()
            .flatten()
            .unwrap_or_default()
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn account(
    apple_id: &str,
    anisette_url: &str,
    server_client_info: bool,
    storage: &SharedStorage,
) -> Result<AppleAccount, Report> {
    let provider = RemoteV3AnisetteProvider::new(anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override((!server_client_info).then(client_info_override));
    AppleAccount::builder(apple_id)
        .anisette_provider(provider)
        .build()
        .await
}

/// Reads one line from the terminal (not stdin, which may be redirected), for 2FA choices and codes.
fn tty_line(prompt: &str) -> Result<String, Report> {
    let tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .map_err(|_| report!("login needs a terminal: run it yourself in Terminal"))?;
    let mut out = tty.try_clone()?;
    write!(out, "{prompt}")?;
    out.flush()?;
    let mut line = String::new();
    std::io::BufReader::new(tty).read_line(&mut line)?;
    Ok(line.trim().to_string())
}

/// The 2FA prompt: a code from a trusted device by default; "sms" lists the trusted numbers Apple
/// gives (already masked by Apple, shown only on the person's own terminal).
async fn two_factor(params: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, Report> {
    if params.unknown {
        eprintln!("That 2FA method didn't work.");
    }
    let others: Vec<_> = params.numbers.iter().collect();
    if !others.is_empty() {
        eprintln!("Type \"sms <n>\" to get a text instead, \"devices\" for your devices, \"resend\", or \"abort\":");
        for n in &others {
            eprintln!("  {}: {}", n.id, n.number_with_dial_code);
        }
    }
    let line = tty_line(if params.sms {
        "Code from the text message: "
    } else {
        "Code shown on your Apple devices: "
    })?;
    Ok(match line.as_str() {
        "abort" | "" => TwoFactorCallbackResponse::Abort,
        "devices" => TwoFactorCallbackResponse::SendToDevices,
        "resend" => TwoFactorCallbackResponse::ResendCode,
        s if s.starts_with("sms ") => TwoFactorCallbackResponse::SendSms(
            s[4..]
                .trim()
                .parse()
                .map_err(|_| report!("not a number from the list"))?,
        ),
        s => TwoFactorCallbackResponse::SubmitCode(s.to_string()),
    })
}

fn spd_string(spd: &Dictionary, key: &str) -> Result<String, Report> {
    Ok(spd
        .get(key)
        .and_then(Value::as_string)
        .ok_or_else(|| report!("Apple's login response had no {key}"))?
        .to_string())
}
fn spd_data(spd: &Dictionary, key: &str) -> Result<String, Report> {
    Ok(Stored::encode(
        spd.get(key)
            .and_then(Value::as_data)
            .ok_or_else(|| report!("Apple's login response had no {key}"))?,
    ))
}

/// The owner's step: password (no echo) and 2FA on their own terminal, then what later runs need goes to
/// the keychain. Returns the developer session for the report's team list, and the xcode token's stated
/// expiry and duration (Apple's numbers, not secrets).
pub async fn login(
    apple_id: &str,
    anisette_url: &str,
    server_client_info: bool,
) -> Result<(DeveloperSession, u64, u64), Report> {
    let storage = SharedStorage::default();
    // A key made by an earlier login (a certificate on the team uses it) outlives re-logins.
    let previous_key = store::load(apple_id)?.map(|s| s.signing_key.clone());
    let mut account = account(apple_id, anisette_url, server_client_info, &storage).await?;
    let password = Zeroizing::new(
        rpassword::prompt_password(format!("Apple ID password for {apple_id}: "))
            .map_err(|_| report!("couldn't read the password from the terminal"))?,
    );
    if password.is_empty() {
        bail!("no password typed");
    }
    account.login(&password, two_factor).await?;
    drop(password);
    let token = account.get_app_token("xcode.auth").await?;
    let spd = account
        .spd
        .as_ref()
        .ok_or_else(|| report!("logged in, but Apple sent no session data"))?;
    let stored = Stored {
        version: 1,
        anisette_url: anisette_url.to_string(),
        server_client_info,
        logged_in_at: now(),
        anisette_state: storage.anisette_state(),
        adsid: spd_string(spd, "adsid")?,
        gs_idms_token: spd_string(spd, "GsIdmsToken")?,
        sk: spd_data(spd, "sk")?,
        c: spd_data(spd, "c")?,
        xcode_token: token.token.clone(),
        xcode_token_expiry: token.expiry,
        xcode_token_duration: token.duration,
        signing_key: previous_key.unwrap_or_default(),
    };
    store::save(apple_id, &stored)?;
    let (expiry, duration) = (token.expiry, token.duration);
    let session = DeveloperSession::new(
        token,
        stored.adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    Ok((session, expiry, duration))
}

/// What came back from the keychain, and an account on the same anisette identity, ready to use.
pub struct Restored {
    pub stored: Stored,
    pub account: AppleAccount,
    storage: SharedStorage,
}

pub async fn restore(apple_id: &str) -> Result<Restored, Report> {
    let stored = store::load(apple_id)?.ok_or_else(|| {
        report!("no stored login for that Apple ID: the owner runs `spisideload login` first")
    })?;
    let storage = SharedStorage::default();
    if !stored.anisette_state.is_empty() {
        storage.store(ANISETTE_STATE_KEY, &stored.anisette_state)?;
    }
    let mut account =
        account(apple_id, &stored.anisette_url, stored.server_client_info, &storage).await?;
    let mut spd = Dictionary::new();
    spd.insert("adsid".into(), Value::String(stored.adsid.clone()));
    spd.insert("GsIdmsToken".into(), Value::String(stored.gs_idms_token.clone()));
    spd.insert("sk".into(), Value::Data(Stored::bytes(&stored.sk)?));
    spd.insert("c".into(), Value::Data(Stored::bytes(&stored.c)?));
    account.spd = Some(spd);
    Ok(Restored {
        stored,
        account,
        storage,
    })
}

impl Restored {
    /// A session on the xcode token login stored (check-session's first question).
    pub fn stored_session(&self) -> DeveloperSession {
        DeveloperSession::new(
            AppToken {
                token: self.stored.xcode_token.clone(),
                duration: self.stored.xcode_token_duration,
                expiry: self.stored.xcode_token_expiry,
            },
            self.stored.adsid.clone(),
            self.account.grandslam_client.clone(),
            self.account.anisette_generator.clone(),
        )
    }

    /// A session on a new xcode token minted from the stored GS token (what every provision run uses,
    /// as a host would: a minute's work, no password). The new token isn't stored.
    pub async fn minted_session(&mut self) -> Result<(DeveloperSession, AppToken), Report> {
        let token = self.account.get_app_token("xcode.auth").await?;
        let session = DeveloperSession::new(
            token.clone(),
            self.stored.adsid.clone(),
            self.account.grandslam_client.clone(),
            self.account.anisette_generator.clone(),
        );
        Ok((session, token))
    }

    /// Writes back what may have changed: the anisette state (re-provisioned if the server said it had
    /// to be) and the signing key.
    pub fn save(&mut self, apple_id: &str) -> Result<(), Report> {
        let state = self.storage.anisette_state();
        if !state.is_empty() {
            self.stored.anisette_state = state;
        }
        store::save(apple_id, &self.stored)
    }
}
