// The window: the same install as slashplayed-cli (flow.rs), with its questions as screens. One fixed-size
// window; the screen follows the run (front.rs's Shared): the device, the Apple ID, the code, the team (only
// when there are several), the steps as they go, and the end. An error shows at the step it stopped, with
// Try Again and Copy Details.
//
// SP_GUI_DRILL=<state> opens one screen with made-up data and no run (drill.rs), for screenshots.

mod drill;
pub mod front;
mod theme;
#[cfg(test)]
mod tests;

use eframe::egui;
use std::sync::Arc;

use egui::{Align, Button, Layout, RichText, TextEdit};
use isideload::auth::apple_account::TwoFactorCallbackResponse;
use zeroize::{Zeroize, Zeroizing};

use crate::flow::{SignIn, Step, Wait};
use front::{Handle, Question, Shared, Starter, lock};
use theme::{DIM, ERROR, GOLD, GROUND, WELL};

/// The window's size: fixed, so every screen is laid out for it.
pub const SIZE: [f32; 2] = [560.0, 620.0];

const STEPS: [(Step, &str); 6] = [
    (Step::Kit, "Get the Slashplayed app"),
    (Step::Device, "Connect to the device"),
    (Step::SignIn, "Sign in to Apple"),
    (Step::Provision, "Make the signing profiles"),
    (Step::Install, "Sign and install the app"),
    (Step::Container, "Get it ready to install games"),
];

pub struct App {
    shared: Handle,
    starter: Starter,
    /// Goodmountain is loaded (theme::apply).
    face: bool,
    apple_id: String,
    /// The password field's text, until Install hands it to the sign-in. Zeroed on drop.
    password: Zeroizing<String>,
    code: String,
    show_numbers: bool,
    device_choice: Option<String>,
    team_choice: Option<usize>,
    /// The Forget dialog: its Apple ID field and what it last said.
    forget: Option<(String, Option<String>)>,
    /// Its Forget, running: the credential store can take a while (Secret Service's unlock prompt).
    forgetting: Option<std::thread::JoinHandle<String>>,
    /// A drill's screenshot to save (SP_GUI_SHOT), and the frames drawn so far.
    shot: Option<(std::path::PathBuf, u32)>,
}

impl App {
    /// The window, with each run started by `starter`; or the drill's screen, and no run.
    pub fn new(ctx: &egui::Context, starter: Starter, drill: Option<&str>) -> Self {
        let face = theme::apply(ctx);
        let mut app = Self {
            shared: Handle::default(),
            starter,
            face,
            apple_id: String::new(),
            password: Zeroizing::new(String::new()),
            code: String::new(),
            show_numbers: false,
            device_choice: None,
            team_choice: None,
            forget: None,
            forgetting: None,
            shot: None,
        };
        match drill {
            Some(state) => {
                drill::fill(&mut app, state);
                app.shot = std::env::var_os("SP_GUI_SHOT").map(|p| (p.into(), 0));
            }
            None => (app.starter)(app.shared.clone(), ctx.clone()),
        }
        app
    }

    fn main_button(&self, ui: &mut egui::Ui, text: &str, enabled: bool) -> bool {
        let label = RichText::new(text).family(theme::family(self.face)).size(20.0).color(GROUND);
        ui.add_enabled(enabled, Button::new(label).fill(GOLD).min_size(egui::vec2(160.0, 40.0))).clicked()
    }

