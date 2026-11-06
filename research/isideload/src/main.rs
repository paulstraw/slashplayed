// spisideload: the isideload spike's CLI (research/isideload/README.md). Each command writes a JSON report
// to the path given with --report (check-session appends a line to --log), so a run the owner does in
// their own Terminal leaves something an agent can read: never a token, anisette value, key, password, or
// size of one. Apple IDs, team IDs and UDIDs do appear in reports, which live in a scratch folder and are
// never committed.
//
//   spisideload login         --apple-id <id> [--anisette <url>] [--server-client-info] --report <file>
//                             (the owner: password, 2FA)
//   spisideload teams         --apple-id <id> --report <file>
//   spisideload provision     --apple-id <id> --team <TEAMID> [--udid <udid>] [--free|--paid]
//                             [--create-app-ids] [--create-cert] [--profiles-only] --out <dir> [--identity <dir>] --report <file>
//   spisideload sign-quick    --apple-id <id> --profiles <dir> --app <Slashplayed.app> --report <file>
//   spisideload check-session --apple-id <id> --log <file.jsonl>
//   spisideload forget        --apple-id <id>
//   spisideload export-token  --apple-id <id> --out <file>
//                             (the stored xcode token as the device keeps it, apps/client/spapple.m: a 0600
//                             file for apps/client/push-apple-token.sh, which pushes and then deletes it)
//
// No tracing subscriber is installed, so nothing isideload logs (at any level) reaches any output; the
// README has the audit of what it would log. Errors are printed as their chain of contexts only, never
// their attachments (where isideload puts response bodies), and DEBUG_SENSITIVE, which makes isideload
// print whole plists into errors, is cleared before anything runs.

mod profile;
mod provision;
mod quicksign;
mod session;
mod store;

use std::{collections::HashMap, fs, io::Write, path::PathBuf};

use rootcause::prelude::*;
use serde_json::{Value as Json, json};

/// A command's report, rewritten after every step so a failure still leaves what got done.
pub struct Log {
    path: Option<PathBuf>,
    value: Json,
}

impl Log {
    fn new(command: &str, path: Option<PathBuf>) -> Self {
        Self {
            path,
            value: json!({ "command": command, "started": session::now(), "steps": [] }),
        }
    }
    pub fn step(&mut self, name: &str, detail: Json) {
        eprintln!("- {name}");
        self.value["steps"]
            .as_array_mut()
            .unwrap()
            .push(json!({ "step": name, "detail": detail }));
        self.write();
    }
    fn set(&mut self, key: &str, v: Json) {
        self.value[key] = v;
        self.write();
    }
    fn write(&self) {
        if let Some(p) = &self.path
            && let Ok(s) = serde_json::to_string_pretty(&self.value)
        {
            let _ = fs::write(p, s + "\n");
        }
    }
}

/// An error as the chain of what failed, without the attachments isideload hangs on them (raw response
/// bodies, plists).
pub fn safe_error(e: &Report) -> String {
    e.iter_reports()
        .map(|n| n.format_current_context().to_string().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" <- ")
}

struct Args {
    command: String,
    values: HashMap<String, String>,
    flags: Vec<String>,
}

impl Args {
    fn parse() -> Result<Self, Report> {
        let mut it = std::env::args().skip(1);
        let command = it.next().unwrap_or_default();
        let (mut values, mut flags) = (HashMap::new(), Vec::new());
        let valued = [
            "--apple-id", "--anisette", "--report", "--team", "--udid", "--out", "--identity",
            "--profiles", "--app", "--log",
        ];
        while let Some(a) = it.next() {
            if valued.contains(&a.as_str()) {
                let v = it.next().ok_or_else(|| report!("{a} needs a value"))?;
                values.insert(a, v);
            } else if a.starts_with("--") {
                flags.push(a);
            } else {
                bail!("unexpected argument {a}");
            }
        }
        Ok(Self { command, values, flags })
    }
    fn get(&self, k: &str) -> Result<String, Report> {
        self.values.get(k).cloned().ok_or_else(|| report!("{} needs {k}", self.command))
    }
    fn opt(&self, k: &str) -> Option<String> {
        self.values.get(k).cloned()
    }
    fn flag(&self, k: &str) -> bool {
        self.flags.iter().any(|f| f == k)
    }
}

fn main() {
    // Before any thread exists (the runtime is built below): isideload reads this to print sensitive
    // plists and the full email into errors and logs.
    unsafe { std::env::remove_var("DEBUG_SENSITIVE") };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let args = match Args::parse() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("spisideload: {}", safe_error(&e));
            std::process::exit(2);
        }
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let mut log = Log::new(&args.command, args.opt("--report").map(PathBuf::from));
    let result = runtime.block_on(run(&args, &mut log));
    match result {
        Ok(()) => {
            log.set("ok", json!(true));
            eprintln!("spisideload {}: done", args.command);
        }
        Err(e) => {
            let msg = safe_error(&e);
            log.set("ok", json!(false));
            log.set("error", json!(msg));
            eprintln!("spisideload {}: {msg}", args.command);
            std::process::exit(1);
        }
    }
}

