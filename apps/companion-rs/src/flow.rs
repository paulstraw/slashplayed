// One install, as both programs run it: the order of the six steps (main.rs's list), and every question
// that's the person's to answer, asked through a Frontend (the command line's prompts, or the window's
// screens). What talks to the device and to Apple is a Backend: live.rs's, or a test's fake. So the order,
// the waits, and the questions are the same code for both programs, and testable without a device or an
// Apple ID.
//
// The password and the 2FA code go from the Frontend straight into the sign-in (account.rs) and are never
// kept here, logged, or put in an Event; an Event never carries a credential (CLAUDE.md).

use std::{future::Future, path::Path, pin::Pin, time::Duration};

use isideload::{
    auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::teams::DeveloperTeam,
};
use rootcause::prelude::*;
use zeroize::Zeroizing;

/// A Frontend's answer, to come: boxed, so the trait stays usable as `&dyn Frontend`, and Send, because the
/// sign-in's 2FA callback must be.
pub type Ask<'a, T> = Pin<Box<dyn Future<Output = Result<T, Report>> + Send + 'a>>;

/// An iPhone, iPad, or anything else usbmuxd lists on USB, as lockdown names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceInfo {
    pub udid: String,
    pub name: String,
    /// lockdown's DeviceClass: iPhone, iPad, RealityDevice, …
    pub class: String,
    pub os: String,
}

/// The six steps, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Step {
    /// The device kit, downloaded and checked.
    Kit,
    /// The device: picked, trusting this computer, Developer Mode on.
    Device,
    /// The Apple ID sign-in and the team.
    SignIn,
    /// The device, App IDs, capabilities, certificate, and profiles on the team.
    Provision,
    /// The app signed and installed.
    Install,
    /// The pairing record, the developer disk image, and the Apple token, into the app's container.
    Container,
}

/// Why the device asks for the person.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Wait {
    /// Locked, with a pairing it accepts: setup goes on once it's unlocked.
    UnlockTrusted { device: String },
    /// Locked, and not paired yet: it asks whether to trust this computer once it's unlocked.
    UnlockToTrust { device: String },
    /// Locked, at its first service: setup goes on once it's unlocked.
    Unlock { device: String },
    /// Asking whether to trust this computer.
    Trust { device: String },
    /// Developer Mode is off: its steps on the device, after which this goes on by itself.
    DeveloperMode { device: String },
}

impl Wait {
    /// The sentence for the person, as the command line has always said it.
    pub fn text(&self) -> String {
        match self {
            Wait::UnlockTrusted { device } => {
                format!("Unlock {device}: it trusts this computer, and setup goes on once it's unlocked.")
            }
            Wait::UnlockToTrust { device } => {
                format!("Unlock {device}: it asks whether to trust this computer once it's unlocked.")
            }
            Wait::Unlock { device } => format!("Unlock {device}: setup goes on once it's unlocked."),
            Wait::Trust { device } => format!("On {device}, tap Trust, then enter its passcode."),
            Wait::DeveloperMode { device } => format!(
                "Developer Mode is off on {device}. On it, open Settings > Privacy & Security > Developer Mode, turn it on, and restart when asked; after the restart, tap Turn On and enter the passcode."
            ),
        }
    }
}

/// How the run ended, for the closing words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Done {
    pub device: String,
    /// Signed with a free Apple ID's team.
    pub free: bool,
    /// The device got the Apple token, so the app renews its own profiles.
    pub renews: bool,
}

impl Done {
    /// The closing lines, as the command line has always printed them.
    pub fn lines(&self) -> Vec<String> {
        let mut out = vec![format!("Slashplayed is on {}.", self.device)];
        if self.free {
            out.push(
                "It's signed with a free Apple ID: the first time, trust it in Settings > General > VPN & Device Management."
                    .into(),
            );
            out.push(if self.renews {
                "Its signing lasts 7 days. It renews itself when a game starts in the last 3; if it can't, its start screen says so, and running this again fixes it.".into()
            } else {
                "Run this again within 7 days, or the app stops opening.".into()
            });
        }
        out.push("Open Slashplayed and tap a game to install it on the device.".into());
        out
    }
}