    fn header(&mut self, ui: &mut egui::Ui, title: &str) {
        ui.horizontal(|ui| {
            ui.label(theme::title(title, self.face));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.menu_button(RichText::new("…").size(20.0), |ui| {
                    if ui.button("Forget this computer's signing key…").clicked() {
                        self.forget = Some((self.apple_id.clone(), None));
                        ui.close();
                    }
                });
            });
        });
        ui.add_space(12.0);
    }

    fn restart(&mut self, ctx: &egui::Context) {
        {
            let mut s = lock(&self.shared);
            // Kept for the next run, unless that device is where it failed: then the person picks again.
            let failed_there = s.step == Some(Step::Device) && s.outcome.as_ref().is_some_and(|o| o.is_err());
            let picked = s.picked.take().filter(|_| !failed_there);
            *s = Shared { picked, ..Default::default() };
        }
        self.code.zeroize();
        forget_typing(ctx);
        self.show_numbers = false;
        self.team_choice = None;
        self.device_choice = None;
        (self.starter)(self.shared.clone(), ctx.clone());
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let shared = self.shared.clone();
        let mut s = lock(&shared);
        // A cancelled sign-in isn't an error: start over, the Apple ID kept.
        if s.cancelled && s.outcome.is_some() {
            drop(s);
            self.restart(&ctx);
            s = lock(&shared);
        }
        let frame = egui::Frame::new().fill(GROUND).inner_margin(28.0);
        egui::CentralPanel::default().frame(frame).show(ui, |ui| {
            match (&s.outcome, &s.question) {
                (Some(Ok(_)), _) => self.done(ui, &mut s),
                (Some(Err(_)), _) => self.steps(ui, &mut s, "Something went wrong"),
                (None, Some(Question::SignIn(_))) => self.sign_in(ui, &mut s),
                (None, Some(Question::TwoFactor { .. })) => self.two_factor(ui, &mut s),
                (None, Some(Question::Team { .. })) => self.team(ui, &mut s),
                (None, _) if s.step.is_none() || s.step == Some(Step::Kit) || s.step == Some(Step::Device) => {
                    self.device(ui, &mut s)
                }
                (None, _) => self.steps(ui, &mut s, "Installing"),
            }
        });
        if matches!(s.question, Some(Question::Revoke { .. })) {
            self.revoke(&ctx, &mut s);
        }
        let retry = s.outcome.as_ref().is_some_and(|o| o.is_err()) && ctx.data(|d| d.get_temp::<bool>(retry_id())) == Some(true);
        drop(s);
        if retry {
            ctx.data_mut(|d| d.remove::<bool>(retry_id()));
            self.restart(&ctx);
        }
        self.forget_dialog(&ctx);
        self.screenshot(&ctx);
    }
}

impl App {
    /// A drill with SP_GUI_SHOT=<file.png>: the window's own frame, once it has settled, saved there, and
    /// the window closed. The rendered frame, on every system, with nothing else on the screen.
    fn screenshot(&mut self, ctx: &egui::Context) {
        let Some((path, frames)) = &mut self.shot else { return };
        *frames += 1;
        if *frames == 20 {
            let (path, ctx2) = (path.clone(), ctx.clone());
            ctx.request_screenshot(move |image| {
                let [w, h] = image.size;
                if let Err(e) = image::save_buffer(&path, image.as_raw(), w as u32, h as u32, image::ExtendedColorType::Rgba8) {
                    eprintln!("SP_GUI_SHOT: couldn't save {}: {e}", path.display());
                }
                ctx2.send_viewport_cmd(egui::ViewportCommand::Close);
            });
        }
        ctx.request_repaint();
    }
}

fn retry_id() -> egui::Id {
    egui::Id::unique("sp-retry")
}

fn password_id() -> egui::Id {
    egui::Id::unique("sp-password")
}

fn code_id() -> egui::Id {
    egui::Id::unique("sp-code")
}

/// egui keeps each text field's undo history, its text included, in the Context for as long as the
/// window is open: Ctrl+Z in an emptied password field would bring the password back. Dropped once the
/// text is sent (egui's own copies are freed, not zeroed: best effort, as the zeroing is).
fn forget_typing(ctx: &egui::Context) {
    ctx.data_mut(|d| {
        d.remove::<egui::text_edit::TextEditState>(password_id());
        d.remove::<egui::text_edit::TextEditState>(code_id());
    });
}

/// A note in a well, for what the person has to do on the device.
fn note(ui: &mut egui::Ui, text: &str) {
    egui::Frame::new().fill(WELL).stroke(egui::Stroke::new(1.0, GOLD.linear_multiply(0.6))).inner_margin(12.0).corner_radius(4.0).show(
        ui,
        |ui| {
            ui.set_width(ui.available_width());
            ui.label(text);
        },
    );
}

enum Mark {
    Done,
    Failed,
    ToCome,
}

