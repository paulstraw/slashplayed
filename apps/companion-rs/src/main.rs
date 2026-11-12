// slashplayed-cli: sets up Slashplayed on an iPad or iPhone from Windows, Linux, or a Mac, with no Xcode
// and no Mac companion (docs/setup-without-a-mac.md; how it works: docs/architecture.md, "The host tool").
// Run it again to re-sign when the app can't renew its own profiles (its start screen says so). Each run:
//
//   1. the device kit (the device app, unsigned: kit.rs), downloaded and checked, before anything else;
//   2. the device over USB: trusted by this computer, Developer Mode on (device.rs);
//   3. the Apple ID sign-in, held in memory only, and the team (account.rs);
//   4. the device, App IDs, capabilities, certificate, and profiles (provision.rs);
//   5. the app signed with zsign (sign.rs) and installed over USB;
//   6. the RemotePairing record and the developer disk image (ddi.rs) into its container, for the JIT helper,
//      and the Apple token, for the app to renew its own profiles (apps/client/spapple.m).
//
// The device does the rest: it installs and updates games itself, with no signing credential on it (it loads each
// game's unchanged client with spguest, so nothing there is signed), and picks their region (PR #35, #41),
// so this never writes .build.info, a region, or addons. Vision Pro stays Mac-only.

use std::collections::HashMap;

use isideload::{
    auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::teams::DeveloperTeam,
};
use rootcause::prelude::*;
use slashplayed_companion::{
    account, device,
    flow::{self, Ask, CertLimit, DeviceInfo, Event, Frontend, SignIn, Wait},
    keystore, kit, live, secret,
};
use zeroize::Zeroizing;

const USAGE: &str = "\
slashplayed-cli: set up Slashplayed on an iPhone or iPad without a Mac.

Usage:
  slashplayed-cli [install] [options]         install or re-sign Slashplayed on the device on USB
  slashplayed-cli devices                     list the iPhones and iPads on USB
  slashplayed-cli forget --apple-id <id>
                                          delete this computer's signing key for that Apple ID
  slashplayed-cli --version

Options for install:
  --apple-id <id>       the Apple ID to sign with (asked for if not given)
  --team <TEAMID>       the team, when the Apple ID has several (asked for if not given)
  --udid <UDID>         the device, when several are plugged in
  --bundle-id <id>      the app's bundle ID (default: <team ID>.slashplayed, as the Mac companion uses)
  --anisette <url>      the anisette server (default: https://mac-ani.jkcoxson.com)
  --server-client-info  send the anisette server's own client identity rather than iloader's fixed one
  --kit <zip>           a device kit to use instead of this release's
  --pair-again          make a new pairing record even if the app has one
  --revoke-oldest       with no credential store, at the team's certificate limit: revoke the oldest
                        certificate a Slashplayed tool made, even another computer's

Slashplayed renews its own signing on the device when a game starts near its end. Run this again if
its start screen says it can't.
Your Apple ID password is used once for the sign-in and never stored.";

struct Args {
    command: String,
    values: HashMap<String, String>,
    flags: Vec<String>,
}

const VALUED: &[&str] = &["--apple-id", "--team", "--udid", "--bundle-id", "--anisette", "--kit"];
const FLAGS: &[&str] = &["--server-client-info", "--pair-again", "--revoke-oldest"];

fn parse(args: impl IntoIterator<Item = String>) -> Result<Args, Report> {
    let mut it = args.into_iter().peekable();
    let command = match it.peek() {
        Some(a) if !a.starts_with("--") => it.next().unwrap(),
        _ => "install".to_string(),
    };
    let (mut values, mut flags) = (HashMap::new(), Vec::new());
    while let Some(a) = it.next() {
        if VALUED.contains(&a.as_str()) {
            let v = it.next().ok_or_else(|| report!("{a} needs a value"))?;
            values.insert(a, v);
        } else if FLAGS.contains(&a.as_str()) || a == "--help" || a == "-h" || a == "--version" {
            flags.push(a);
        } else {
            bail!("unknown argument {a} (see --help)");
        }
    }
    Ok(Args { command, values, flags })
}

impl Args {
    fn opt(&self, k: &str) -> Option<&str> {
        self.values.get(k).map(String::as_str)
    }
    fn flag(&self, k: &str) -> bool {
        self.flags.iter().any(|f| f == k)
    }
}

fn main() {
    slashplayed_companion::init();
    let args = match parse(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("slashplayed-cli: {}", secret::safe_error(&e));
            std::process::exit(2);
        }
    };
    if args.flag("--help") || args.flag("-h") || args.command == "help" {
        println!("{USAGE}");
        return;
    }
    if args.flag("--version") || args.command == "version" {
        println!("slashplayed-cli {} (device kit: {})", env!("CARGO_PKG_VERSION"), kit::release_tag());
        return;
    }
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    if let Err(e) = runtime.block_on(run(&args)) {
        eprintln!("slashplayed-cli: {}", secret::safe_error(&e));
        std::process::exit(1);
    }
}