/// Something for the person to see. Never a credential.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// A step began.
    Step(Step),
    /// One line of what happened (the command line's "- " lines).
    Say(String),
    /// The device waits for the person.
    Wait(Wait),
    /// The app's install on the device, in percent.
    Progress(u64),
    /// Finished.
    Done(Done),
}

/// The Apple ID to sign in with, and whether to make a new pairing record even if the app has one.
pub struct SignIn {
    pub apple_id: String,
    pub pair_again: bool,
}

/// The team's certificate limit, reached with no credential store to keep this computer's key in (so it
/// can't reuse a certificate): whether to revoke the oldest one a Slashplayed tool made.
pub struct CertLimit {
    /// The team's certificates by name and end date (provision::describe).
    pub certificates: String,
    /// The one that would be revoked, by name and end date. Only asked when there is one.
    pub oldest: String,
}

/// The person's side of a run.
pub trait Frontend: Sync {
    fn report(&self, event: Event);

    fn say(&self, line: &str) {
        self.report(Event::Say(line.to_string()));
    }

    /// The device to set up, from those on USB now; None to look again in a moment (devices come and go).
    fn choose_device<'a>(&'a self, devices: &'a [DeviceInfo]) -> Ask<'a, Option<usize>>;

    /// Whether to wait for Developer Mode to be turned on, rather than stop (the person runs it again then).
    fn waits_for_developer_mode(&self) -> bool;

    fn sign_in(&self) -> Ask<'_, SignIn>;

    /// The Apple ID's password, for the sign-in only: used once and zeroed (account.rs).
    fn password<'a>(&'a self, apple_id: &'a str) -> Ask<'a, Zeroizing<String>>;

    /// What to do about Apple's two-factor step: a code, or another way to get one.
    fn two_factor(&self, params: TwoFactorCallbackParams) -> Ask<'_, TwoFactorCallbackResponse>;

    /// Which of the Apple ID's teams signs Slashplayed, when it has several and none was named.
    fn choose_team<'a>(&'a self, teams: &'a [DeveloperTeam]) -> Ask<'a, usize>;

    /// Ok to revoke, an error (saying what to do instead) not to.
    fn confirm_revoke<'a>(&'a self, limit: &'a CertLimit) -> Ask<'a, ()>;
}

/// What the person can't choose, set on the command line only.
pub struct Options<'a> {
    /// A kit to use instead of this release's (--kit).
    pub kit: Option<&'a Path>,
    /// The team (--team), when the Apple ID has several.
    pub team: Option<&'a str>,
    /// The app's bundle ID (--bundle-id); default <team>.slashplayed.
    pub bundle_id: Option<&'a str>,
    pub anisette: &'a str,
    pub server_client_info: bool,
}