/// A step's mark, drawn: the default faces have no check mark or cross.
fn mark(ui: &mut egui::Ui, m: Mark) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(18.0, 18.0), egui::Sense::hover());
    let p = ui.painter();
    let c = rect.center();
    let at = |x: f32, y: f32| c + egui::vec2(x, y);
    match m {
        Mark::Done => {
            p.line(vec![at(-5.5, 0.5), at(-1.5, 4.5), at(6.0, -4.5)], egui::Stroke::new(2.2, GOLD));
        }
        Mark::Failed => {
            let s = egui::Stroke::new(2.2, ERROR);
            p.line_segment([at(-4.5, -4.5), at(4.5, 4.5)], s);
            p.line_segment([at(-4.5, 4.5), at(4.5, -4.5)], s);
        }
        Mark::ToCome => {
            p.circle_stroke(c, 4.0, egui::Stroke::new(1.2, DIM));
        }
    }
}

fn small(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).small().color(DIM));
}

impl App {
    fn device(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Connect your device");
        if s.step.is_none() || s.step == Some(Step::Kit) {
            ui.horizontal(|ui| {
                ui.spinner();
                ui.label("Getting the Slashplayed app…");
            });
            return;
        }
        let Some(d) = s.device.clone() else {
            if s.devices.is_empty() {
                ui.label("Plug in your iPhone or iPad with its cable, and unlock it.");
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("Looking for it…").color(DIM));
                });
                return;
            }
            ui.label("Several are plugged in. Which one should get Slashplayed?");
            ui.add_space(8.0);
            for d in &s.devices {
                let label = format!("{} ({}, iOS {})", d.name, d.class, d.os);
                ui.radio_value(&mut self.device_choice, Some(d.udid.clone()), label);
            }
            ui.add_space(16.0);
            let chosen = self.device_choice.as_ref().filter(|u| s.devices.iter().any(|d| &d.udid == *u));
            if self.main_button(ui, "Continue", chosen.is_some()) {
                s.picked = chosen.cloned();
            }
            return;
        };
        ui.label(RichText::new(&d.name).size(18.0));
        small(ui, &format!("{}, iOS {}", d.class, d.os));
        ui.add_space(12.0);
        match &s.wait {
            Some(Wait::DeveloperMode { device }) => {
                ui.label(format!("Developer Mode is off on {device}. To turn it on:"));
                ui.add_space(4.0);
                for (i, line) in [
                    "Open Settings > Privacy & Security > Developer Mode.".to_string(),
                    "Turn it on, and restart when it asks.".to_string(),
                    "After the restart, unlock it, tap Turn On, and enter the passcode.".to_string(),
                ]
                .iter()
                .enumerate()
                {
                    ui.label(format!("{}. {line}", i + 1));
                }
                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("Setup goes on by itself once it's on.").color(DIM));
                });
            }
            Some(w) => {
                note(ui, &w.text());
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("Waiting for the device…").color(DIM));
                });
            }
            None => {
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label("Connecting…");
                });
            }
        }
    }

    fn sign_in(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Sign in with your Apple ID");
        if let Some(d) = &s.device {
            ui.label(format!("Slashplayed gets signed with your Apple ID, for {}.", d.name));
            ui.add_space(8.0);
        }
        let id_label = ui.label("Apple ID");
        ui.add(TextEdit::singleline(&mut self.apple_id).hint_text("name@example.com").desired_width(f32::INFINITY))
            .labelled_by(id_label.id);
        ui.add_space(4.0);
        let pw_label = ui.label("Password");
        let pw = ui
            .add(TextEdit::singleline(&mut *self.password).id(password_id()).password(true).desired_width(f32::INFINITY))
            .labelled_by(pw_label.id);
        small(ui, "Your password is used once, for this sign-in, and never stored.");
        ui.add_space(16.0);
        let ready = !self.apple_id.trim().is_empty() && !self.password.is_empty();
        let enter = pw.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if (self.main_button(ui, "Install", ready) || (enter && ready))
            && let Some(Question::SignIn(reply)) = s.question.take()
        {
            let password = Zeroizing::new(std::mem::take(&mut *self.password));
            forget_typing(ui.ctx());
            // No pair-again here: a record the device refuses, the app deletes itself (apps/client/spjit.m), and
            // the next run sends a new one. slashplayed-cli keeps --pair-again for the rare rest.
            let sign_in = SignIn { apple_id: self.apple_id.trim().to_string(), pair_again: false };
            let _ = reply.send((sign_in, password));
        }
    }

    fn two_factor(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Question::TwoFactor { sms, retry, unknown, numbers, .. }) = &s.question else { return };
        let (sms, retry, unknown, numbers) = (*sms, *retry, *unknown, numbers.clone());
        self.header(ui, "Enter the code");
        if retry {
            ui.label(RichText::new("That didn't work. Try again, or get a code another way.").color(ERROR));
        }
        let mut answer = None;
        if unknown {
            // The last way failed and Apple says nothing of where a code went: a code can't be sent, nor
            // resent, only asked for again (isideload's NeedsUnknown2FA).
            ui.label("Get a new code: on your Apple devices, or by text.");
            ui.add_space(12.0);
            ui.horizontal(|ui| {
                if ui.button("Send it to my Apple devices").clicked() {
                    answer = Some(TwoFactorCallbackResponse::SendToDevices);
                }
                if ui.button("Cancel").clicked() {
                    answer = Some(TwoFactorCallbackResponse::Abort);
                }
            });
            self.numbers(ui, &numbers, &mut answer);
            self.answer_code(&ui.ctx().clone(), s, answer);
            return;
        }
        ui.label(if sms {
            "Apple texted a code to your phone."
        } else {
            "Apple sent a code to your Apple devices: allow the sign-in on one of them to see it."
        });
        ui.add_space(8.0);
        let label = ui.label(if sms { "Code from the text message" } else { "Code from your Apple device" });
        let field = ui
