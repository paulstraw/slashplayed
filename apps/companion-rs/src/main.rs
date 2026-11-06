// slashplayed-companion: sets up Slashplayed on an iPad or iPhone from Windows, Linux, or a Mac, with no Xcode
// and no Mac companion (docs/setup-without-a-mac.md; how it works: docs/architecture.md, "The host tool").
// Run it again to re-sign: weekly on a free Apple ID, yearly on a paid one. Each run:
//
//   1. the device kit (the device app, unsigned: kit.rs), downloaded and checked, before anything else;
//   2. the device over USB: trusted by this computer, Developer Mode on (device.rs);
//   3. the Apple ID sign-in, held in memory only, and the team (account.rs);
//   4. the device, App IDs, capabilities, certificate, and profiles (provision.rs);
//   5. the app signed with zsign (sign.rs) and installed over USB;
//   6. the RemotePairing record, the developer disk image (ddi.rs), and the signing identity into its
//      container, for the JIT helper and the device's own game installs.
//
// The device does the rest: it installs and updates games itself and picks their region (PR #35, #41), so
// this never writes .build.info, a region, or addons. Vision Pro stays Mac-only.

mod account;
mod ddi;
mod device;
mod keystore;
mod kit;
mod profile;
mod provision;
mod secret;
mod sign;

use std::collections::HashMap;

use rootcause::prelude::*;
use zeroize::Zeroizing;

/// One step's line, for the person running it.
pub fn say(line: &str) {
    eprintln!("- {line}");
}

const USAGE: &str = "\
slashplayed-companion: set up Slashplayed on an iPhone or iPad without a Mac.

Usage:
  slashplayed-companion [install] [options]   install or re-sign Slashplayed on the device on USB
  slashplayed-companion devices               list the iPhones and iPads on USB
  slashplayed-companion forget --apple-id <id>
                                          delete this computer's signing key for that Apple ID
  slashplayed-companion --version

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

