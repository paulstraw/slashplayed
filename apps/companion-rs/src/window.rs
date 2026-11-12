// slashplayed-companion: the window that sets up Slashplayed on an iPad or iPhone from Windows or Linux
// (src/gui; docs/setup-without-a-mac.md). slashplayed-cli does the same from a terminal.
//
// No console on Windows: opened from Explorer, a console program would open a terminal window behind it.
#![windows_subsystem = "windows"]

fn main() -> eframe::Result {
    slashplayed_companion::init();
    slashplayed_companion::gui::run()
}
