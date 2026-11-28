// The window driven through its accessibility tree (egui_kittest; no image snapshots, which differ by
// font and driver), with flow.rs's whole run behind it on the fake device and Apple ID (flow::fake): what
// the person sees, and what their clicks send.

use std::time::{Duration, Instant};

use egui_kittest::{
    Harness,
    kittest::Queryable,
};

use super::{App, SIZE, front};
use crate::flow::fake::{Fake, password, team};

/// A window whose runs go to `fake` (a fresh copy each run, sharing its log).
fn window(fake: impl Fn() -> Fake + Send + Sync + 'static) -> Harness<'static, App> {
    let starter = front::starter(move || Ok(fake()), None);
    Harness::builder().with_size(SIZE).build_eframe(move |cc| App::new(&cc.egui_ctx, starter, None))
}

/// Steps the window until `label` shows (the run is on its own thread), failing after a while.
fn wait_for(h: &mut Harness<'_, App>, label: &str) {
    let start = Instant::now();
    loop {
        h.step();
        if h.query_by_label_contains(label).is_some() {
            return;
        }
        if start.elapsed() > Duration::from_secs(10) {
            panic!("no {label:?} on the screen; the tree:\n{:#?}", h.root());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Types into the text field `label` names (its label is a node too, so by role).
fn type_into(h: &mut Harness<'_, App>, label: &str, text: &str) {
    use eframe::egui::accesskit::Role;
    let field = |n: &egui_kittest::kittest::AccessKitNode<'_>| {
        matches!(n.role(), Role::TextInput | Role::PasswordInput) && n.label().is_some_and(|l| l == label)
    };
    h.get_by(field).focus();
    h.run_steps(2);
    h.get_by(field).type_text(text);
    h.run_steps(2);
}

fn sign_in(h: &mut Harness<'_, App>) {
    sign_in_with(h, &password());
}

fn sign_in_with(h: &mut Harness<'_, App>, password: &str) {
    wait_for(h, "Sign in with your Apple ID");
    type_into(h, "Apple ID", "x@example.com");
    type_into(h, "Password", password);
    h.get_by_label("Install").click();
}

/// The text field `label` names: what it holds, as the accessibility tree has it.
fn field_value(h: &Harness<'_, App>, label: &str) -> String {
    use eframe::egui::accesskit::Role;
    let n = h.get_by(|n| matches!(n.role(), Role::TextInput | Role::PasswordInput) && n.label().is_some_and(|l| l == label));
    n.value().unwrap_or_default()
}

/// The password, once sent, isn't kept anywhere Ctrl+Z can bring it back from (egui's undo history).
#[test]
fn undo_doesnt_bring_the_password_back() {
    let mut h = window(|| Fake { two_factor: false, ..Default::default() });
    wait_for(&mut h, "Sign in with your Apple ID");
    type_into(&mut h, "Apple ID", "x@example.com");
    type_into(&mut h, "Password", "wrong-one");
    // egui's undo keeps text that has stood still a while (a second), as a person's pause before Install.
    for _ in 0..90 {
        h.step();
    }
    h.get_by_label("Install").click();
    wait_for(&mut h, "Apple didn't accept the sign-in");
    h.get_by_label("Try Again").click();
    wait_for(&mut h, "Sign in with your Apple ID");
    h.get_by(|n| n.role() == eframe::egui::accesskit::Role::PasswordInput).focus();
    h.run_steps(2);
    h.key_press_modifiers(eframe::egui::Modifiers::COMMAND, eframe::egui::Key::Z);
    h.run_steps(2);
    assert!(field_value(&h, "Password").is_empty(), "the password came back with Ctrl+Z");
}

/// A wrong code says so, and the next one goes through.
#[test]
fn a_wrong_code_says_so() {
    let mut h = window(|| Fake { wrong_code: true, ..Default::default() });
    sign_in(&mut h);
    wait_for(&mut h, "Code from your Apple device");
    assert!(h.query_by_label_contains("That didn't work").is_none());
    type_into(&mut h, "Code from your Apple device", "111111");
    h.get_by_label("Continue").click();
    wait_for(&mut h, "That didn't work");
    type_into(&mut h, "Code from your Apple device", "123456");
    h.get_by_label("Continue").click();
    wait_for(&mut h, "All set");
}

#[test]
fn text_me_instead() {
    let log = Fake::default().calls;
    let shared = log.clone();
    let mut h = window(move || Fake { calls: shared.clone(), ..Default::default() });
    sign_in(&mut h);
    wait_for(&mut h, "Code from your Apple device");
    assert!(h.query_by_label_contains("Text +1").is_none(), "the numbers stay folded away until asked for");
    h.get_by_label("Text me instead").click();
    h.run_steps(2);
    h.get_by_label("Text +1 (•••) •••-••12").click();
    wait_for(&mut h, "Code from the text message");
    type_into(&mut h, "Code from the text message", "123456");
    h.get_by_label("Continue").click();
    wait_for(&mut h, "All set");
    let calls = log.lock().unwrap().clone();
    assert!(calls.contains(&"sms 3".to_string()), "{calls:?}");
    assert!(calls.contains(&"code 123456 sms=true".to_string()), "{calls:?}");
}

#[test]
fn team_screen_only_with_several_teams() {
    // One team: from the sign-in straight to the end, never the team screen.
    let mut h = window(|| Fake { two_factor: false, ..Default::default() });
    sign_in(&mut h);
    let start = Instant::now();
    while h.query_by_label_contains("All set").is_none() {
        assert!(h.query_by_label_contains("Pick a team").is_none(), "one team, and the team screen showed");
        assert!(start.elapsed() < Duration::from_secs(10), "never finished");
        h.step();
        std::thread::sleep(Duration::from_millis(2));
    }

    let log = Fake::default().calls;
    let shared = log.clone();
    let mut h = window(move || Fake {
        two_factor: false,
        teams: vec![team("T1"), team("T2")],
        calls: shared.clone(),
        ..Default::default()
    });
    sign_in(&mut h);
    wait_for(&mut h, "Pick a team");
    h.get_by_label("Team T2 (T2)").click();
    h.run_steps(2);
    h.get_by_label("Continue").click();
    wait_for(&mut h, "All set");
    assert!(log.lock().unwrap().contains(&"provision T2 T2.slashplayed".to_string()));
}

#[test]
fn certificate_limit_cancel_or_revoke() {
    for (button, revoked) in [("Cancel", false), ("Revoke", true)] {
        let log = Fake::default().calls;
        let shared = log.clone();
        let mut h = window(move || Fake { two_factor: false, cert_limit: true, calls: shared.clone(), ..Default::default() });
        sign_in(&mut h);
        wait_for(&mut h, "The team has all its certificates");
        h.get_by_label(button).click();
        if revoked {
            wait_for(&mut h, "All set");
        } else {
            wait_for(&mut h, "Nothing was revoked");
            assert!(h.query_by_label("Try Again").is_some());
            assert!(h.query_by_label("Copy Details").is_some());
        }
        assert_eq!(log.lock().unwrap().contains(&"revoked".to_string()), revoked, "{button}");
    }
}

/// Pair Only, offered once the app is on the device: no Apple ID, no password, nothing signed.
#[test]
fn pair_only_needs_no_apple_id() {
    let log = Fake::default().calls;
    let shared = log.clone();
    let mut h = window(move || Fake { installed: vec!["T1.slashplayed".into()], calls: shared.clone(), ..Default::default() });
    wait_for(&mut h, "Pair Only");
    // A password typed before choosing Pair Only isn't kept: nothing signs in to use it.
    type_into(&mut h, "Password", &password());
    assert!(!h.state().password.is_empty());
    h.get_by_label("Pair Only").click();
    h.run_steps(1);
    assert!(h.state().password.is_empty(), "the password outlived Pair Only");
    wait_for(&mut h, "has a new pairing record");
    let calls = log.lock().unwrap().clone();
    assert!(calls.contains(&"pairing".to_string()), "{calls:?}");
    assert!(!calls.iter().any(|c| c.starts_with("anisette") || c.starts_with("provision")), "{calls:?}");

    // A fresh device: there's nothing to pair, so it isn't offered.
    let mut h = window(Fake::default);
    wait_for(&mut h, "Sign in with your Apple ID");
    assert!(h.query_by_label("Pair Only").is_none());

    // There twice: not offered, and the window says why.
    let mut h = window(|| Fake { installed: vec!["T1.slashplayed".into(), "T2.slashplayed".into()], ..Default::default() });
    wait_for(&mut h, "Sign in with your Apple ID");
    assert!(h.query_by_label("Pair Only").is_none());
    assert!(h.query_by_label_contains("--pair-again --bundle-id").is_some(), "no word of why there's no Pair Only");
}

/// The anisette server typed in the window is the one the sign-in uses.
#[test]
fn the_anisette_server_can_be_changed() {
    let log = Fake::default().calls;
    let shared = log.clone();
    let mut h = window(move || Fake { two_factor: false, calls: shared.clone(), ..Default::default() });
    wait_for(&mut h, "Sign in with your Apple ID");
    h.get_by_label("Anisette server").click();
    h.run_steps(2);
    use eframe::egui::{Key, accesskit::Role};
    let server = |n: &egui_kittest::kittest::AccessKitNode<'_>| n.role() == Role::TextInput && n.label().is_some_and(|l| l == "Server address");
    assert_eq!(field_value(&h, "Server address"), crate::account::DEFAULT_ANISETTE);
    h.get_by(server).focus();
    h.run_steps(2);
    // Emptied from wherever the cursor landed.
    for _ in 0..40 {
        h.key_press(Key::Backspace);
        h.key_press(Key::Delete);
    }
    h.run_steps(2);
    h.get_by(server).type_text("https://ani.example.org");
    h.run_steps(2);
    assert_eq!(field_value(&h, "Server address"), "https://ani.example.org");
    type_into(&mut h, "Apple ID", "x@example.com");
    type_into(&mut h, "Password", &password());
    h.get_by_label("Install").click();
    wait_for(&mut h, "All set");
    let calls = log.lock().unwrap().clone();
    assert!(calls.contains(&"anisette https://ani.example.org".to_string()), "{calls:?}");
}

#[test]
fn every_drill_state_opens() {
    for state in super::drill::STATES {
        let starter: front::Starter = std::sync::Arc::new(|_, _| panic!("a drill starts no run"));
        let mut h = Harness::builder().with_size(SIZE).build_eframe(move |cc| App::new(&cc.egui_ctx, starter, Some(state)));
        h.run_steps(3);
        assert!(h.query_by_label("…").is_some(), "{state}: no menu");
        let title = match *state {
            "device" | "unlock" | "developer-mode" => "Connect your device",
            "sign-in" | "sign-in-installed" | "sign-in-twice" => "Sign in with your Apple ID",
            "code" => "Enter the code",
            "team" => "Pick a team",
            "installing" | "cert-limit" => "Installing",
            "done" | "paired" => "All set",
            "error" => "Something went wrong",
            other => panic!("no title for the drill state {other}"),
        };
        assert!(h.query_by_label(title).is_some(), "{state}: not the {title:?} screen");
        assert_eq!(h.query_by_label("Pair Only").is_some(), *state == "sign-in-installed", "{state}: Pair Only");
    }
}
