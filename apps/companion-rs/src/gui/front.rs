// The window's side of a run: what the flow (flow.rs) last said, and the question it waits on, in one
// Shared the window reads every frame; and the Frontend that fills it, on the run's own thread. A question
// is a oneshot channel the window answers once.
//
// The password goes from the window's field to Gui::password, never into Shared: Shared is what the window
// draws and what Copy Details copies from, and holds no credential.

use eframe::egui;
use std::sync::{Arc, Mutex, MutexGuard};

use isideload::{
    auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::teams::DeveloperTeam,
};
use rootcause::prelude::*;
use tokio::sync::oneshot;
use zeroize::Zeroizing;

use crate::flow::{self, Ask, Backend, CertLimit, DeviceInfo, Done, Event, Frontend, SignIn, Step, Wait};

/// What the flow waits for the person to answer.
pub enum Question {
    /// The Apple ID, and the password (kept by Gui until the sign-in asks).
    SignIn(oneshot::Sender<(SignIn, Zeroizing<String>)>),
    TwoFactor {
        /// The code came by text message (else to the person's Apple devices).
        sms: bool,
        /// The last answer didn't work.
        retry: bool,
        /// The trusted numbers, as Apple masks them: id and number.
        numbers: Vec<(u32, String)>,
        reply: oneshot::Sender<TwoFactorCallbackResponse>,
    },
    Team {
        /// Name and team ID.
        teams: Vec<(String, String)>,
        reply: oneshot::Sender<usize>,
    },
    Revoke {
        certificates: String,
        oldest: String,
        reply: oneshot::Sender<bool>,
    },
}

#[derive(Default)]
pub struct Shared {
    pub step: Option<Step>,
    /// The say() lines, for Details.
    pub lines: Vec<String>,
    pub wait: Option<Wait>,
    pub progress: Option<u64>,
    /// What's on USB now, while the device is picked.
    pub devices: Vec<DeviceInfo>,
    /// The device the person picked from several, by UDID.
    pub picked: Option<String>,
    /// The device being set up.
    pub device: Option<DeviceInfo>,
    pub question: Option<Question>,
    /// The run's end: what it did, or its error through secret::safe_error.
    pub outcome: Option<Result<Done, String>>,
    /// The person cancelled the sign-in: the run's error is theirs, and it starts again.
    pub cancelled: bool,
}

impl Shared {
    /// What Copy Details copies: the error and the lines, which hold no credential.
    pub fn details(&self) -> String {
        let mut out = String::new();
        if let Some(Err(e)) = &self.outcome {
            out.push_str(e);
            out.push_str("\n\n");
        }
        for l in &self.lines {
            out.push_str("- ");
            out.push_str(l);
            out.push('\n');
        }
        out.push_str(&format!(
            "\nSlashplayed Companion {} (device kit: {}) on {}\n",
            env!("CARGO_PKG_VERSION"),
            crate::kit::release_tag(),
            std::env::consts::OS
        ));
        out
    }
}

pub type Handle = Arc<Mutex<Shared>>;

pub fn lock(s: &Handle) -> MutexGuard<'_, Shared> {
    s.lock().unwrap_or_else(|p| p.into_inner())
}

/// Starts a run: the person's side in `shared`, the device and Apple from `backend`.
pub type Starter = Arc<dyn Fn(Handle, egui::Context) + Send + Sync>;

/// A Starter for a Backend: each run on a thread of its own, with its own runtime.
pub fn starter<B: Backend + 'static>(
    backend: impl Fn() -> Result<B, Report> + Send + Sync + 'static,
    kit: Option<std::path::PathBuf>,
) -> Starter {
    let backend = Arc::new(backend);
    Arc::new(move |shared: Handle, ctx: egui::Context| {
        let (backend, kit) = (backend.clone(), kit.clone());
        std::thread::spawn(move || {
            let gui = Gui { shared: shared.clone(), ctx: ctx.clone(), password: Mutex::new(None) };
            let opts = flow::Options {
                kit: kit.as_deref(),
                team: None,
                bundle_id: None,
                anisette: crate::account::DEFAULT_ANISETTE,
                server_client_info: false,
            };
            let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
            let result = runtime.block_on(async { flow::install(&mut backend()?, &gui, &opts).await });
            drop(gui);
            let mut s = lock(&shared);
            s.question = None;
            s.outcome = Some(result.map_err(|e| crate::secret::safe_error(&e)));
            drop(s);
            ctx.request_repaint();
        });
    })
}

