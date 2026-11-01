import Foundation

/// An onboarding step's outcome (Onboarding.Status), on its own so the tests can compile it without the
/// app's views and Pipeline.
enum SetupStatus: Equatable {
    case checking
    case ok(String)
    /// What's wrong (a title) and how to fix it.
    case problem(String, String)

    var isOK: Bool { if case .ok = self { true } else { false } }

    /// The companion.txt line for this outcome of the step titled `step`, or nil when nothing changed: the
    /// step on screen is checked every 3 s, so only a new outcome is logged (the first one, a fix, a new
    /// problem). Without these a user stuck in setup leaves no trace in Export Diagnostics.
    func logLine(_ step: String, was: SetupStatus?) -> String? {
        guard self != was else { return nil }
        switch self {
        case .checking: return nil
        case .ok(let message): return "[setup] \(step): ok — \(message)"
        case .problem(let title, let fix): return "[setup] \(step): \(title) — \(fix.replacingOccurrences(of: "\n", with: " / "))"
        }
    }

    /// The install step's outcome from each usable device's name and what it holds (ClientBuild.installNeed):
    /// it passes once one is up to date, since that one can be played on and the rest installed later.
    static func firstInstall(_ devices: [(name: String, need: ClientBuild.InstallNeed)]) -> SetupStatus {
        let done = devices.filter { $0.need == .upToDate }.map(\.name)
        guard done.isEmpty else { return .ok("Slashplayed is on \(list(done)).") }
        let stale = devices.filter { installState($0.need, wake: nil).button == "Update" }.map(\.name)
        guard stale.isEmpty else {
            return .problem("Slashplayed on \(list(stale)) needs an update", "Press Update for the device you'll play on.")
        }
        return .problem("Slashplayed isn't on a device yet", "Press Install for the device you'll play on.")
    }

    /// The main window's heading with nothing running (Headline). Once Slashplayed is on the device it
    /// starts from there, and Play here builds and installs first; with it deleted there (rc19's run: the
    /// heading still said to open it), Play is the only way back.
    static func idleHeading(noun: String, appMissing: Bool) -> (title: String, detail: String) {
        appMissing
            ? ("Press Play to install Slashplayed on the \(noun)",
               "Slashplayed isn't on the \(noun): it was deleted there, or never installed. Play builds it, installs it, and starts the game.")
            : ("Open Slashplayed on the \(noun) to play",
               "Or press Play here: it updates the app on the \(noun) first, after a patch or a change of games, and then starts the game.")
    }

    /// The install step's line for a device (ClientBuild.installNeed with the device asked) and its button
    /// (nil once it's up to date). "Not installed" only when it isn't there: rc7's run showed it for an iPad
    /// that had Slashplayed, an older build of the one the iPad and the iPhone share. One this Mac didn't
    /// install may be another Mac's or not there at all (an unreachable device can't say), so it's worded
    /// to be true either way. `wake` is what makes an unreachable device answer ("Connect it with USB").
    static func installState(_ need: ClientBuild.InstallNeed, wake: String?) -> (text: String, button: String?) {
        let text: String, button: String?
        switch need {
        case .upToDate: return ("Installed", nil)
        case .notOnDevice: (text, button) = ("Not installed", "Install")
        case .notFromThisMac: (text, button) = ("Not installed from this Mac", "Install")
        case .olderBuild: (text, button) = ("Installed, needs an update", "Update")
        case .otherGames: (text, button) = ("Installed, needs an update for the games you chose", "Update")
        case .replaced: (text, button) = ("Installed from another Mac or Xcode, needs an update", "Update")
        }
        return (wake.map { "\(text). \($0)" } ?? text, button)
    }

    /// The reason in companion.txt, so a device's state in the install step can be traced.
    static func logName(_ need: ClientBuild.InstallNeed) -> String {
        switch need {
        case .upToDate: "up to date"
        case .notOnDevice: "not on the device"
        case .notFromThisMac: "not installed from this Mac"
        case .olderBuild: "an earlier build"
        case .otherGames: "other games"
        case .replaced: "installed again elsewhere"
        }
    }

    /// "1 file", "2 files": a count and its noun, plural unless it's one. Every "N <things>" the companion
    /// shows or logs goes through this, so a delta copy doesn't read "1 files".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(n == 1 ? noun : noun + "s")"
    }

    /// "a", "a and b", "a, b, and c" (the serial comma), or with "or".
    static func list(_ names: [String], or: Bool = false) -> String {
        let and = or ? "or" : "and"
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) \(and) \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", \(and) " + names.last!
        }
    }
}
