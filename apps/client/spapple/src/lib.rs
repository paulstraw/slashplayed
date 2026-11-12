// spapple: Apple's developer services for the launcher, through isideload. One C entry point takes a JSON
// request and returns a JSON reply (spapple.h), so the Objective-C side stays a few lines and the Rust side
// owns every type isideload has.
//
// Requests ("op"):
//   "profiles": with the Apple token the device keeps ("token": what spapple.m stores), downloads the
//     team provisioning profiles of the App IDs "app" and "helper" on team "team". The reply's "app" and
//     "helper" are the profile files (base64), and "remade" lists the App IDs that had lapsed and were made
//     again first (a free team's last 7 days). Its "anisette_state" is set when the anisette server
//     re-provisioned this device's machine identity, for the caller to store with the token, in a failed
//     reply too: the server moved on from the old identity before the step that failed.
//   "login": the launcher's own Apple sign-in (spapplescreen.swift, through spapple.m), which makes the token.
//     With "email", "password", "anisette_url", and the app's "team", it signs in and runs until Apple asks for
//     a 2FA code: the reply's "step" is "code", with "sms" (the code goes by text, else to the person's Apple
//     devices), "unknown" (the last way failed: offer them all), "retry" (the last code was wrong), and
//     "numbers" (Apple's trusted numbers, masked by Apple, each with its "id"). "login_answer" goes on with
//     "answer": "code" (with "code"), "sms" (with that number's "id"), "devices", or "resend", and replies the
//     same way. When it's done, "step" is "done" and "token" is what the device keeps (Token's fields), after
//     checking the Apple ID is on the team, without which the token renews nothing ("problem": "team").
//     "login_cancel" ends a sign-in that's waiting. One sign-in at a time: a new "login" ends the last.
// Every reply has "ok"; a failed one has "error" (for the log and the person) and, when Apple answered with
// one, "code": its developer-services or GrandSlam error number, and "message": Apple's own words for it,
// and "http_status": the HTTP status of a refusal from Apple's own servers (never another's, such as the
// anisette server's).
//
// The token and the password are credentials (CLAUDE.md, "The Apple ID is a credential" and "The Apple token
// is a credential"): nothing here logs them, puts them in an error, or stores them. The password is in memory
// only for the sign-in, and the token for the request that uses it or the one reply that hands it over.
// Zeroing is best effort: this library zeroes the copies it owns (the request, the password once Apple has
// taken it or the sign-in ends, Token, and the reply once it's written and again in spapple_free), but not
// the ones isideload makes and drops as they are (its AppToken and DeveloperSession, the request bodies it
// builds). No tracing subscriber is installed, so nothing isideload logs goes anywhere; DEBUG_SENSITIVE, which
// makes isideload put whole plists and the full email into errors, is cleared once, before the runtime starts.

use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

