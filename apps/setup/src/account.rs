// The Apple ID sign-in (GSA over SRP, 2FA, anisette from a remote-v3 server) and the developer session it
// gives, through isideload. Owner decisions (2026-11-01): the password is typed by the person, used once for
// the login, and held only in memory; nothing about it is logged, not even its length; the whole login lives
// in this process and is gone when it exits. So a run asks for the password (and usually a 2FA code) every
// time: the session it mints is used within minutes, well inside the hour a fresh login's token can mint for
// (research/isideload/README.md, "Token lifetime").
//
// No tracing subscriber is installed anywhere in this tool, so nothing isideload logs reaches any output; and
// DEBUG_SENSITIVE, which makes it put whole plists and the full email into errors, is cleared before the
// runtime starts (main.rs).

use std::{
    collections::HashMap,
    io::{BufRead, Write},
    sync::{Arc, Mutex},
};

use isideload::{
    anisette::{AnisetteClientInfo, remote_v3::RemoteV3AnisetteProvider},
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::developer_session::DeveloperSession,
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use zeroize::Zeroizing;

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

/// One line from the person (stdin), for the Apple ID, team, and 2FA prompts.
pub fn ask(prompt: &str) -> Result<String, Report> {
    eprint!("{prompt}");
    std::io::stderr().flush()?;
    let mut line = String::new();
    if std::io::stdin().lock().read_line(&mut line)? == 0 {
        bail!("no answer (the input ended)");
    }
    Ok(line.trim().to_string())
}

async fn two_factor(params: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, Report> {
    if params.unknown {
        eprintln!("That didn't work. Try again, or pick another way to get a code.");
    }
    if !params.numbers.is_empty() {
        eprintln!("Type \"sms <n>\" to get a text instead, \"devices\" for your Apple devices, \"resend\", or \"abort\":");
        // Apple sends the numbers masked; they're shown only on this person's own screen.
        for n in &params.numbers {
            eprintln!("  {}: {}", n.id, n.number_with_dial_code);
        }
    }
    let line = ask(if params.sms { "Code from the text message: " } else { "Code shown on your Apple devices: " })?;
    Ok(match line.as_str() {
        "abort" | "" => TwoFactorCallbackResponse::Abort,
        "devices" => TwoFactorCallbackResponse::SendToDevices,
        "resend" => TwoFactorCallbackResponse::ResendCode,
        s if s.starts_with("sms ") => TwoFactorCallbackResponse::SendSms(
            s[4..].trim().parse().map_err(|_| report!("not a number from the list"))?,
        ),
        s => TwoFactorCallbackResponse::SubmitCode(s.to_string()),
    })
}

/// Signs in and returns a developer session. The password is read here, with no echo, and dropped
/// (zeroed) as soon as the login call returns.
pub async fn sign_in(apple_id: &str, anisette_url: &str, server_client_info: bool) -> Result<DeveloperSession, Report> {
    let storage = MemoryStorage::default();
    let provider = RemoteV3AnisetteProvider::new(anisette_url, Box::new(storage), "0".into())?
        .set_client_info_override((!server_client_info).then(client_info_override));
    let mut account = AppleAccount::builder(apple_id).anisette_provider(provider).build().await?;
    let password = Zeroizing::new(
        rpassword::prompt_password(format!("Apple ID password for {apple_id} (not shown as you type): "))
            .map_err(|_| report!("couldn't read the password: run this in a terminal"))?,
    );
    if password.is_empty() {
        bail!("no password typed");
    }
    let result = account.login(&password, two_factor).await;
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
    Ok(DeveloperSession::new(token, adsid, account.grandslam_client.clone(), account.anisette_generator.clone()))
}