struct Gui {
    shared: Handle,
    ctx: egui::Context,
    /// The password from the sign-in screen until the sign-in takes it.
    password: Mutex<Option<Zeroizing<String>>>,
}

impl Gui {
    fn with<R>(&self, f: impl FnOnce(&mut Shared) -> R) -> R {
        let r = f(&mut lock(&self.shared));
        self.ctx.request_repaint();
        r
    }

    async fn ask<T>(&self, question: impl FnOnce(oneshot::Sender<T>) -> Question) -> Result<T, Report> {
        let (tx, rx) = oneshot::channel();
        self.with(|s| s.question = Some(question(tx)));
        rx.await.map_err(|_| report!("the window closed"))
    }
}

impl Frontend for Gui {
    fn report(&self, event: Event) {
        self.with(|s| match event {
            Event::Step(step) => {
                s.step = Some(step);
                s.wait = None;
                s.progress = None;
            }
            Event::Say(line) => {
                s.wait = None;
                s.lines.push(line);
            }
            Event::Wait(w) => s.wait = Some(w),
            Event::Progress(p) => s.progress = Some(p),
            Event::Done(_) => {}
        });
    }

    fn choose_device<'a>(&'a self, devices: &'a [DeviceInfo]) -> Ask<'a, Option<usize>> {
        let pick = self.with(|s| {
            s.devices = devices.to_vec();
            // The one picked, while it's plugged in; else the only one.
            let i = match &s.picked {
                Some(u) => devices.iter().position(|d| &d.udid == u),
                None if devices.len() == 1 => Some(0),
                None => None,
            };
            if let Some(i) = i {
                s.device = Some(devices[i].clone());
            }
            i
        });
        Box::pin(async move { Ok(pick) })
    }

    fn waits_for_developer_mode(&self) -> bool {
        true
    }

    fn sign_in(&self) -> Ask<'_, SignIn> {
        Box::pin(async move {
            let (sign_in, password) = self.ask(Question::SignIn).await?;
            *self.password.lock().unwrap_or_else(|p| p.into_inner()) = Some(password);
            Ok(sign_in)
        })
    }

    fn password<'a>(&'a self, _: &'a str) -> Ask<'a, Zeroizing<String>> {
        let p = self.password.lock().unwrap_or_else(|p| p.into_inner()).take();
        Box::pin(async move { p.ok_or_else(|| report!("no password typed")) })
    }

    fn two_factor(&self, p: TwoFactorCallbackParams) -> Ask<'_, TwoFactorCallbackResponse> {
        let numbers = p.numbers.iter().map(|n| (n.id, n.number_with_dial_code.clone())).collect();
        Box::pin(async move {
            let answer = self.ask(|reply| Question::TwoFactor { sms: p.sms, retry: p.unknown, numbers, reply }).await?;
            if matches!(answer, TwoFactorCallbackResponse::Abort) {
                self.with(|s| s.cancelled = true);
            }
            Ok(answer)
        })
    }

    fn choose_team<'a>(&'a self, teams: &'a [DeveloperTeam]) -> Ask<'a, usize> {
        let teams = teams.iter().map(|t| (t.name.clone().unwrap_or_else(|| "?".into()), t.team_id.clone())).collect();
        Box::pin(async move { self.ask(|reply| Question::Team { teams, reply }).await })
    }

    fn confirm_revoke<'a>(&'a self, limit: &'a CertLimit) -> Ask<'a, ()> {
        Box::pin(async move {
            let oldest = limit.oldest.clone();
            let certificates = limit.certificates.clone();
            if self.ask(|reply| Question::Revoke { certificates, oldest, reply }).await? {
                Ok(())
            } else {
                bail!(
                    "the team has all the development certificates Apple allows, and this computer has no credential store to keep its signing key in. Nothing was revoked. Free a slot yourself, then try again"
                )
            }
        })
    }
}