use base64::Engine;
use isideload::{
    SideloadError,
    anisette::{
        AnisetteClientInfo,
        remote_v3::{ANISETTE_STATE_KEY, RemoteV3AnisetteProvider},
    },
    auth::apple_account::{AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi, developer_session::DeveloperSession, teams::TeamsApi,
    },
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zeroize::{Zeroize, Zeroizing};

/// What the device keeps of a sign-in (spapple.m stores it whole, as this JSON): the xcode.auth app
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

/// The developer-services or GrandSlam error number in a failure, and Apple's words for it, if Apple sent one.
fn apple_error(e: &Report) -> Option<(i64, String)> {
    e.iter_reports().find_map(|n| match n.downcast_current_context::<SideloadError>() {
        Some(SideloadError::DeveloperError(code, m)) | Some(SideloadError::AuthWithMessage(code, m)) => Some((*code, m.clone())),
        _ => None,
    })
}

/// The HTTP status of a refusal from Apple's own servers (developer services, GrandSlam) in a failure: a 401
/// there is Apple not taking the token. Only an apple.com host's: the anisette server's refusals, and numbers
/// in the error's text (a team or bundle ID, a URL), say nothing about the token.
fn apple_http_status(e: &Report) -> Option<u16> {
    e.iter_reports().find_map(|n| {
        let r = n.downcast_current_context::<reqwest::Error>()?;
        let host = r.url()?.host_str()?;
        if host != "apple.com" && !host.ends_with(".apple.com") {
            return None;
        }
        r.status().map(|s| s.as_u16())
    })
}

/// A failed request's reply (the header's "error", "code", "message", and "http_status").
fn error_reply(e: &Report) -> Value {
    let mut v = json!({ "ok": false, "error": one_line(e) });
    if let Some((code, message)) = apple_error(e) {
        v["code"] = json!(code);
        v["message"] = json!(message);
    }
    if let Some(status) = apple_http_status(e) {
        v["http_status"] = json!(status);
    }
    v
}

async fn session(token: &Token, storage: &MemoryStorage) -> Result<DeveloperSession, Report> {
    if !token.anisette_state.is_empty() {
        storage.store(ANISETTE_STATE_KEY, &token.anisette_state)?;
    }
    let provider = RemoteV3AnisetteProvider::new(&token.anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override(Some(client_info_override()));
    // No email: the account is only the GrandSlam client and anisette for the session, never logged in here.
    let account = AppleAccount::builder("").anisette_provider(provider).build().await?;
    // isideload's AppToken and the session keep copies of the token that it drops unzeroed (the header).
    Ok(DeveloperSession::new(
        AppToken { token: token.token.clone(), duration: token.duration, expiry: token.expiry },
        token.adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    ))
}

/// The "profiles" reply, with the re-provisioned anisette state whether or not the rest worked (the header).
async fn profiles(req: ProfilesRequest) -> Value {
    let storage = MemoryStorage::default();
    let mut reply = fetch(&req, &storage).await.unwrap_or_else(|e| error_reply(&e));
    if let Ok(Some(state)) = storage.retrieve(ANISETTE_STATE_KEY) {
        let state = Zeroizing::new(state);
        if !state.is_empty() && *state != req.token.anisette_state {
            reply["anisette_state"] = Value::String(state.to_string());
        }
    }
    reply
}

async fn fetch(req: &ProfilesRequest, storage: &MemoryStorage) -> Result<Value, Report> {
    let mut session = session(&req.token, storage).await?;
    let team = session
        .list_teams()
        .await?
        .into_iter()
        .find(|t| t.team_id == req.team)
        .ok_or_else(|| report!("this Apple ID isn't on the team {}", req.team))?;
    // A free team's App IDs lapse 7 days after they're made (Apple's "Choosing a Membership"; seen on the
    // free spike, whose helper's was gone after 9 days), and a team profile can't be had for one that's gone.
    // So one that's missing is made again, under the same identifier, as slashplayed-companion makes it
    // (provision.rs's app_ids), and the app's gets increased-memory-limit back, the one capability a free
    // team's app is signed with (its profile must grant it). The profiles the device already has stay valid
    // until their own day, whatever becomes of the App ID: a lapsed one only stops the next download.
    let mut ids = session.list_app_ids(&team, None).await?;
    let missing: Vec<String> = [req.app.clone(), req.helper.clone()]
        .into_iter()
        .filter(|b| !ids.app_ids.iter().any(|a| &a.identifier == b))
        .collect();
    if !missing.is_empty() {
        if let Some(avail) = ids.available_quantity
            && avail < missing.len() as i64
        {
            return Err(report!(
                "the team's App IDs for Slashplayed lapsed, and it can make {avail} more right now ({} needed): a free team makes 10 a week",
                missing.len()
            ));
        }
        for b in &missing {
            let name = if *b == req.helper { "Slashplayed helper" } else { "Slashplayed" };
            session.add_app_id(&team, name, b, None).await?;
        }
        ids = session.list_app_ids(&team, None).await?;
    }
    let find = |b: &str| {
        ids.app_ids
            .iter()
            .find(|a| a.identifier == b)
            .cloned()
            .ok_or_else(|| report!("the team has no App ID {b}"))
    };
    let (app_id, helper_id) = (find(&req.app)?, find(&req.helper)?);
    if missing.contains(&req.app) {
        session.add_increased_memory_limit(&team, &app_id).await?;
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let app = session.download_team_provisioning_profile(&team, &app_id, None).await?;
    let helper = session.download_team_provisioning_profile(&team, &helper_id, None).await?;
    Ok(json!({
        "ok": true,
        "app": b64.encode(app.encoded_profile.as_ref()),
        "helper": b64.encode(helper.encoded_profile.as_ref()),
        "remade": missing,
    }))
}

// ---- The launcher's Apple sign-in ("login", "login_answer", "login_cancel")

#[derive(Deserialize)]
struct LoginRequest {
    email: String,
    password: String,
    anisette_url: String,
    team: String,
}

impl Drop for LoginRequest {
    fn drop(&mut self) {
        self.email.zeroize();
        self.password.zeroize();
    }
}

#[derive(Deserialize)]
struct AnswerRequest {
    answer: String,
    #[serde(default)]
    code: String,
    #[serde(default)]
    id: u32,
}

impl Drop for AnswerRequest {
    fn drop(&mut self) {
        self.code.zeroize();
    }
}

/// What a sign-in under way tells the waiting call: Apple wants a code, or it's over (its reply).
enum Event {
    Prompt(TwoFactorCallbackParams),
    Done(Value),
}

/// A sign-in under way, between the calls that answer it: its task (isideload's login, parked in its 2FA
/// callback while the person types) and the two channels to it. Dropped, the task is aborted, which drops the
/// password with it.
struct Login {
    events: mpsc::UnboundedReceiver<Event>,
    answers: mpsc::UnboundedSender<TwoFactorCallbackResponse>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Login {
    fn drop(&mut self) {
        self.task.abort();
    }
}

static LOGIN: Mutex<Option<Login>> = Mutex::new(None);

fn waiting() -> std::sync::MutexGuard<'static, Option<Login>> {
    LOGIN.lock().unwrap_or_else(|p| p.into_inner())
}

/// The sign-in itself, as slashplayed-companion's (apps/companion-rs/src/account.rs) with its client identity
/// and anisette server, then the token the device keeps. The password is taken out of the request and zeroed
/// as soon as the login returns.
async fn login<C>(mut req: LoginRequest, two_factor: C) -> Result<Value, Report>
where
    C: isideload::util::callbacks::TwoFactorCallback,
{
    let storage = MemoryStorage::default();
    let provider = RemoteV3AnisetteProvider::new(&req.anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override(Some(client_info_override()));
    let mut account = AppleAccount::builder(&req.email).anisette_provider(provider).build().await?;
    let password = Zeroizing::new(std::mem::take(&mut req.password));
    let result = account.login(&password, two_factor).await;
    drop(password);
    result.context("Apple didn't accept the sign-in")?;
    let token = account.get_app_token("xcode.auth").await?;
    let adsid = Zeroizing::new(
        account
            .spd
            .as_ref()
            .and_then(|s| s.get("adsid"))
            .and_then(|v| v.as_string())
            .ok_or_else(|| report!("signed in, but Apple sent no session data"))?
            .to_string(),
    );
    // Only a token that can renew this app is kept: one for an Apple ID on the team that signed it.
    let mut session = DeveloperSession::new(
        token.clone(),
        adsid.to_string(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    let mut token = token;
    let on_team = session.list_teams().await.map(|teams| teams.iter().any(|t| t.team_id == req.team));
    let reply = match on_team {
        Err(e) => Err(e),
        Ok(false) => Ok(json!({
            "ok": false, "problem": "team",
            "error": "this Apple ID isn't on the team that signed the app",
        })),
        Ok(true) => storage.retrieve(ANISETTE_STATE_KEY).map(|state| {
            let state = Zeroizing::new(state.unwrap_or_default());
            json!({
                "ok": true, "step": "done",
                "token": {
                    "token": token.token, "expiry": token.expiry, "duration": token.duration, "adsid": *adsid,
                    "anisette_url": req.anisette_url, "anisette_state": *state,
                },
            })
        }),
    };
    // json! copied it: the original goes too, on every path (the session's own copy is isideload's).
    token.token.zeroize();
    reply
}

/// The sign-in's task: its 2FA callback hands Apple's ask to the waiting call and waits for the next call's
/// answer; a closed channel (the sign-in ended) aborts it.
async fn login_task(
    req: LoginRequest,
    events: mpsc::UnboundedSender<Event>,
    answers: mpsc::UnboundedReceiver<TwoFactorCallbackResponse>,
) {
    let answers = Arc::new(tokio::sync::Mutex::new(answers));
    let prompts = events.clone();
    let two_factor = move |params: TwoFactorCallbackParams| {
        let (prompts, answers) = (prompts.clone(), answers.clone());
        async move {
            prompts.send(Event::Prompt(params)).map_err(|_| report!("the sign-in was closed"))?;
            answers.lock().await.recv().await.ok_or_else(|| report!("the sign-in was closed"))
        }
    };
    let reply = login(req, two_factor).await.unwrap_or_else(|e| error_reply(&e));
    let _ = events.send(Event::Done(reply));
}

/// Waits for the sign-in's next word: Apple's ask for a code (the sign-in stays, for login_answer) or its end.
/// Two minutes at most for one step, so a dead network can't hang the screen.
fn login_wait(mut login: Login) -> Result<Value, Report> {
    let event = runtime().block_on(async { tokio::time::timeout(Duration::from_secs(120), login.events.recv()).await });
    match event {
        Err(_) => Err(report!("Apple didn't answer within 2 minutes")),
        Ok(None) => Err(report!("the sign-in ended")),
        Ok(Some(Event::Done(reply))) => Ok(reply),
        Ok(Some(Event::Prompt(p))) => {
            *waiting() = Some(login);
            // Apple's trusted numbers come masked; the screen shows them only to the person signing in.
            let numbers: Vec<Value> =
                p.numbers.iter().map(|n| json!({ "id": n.id, "number": n.number_with_dial_code })).collect();
            Ok(json!({
                "ok": true, "step": "code", "sms": p.sms, "unknown": p.unknown, "retry": p.last_error.is_some(),
                "numbers": numbers, "selected": p.selected_number_id,
            }))
        }
    }
}

fn login_start(req: LoginRequest) -> Result<Value, Report> {
    drop(waiting().take());
    let (events_tx, events) = mpsc::unbounded_channel();
    let (answers, answers_rx) = mpsc::unbounded_channel();
    let task = runtime().spawn(login_task(req, events_tx, answers_rx));
    login_wait(Login { events, answers, task })
}

fn login_answer(req: AnswerRequest) -> Result<Value, Report> {
    let login = waiting().take().ok_or_else(|| report!("no sign-in is waiting for a code"))?;
    let answer = match req.answer.as_str() {
        "code" => TwoFactorCallbackResponse::SubmitCode(req.code.clone()),
        "sms" => TwoFactorCallbackResponse::SendSms(req.id),
        "devices" => TwoFactorCallbackResponse::SendToDevices,
        "resend" => TwoFactorCallbackResponse::ResendCode,
        other => bail!("unknown answer {other}"),
    };
    login.answers.send(answer).map_err(|_| report!("the sign-in ended"))?;
    login_wait(login)
}

/// Zeroes every string in a reply once it's written out (a "login" reply's token).
fn scrub(v: &mut Value) {
    match v {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(scrub),
        Value::Object(o) => o.values_mut().for_each(scrub),
        _ => {}
    }
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        // SAFETY: once, before the runtime below starts this library's threads. The launcher's own threads may
        // be up, but Darwin's getenv and unsetenv both take libc's environment lock, and nothing in the
        // launcher keeps a pointer getenv returned for this variable.
        unsafe { std::env::remove_var("DEBUG_SENSITIVE") };
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn call(request: &[u8]) -> Value {
    // Only "op" is read here, into its own struct: a whole Value would copy a login's password unzeroed.
    #[derive(Deserialize)]
    struct Op {
        op: Option<String>,
    }
    let op = serde_json::from_slice::<Op>(request).ok().and_then(|o| o.op);
    // A parse error can quote a value (serde_json's "invalid type: string ..."), so a login's says nothing.
    let result = match op.as_deref() {
        Some("profiles") => match serde_json::from_slice::<ProfilesRequest>(request) {
            Err(_) => Err(report!("a profiles request without its fields")),
            Ok(req) => Ok(runtime().block_on(profiles(req))),
        },
        Some("login") => match serde_json::from_slice::<LoginRequest>(request) {
            Err(_) => Err(report!("a login request without its fields")),
            Ok(req) => login_start(req),
        },
        Some("login_answer") => match serde_json::from_slice::<AnswerRequest>(request) {
            Err(_) => Err(report!("a login answer without its fields")),
            Ok(req) => login_answer(req),
        },
        Some("login_cancel") => {
            drop(waiting().take());
            Ok(json!({ "ok": true }))
        }
        Some(other) => Err(report!("unknown op {other}")),
        None => Err(report!("a request with no op")),
    };
    result.unwrap_or_else(|e| error_reply(&e))
}

/// See spapple.h. Blocks for the network: never on the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn spapple_call(request: *const c_char) -> *mut c_char {
    let mut reply = if request.is_null() {
        json!({ "ok": false, "error": "no request" })
    } else {
        // SAFETY: the caller passes a NUL-terminated string that outlives the call (spapple.h).
        let bytes = Zeroizing::new(unsafe { CStr::from_ptr(request) }.to_bytes().to_vec());
        std::panic::catch_unwind(|| call(&bytes))
            .unwrap_or_else(|_| json!({ "ok": false, "error": "spapple panicked" }))
    };
    // Written once into room enough for any reply but a profiles one, so a login's token isn't left behind in
    // a buffer outgrown on the way (a profiles reply holds no token, at most an anisette state, which may be);
    // then the Value's own copy is zeroed.
    let mut out = Vec::with_capacity(64 * 1024);
    let written = serde_json::to_writer(&mut out, &reply);
    scrub(&mut reply);
    if written.is_err() {
        out.zeroize();
        return std::ptr::null_mut();
    }
    // Copied into exactly the room CString needs (the reply and its NUL), so its push and into_boxed_slice
    // don't reallocate and free a copy unzeroed; then the writer's buffer is zeroed.
    let mut exact = Vec::with_capacity(out.len() + 1);
    exact.extend_from_slice(&out);
    out.zeroize();
    match CString::new(exact) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            e.into_vec().zeroize();
            std::ptr::null_mut()
        }
    }
}

/// Frees a reply, zeroing it first (a login's carries the token).
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
