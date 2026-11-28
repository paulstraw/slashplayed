// SP_GUI_DRILL=<state>: one screen with made-up data and no run, for screenshots and a look at each screen
// without a device (as the launcher's SP_START_DRILL does). Nothing here reaches a device or Apple; a
// question's answer goes nowhere.

use tokio::sync::oneshot;

use super::{App, front::Question, lock};
use crate::flow::{DeviceInfo, Done, PairOnly, Step, Wait};

pub const STATES: &[&str] = &[
    "device", "unlock", "developer-mode", "sign-in", "sign-in-installed", "sign-in-twice", "code", "team", "installing", "done", "paired", "error",
    "cert-limit",
];

fn phone(udid: &str, name: &str, class: &str, os: &str) -> DeviceInfo {
    DeviceInfo { udid: udid.into(), name: name.into(), class: class.into(), os: os.into() }
}

pub fn fill(app: &mut App, state: &str) {
    let mut s = lock(&app.shared);
    let iphone = phone("A", "Alex's iPhone", "iPhone", "27.1");
    let lines = [
        "device kit 1.5.0 from v1.5.0's slashplayed-device-kit.zip",
        "Alex's iPhone (iPhone, iOS 27.1)",
        "signing in, with anisette from https://mac-ani.jkcoxson.com",
        "team Alex Example (Personal Team) (A1B2C3D4E5)",
        "Alex's iPhone is already registered on the team",
        "reusing this computer's Slashplayed certificate",
        "profiles made: a free team, good for 6 more days (run this again within a week to keep Slashplayed opening)",
        "signed",
        "installing on Alex's iPhone (61 MB)",
    ];
    let numbers = vec![(1, "+1 (•••) •••-••42".to_string()), (2, "+44 ••••• ••••91".to_string())];
    s.step = Some(Step::Device);
    match state {
        "device" => {
            s.devices = vec![iphone.clone(), phone("B", "Alex's iPad", "iPad", "26.4")];
            app.device_choice = Some("A".into());
        }
        "unlock" => {
            s.device = Some(iphone.clone());
            s.wait = Some(Wait::UnlockToTrust { device: iphone.name.clone() });
        }
        "developer-mode" => {
            s.device = Some(iphone.clone());
            s.wait = Some(Wait::DeveloperMode { device: iphone.name.clone() });
        }
        "sign-in" | "sign-in-installed" | "sign-in-twice" => {
            s.step = Some(Step::SignIn);
            s.device = Some(iphone.clone());
            let pair_only = match state {
                "sign-in-installed" => PairOnly::Offered,
                "sign-in-twice" => PairOnly::Unavailable(format!(
                    "{} has Slashplayed installed more than once (T1.slashplayed, com.example.slashplayed), so it can't tell which to pair: pair one with slashplayed-cli --pair-again --bundle-id <one of them>",
                    iphone.name
                )),
                _ => PairOnly::NotInstalled,
            };
            s.question = Some(Question::SignIn { pair_only, reply: oneshot::channel().0 });
            app.apple_id = "alex@example.com".into();
        }
        "code" => {
            s.step = Some(Step::SignIn);
            s.question = Some(Question::TwoFactor { sms: false, retry: false, unknown: false, numbers, reply: oneshot::channel().0 });
            app.show_numbers = true;
        }
        "team" => {
            s.step = Some(Step::SignIn);
            s.question = Some(Question::Team {
                teams: vec![("Alex Example (Personal Team)".into(), "A1B2C3D4E5".into()), ("Example Studio LLC".into(), "F6G7H8J9K0".into())],
                reply: oneshot::channel().0,
            });
            app.team_choice = Some(0);
        }
        "installing" => {
            s.step = Some(Step::Install);
            s.lines = lines.iter().map(|l| l.to_string()).collect();
            s.progress = Some(64);
        }
        "done" => {
            s.step = Some(Step::Container);
            s.lines = lines.iter().map(|l| l.to_string()).collect();
            s.outcome = Some(Ok(Done { device: iphone.name.clone(), free: true, renews: true, pair_only: false, expired: None }));
        }
        "paired" => {
            s.step = Some(Step::Container);
            s.pair_only = true;
            s.lines = vec![lines[0].to_string(), lines[1].to_string(), "pairing com.example.slashplayed again, with no sign-in".into()];
            s.outcome = Some(Ok(Done { device: iphone.name.clone(), free: false, renews: false, pair_only: true, expired: None }));
        }
        "error" => {
            s.step = Some(Step::SignIn);
            s.lines = lines[..3].iter().map(|l| l.to_string()).collect();
            s.outcome = Some(Err("Apple didn't accept the sign-in: the Apple ID or password is wrong".into()));
        }
        "cert-limit" => {
            s.step = Some(Step::Provision);
            s.lines = lines[..6].iter().map(|l| l.to_string()).collect();
            s.question = Some(Question::Revoke {
                certificates: "\"Alex's MacBook Pro\", until 2027-03-02; \"Slashplayed companion\", until 2026-11-30".into(),
                oldest: "\"Slashplayed companion\", until 2026-11-30".into(),
                reply: oneshot::channel().0,
            });
        }
        other => {
            drop(s);
            eprintln!("SP_GUI_DRILL: no state {other} (one of: {})", STATES.join(", "));
            std::process::exit(2);
        }
    }
}