async fn run(args: &Args) -> Result<(), Report> {
    match args.command.as_str() {
        "install" => install(args).await,
        "devices" => {
            let devices = device::list().await?;
            if devices.is_empty() {
                println!("No iPhone or iPad on USB.");
            }
            for d in devices {
                println!("{}\t{}\tiOS {}\t{}", d.usb.udid, d.class, d.os, d.name);
            }
            Ok(())
        }
        "forget" => {
            let id = args.opt("--apple-id").ok_or_else(|| report!("forget needs --apple-id"))?;
            let had = keystore::forget(id)?;
            println!("{}", if had { "Deleted this computer's signing key for that Apple ID." } else { "This computer has no signing key for that Apple ID." });
            Ok(())
        }
        other => bail!("unknown command {other} (see --help)"),
    }
}

async fn install(args: &Args) -> Result<(), Report> {
    let opts = flow::Options {
        kit: args.opt("--kit").map(std::path::Path::new),
        team: args.opt("--team"),
        bundle_id: args.opt("--bundle-id"),
        anisette: args.opt("--anisette").unwrap_or(account::DEFAULT_ANISETTE),
        server_client_info: args.flag("--server-client-info"),
    };
    flow::install(&mut live::Live::new()?, &Cli(args), &opts).await?;
    Ok(())
}

/// One line from the person (stdin), for the Apple ID, team, and 2FA prompts.
fn ask(prompt: &str) -> Result<String, Report> {
    use std::io::{BufRead, Write};
    eprint!("{prompt}");
    std::io::stderr().flush()?;
    let mut line = String::new();
    if std::io::stdin().lock().read_line(&mut line)? == 0 {
        bail!("no answer (the input ended)");
    }
    Ok(line.trim().to_string())
}

/// The command line's side of a run: lines on stderr, questions on stdin, and the flags for what the
/// window would ask.
struct Cli<'a>(&'a Args);

