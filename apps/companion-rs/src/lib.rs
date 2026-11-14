// The host tool's library: everything one install does (flow.rs, with live.rs's device and Apple), for the
// two programs that run it: the window (gui/, window.rs) and the command line (main.rs). How it works: docs/internals/host-tool.md.

pub mod account;
pub mod ddi;
pub mod device;
pub mod flow;
pub mod gui;
pub mod keystore;
pub mod kit;
pub mod live;
pub mod profile;
pub mod provision;
pub mod secret;
pub mod sign;

/// What every program does before anything else, before any thread exists: isideload reads
/// DEBUG_SENSITIVE to put sensitive plists and the full email into its errors, so it's cleared. No tracing
/// subscriber is ever installed, so nothing isideload logs goes anywhere. Then rustls's provider (reqwest is
/// built with rustls-no-provider) and isideload.
pub fn init() {
    // SAFETY: called first in main, while the process has one thread.
    unsafe { std::env::remove_var("DEBUG_SENSITIVE") };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
}
