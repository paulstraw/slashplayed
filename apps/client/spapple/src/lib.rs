// spapple: Apple's developer services for the launcher, through isideload. One C entry point takes a JSON
// request and returns a JSON reply (spapple.h), so the Objective-C side stays a few lines and the Rust side
// owns every type isideload has.
//
// Requests ("op"):
//   "profiles": with the Apple token the device keeps ("token": what spappletoken.m stores), downloads the
//     team provisioning profiles of the App IDs "app" and "helper" on team "team". The reply's "app" and
//     "helper" are the profile files (base64), and "anisette_state" is set when the anisette server
//     re-provisioned this device's machine identity, for the caller to store with the token.
// Every reply has "ok"; a failed one has "error" (for the log and the person) and, when Apple answered with
// one, "code": its developer-services or GrandSlam error number.
//
// The token is a credential (CLAUDE.md, "The Apple ID is a credential"): nothing here logs it or puts it in a
// reply or an error, and its copies are zeroed when the request ends. No tracing subscriber is installed, so
// nothing isideload logs goes anywhere; DEBUG_SENSITIVE, which makes isideload put whole plists into errors,
// is cleared on every call.

use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    sync::{Arc, Mutex, OnceLock},
};

use base64::Engine;
use isideload::{
    SideloadError,
    anisette::{
        AnisetteClientInfo,
        remote_v3::{ANISETTE_STATE_KEY, RemoteV3AnisetteProvider},
    },
    auth::apple_account::{AppToken, AppleAccount},
    dev::{
        app_ids::AppIdsApi, developer_session::DeveloperSession, teams::TeamsApi,
    },
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::{Zeroize, Zeroizing};

/// What the device keeps of a sign-in (spappletoken.m stores it whole, as this JSON): the xcode.auth app
/// token, the account's adsid it goes with, and the anisette server and machine identity it was made on.
/// Every later request has to claim the same machine (research/isideload/README.md, "Anisette").
#[derive(Deserialize)]
struct Token {
    token: String,
    expiry: u64,
    duration: u64,
    adsid: String,
    anisette_url: String,
    #[serde(default)]
    anisette_state: String,
}

impl Drop for Token {
    fn drop(&mut self) {
        self.token.zeroize();
        self.adsid.zeroize();
        self.anisette_state.zeroize();
    }
}

#[derive(Deserialize)]
struct ProfilesRequest {
    token: Token,
    team: String,
    app: String,
    helper: String,
}

/// iloader 2.4.1's client identity, which the companion and the spike send too: the anisette server's own
/// is refused for SMS 2FA, and every request after the login has to claim the one the login did.
fn client_info_override() -> AnisetteClientInfo {
    AnisetteClientInfo {
        client_info: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>".into(),
        user_agent: "akd/1.0 CFNetwork/811.5.4".into(),
    }
}

/// isideload's storage, in memory for the one request: the anisette state goes in from the token and is
/// read back out after, in case the server re-provisioned it.
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

impl Drop for MemoryStorage {
    fn drop(&mut self) {
        // The last clone zeroes what it held (the anisette state is the device's machine identity).
        if Arc::strong_count(&self.0) == 1 {
            for v in self.0.lock().unwrap_or_else(|p| p.into_inner()).values_mut() {
                v.zeroize();
            }
        }
    }
}

/// A failure as one line, its chain of contexts only ("what failed <- why"): not the report's own format, which
/// spans lines and names source files, nor its attachments, where isideload puts response bodies.
fn one_line(e: &Report) -> String {
    e.iter_reports()
        .map(|n| n.format_current_context().to_string().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" <- ")
}

/// The developer-services or GrandSlam error number in a failure, if Apple sent one.
fn apple_code(e: &Report) -> Option<i64> {
    e.iter_reports().find_map(|n| match n.downcast_current_context::<SideloadError>() {
        Some(SideloadError::DeveloperError(code, _)) | Some(SideloadError::AuthWithMessage(code, _)) => Some(*code),
        _ => None,
    })
}

async fn session(token: &Token, storage: &MemoryStorage) -> Result<DeveloperSession, Report> {
    if !token.anisette_state.is_empty() {
        storage.store(ANISETTE_STATE_KEY, &token.anisette_state)?;
    }
    let provider = RemoteV3AnisetteProvider::new(&token.anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override(Some(client_info_override()));
    // No email: the account is only the GrandSlam client and anisette for the session, never logged in here.
    let account = AppleAccount::builder("").anisette_provider(provider).build().await?;
    Ok(DeveloperSession::new(
        AppToken { token: token.token.clone(), duration: token.duration, expiry: token.expiry },
        token.adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    ))
}

async fn profiles(req: ProfilesRequest) -> Result<Value, Report> {
    let storage = MemoryStorage::default();
    let mut session = session(&req.token, &storage).await?;
    let team = session
        .list_teams()
        .await?
        .into_iter()
        .find(|t| t.team_id == req.team)
        .ok_or_else(|| report!("this Apple ID isn't on the team {}", req.team))?;
    let ids = session.list_app_ids(&team, None).await?;
    let find = |b: &str| {
        ids.app_ids
            .iter()
            .find(|a| a.identifier == b)
            .cloned()
            .ok_or_else(|| report!("the team has no App ID {b}"))
    };
    let (app_id, helper_id) = (find(&req.app)?, find(&req.helper)?);
    let b64 = base64::engine::general_purpose::STANDARD;
    let app = session.download_team_provisioning_profile(&team, &app_id, None).await?;
    let helper = session.download_team_provisioning_profile(&team, &helper_id, None).await?;
    let mut reply = json!({
        "ok": true,
        "app": b64.encode(app.encoded_profile.as_ref()),
        "helper": b64.encode(helper.encoded_profile.as_ref()),
    });
    let state = Zeroizing::new(storage.retrieve(ANISETTE_STATE_KEY)?.unwrap_or_default());
    if !state.is_empty() && *state != req.token.anisette_state {
        reply["anisette_state"] = Value::String(state.to_string());
    }
    Ok(reply)
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn call(request: &[u8]) -> Value {
    // SAFETY: called before any thread this library starts reads the environment.
    unsafe { std::env::remove_var("DEBUG_SENSITIVE") };
    let op = serde_json::from_slice::<Value>(request)
        .ok()
        .and_then(|v| v.get("op").and_then(Value::as_str).map(str::to_string));
    let result = match op.as_deref() {
        Some("profiles") => match serde_json::from_slice::<ProfilesRequest>(request) {
            // The parse error names a field, never a value.
            Err(e) => Err(report!("a profiles request without {}", e.to_string().split(" at line").next().unwrap_or("its fields"))),
            Ok(req) => runtime().block_on(profiles(req)),
        },
        Some(other) => Err(report!("unknown op {other}")),
        None => Err(report!("a request with no op")),
    };
    match result {
        Ok(v) => v,
        Err(e) => {
            let mut v = json!({ "ok": false, "error": one_line(&e) });
            if let Some(code) = apple_code(&e) {
                v["code"] = json!(code);
            }
            v
        }
    }
}

/// See spapple.h. Blocks for the network: never on the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn spapple_call(request: *const c_char) -> *mut c_char {
    let reply = if request.is_null() {
        json!({ "ok": false, "error": "no request" })
    } else {
        // SAFETY: the caller passes a NUL-terminated string that outlives the call (spapple.h).
        let bytes = Zeroizing::new(unsafe { CStr::from_ptr(request) }.to_bytes().to_vec());
        std::panic::catch_unwind(|| call(&bytes))
            .unwrap_or_else(|_| json!({ "ok": false, "error": "spapple panicked" }))
    };
    CString::new(reply.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Frees a reply, zeroing it first (a profiles reply has no secret, but a later op's may).
#[unsafe(no_mangle)]
pub extern "C" fn spapple_free(reply: *mut c_char) {
    if reply.is_null() {
        return;
    }
    // SAFETY: `reply` came from spapple_call's CString::into_raw and is freed once (spapple.h).
    let s = unsafe { CString::from_raw(reply) };
    let mut bytes = s.into_bytes();
    bytes.zeroize();
}