impl Frontend for Cli<'_> {
    fn report(&self, event: Event) {
        match event {
            Event::Say(line) => eprintln!("- {line}"),
            // The device asks for Trust itself; the command line has never said more about it.
            Event::Wait(Wait::Trust { .. }) => {}
            Event::Wait(w) => eprintln!("{}", w.text()),
            Event::Done(done) => {
                eprintln!();
                for line in done.lines() {
                    eprintln!("{line}");
                }
            }
            Event::Step(_) | Event::Progress(_) => {}
        }
    }

    fn choose_device<'a>(&'a self, devices: &'a [DeviceInfo]) -> Ask<'a, Option<usize>> {
        let udid = self.0.opt("--udid");
        Box::pin(async move {
            if let Some(u) = udid {
                return match devices.iter().position(|d| d.udid == u) {
                    Some(i) => Ok(Some(i)),
                    None => bail!("no device {u} on USB: plug it in with its cable and unlock it"),
                };
            }
            match devices.len() {
                0 => bail!("no iPhone or iPad on USB: plug one in with its cable and unlock it"),
                1 => Ok(Some(0)),
                n => {
                    eprintln!("{n} devices are plugged in:");
                    for d in devices {
                        eprintln!("  {} ({}, iOS {}): --udid {}", d.name, d.class, d.os, d.udid);
                    }
                    bail!("name the one to set up with --udid");
                }
            }
        })
    }

    fn waits_for_developer_mode(&self) -> bool {
        false
    }

    fn sign_in(&self) -> Ask<'_, SignIn> {
        Box::pin(async move {
            let apple_id = match self.0.opt("--apple-id") {
                Some(id) => id.to_string(),
                None => ask("Apple ID (email): ")?,
            };
            Ok(SignIn { apple_id, pair_again: self.0.flag("--pair-again") })
        })
    }

    fn password<'a>(&'a self, apple_id: &'a str) -> Ask<'a, Zeroizing<String>> {
        Box::pin(async move {
            Ok(Zeroizing::new(
                rpassword::prompt_password(format!("Apple ID password for {apple_id} (not shown as you type): "))
                    .map_err(|_| report!("couldn't read the password: run this in a terminal"))?,
            ))
        })
    }

    fn two_factor(&self, params: TwoFactorCallbackParams) -> Ask<'_, TwoFactorCallbackResponse> {
        Box::pin(async move {
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
        })
    }

    fn choose_team<'a>(&'a self, teams: &'a [DeveloperTeam]) -> Ask<'a, usize> {
        Box::pin(async move {
            eprintln!("This Apple ID has {} teams:", teams.len());
            for (i, t) in teams.iter().enumerate() {
                eprintln!("  {}: {} ({})", i + 1, t.name.as_deref().unwrap_or("?"), t.team_id);
            }
            let n: usize = ask("Which one should sign Slashplayed? ")?.parse().map_err(|_| report!("not a number from the list"))?;
            if n == 0 || n > teams.len() {
                bail!("not a number from the list");
            }
            Ok(n - 1)
        })
    }

    fn confirm_revoke<'a>(&'a self, limit: &'a CertLimit) -> Ask<'a, ()> {
        Box::pin(async move {
            if self.0.flag("--revoke-oldest") {
                return Ok(());
            }
            bail!(
                "the team has all the development certificates Apple allows ({}), and this computer has no credential store to keep its signing key in, so it can't reuse a certificate. Nothing was revoked. Free a slot yourself, or run this again with --revoke-oldest to revoke the oldest certificate a Slashplayed tool made, on this or another computer (that computer's device then needs its own run before Slashplayed opens again)",
                limit.certificates
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(a: &[&str]) -> Result<Args, Report> {
        parse(a.iter().map(|s| s.to_string()))
    }

    #[test]
    fn install_is_the_default() {
        let a = p(&["--apple-id", "x@example.com", "--pair-again"]).unwrap();
        assert_eq!(a.command, "install");
        assert_eq!(a.opt("--apple-id"), Some("x@example.com"));
        assert!(a.flag("--pair-again"));
        assert_eq!(p(&["devices"]).unwrap().command, "devices");
    }

    fn phones() -> Vec<DeviceInfo> {
        ["A", "B"].map(|u| DeviceInfo { udid: u.into(), name: u.into(), class: "iPhone".into(), os: "27.1".into() }).to_vec()
    }

    /// The flags that answer the window's questions on the command line.
    #[tokio::test]
    async fn flags_answer_the_questions() {
        let a = p(&["--udid", "B", "--apple-id", "x@example.com", "--pair-again"]).unwrap();
        let cli = Cli(&a);
        assert_eq!(cli.choose_device(&phones()).await.unwrap(), Some(1));
        let s = cli.sign_in().await.unwrap();
        assert_eq!((s.apple_id.as_str(), s.pair_again), ("x@example.com", true));
        let limit = CertLimit { certificates: "c".into(), oldest: "o".into() };
        assert!(cli.confirm_revoke(&limit).await.is_err(), "no revoke without --revoke-oldest");

        let a = p(&["--apple-id", "x@example.com", "--revoke-oldest"]).unwrap();
        let cli = Cli(&a);
        assert!(!cli.sign_in().await.unwrap().pair_again);
        assert!(cli.confirm_revoke(&limit).await.is_ok());
        assert!(cli.choose_device(&phones()).await.is_err(), "several devices and no --udid");
        let a = p(&["--udid", "C"]).unwrap();
        assert!(Cli(&a).choose_device(&phones()).await.is_err());
    }

    #[test]
    fn bad_arguments() {
        assert!(p(&["--team"]).is_err());
        assert!(p(&["--password", "x"]).is_err(), "no password ever comes from the command line");
        assert!(p(&["install", "extra"]).is_err());
    }
}