.add(TextEdit::singleline(&mut self.code).id(code_id()).char_limit(6).desired_width(140.0).font(egui::TextStyle::Heading))
            .labelled_by(label.id);
        self.code.retain(|c| c.is_ascii_digit());
        ui.add_space(12.0);
        let ready = self.code.len() == 6;
        let enter = field.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if self.main_button(ui, "Continue", ready) || (enter && ready) {
            answer = Some(TwoFactorCallbackResponse::SubmitCode(self.code.clone()));
        }
        ui.add_space(16.0);
        ui.horizontal(|ui| {
            if !numbers.is_empty() && ui.button("Text me instead").clicked() {
                self.show_numbers = !self.show_numbers;
            }
            if sms && ui.button("Send it to my Apple devices").clicked() {
                answer = Some(TwoFactorCallbackResponse::SendToDevices);
            }
            if ui.button("Resend").clicked() {
                answer = Some(TwoFactorCallbackResponse::ResendCode);
            }
            if ui.button("Cancel").clicked() {
                answer = Some(TwoFactorCallbackResponse::Abort);
            }
        });
        if self.show_numbers {
            self.numbers(ui, &numbers, &mut answer);
        }
        self.answer_code(&ui.ctx().clone(), s, answer);
    }

    fn numbers(&mut self, ui: &mut egui::Ui, numbers: &[(u32, String)], answer: &mut Option<TwoFactorCallbackResponse>) {
        if numbers.is_empty() {
            return;
        }
        ui.add_space(8.0);
        ui.label("Text a code to:");
        for (id, number) in numbers {
            // Apple sends them masked; they're shown only here, on the person's own screen.
            if ui.button(format!("Text {number}")).clicked() {
                *answer = Some(TwoFactorCallbackResponse::SendSms(*id));
            }
        }
    }

    fn answer_code(&mut self, ctx: &egui::Context, s: &mut Shared, answer: Option<TwoFactorCallbackResponse>) {
        if let Some(a) = answer
            && let Some(Question::TwoFactor { reply, .. }) = s.question.take()
        {
            self.code.zeroize();
            forget_typing(ctx);
            self.show_numbers = false;
            let _ = reply.send(a);
        }
    }

    fn team(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Question::Team { teams, .. }) = &s.question else { return };
        let teams = teams.clone();
        self.header(ui, "Pick a team");
        ui.label("This Apple ID has several teams. Which one should sign Slashplayed?");
        ui.add_space(8.0);
        for (i, (name, id)) in teams.iter().enumerate() {
            ui.radio_value(&mut self.team_choice, Some(i), format!("{name} ({id})"));
        }
        ui.add_space(16.0);
        if self.main_button(ui, "Continue", self.team_choice.is_some())
            && let (Some(i), Some(Question::Team { reply, .. })) = (self.team_choice, s.question.take())
        {
            let _ = reply.send(i);
        }
    }

    /// The six steps as a checklist: done, the current one (with its wait, its progress, or its error), and
    /// those to come; and the Details below.
    fn steps(&mut self, ui: &mut egui::Ui, s: &mut Shared, title: &str) {
        self.header(ui, title);
        let error = s.outcome.as_ref().and_then(|o| o.as_ref().err().cloned());
        let current = s.step.unwrap_or(Step::Kit);
        for (step, label) in STEPS {
            ui.horizontal(|ui| {
                ui.set_min_height(24.0);
                if step < current || s.outcome.as_ref().is_some_and(|o| o.is_ok()) {
                    mark(ui, Mark::Done);
                    ui.label(label);
                } else if step == current {
                    if error.is_some() {
                        mark(ui, Mark::Failed);
                    } else {
                        ui.spinner();
                    }
                    ui.label(RichText::new(label).strong());
                } else {
                    mark(ui, Mark::ToCome);
                    ui.label(RichText::new(label).color(DIM));
                }
            });
            if step == current {
                ui.indent(label, |ui| {
                    if let Some(e) = &error {
                        ui.label(RichText::new(capitalized(e)).color(ERROR));
                    } else if let Some(w) = &s.wait {
                        note(ui, &w.text());
                    } else if step == Step::Install
                        && let Some(p) = s.progress
                    {
                        ui.add(egui::ProgressBar::new(p as f32 / 100.0).show_percentage().fill(GOLD.linear_multiply(0.8)));
                    } else if step == Step::Install && s.lines.last().is_some_and(|l| l.starts_with("installing on")) {
                        // The copy to the device reports nothing (idevice's upload has no progress), and on a
                        // phone it takes a minute or so: say it's going, until the install's percentages come.
                        small(ui, "Copying the app to the device. This can take a minute or two.");
                    }
                });
            }
        }
        if error.is_some() {
            ui.add_space(16.0);
            ui.horizontal(|ui| {
                if self.main_button(ui, "Try Again", true) {
                    ui.ctx().data_mut(|d| d.insert_temp(retry_id(), true));
                }
                if ui.button("Copy Details").clicked() {
                    ui.ctx().copy_text(s.details());
                }
            });
        }
        ui.add_space(12.0);
        details(ui, s);
    }

    fn done(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Ok(done)) = &s.outcome else { return };
        let lines = done.lines();
        self.header(ui, "All set");
        for (i, line) in lines.iter().enumerate() {
            if i == 0 {
                ui.label(RichText::new(line).size(18.0));
            } else {
                ui.label(line);
            }
            ui.add_space(4.0);
        }
        ui.add_space(16.0);
        if self.main_button(ui, "Done", true) {
            ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
        }
        ui.add_space(12.0);
        details(ui, s);
    }

    /// At the team's certificate limit: Revoke the oldest of Slashplayed's, or Cancel and revoke nothing.
    fn revoke(&mut self, ctx: &egui::Context, s: &mut Shared) {
        let Some(Question::Revoke { certificates, oldest, .. }) = &s.question else { return };
        let (certificates, oldest) = (certificates.clone(), oldest.clone());
        let mut answer = None;
        egui::Modal::new(egui::Id::unique("sp-revoke")).show(ctx, |ui| {
            ui.set_width(440.0);
            ui.label(RichText::new("The team has all its certificates").family(theme::family(self.face)).size(22.0).color(GOLD));
            ui.add_space(8.0);
            ui.label(format!(
                "Apple allows only so many development certificates, and the team has them all: {certificates}. This computer has no credential store to keep a signing key in, so it can't reuse one."
            ));
            ui.add_space(4.0);
            ui.label(format!(
                "Slashplayed can revoke {oldest}, the oldest one a Slashplayed tool made, on this or another computer. A device signed with it needs its own run again before Slashplayed opens there."
            ));
            ui.add_space(12.0);
            ui.horizontal(|ui| {
                if self.main_button(ui, "Revoke", true) {
                    answer = Some(true);
                }
                if ui.button("Cancel").clicked() {
                    answer = Some(false);
                }
            });
        });
        if let Some(a) = answer
            && let Some(Question::Revoke { reply, .. }) = s.question.take()
        {
            let _ = reply.send(a);
        }
    }

    fn forget_dialog(&mut self, ctx: &egui::Context) {
        let Some((id, said)) = &mut self.forget else { return };
        if self.forgetting.as_ref().is_some_and(|h| h.is_finished()) {
            let h = self.forgetting.take().unwrap();
            *said = Some(h.join().unwrap_or_else(|_| "Couldn't reach the credential store.".into()));
        }
        let busy = self.forgetting.is_some();
        let mut close = false;
        egui::Modal::new(egui::Id::unique("sp-forget")).show(ctx, |ui| {
            ui.set_width(400.0);
            ui.label(RichText::new("Forget the signing key").family(theme::family(self.face)).size(22.0).color(GOLD));
            ui.add_space(8.0);
            ui.label("This computer keeps a signing key for each Apple ID, so it can reuse its certificate. Forgetting it makes the next run make a new certificate.");
            ui.add_space(8.0);
            let label = ui.label("Apple ID");
            ui.add(TextEdit::singleline(id).desired_width(f32::INFINITY)).labelled_by(label.id);
            if let Some(said) = said.as_ref() {
                ui.label(said);
            }
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                if ui.add_enabled(!busy && !id.trim().is_empty(), Button::new("Forget")).clicked() {
                    let (id, ctx) = (id.trim().to_string(), ui.ctx().clone());
                    self.forgetting = Some(std::thread::spawn(move || {
                        let said = match crate::keystore::forget(&id) {
                            Ok(true) => "Deleted this computer's signing key for that Apple ID.".into(),
                            Ok(false) => "This computer has no signing key for that Apple ID.".into(),
                            Err(e) => capitalized(&crate::secret::safe_error(&e)),
                        };
                        ctx.request_repaint();
                        said
                    }));
                }
                if busy {
                    ui.spinner();
                }
                if ui.button("Close").clicked() {
                    close = true;
                }
            });
        });
        if close {
            self.forget = None;
        }
    }
}

