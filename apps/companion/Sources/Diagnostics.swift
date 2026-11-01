import Foundation

/// Help > Export Diagnostics: one zip to attach to a bug report, in ~/Library/Logs/Slashplayed/diagnostics/.
/// It holds
///   - companion/: the companion's own logs (companion.txt, build.txt, console*.txt), the top
///     of ~/Library/Logs/Slashplayed;
///   - device/: from what Pull Device Logs fetches (DeviceLogs), when the device is reachable: the shims'
///     spconsole*.log, the system's crash, jetsam and resource reports, and its summary.txt. Not the
///     client's own Logs and Errors folders, which can hold account details (Pull Device Logs keeps them
///     on this Mac);
///   - versions.txt: the companion, macOS, Xcode, the device's model and OS, each game's version and build;
///   - summary.txt: the window's steps when it was exported (what failed, and the message), and what was
///     left out or redacted.
/// Nothing from Battle.net's login reaches the zip. The net.battle prefs (the launch token among them) are
/// read only here, in memory, to blank out every value of theirs found in any file (some can turn up in
/// the logs); the values themselves are never written, logged or shown, only how many were blanked.
/// Files from the token export (TokenRelay) and anything named like it are left out altogether.
/// Device identifiers are blanked too, since the zip is meant for a public issue: every UDID, CoreDevice
/// identifier, serial number and ECID devicectl lists (build.txt names the device it provisions for), any
/// other UDID-shaped string, and the crash reports' crashReporterKey and deviceIdentifierForVendor.
/// So are personal details, for the same reason: the user's full name, the signing certificates' names
/// and IDs ("Apple Development: <name> (<ID>)"), Xcode's teams (IDs and names, a Personal Team's being the
/// user's name) and Apple IDs, the devices' names ("<name>'s iPhone"), this Mac's names, and the user folder
/// in /Users paths (personalDetails(…), redactPersonal).
/// Hidden files (Finder's .DS_Store) are left out.
enum Diagnostics {
    /// What a found value is replaced with.
    static let marker = Data("[redacted]".utf8)
    /// What a device identifier is replaced with.
    static let deviceMarker = Data("[device id]".utf8)
    /// Shorter values (flags, "1", "enUS") aren't secrets, and blanking them would garble every log.
    static let minLength = 8
    /// Names are shorter than secrets ("Jo Li"), but under this they'd blank common words.
    static let minNameLength = 5

    /// A personal detail to blank, and what it's blanked with ("[team id]", "[device name]", …).
    struct Detail: Hashable {
        var value: Data
        var marker: Data
        init(_ value: String, _ marker: String) {
            self.value = Data(value.utf8)
            self.marker = Data("[\(marker)]".utf8)
        }
    }

    struct Exported {
        var zip: URL
        /// Files left out (the token export's), and how many values were blanked.
        var excluded: [String] = []
        var redactions = 0
        var deviceRedactions = 0
        var personalRedactions = 0
    }

    /// Everything export needs, gathered by the app (gather) or made up by a test.
    struct Input {
        /// The companion's log directory: its top-level files go in companion/.
        var logs: URL
        /// The DeviceLogs folder pulled for this export, if the device was reachable.
        var deviceLogs: URL?
        var versions: String
        var summary: String
        /// Byte strings that must not appear in the zip (secrets(in:) of the net.battle prefs).
        var secrets: [Data]
        /// The device identifiers to blank (deviceIdentifiers(in:devices:)); patterns catch others.
        var deviceIDs: [Data] = []
        /// The personal details to blank (personalDetails(…)); patterns catch certificate names and /Users paths.
        var personal: [Detail] = []
        /// Folders (and files) left out wherever they turn up: the token export's.
        var excluded: [URL]
        /// Where the zip goes.
        var output: URL
    }

