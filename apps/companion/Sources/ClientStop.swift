import Foundation

/// What Play says when the client quits on its own, without Stop Client (Pipeline.launchSteps, "The client
/// stopped"), from what ClientLauncher saw on the console: the exit code, and the last alert the client
/// asked for. The client shows its error in an alert before it quits, and the device has no alert server for
/// apps, so the AppKit shim only logs it (shims/appkit/spnotice.m) and nobody saw it: a first stream's
/// "ERROR #137 (0x85100089) File I/O error." read only "It quit with exit code 1" (the rc9 run).
enum ClientStop {
    /// The message in the AppKit shim's line for an alert: `CFUserNotificationCreate: "<title>" /
    /// "<message>" (no alert server here: …)`. nil for any other line, or an alert with no message.
    static func alert(in line: String) -> String? {
        guard let m = line.firstMatch(of: try! Regex(#"CFUserNotificationCreate: ".*?" / "(.*)" \(no alert server"#,
                                                     as: (Substring, Substring).self))
        else { return nil }
        let message = m.1.trimmingCharacters(in: .whitespaces)
        return message.isEmpty || message == "(null)" ? nil : message
    }

    /// The step's detail, the action first. A file error went away on the next Play in the rc9 run (it came
    /// while the game streamed its data), so it says to press Play again.
    static func message(code: Int, alert: String?) -> String {
        let log = "The log has its last messages (~/Library/Logs/Slashplayed/console.txt)."
        guard let alert else { return "It quit with exit code \(code). \(log)" }
        if alert.localizedCaseInsensitiveContains("File I/O") {
            return "Press Play to try again. The game stopped on a file error (“\(alert)”), which can happen while it streams its data; the next start usually works. If it keeps happening, check the device's free space. \(log)"
        }
        return "The game said “\(alert)” and quit (exit code \(code)). \(log)"
    }
}