fn details(ui: &mut egui::Ui, s: &Shared) {
    egui::CollapsingHeader::new("Details").default_open(false).show(ui, |ui| {
        egui::ScrollArea::vertical().max_height(160.0).stick_to_bottom(true).show(ui, |ui| {
            for l in &s.lines {
                ui.label(RichText::new(l).small().color(DIM));
            }
        });
    });
}

/// The library's errors start in lower case, to follow "slashplayed-cli: "; a screen starts a sentence.
fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => String::new(),
    }
}

/// Runs the window, with the real device and Apple.
pub fn run() -> eframe::Result {
    let drill = std::env::var("SP_GUI_DRILL").ok();
    // A development build has no kit pinned (build.rs): this names one, as slashplayed-cli's --kit does. A
    // release build uses only its pinned kit, whatever the environment says.
    let kit = std::env::var_os("SP_GUI_KIT").filter(|_| crate::kit::pinned_sha256().is_none()).map(std::path::PathBuf::from);
    let starter = front::starter(crate::live::Live::new, kit);
    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../../icons/slashplayed.png")).expect("the window's icon");
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Slashplayed Companion")
            // Wayland has no window icons: the compositor matches this to a desktop entry, if there's one.
            .with_app_id("slashplayed-companion")
            .with_inner_size(SIZE)
            .with_resizable(false)
            .with_maximize_button(false)
            .with_icon(Arc::new(icon)),
        ..Default::default()
    };
    eframe::run_native(
        "Slashplayed Companion",
        options,
        Box::new(move |cc| Ok(Box::new(App::new(&cc.egui_ctx, starter, drill.as_deref())))),
    )
}