/// The device and Apple, for the flow. live.rs's talks to them; tests fake them.
#[allow(async_fn_in_trait)]
pub trait Backend {
    /// 1. The device kit, downloaded (or read from `path`), checked, and unpacked: its version and where it
    /// came from.
    async fn kit(&mut self, path: Option<&Path>) -> Result<(String, String), Report>;
    /// 2. What's on USB now.
    async fn devices(&mut self) -> Result<Vec<DeviceInfo>, Report>;
    /// The device trusts this computer (waiting for its unlock and Trust).
    async fn trust(&mut self, d: &DeviceInfo, ui: &dyn Frontend) -> Result<(), Report>;
    /// Whether Developer Mode is on (waiting for its unlock); when it's off, its setting is shown in
    /// Settings.
    async fn developer_mode(&mut self, d: &DeviceInfo, ui: &dyn Frontend) -> Result<bool, Report>;
    /// 3. Signs in (the Frontend gives the password and the 2FA answers) and keeps the session.
    async fn sign_in(&mut self, apple_id: &str, anisette: &str, server_client_info: bool, ui: &dyn Frontend)
    -> Result<(), Report>;
    async fn teams(&mut self) -> Result<Vec<DeveloperTeam>, Report>;
    /// 4. Everything on the team; whether the team is free.
    async fn provision(
        &mut self,
        team: &DeveloperTeam,
        d: &DeviceInfo,
        bundle_id: &str,
        apple_id: &str,
        ui: &dyn Frontend,
    ) -> Result<bool, Report>;
    /// 5. The kit's app, signed for the team and installed.
    async fn sign_and_install(&mut self, d: &DeviceInfo, team: &DeveloperTeam, bundle_id: &str, free: bool, ui: &dyn Frontend)
    -> Result<(), Report>;
    /// 6. Whether the app's container has a pairing record.
    async fn has_pairing(&mut self, d: &DeviceInfo, bundle_id: &str) -> Result<bool, Report>;
    /// A new RemotePairing record into the container: its size.
    async fn send_pairing(&mut self, d: &DeviceInfo) -> Result<usize, Report>;
    /// The developer disk image into the container, unless it's there: whether it was copied.
    async fn send_ddi(&mut self, ui: &dyn Frontend) -> Result<bool, Report>;
    /// The Apple token into the container: false when the sign-in made none (--server-client-info).
    async fn send_token(&mut self) -> Result<bool, Report>;
}

/// Exactly one team is the one: none is an error, several are the person's to choose.
pub fn only_team(teams: &[DeveloperTeam]) -> Result<Option<usize>, Report> {
    match teams.len() {
        0 => bail!(
            "this Apple ID has no developer team. Sign in once at developer.apple.com to make its free Personal Team, then try again"
        ),
        1 => Ok(Some(0)),
        _ => Ok(None),
    }
}

/// How often a wait looks at the device again.
pub const POLL: Duration = Duration::from_secs(2);
/// How long the Developer Mode wait goes without a word from the device before it stops: its restart takes
/// a minute or two, and an error that lasts longer (usbmuxd gone, a pairing it now refuses) won't pass.
pub const DEVICE_SILENCE: Duration = Duration::from_secs(300);