Run it again to re-sign: within 7 days on a free Apple ID, within a year on a paid one.
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
    // Before any thread exists: isideload reads this to put sensitive plists and the full email into its
    // errors. No tracing subscriber is ever installed, so nothing it logs goes anywhere.
    unsafe { std::env::remove_var("DEBUG_SENSITIVE") };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let args = match parse(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("slashplayed-companion: {}", secret::safe_error(&e));
            std::process::exit(2);
        }
    };
    if args.flag("--help") || args.flag("-h") || args.command == "help" {
        println!("{USAGE}");
        return;
    }
    if args.flag("--version") || args.command == "version" {
        println!("slashplayed-companion {} (device kit: {})", env!("CARGO_PKG_VERSION"), kit::release_tag());
        return;
    }
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    if let Err(e) = runtime.block_on(run(&args)) {
        eprintln!("slashplayed-companion: {}", secret::safe_error(&e));
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
    // 1. The kit, first: a bad download shouldn't cost a sign-in.
    let scratch = secret::Scratch::new("companion")?;
    let (bytes, from) = kit::fetch(args.opt("--kit").map(std::path::Path::new)).await?;
    let kit = kit::extract(&bytes, scratch.path())?;
    drop(bytes);
    say(&format!("device kit {} from {from}", kit.version));

    // 2. The device.
    let d = device::pick(args.opt("--udid")).await?;
    say(&format!("{} ({}, iOS {})", d.name, d.class, d.os));
    device::ensure_trusted(&d).await?;
    device::ensure_developer_mode(&d).await?;

    // 3. The Apple ID and team.
    let apple_id = match args.opt("--apple-id") {
        Some(id) => id.to_string(),
        None => account::ask("Apple ID (email): ")?,
    };
    if apple_id.is_empty() {
        bail!("no Apple ID given");
    }
    let anisette = args.opt("--anisette").unwrap_or(account::DEFAULT_ANISETTE);
    say(&format!("signing in, with anisette from {anisette}"));
    let (mut session, device_token) = account::sign_in(&apple_id, anisette, args.flag("--server-client-info")).await?;
    let team = provision::pick_team(&mut session, args.opt("--team")).await?;
    say(&format!("team {} ({})", team.name.as_deref().unwrap_or("?"), team.team_id));
    let bundle_id = args.opt("--bundle-id").map(str::to_string).unwrap_or_else(|| format!("{}.slashplayed", team.team_id));
    if !kit::valid_bundle_id(&bundle_id) {
        bail!("{bundle_id} isn't a valid bundle ID (letters, digits, and hyphens, separated by dots)");
    }

    // 4. Provisioning.
    provision::register_device(&mut session, &team, &d.usb, &d.name).await?;
    let (app_id, helper_id) = provision::app_ids(&mut session, &team, &bundle_id).await?;
    let eva = provision::capabilities(&mut session, &team, &app_id).await?;
    let id = provision::identity(&mut session, &team, &apple_id, args.flag("--revoke-oldest")).await?;
    let (app_profile, helper_profile, free) =
        provision::profiles(&mut session, &team, &app_id, &helper_id, &d.usb.udid, &id, eva).await?;
    drop(session);

    // 5. Sign and install.
    kit::set_bundle_id(&kit.app, &bundle_id)?;
    let dropped: &[&str] = if free { kit::FREE_TEAM_DROPPED } else { &[] };
    let app_ents = kit::entitlements(&kit.entitlements, &team.team_id, &bundle_id, dropped)?;
    let helper_ents = kit::entitlements(&kit.helper_entitlements, &team.team_id, &kit::helper_id(&bundle_id), &[])?;
    let key_pem = Zeroizing::new(
        rsa::pkcs8::EncodePrivateKey::to_pkcs8_pem(&id.key, rsa::pkcs8::LineEnding::LF)
            .map_err(|_| report!("couldn't encode the key"))?
            .to_string(),
    );
    sign::sign_app(
        &kit.app,
        &sign::Inputs {
            key_pem: &key_pem,
            cert_der: &id.cert_der,
            app_profile: &app_profile,
            app_entitlements: &app_ents,
            helper_profile: &helper_profile,
            helper_entitlements: &helper_ents,
        },
    )?;
    drop(key_pem);
    say("signed");
    let ipa = scratch.path().join("Slashplayed.ipa");
    kit::ipa(&kit.app, &ipa)?;
    say(&format!("installing on {} ({} MB)", d.name, std::fs::metadata(&ipa)?.len() / 1_000_000));
    device::install(&d, &ipa).await?;
    say("installed");

    // 6. Into the container: the pairing record, the developer disk image, the signing identity.
    let mut afc = device::container(&d, &bundle_id).await?;
    let has_pairing = device::size(&mut afc, device::PAIRING_PATH).await.unwrap_or(0) > 0;
    if has_pairing && !args.flag("--pair-again") {
        say("the app already has a pairing record");
    } else {
        let size = device::send_pairing(&d, &mut afc).await?;
        say(&format!("sent {} ({size} bytes)", device::PAIRING_PATH));
    }
    if !ddi::send_if_needed(&mut afc).await? {
        say("the app already has this developer disk image");
    }
    // The .p12 first: the launcher imports only a whole pair, and deletes a half one (DeviceIdentity.swift).
    let password = secret::p12_password();
    let p12 = provision::p12(&id, &password)?;
    device::put(&mut afc, "Library/spidentity.p12", &p12).await?;
    device::put(&mut afc, "Library/spidentity.pass", password.as_bytes()).await?;
    drop(p12);
    drop(password);
    say("sent the signing identity, for installing and updating games on the device");
    // The Apple token last: with it the app gets its own renewed profiles from Apple (apps/client/spapple.m),
    // so it keeps opening with no computer. The launcher imports it into its keychain and deletes the file.
    match device_token {
        Some(t) => {
            device::put(&mut afc, "Library/spappletoken.json", &t).await?;
            drop(t);
            say("sent the Apple token, for the app to renew its own profiles");
        }
        None => say("no Apple token sent (--server-client-info): the app can't renew its own profiles"),
    }

    eprintln!();
    eprintln!("Slashplayed is on {}.", d.name);
    if free {
        eprintln!(
            "It's signed with a free Apple ID: the first time, trust it in Settings > General > VPN & Device Management. Run this again within 7 days, or the app stops opening."
        );
    }
    eprintln!("Open Slashplayed and tap a game to install it on the device.");
    Ok(())
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

    #[test]
    fn bad_arguments() {
        assert!(p(&["--team"]).is_err());
        assert!(p(&["--password", "x"]).is_err(), "no password ever comes from the command line");
        assert!(p(&["install", "extra"]).is_err());
    }
}
