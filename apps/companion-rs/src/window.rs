// slashplayed-companion: the window that sets up Slashplayed on an iPad or iPhone from Windows or Linux
// (src/gui; docs/setup-without-a-mac.md). slashplayed-cli does the same from a terminal.
//
// No console on Windows: opened from Explorer, a console program would open a terminal window behind it.
#![windows_subsystem = "windows"]

fn main() -> std::process::ExitCode {
    slashplayed_companion::init();
    // An OpenGL context that won't start (a VM, Remote Desktop, the Basic Display Adapter), or a panic in
    // the window: said where the person can see it, as a console program would in its terminal.
    let said = match std::panic::catch_unwind(slashplayed_companion::gui::run) {
        Ok(Ok(())) => return std::process::ExitCode::SUCCESS,
        Ok(Err(e)) => format!("The window couldn't open: {e}"),
        Err(_) => "The window stopped unexpectedly.".to_string(),
    };
    fatal(&said);
    std::process::ExitCode::FAILURE
}

#[cfg(windows)]
fn fatal(text: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
    let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<u16>>();
    let (text, title) = (wide(text), wide("Slashplayed Companion"));
    // SAFETY: both are NUL-terminated UTF-16, alive for the call; no owner window.
    unsafe { MessageBoxW(std::ptr::null_mut(), text.as_ptr(), title.as_ptr(), MB_OK | MB_ICONERROR) };
}

#[cfg(not(windows))]
fn fatal(text: &str) {
    eprintln!("slashplayed-companion: {text}");
}