/// One install, start to finish. To stop it early (the window closing), drop the future: every wait in it
/// is an await.
pub async fn install(b: &mut impl Backend, ui: &dyn Frontend, opts: &Options<'_>) -> Result<Done, Report> {
    // 1. The kit, first: a bad download shouldn't cost a sign-in.
    ui.report(Event::Step(Step::Kit));
    let (version, from) = b.kit(opts.kit).await?;
    ui.say(&format!("device kit {version} from {from}"));

    // 2. The device.
    ui.report(Event::Step(Step::Device));
    let mut d = loop {
        let devices = b.devices().await?;
        if let Some(i) = ui.choose_device(&devices).await? {
            break devices.into_iter().nth(i).ok_or_else(|| report!("no such device"))?;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    match d.class.as_str() {
        "iPhone" | "iPad" => {}
        "RealityDevice" | "AppleVision" => bail!(
            "{} is a Vision Pro. Setting up Slashplayed on Vision Pro still needs a Mac with the Slashplayed Companion",
            d.name
        ),
        other => bail!("{} is a {other}: Slashplayed runs on iPhone, iPad, and Vision Pro", d.name),
    }
    ui.say(&format!("{} ({}, iOS {})", d.name, d.class, d.os));
    b.trust(&d, ui).await?;
    if !b.developer_mode(&d, ui).await? {
        let wait = Wait::DeveloperMode { device: d.name.clone() };
        if !ui.waits_for_developer_mode() {
            bail!(
                "Developer Mode is off on {}. On it, open Settings > Privacy & Security > Developer Mode, turn it on, and restart when asked; after the restart, tap Turn On, enter the passcode, then run this again",
                d.name
            );
        }
        // Turning it on restarts the device: it leaves USB, comes back locked, and asks to Turn On after its
        // unlock. Errors on the way are the restart's, so the wait looks again; one that outlasts any restart
        // (DEVICE_SILENCE) stops it, with what went wrong.
        let mut heard = tokio::time::Instant::now();
        let mut last: Option<String> = None;
        loop {
            ui.report(Event::Wait(wait.clone()));
            tokio::time::sleep(POLL).await;
            let answer = match b.devices().await {
                Ok(devices) => match devices.into_iter().find(|x| x.udid == d.udid) {
                    Some(back) => {
                        d = back;
                        b.developer_mode(&d, ui).await.map(Some)
                    }
                    None => Ok(None),
                },
                Err(e) => Err(e),
            };
            match answer {
                Ok(Some(true)) => break,
                Ok(Some(false)) => heard = tokio::time::Instant::now(),
                Ok(None) => {}
                Err(e) => last = Some(crate::secret::safe_error(&e)),
            }
            if heard.elapsed() > DEVICE_SILENCE {
                match last {
                    Some(e) => bail!("lost {} while waiting for Developer Mode: {e}", d.name),
                    None => bail!(
                        "{} hasn't come back on USB since its restart for Developer Mode: plug it in, unlock it, and try again",
                        d.name
                    ),
                }
            }
        }
        ui.say(&format!("Developer Mode is on on {}", d.name));
    }

    // 3. The Apple ID and team.
    ui.report(Event::Step(Step::SignIn));
    let SignIn { apple_id, pair_again } = ui.sign_in().await?;
    if apple_id.is_empty() {
        bail!("no Apple ID given");
    }
    ui.say(&format!("signing in, with anisette from {}", opts.anisette));
    b.sign_in(&apple_id, opts.anisette, opts.server_client_info, ui).await?;
    let mut teams = b.teams().await?;
    let i = match opts.team {
        Some(id) => teams.iter().position(|t| t.team_id == id).ok_or_else(|| report!("this Apple ID has no team {id}"))?,
        None => match only_team(&teams)? {
            Some(i) => i,
            None => ui.choose_team(&teams).await?,
        },
    };
    if i >= teams.len() {
        bail!("not a number from the list");
    }
    let team = teams.remove(i);
    ui.say(&format!("team {} ({})", team.name.as_deref().unwrap_or("?"), team.team_id));
    let bundle_id = opts.bundle_id.map(str::to_string).unwrap_or_else(|| format!("{}.slashplayed", team.team_id));
    if !crate::kit::valid_bundle_id(&bundle_id) {
        bail!("{bundle_id} isn't a valid bundle ID (letters, digits, and hyphens, separated by dots)");
    }

    // 4. Provisioning.
    ui.report(Event::Step(Step::Provision));
    let free = b.provision(&team, &d, &bundle_id, &apple_id, ui).await?;

    // 5. Sign and install.
    ui.report(Event::Step(Step::Install));
    b.sign_and_install(&d, &team, &bundle_id, free, ui).await?;

    // 6. Into the container: the pairing record, the developer disk image, and the Apple token (with it the
    // app gets its own renewed profiles from Apple: apps/client/spapple.m).
    ui.report(Event::Step(Step::Container));
    if b.has_pairing(&d, &bundle_id).await? && !pair_again {
        ui.say("the app already has a pairing record");
    } else {
        let size = b.send_pairing(&d).await?;
        ui.say(&format!("sent {} ({size} bytes)", crate::device::PAIRING_PATH));
    }
    if !b.send_ddi(ui).await? {
        ui.say("the app already has this developer disk image");
    }
    let renews = b.send_token().await?;
    ui.say(if renews {
        "sent the Apple token, for the app to renew its own profiles"
    } else {
        "no Apple token sent (--server-client-info): the app can't renew its own profiles"
    });

    let done = Done { device: d.name.clone(), free, renews };
    ui.report(Event::Done(done.clone()));
    Ok(done)
}

#[cfg(test)]
pub(crate) mod fake {
    //! A device and an Apple ID made up here, for flow.rs's tests and the window's (src/gui/tests.rs).
    use std::sync::{Arc, Mutex};

    use isideload::auth::apple_account::TrustedNumber;

    use super::*;

    /// The made-up Apple ID's password. Built, not written out: a password in the source, even a fake one,
    /// is what code scanning looks for.
    pub fn password() -> String {
        ('a'..='h').collect()
    }

    pub fn team(id: &str) -> DeveloperTeam {
        DeveloperTeam { name: Some(format!("Team {id}")), team_id: id.into(), r#type: None, status: None }
    }

    pub fn phone(udid: &str, class: &str) -> DeviceInfo {
        DeviceInfo { udid: udid.into(), name: format!("{class} {udid}"), class: class.into(), os: "27.1".into() }
    }

    /// A device and an Apple ID made up here. `lists` is what each devices() call answers, the last one
    /// repeated; `dev_mode` what each developer_mode() call answers, likewise.
    pub struct Fake {
        pub lists: Vec<Vec<DeviceInfo>>,
        pub dev_mode: Vec<Result<bool, &'static str>>,
        /// The last devices() answer: developer_mode() fails for a device not in it, as the real one does.
        pub seen: Vec<DeviceInfo>,
        pub teams: Vec<DeveloperTeam>,
        pub free: bool,
        pub has_pairing: bool,
        pub token: bool,
        /// The person must answer Apple's two-factor step (a text, then the code).
        pub two_factor: bool,
        /// The team's certificate limit is hit, with no store for the key: the revoke is asked.
        pub cert_limit: bool,
        /// The first code is wrong: Apple asks again, with its error.
        pub wrong_code: bool,
        /// What the backend was asked, in order.
        pub calls: Arc<Mutex<Vec<String>>>,
    }

    impl Default for Fake {
        fn default() -> Self {
            Self {
                lists: vec![vec![phone("A", "iPhone")]],
                dev_mode: vec![Ok(true)],
                seen: Vec::new(),
                teams: vec![team("T1")],
                free: true,
                has_pairing: false,
                token: true,
                two_factor: true,
                cert_limit: false,
                wrong_code: false,
                calls: Arc::default(),
            }
        }
    }

    fn next<T: Clone>(v: &mut Vec<T>) -> T {
        if v.len() > 1 { v.remove(0) } else { v[0].clone() }
    }

    impl Fake {
        fn log(&self, s: String) {
            self.calls.lock().unwrap().push(s);
        }
        pub fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl Backend for Fake {
        async fn kit(&mut self, _: Option<&Path>) -> Result<(String, String), Report> {
            self.log("kit".into());
            Ok(("9.9.9".into(), "a test".into()))
        }
        async fn devices(&mut self) -> Result<Vec<DeviceInfo>, Report> {
            self.seen = next(&mut self.lists);
            Ok(self.seen.clone())
        }
        async fn trust(&mut self, d: &DeviceInfo, _: &dyn Frontend) -> Result<(), Report> {
            self.log(format!("trust {}", d.udid));
            Ok(())
        }
        async fn developer_mode(&mut self, d: &DeviceInfo, _: &dyn Frontend) -> Result<bool, Report> {
            self.log(format!("devmode {}", d.udid));
            if !self.seen.iter().any(|x| x.udid == d.udid) {
                bail!("no device {} on USB", d.udid);
            }
            next(&mut self.dev_mode).map_err(|e| report!("{e}"))
        }
        /// As account::sign_in asks: the password once, then the 2FA step until it's answered with a code.
        async fn sign_in(&mut self, apple_id: &str, _: &str, _: bool, ui: &dyn Frontend) -> Result<(), Report> {
            let password = ui.password(apple_id).await?;
            // Compared without printing it, as a real password must never be.
            if *password != fake::password() {
                bail!("Apple didn't accept the sign-in");
            }
            if !self.two_factor {
                return Ok(());
            }
            let numbers = vec![TrustedNumber {
                number_with_dial_code: "+1 (•••) •••-••12".into(),
                last_two_digits: "12".into(),
                push_mode: "sms".into(),
                id: 3,
            }];
            let (mut sms, mut last_error, mut wrong) = (false, None, self.wrong_code);
            loop {
                let params = TwoFactorCallbackParams { last_error: last_error.take(), unknown: false, sms, numbers: numbers.clone(), selected_number_id: None };
                match ui.two_factor(params).await? {
                    TwoFactorCallbackResponse::SubmitCode(c) => {
                        self.log(format!("code {c} sms={sms}"));
                        if std::mem::take(&mut wrong) {
                            last_error = Some("-21669 - Incorrect verification code".to_string());
                            continue;
                        }
                        return Ok(());
                    }
                    TwoFactorCallbackResponse::SendSms(n) => {
                        self.log(format!("sms {n}"));
                        sms = true;
                    }
                    TwoFactorCallbackResponse::Abort => bail!("aborted"),
                    _ => {}
                }
            }
        }
        async fn teams(&mut self) -> Result<Vec<DeveloperTeam>, Report> {
            Ok(self.teams.clone())
        }
        async fn provision(&mut self, t: &DeveloperTeam, _: &DeviceInfo, bundle_id: &str, _: &str, ui: &dyn Frontend) -> Result<bool, Report> {
            self.log(format!("provision {} {bundle_id}", t.team_id));
            if self.cert_limit {
                let oldest = "\"Slashplayed companion\", until 2026-12-01".to_string();
                ui.confirm_revoke(&CertLimit { certificates: oldest.clone(), oldest }).await?;
                self.log("revoked".into());
            }
            Ok(self.free)
        }
        async fn sign_and_install(&mut self, _: &DeviceInfo, _: &DeveloperTeam, _: &str, free: bool, ui: &dyn Frontend) -> Result<(), Report> {
            self.log(format!("install free={free}"));
            ui.report(Event::Progress(50));
            Ok(())
        }
        async fn has_pairing(&mut self, _: &DeviceInfo, _: &str) -> Result<bool, Report> {
            self.log("has pairing?".into());
            Ok(self.has_pairing)
        }
        async fn send_pairing(&mut self, _: &DeviceInfo) -> Result<usize, Report> {
            self.log("pairing".into());
            Ok(1234)
        }
        async fn send_ddi(&mut self, _: &dyn Frontend) -> Result<bool, Report> {
            self.log("ddi".into());
            Ok(true)
        }
        async fn send_token(&mut self) -> Result<bool, Report> {
            self.log("token".into());
            Ok(self.token)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::{fake::*, *};

    /// The person, scripted: picks the first device once there is one, signs in, asks for a text first.
    #[derive(Default)]
    struct Person {
        waits: bool,
        pair_again: bool,
        team: usize,
        revoke: bool,
        events: Mutex<Vec<Event>>,
        asked: Mutex<Vec<String>>,
    }

    impl Person {
        fn asked(&self, s: &str) {
            self.asked.lock().unwrap().push(s.into());
        }
        fn events(&self) -> Vec<Event> {
            self.events.lock().unwrap().clone()
        }
    }

    impl Frontend for Person {
        fn report(&self, event: Event) {
            self.events.lock().unwrap().push(event);
        }
        fn choose_device<'a>(&'a self, devices: &'a [DeviceInfo]) -> Ask<'a, Option<usize>> {
            Box::pin(async move { Ok((!devices.is_empty()).then_some(0)) })
        }
        fn waits_for_developer_mode(&self) -> bool {
            self.waits
        }
        fn sign_in(&self) -> Ask<'_, SignIn> {
            Box::pin(async move { Ok(SignIn { apple_id: "x@example.com".into(), pair_again: self.pair_again }) })
        }
        fn password<'a>(&'a self, _: &'a str) -> Ask<'a, Zeroizing<String>> {
            self.asked("password");
            Box::pin(async move { Ok(Zeroizing::new(password())) })
        }
        fn two_factor(&self, p: TwoFactorCallbackParams) -> Ask<'_, TwoFactorCallbackResponse> {
            self.asked("code");
            Box::pin(async move {
                Ok(if p.sms { TwoFactorCallbackResponse::SubmitCode("123456".into()) } else { TwoFactorCallbackResponse::SendSms(p.numbers[0].id) })
            })
        }
        fn choose_team<'a>(&'a self, _: &'a [DeveloperTeam]) -> Ask<'a, usize> {
            self.asked("team");
            Box::pin(async move { Ok(self.team) })
        }
        fn confirm_revoke<'a>(&'a self, _: &'a CertLimit) -> Ask<'a, ()> {
            self.asked("revoke");
            Box::pin(async move { if self.revoke { Ok(()) } else { bail!("not revoked") } })
        }
    }

    fn opts() -> Options<'static> {
        Options { kit: None, team: None, bundle_id: None, anisette: "https://anisette.example", server_client_info: false }
    }

    #[tokio::test(start_paused = true)]
    async fn one_run_in_order() {
        let mut b = Fake::default();
        let ui = Person::default();
        let done = install(&mut b, &ui, &opts()).await.unwrap();
        assert_eq!(done, Done { device: "iPhone A".into(), free: true, renews: true });
        assert_eq!(
            b.calls(),
            [
                "kit", "trust A", "devmode A", "sms 3", "code 123456 sms=true", "provision T1 T1.slashplayed", "install free=true",
                "has pairing?", "pairing", "ddi", "token",
            ]
        );
        // One team: never asked. The password once, the code twice (the text, then the code).
        assert_eq!(*ui.asked.lock().unwrap(), ["password", "code", "code"]);
        let steps: Vec<Step> = ui.events().into_iter().filter_map(|e| if let Event::Step(s) = e { Some(s) } else { None }).collect();
        assert_eq!(steps, [Step::Kit, Step::Device, Step::SignIn, Step::Provision, Step::Install, Step::Container]);
        assert!(ui.events().contains(&Event::Progress(50)));
        assert_eq!(ui.events().last(), Some(&Event::Done(done)));
    }

    #[tokio::test(start_paused = true)]
    async fn several_teams_are_the_persons_to_choose() {
        let mut b = Fake { teams: vec![team("T1"), team("T2")], ..Default::default() };
        let ui = Person { team: 1, ..Default::default() };
        install(&mut b, &ui, &opts()).await.unwrap();
        assert!(ui.asked.lock().unwrap().contains(&"team".to_string()));
        assert!(b.calls().contains(&"provision T2 T2.slashplayed".to_string()), "{:?}", b.calls());

        // Named on the command line: not asked, and a team it doesn't have is an error.
        let mut b = Fake { teams: vec![team("T1"), team("T2")], ..Default::default() };
        let ui = Person::default();
        install(&mut b, &ui, &Options { team: Some("T2"), ..opts() }).await.unwrap();
        assert!(!ui.asked.lock().unwrap().contains(&"team".to_string()));
        let mut b = Fake { teams: vec![team("T1")], ..Default::default() };
        assert!(install(&mut b, &Person::default(), &Options { team: Some("T9"), ..opts() }).await.is_err());

        let mut b = Fake { teams: vec![], ..Default::default() };
        let e = install(&mut b, &Person::default(), &opts()).await.unwrap_err();
        assert!(e.to_string().contains("no developer team"), "{e}");
    }

    #[tokio::test(start_paused = true)]
    async fn the_device_list_is_looked_at_until_one_is_there() {
        let mut b = Fake { lists: vec![vec![], vec![], vec![phone("B", "iPad")]], ..Default::default() };
        let ui = Person::default();
        assert_eq!(install(&mut b, &ui, &opts()).await.unwrap().device, "iPad B");
    }

    #[tokio::test(start_paused = true)]
    async fn vision_pro_stays_mac_only() {
        let mut b = Fake { lists: vec![vec![phone("V", "RealityDevice")]], ..Default::default() };
        let e = install(&mut b, &Person::default(), &opts()).await.unwrap_err();
        assert!(e.to_string().contains("still needs a Mac"), "{e}");
        assert_eq!(b.calls(), ["kit"], "nothing is asked of a Vision Pro");
    }

    #[tokio::test(start_paused = true)]
    async fn developer_mode_waits_through_the_restart() {
        // Off; then the device is gone (restarting), back but not answering yet, back with it still off
        // (before Turn On), then on. It comes back with a new name, which the end must use.
        let renamed = DeviceInfo { name: "Alex's iPhone".into(), ..phone("A", "iPhone") };
        let mut b = Fake {
            lists: vec![vec![phone("A", "iPhone")], vec![], vec![renamed.clone()]],
            dev_mode: vec![Ok(false), Err("locked"), Ok(false), Ok(true)],
            ..Default::default()
        };
        let ui = Person { waits: true, ..Default::default() };
        let done = install(&mut b, &ui, &opts()).await.unwrap();
        assert_eq!(done.device, "Alex's iPhone");
        let waits = ui.events().iter().filter(|e| matches!(e, Event::Wait(Wait::DeveloperMode { .. }))).count();
        assert_eq!(waits, 4, "{:?}", ui.events());
        // Never asked while it was off USB: the first look, then the three times it was there.
        assert_eq!(b.calls().iter().filter(|c| c.starts_with("devmode")).count(), 4, "{:?}", b.calls());

        // The command line stops and says to run it again.
        let mut b = Fake { dev_mode: vec![Ok(false)], ..Default::default() };
        let e = install(&mut b, &Person::default(), &opts()).await.unwrap_err();
        assert!(e.to_string().contains("then run this again"), "{e}");
        assert_eq!(b.calls(), ["kit", "trust A", "devmode A"], "no sign-in before Developer Mode");
    }

    #[tokio::test(start_paused = true)]
    async fn an_error_that_outlasts_the_restart_stops_the_wait() {
        let mut b = Fake { dev_mode: vec![Ok(false), Err("the device refused the pairing")], ..Default::default() };
        let start = tokio::time::Instant::now();
        // Bounded, so a wait that never stops fails the test rather than hang it.
        let (ui, o) = (Person { waits: true, ..Default::default() }, opts());
        let run = install(&mut b, &ui, &o);
        let e = tokio::time::timeout(DEVICE_SILENCE * 2, run).await.expect("the wait never stopped").unwrap_err();
        assert!(e.to_string().contains("the device refused the pairing"), "{e}");
        assert!(start.elapsed() >= DEVICE_SILENCE, "it gave up before a restart could have finished");

        // Gone from USB and never back: stops too, saying so.
        let mut b = Fake { lists: vec![vec![phone("A", "iPhone")], vec![]], dev_mode: vec![Ok(false)], ..Default::default() };
        let e = install(&mut b, &Person { waits: true, ..Default::default() }, &opts()).await.unwrap_err();
        assert!(e.to_string().contains("hasn't come back on USB"), "{e}");
    }

    #[tokio::test(start_paused = true)]
    async fn the_pairing_record_is_kept_unless_asked() {
        let mut b = Fake { has_pairing: true, ..Default::default() };
        install(&mut b, &Person::default(), &opts()).await.unwrap();
        assert!(!b.calls().contains(&"pairing".to_string()));
        let mut b = Fake { has_pairing: true, ..Default::default() };
        install(&mut b, &Person { pair_again: true, ..Default::default() }, &opts()).await.unwrap();
        assert!(b.calls().contains(&"pairing".to_string()));
    }

    #[test]
    fn closing_words() {
        let paid = Done { device: "iPad".into(), free: false, renews: true }.lines();
        assert_eq!(paid, ["Slashplayed is on iPad.", "Open Slashplayed and tap a game to install it on the device."]);
        let free = Done { device: "iPad".into(), free: true, renews: false }.lines();
        assert!(free[1].contains("VPN & Device Management"));
        assert!(free[2].contains("within 7 days"));
    }
}