    /// Writes the zip: copies each file into a staging folder with the secrets blanked, then has ditto zip
    /// it. Never copies a file it hasn't redacted.
    static func export(_ input: Input) throws -> Exported {
        let fm = FileManager.default
        let name = input.output.deletingPathExtension().lastPathComponent
        let staging = fm.temporaryDirectory.appending(path: "sp-diagnostics-\(UUID().uuidString)")
        let root = staging.appending(path: name)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Longest first, so a secret that holds a shorter one is blanked whole.
        let secrets = Set(input.secrets.filter { $0.count >= minLength }).sorted { $0.count > $1.count }
        let deviceIDs = Set(input.deviceIDs.filter { $0.count >= minLength }).sorted { $0.count > $1.count }
        let personal = Set(input.personal.filter { $0.value.count >= minNameLength }).sorted { $0.value.count > $1.value.count }
        var exported = Exported(zip: input.output)

        /// Battle.net's values first, then the devices', then the personal details (a device name can hold
        /// the user's name, so it goes before the name alone: longest first).
        func clean(_ data: Data) -> Data {
            let (out, n) = redact(data, secrets)
            let (ids, m) = redactDeviceIDs(out, deviceIDs)
            let (clean, k) = redactPersonal(ids, personal)
            exported.redactions += n
            exported.deviceRedactions += m
            exported.personalRedactions += k
            return clean
        }

        func add(_ source: URL, as path: String) throws {
            if isExcluded(source, input.excluded) {
                exported.excluded.append(path)
                return
            }
            let data = clean(try Data(contentsOf: source))
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        // Only the log directory's own files: triage/ and diagnostics/ hold earlier pulls and exports.
        for (url, path) in regularFiles(in: input.logs, recursive: false) where !isHidden(path) {
            try add(url, as: "companion/\(path)")
        }
        if let device = input.deviceLogs {
            for (url, path) in regularFiles(in: device, recursive: true) where isDeviceFileIncluded(path) && !isHidden(path) {
                try add(url, as: "device/\(path)")
            }
        }

        try clean(Data((input.versions + "\n").utf8)).write(to: root.appending(path: "versions.txt"))
        var summary = input.summary
        // Counted before the summary's own redaction, which finds none: it's made from what's above.
        summary += "\n\n" + redactedLine(exported)
        if input.deviceLogs != nil {
            summary += "\nThe client's own Logs and Errors folders aren't included (they can hold account details); Pull Device Logs saves them in ~/Library/Logs/Slashplayed/triage/."
        }
        if !exported.excluded.isEmpty {
            summary += "\nLeft out (Battle.net login files): \(exported.excluded.joined(separator: ", "))"
        }
        let summaryData = redactPersonal(redactDeviceIDs(redact(Data((summary + "\n").utf8), secrets).0, deviceIDs).0, personal).0
        try summaryData.write(to: root.appending(path: "summary.txt"))

        try fm.createDirectory(at: input.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: input.output)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", root.path, input.output.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure("Zipping the diagnostics failed (ditto exited with status \(ditto.terminationStatus)).") }
        return exported
    }

    /// The summary's count of what was blanked.
    static func redactedLine(_ e: Exported) -> String {
        "Redacted \(SetupStatus.count(e.redactions, "Battle.net value")), \(SetupStatus.count(e.deviceRedactions, "device identifier")), " +
            "and \(SetupStatus.count(e.personalRedactions, "personal detail")) (names, team IDs, device and Mac names, and user folders)."
    }

    /// Which of a DeviceLogs pull's files (paths in its folder) go in the zip.
    static func isDeviceFileIncluded(_ path: String) -> Bool {
        path == "summary.txt" || path.hasPrefix("system/") ||
            path.wholeMatch(of: /app\/Documents\/spconsole[.0-9]*log/) != nil
    }

    /// A path (relative) with a hidden component, such as Finder's .DS_Store.
    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Replaces every occurrence of each secret with the marker, in text and binary files alike.
    static func redact(_ data: Data, _ secrets: [Data], with marker: Data = marker) -> (Data, Int) {
        var out = data
        var count = 0
        for secret in secrets {
            var from = out.startIndex
            while let r = out.range(of: secret, in: from..<out.endIndex) {
                out.replaceSubrange(r, with: marker)
                from = r.lowerBound + marker.count
                count += 1
            }
        }
        return (out, count)
    }

    /// A UDID as iOS and visionOS devices since 2018 have it (8 hex digits, a hyphen, 16 more), not inside a
    /// longer run of letters and digits. The older 40-hex and 36-character forms are too like hashes and
    /// UUIDs elsewhere in the logs to match by shape: those are caught as known values only.
    private static let udidPattern = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}(?![0-9A-Za-z])")
    /// The crash and jetsam reports' per-device keys (JSON), whose values are kept out.
    private static let reportKeyPattern = try! NSRegularExpression(
        pattern: #"("(?:crashReporterKey|deviceIdentifierForVendor)"\s*:\s*")[^"]+(")"#)

    /// Blanks the known device identifiers, then UDID-shaped strings and the reports' device keys.
    /// Binary files too: Latin-1 maps each byte to one character and back, so nothing else changes.
    static func redactDeviceIDs(_ data: Data, _ ids: [Data]) -> (Data, Int) {
        var (out, count) = redact(data, ids, with: deviceMarker)
        guard let text = String(data: out, encoding: .isoLatin1) else { return (out, count) }
        let mutable = NSMutableString(string: text)
        let marker = String(decoding: deviceMarker, as: UTF8.self)
        count += udidPattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: marker))
        count += reportKeyPattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length),
                                                 withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: marker) + "$2")
        if let data = (mutable as String).data(using: .isoLatin1) { out = data }
        return (out, count)
    }

    /// A signing certificate's name, "<kind>: <person or company> (<certificate or team ID>)", as codesign,
    /// security, and xcodebuild print it.
    private static let certificatePattern = try! NSRegularExpression(
        pattern: #"((?:Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution|Mac Developer|Developer ID Application|Developer ID Installer): )[^()"\r\n]+ \([A-Z0-9]{10}\)"#)
    /// A user folder in a path, plain or JSON-escaped (crash reports), but not /Users/Shared.
    private static let userFolderPattern = try! NSRegularExpression(
        pattern: #"(/Users/|\\/Users\\/)(?!Shared(?![^/\\\s"':)]))[^/\\\s"':)]+"#)

    /// Blanks certificate names and user folders by their shape, then the known details, longest first.
    /// Binary files too, through Latin-1 as redactDeviceIDs does.
    static func redactPersonal(_ data: Data, _ details: [Detail]) -> (Data, Int) {
        var out = data, count = 0
        if let text = String(data: out, encoding: .isoLatin1) {
            let mutable = NSMutableString(string: text)
            count += certificatePattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length),
                                                       withTemplate: "$1[name] ([certificate id])")
            count += userFolderPattern.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length),
                                                      withTemplate: "$1[user]")
            if let data = (mutable as String).data(using: .isoLatin1) { out = data }
        }
        for detail in details {
            let (redacted, n) = redact(out, [detail.value], with: detail.marker)
            out = redacted
            count += n
        }
        return (out, count)
    }

    /// The device names that say nothing about anyone: the ones a device has out of the box.
    static func isGenericDeviceName(_ name: String, marketingNames: Set<String>) -> Bool {
        name == Device.none.name || marketingNames.contains(name) || name.wholeMatch(of: /(iPhone|iPad|Apple Vision Pro)( \(\d+\))?/) != nil
    }

    /// The personal details to blank: the user's full name, Xcode's teams (IDs and names) and Apple IDs,
    /// every device's name (devicectl's list and the companion's own), and this Mac's names. Each name
    /// with a straight and a curly apostrophe, since devices write "’s" and people type "'s".
    static func personalDetails(fullName: String, teams: [Signing.Team], appleIDs: [String],
                                in list: [[String: Any]], devices: [Device], hosts: [String]) -> [Detail] {
        var found = [(fullName, "name")]
        for team in teams {
            found += [(team.id, "team id"), (team.name, "team")]
        }
        found += appleIDs.map { ($0, "apple id") }
        let marketing = Set(list.compactMap { ($0["hardwareProperties"] as? [String: Any])?["marketingName"] as? String })
        let names = list.compactMap { ($0["deviceProperties"] as? [String: Any])?["name"] as? String } + devices.map(\.name)
        found += names.filter { !isGenericDeviceName($0, marketingNames: marketing) }.map { ($0, "device name") }
        found += hosts.map { ($0, "mac name") }
        let details = found.flatMap { value, marker in
            [value, value.replacingOccurrences(of: "’", with: "'"), value.replacingOccurrences(of: "'", with: "’")]
                .map { Detail($0, marker) }
        }
        return Array(Set(details.filter { $0.value.count >= minNameLength }))
    }

    /// This Mac's names as logs could hold them: the computer name ("Jo's MacBook Pro"), the host name
    /// ("Jos-MacBook-Pro.local"), and its first part.
    static func macNames() -> [String] {
        let host = ProcessInfo.processInfo.hostName
        return [Host.current().localizedName, host, host.split(separator: ".").first.map(String.init)].compactMap { $0 }
    }

    /// Every identifier of every device devicectl lists (its list devices entries) and of the devices
    /// this companion knows, as the byte strings a log could hold: the UDID, the CoreDevice identifier, the
    /// serial number and the ECID (decimal and hex), each as is, upper- and lowercase.
    static func deviceIdentifiers(in list: [[String: Any]], devices: [Device]) -> [Data] {
        var values = devices.map(\.udid)
        for entry in list {
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            values += [hardware["udid"], entry["identifier"], hardware["serialNumber"]].compactMap { $0 as? String }
            if let ecid = hardware["ecid"] as? NSNumber {
                values += [ecid.stringValue, String(ecid.uint64Value, radix: 16)]
            }
        }
        return Set(values.flatMap { [$0, $0.uppercased(), $0.lowercased()] }.filter { $0.utf8.count >= minLength })
            .map { Data($0.utf8) }
    }

    /// Every value in a prefs domain or plist (strings, data, numbers, nested), as the byte strings a log
    /// could hold it as: as is, data also as base64 and text, and with "/" escaped as JSON writes it
    /// (crash reports are JSON).
    static func secrets(in value: Any) -> [Data] {
        func text(_ s: String) -> [Data] {
            guard s.utf8.count >= minLength else { return [] }
            return s.contains("/") ? [Data(s.utf8), Data(s.replacingOccurrences(of: "/", with: "\\/").utf8)] : [Data(s.utf8)]
        }
        switch value {
        case let s as String: return text(s)
        case let d as Data:
            guard d.count >= minLength else { return [] }
            return [d] + text(d.base64EncodedString()) + (String(data: d, encoding: .utf8).map(text) ?? [])
        case let n as NSNumber: return text(n.stringValue)
        case let a as [Any]: return a.flatMap(secrets(in:))
        case let d as [String: Any]: return d.values.flatMap(secrets(in:))
        default: return []
        }
    }

    /// Under an excluded folder, or named like the token export (spnetbattle.plist, a net.battle export).
    static func isExcluded(_ url: URL, _ excluded: [URL]) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let name = url.lastPathComponent.lowercased()
        return name.contains("netbattle") || name.contains("net.battle") || excluded.contains {
            let dir = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path == dir || path.hasPrefix(dir + "/")
        }
    }

    /// The regular files in a folder (symlinks aren't followed), with their paths relative to it.
    static func regularFiles(in dir: URL, recursive: Bool) -> [(url: URL, path: String)] {
        let fm = FileManager.default
        let paths = recursive ? (fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
            : (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return paths.sorted().compactMap { path in
            let url = dir.appending(path: path)
            let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            return type == .typeRegular ? (url, path) : nil
        }
    }

    // MARK: The app's export

    /// The secrets in the real world: the net.battle prefs, and whatever the token export holds now.
    static func netBattleSecrets() -> [Data] {
        var found: [Data] = []
        if let prefs = CFPreferencesCopyMultiple(nil, "net.battle" as CFString, kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost) as? [String: Any] {
            found += secrets(in: prefs)
        }
        for (url, _) in regularFiles(in: TokenRelay.exportDirectory, recursive: true) {
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                found += secrets(in: plist)
            }
        }
        return found
    }

    /// What's installed and running, for versions.txt. `deviceInfo` is the device's devicectl entry.
    static func versions(device: Device, deviceInfo: [String: Any]?, xcode: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?", build = info["CFBundleVersion"] as? String ?? "?"
        var model = [CChar](repeating: 0, count: 64), size = model.count
        let mac = sysctlbyname("hw.model", &model, &size, nil, 0) == 0 ? String(cString: model) : "?"
        var lines = ["Slashplayed Companion \(short) (\(build))",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(mac)",
                     "Xcode: \(xcode)"]
        if device == .none {
            lines.append("Device: none paired")
        } else {
            let hardware = deviceInfo?["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = deviceInfo?["deviceProperties"] as? [String: Any] ?? [:]
            let os = [hardware["platform"], properties["osVersionNumber"], (properties["osBuildUpdate"]).map { "(\($0))" }]
                .compactMap { $0.map { "\($0)" } }.joined(separator: " ")
            lines.append("Device: \(hardware["marketingName"] as? String ?? device.noun) (\(hardware["productType"] as? String ?? "?")), " +
                         "\(os.isEmpty ? "OS unknown" : os), Developer Mode \(properties["developerModeStatus"] as? String ?? "unknown")")
        }
        lines.append("Game install: \(Flavor.installRoot.path)")
        for flavor in Flavor.allCases {
            let installed = Flavor.installed.contains(flavor)
            let version = installed ? "\(ClientBuild.version(flavor) ?? "?") (build \(ClientBuild.gameBuild(flavor) ?? "?"))" : "not installed"
            lines.append("\(flavor.name): \(version)" + (device.flavors.contains(flavor) ? ", on the \(device.noun)" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// Xcode's version and where it's selected, or why there's none.
    static func xcodeVersion() async -> String {
        let selected = (try? await Shell.run("/usr/bin/xcode-select", ["-p"], check: false))?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let r = try? await Shell.run(Device.xcrun, ["xcodebuild", "-version"], check: false), r.status == 0 else {
            return "not found" + (selected.isEmpty ? "" : " (xcode-select -p: \(selected))")
        }
        return r.text.split(separator: "\n").joined(separator: ", ") + " at \(selected)"
    }

    /// The zip for an export now: ~/Library/Logs/Slashplayed/diagnostics/Slashplayed-Diagnostics-<date-time>.zip.
    static func outputURL() -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return Paths.logs.appending(path: "diagnostics/Slashplayed-Diagnostics-\(stamp.string(from: Date())).zip")
    }
}