async fn run(args: &Args, log: &mut Log) -> Result<(), Report> {
    match args.command.as_str() {
        "login" => {
            let id = args.get("--apple-id")?;
            let url = args.opt("--anisette").unwrap_or_else(|| session::DEFAULT_ANISETTE.into());
            let server_ci = args.flag("--server-client-info");
            log.step("anisette", json!({ "url": url, "server_client_info": server_ci }));
            let (mut s, expiry, duration) = session::login(&id, &url, server_ci).await?;
            log.step("login", json!({ "xcode_token_expiry": expiry, "xcode_token_duration": duration, "stored": true }));
            let (_, teams) = provision::teams(&mut s).await?;
            log.step("teams", teams);
        }
        "teams" => {
            let id = args.get("--apple-id")?;
            let mut r = session::restore(&id).await?;
            let (mut s, _) = r.minted_session().await?;
            let (_, teams) = provision::teams(&mut s).await?;
            log.step("teams", teams);
            r.save(&id)?;
        }
        "provision" => {
            let id = args.get("--apple-id")?;
            let opts = provision::Options {
                team: args.get("--team")?,
                udid: args.opt("--udid"),
                free: match (args.flag("--free"), args.flag("--paid")) {
                    (true, true) => bail!("--free or --paid, not both"),
                    (true, _) => Some(true),
                    (_, true) => Some(false),
                    _ => None,
                },
                create_app_ids: args.flag("--create-app-ids"),
                create_cert: args.flag("--create-cert"),
                profiles_only: args.flag("--profiles-only"),
                out: PathBuf::from(args.get("--out")?),
                identity: args.opt("--identity").map(PathBuf::from),
            };
            let mut r = session::restore(&id).await?;
            provision::provision(&mut r, &id, &opts, log).await?;
        }
        "sign-quick" => {
            let id = args.get("--apple-id")?;
            let stored = store::load(&id)?.ok_or_else(|| report!("no stored login for that Apple ID"))?;
            let app = PathBuf::from(args.get("--app")?);
            let out = quicksign::sign(&app, &PathBuf::from(args.get("--profiles")?), &stored)?;
            log.step("sign-quick", out);
        }
        "check-session" => check_session(args).await?,
        "forget" => {
            let id = args.get("--apple-id")?;
            let had = store::forget(&id)?;
            eprintln!("{}", if had { "forgot the stored login" } else { "no stored login to forget" });
        }
        "export-token" => {
            use std::os::unix::fs::OpenOptionsExt;
            let id = args.get("--apple-id")?;
            let stored = store::load(&id)?.ok_or_else(|| report!("no stored login for that Apple ID"))?;
            if stored.server_client_info {
                bail!("this login sent the server's client identity; the device always sends the override (session.rs)");
            }
            // spapple's Token (apps/client/spapple/src/lib.rs), field for field.
            let blob = zeroize::Zeroizing::new(serde_json::to_vec(&json!({
                "token": stored.xcode_token, "expiry": stored.xcode_token_expiry,
                "duration": stored.xcode_token_duration, "adsid": stored.adsid,
                "anisette_url": stored.anisette_url, "anisette_state": stored.anisette_state,
            }))?);
            let out = PathBuf::from(args.get("--out")?);
            let mut f = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&out)
                .map_err(|e| report!("couldn't create {} (it mustn't exist yet): {e}", out.display()))?;
            f.write_all(&blob)?;
            log.step("export-token", json!({ "xcode_token_stated_expiry": stored.xcode_token_expiry }));
        }
        _ => bail!("commands: login, teams, provision, sign-quick, check-session, forget, export-token (see the README)"),
    }
    Ok(())
}

/// One measurement of the stored login: does the xcode token login stored still work, and can the
/// stored GS token still mint a new one? One JSON line appended per run, with the login's age, so a run
/// a day (by hand or launchd) gives the lifetimes. Outcomes and Apple's error codes only.
async fn check_session(args: &Args) -> Result<(), Report> {
    use isideload::dev::teams::TeamsApi;
    let id = args.get("--apple-id")?;
    let path = PathBuf::from(args.get("--log")?);
    // The Apple ID names the line (one log holds every account's); the log is local, never committed.
    let mut line = json!({ "at": session::now(), "apple_id": id });
    let outcome = |r: Result<(), Report>| match r {
        Ok(()) => json!("ok"),
        Err(e) => json!({ "error": safe_error(&e), "developer_code": provision::developer_code(&e) }),
    };
    match session::restore(&id).await {
        Err(e) => line["restore"] = outcome(Err(e)),
        Ok(mut r) => {
            line["logged_in_at"] = json!(r.stored.logged_in_at);
            line["age_days"] =
                json!(((session::now() - r.stored.logged_in_at) as f64 / 86400.0 * 100.0).round() / 100.0);
            line["stored_xcode_token_stated_expiry"] = json!(r.stored.xcode_token_expiry);
            let mut s = r.stored_session();
            line["stored_xcode_token"] = outcome(s.list_teams().await.map(|_| ()));
            let minted = match r.minted_session().await {
                Ok((mut s, t)) => {
                    line["minted_xcode_token_stated_expiry"] = json!(t.expiry);
                    s.list_teams().await.map(|_| ())
                }
                Err(e) => Err(e),
            };
            line["mint_from_gs_token"] = outcome(minted);
            r.save(&id)?;
        }
    }
    let mut f = fs::OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(f, "{line}")?;
    eprintln!("{line}");
    Ok(())
}
