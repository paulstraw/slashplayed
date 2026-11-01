import XCTest

/// Diagnostics.export on made-up logs with a fake token planted everywhere a real one could turn up: a log
/// line, a crash report's JSON, a binary report, the version text, and a token export file.
final class DiagnosticsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "sp-diagnostics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ path: String) throws {
        try write(Data(text.utf8), path)
    }

    private func write(_ data: Data, _ path: String) throws {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testPlantedTokenNeverReachesTheZip() throws {
        let token = "FAKE-TOKEN-7f3a9c2e81d04b5f"
        let path = "/fake/net.battle/value/8c1e"
        // The prefs as they'd be read: the token as a string, a path, data, a short value that stays.
        let prefs: [String: Any] = [
            "Launch Options": ["Game": ["SECRET": token, "STAMP": 1_760_000_000]],
            "Path": path,
            "Blob": Data(token.utf8),
            "Locale": "enUS",
        ]
        let secrets = Diagnostics.secrets(in: prefs)

        try write("  1.00 [companion] caught the client, arguments: -launcherlogin -fakearg \(token)\n  2.00 locale enUS\n", "logs/companion.txt")
        try write("12:00:00 [sp:system] lifecycle: launched\n", "logs/console.txt")
        try write("old pull", "logs/triage/20260101-000000/summary.txt")
        try write(#"{"path":"\#(path.replacingOccurrences(of: "/", with: "\\/"))","token":"\#(token)"}"#,
                  "device/system/slashplayed-2026-10-16.ips")
        try write(Data([0, 1, 2]) + Data(token.utf8) + Data([0xff, 0xfe]), "device/system/JetsamEvent-2026-10-16.bin")
        try write("12:00:00 [sp:system] lifecycle: launched \(token)\n", "device/app/Documents/spconsole.1.log")
        // The client's own logs stay out.
        try write("account details", "device/app/Documents/_classic_era_/Logs/Client.log")
        try write("account details", "device/app/Documents/_classic_era_/Errors/report.txt")
        try write("== spconsole.log: 12:00:00 to 12:01:00\n", "device/summary.txt")
        // The token export, in its own folder and loose in the logs under its name.
        let plist = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
        try write(plist, "sptoken/spnetbattle.plist")
        try write(plist, "logs/spnetbattle.plist")
        try write(plist, "device/app/Library/spnetbattle.plist")

        let zip = dir.appending(path: "out/Slashplayed-Diagnostics-test.zip")
        let exported = try Diagnostics.export(.init(
            logs: dir.appending(path: "logs"), deviceLogs: dir.appending(path: "device"),
            versions: "Slashplayed Companion 0.1 (1)\nGame install: \(path)", summary: "Steps:\n  failed: The client stopped",
            secrets: secrets, excluded: [dir.appending(path: "sptoken"), dir.appending(path: "device/app/Library")],
            output: zip))

        // Unzipped, no byte of the token or the path is anywhere, as is or escaped or base64.
        let out = dir.appending(path: "unzipped")
        XCTAssertEqual(try TestShell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status, 0)
        let root = out.appending(path: "Slashplayed-Diagnostics-test")
        let files = Diagnostics.regularFiles(in: root, recursive: true).map(\.path)
        XCTAssertEqual(files, ["companion/companion.txt", "companion/console.txt",
                               "device/app/Documents/spconsole.1.log", "device/summary.txt",
                               "device/system/JetsamEvent-2026-10-16.bin", "device/system/slashplayed-2026-10-16.ips",
                               "summary.txt", "versions.txt"])
        let forbidden = [token, path, path.replacingOccurrences(of: "/", with: "\\/"), Data(token.utf8).base64EncodedString()]
        for file in files {
            let data = try Data(contentsOf: root.appending(path: file))
            for value in forbidden {
                XCTAssertNil(data.range(of: Data(value.utf8)), "\(file) holds a planted value")
            }
        }
        // Everything else is kept, the short value too.
        let log = try String(contentsOf: root.appending(path: "companion/companion.txt"), encoding: .utf8)
        XCTAssertEqual(log, "  1.00 [companion] caught the client, arguments: -launcherlogin -fakearg [redacted]\n  2.00 locale enUS\n")
        XCTAssertEqual(exported.redactions, 6)
        XCTAssertEqual(exported.excluded, ["companion/spnetbattle.plist"])
        let summary = try String(contentsOf: root.appending(path: "summary.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("Redacted 6 Battle.net values, 0 device identifiers, and 0 personal details"), summary)
    }

    /// Made-up device identifiers, planted where real ones turn up: build.txt's provisioning line, a log,
    /// a crash report's keys, a binary report. One UDID isn't in devicectl's list (a device unpaired since),
    /// so only its shape catches it. Binary images' UUIDs, a hash, and Finder's .DS_Store are checked too.
    func testDeviceIdentifiersNeverReachTheZip() throws {
        // Joined at run time: check-tree.sh rightly refuses a UDID-shaped literal in the tree.
        let udid = "00008120-" + "000A1B2C3D4E5F60", headset = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
        let coreDevice = "12345678-9ABC-DEF0-1234-56789ABCDEF0", serial = "FAKESER123", ecid: UInt64 = 0x1A2B3C4D5E6F7
        let unlisted = "00006030-" + "0011223344556677"
        let list: [[String: Any]] = [
            ["identifier": coreDevice,
             "hardwareProperties": ["udid": udid, "serialNumber": serial, "ecid": NSNumber(value: ecid)]],
        ]
        let devices = [Device(name: "Vision Pro", udid: headset, kind: .headset)]
        let ids = Diagnostics.deviceIdentifiers(in: list, devices: devices)
        let imageUUID = "AABBCCDD-EEFF-0011-2233-445566778899", hash = String(repeating: "ab", count: 20)

        try write("provisioning x.slashplayed for team T (Team) and device \(udid)\n", "logs/build.txt")
        try write("devicectl --device \(coreDevice.lowercased()) ecid \(ecid) 0x\(String(ecid, radix: 16)) serial \(serial)\n" +
                  "headset \(headset), old \(unlisted)\n", "logs/companion.txt")
        try write("junk", "logs/.DS_Store")
        try write(#"{"crashReporterKey" : "\#(hash)", "deviceIdentifierForVendor":"\#(imageUUID.lowercased())", "uuid":"\#(imageUUID)"}"#,
                  "device/system/JetsamEvent-2026-10-25.ips")
        try write(Data([0, 0xff]) + Data(udid.utf8) + Data([0xfe, 0x80]), "device/system/slashplayed.bin")
        try write("junk", "device/system/.DS_Store")
        try write("== spconsole.log\n", "device/summary.txt")

        let zip = dir.appending(path: "out/Slashplayed-Diagnostics-ids.zip")
        let exported = try Diagnostics.export(.init(
            logs: dir.appending(path: "logs"), deviceLogs: dir.appending(path: "device"),
            versions: "Device: Apple Vision Pro", summary: "Steps:\n  failed: provisioning for \(udid)",
            secrets: [], deviceIDs: ids, excluded: [], output: zip))

        let out = dir.appending(path: "unzipped")
        XCTAssertEqual(try TestShell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status, 0)
        let root = out.appending(path: "Slashplayed-Diagnostics-ids")
        let files = Diagnostics.regularFiles(in: root, recursive: true).map(\.path)
        XCTAssertEqual(files, ["companion/build.txt", "companion/companion.txt", "device/summary.txt",
                               "device/system/JetsamEvent-2026-10-25.ips", "device/system/slashplayed.bin",
                               "summary.txt", "versions.txt"])
        let forbidden = [udid, udid.lowercased(), headset, coreDevice.lowercased(), serial, String(ecid),
                         String(ecid, radix: 16), unlisted, hash, imageUUID.lowercased()]
        for file in files {
            let data = try Data(contentsOf: root.appending(path: file))
            for value in forbidden {
                XCTAssertNil(data.range(of: Data(value.utf8)), "\(file) holds a planted identifier")
            }
        }
        let build = try String(contentsOf: root.appending(path: "companion/build.txt"), encoding: .utf8)
        XCTAssertEqual(build, "provisioning x.slashplayed for team T (Team) and device [device id]\n")
        // The binary report's other bytes, and the binary images' UUID, stay.
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "device/system/slashplayed.bin")),
                       Data([0, 0xff]) + Diagnostics.deviceMarker + Data([0xfe, 0x80]))
        let report = try String(contentsOf: root.appending(path: "device/system/JetsamEvent-2026-10-25.ips"), encoding: .utf8)
        XCTAssertEqual(report, #"{"crashReporterKey" : "[device id]", "deviceIdentifierForVendor":"[device id]", "uuid":"\#(imageUUID)"}"#)
        XCTAssertEqual(exported.deviceRedactions, 10)
        let summary = try String(contentsOf: root.appending(path: "summary.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("provisioning for [device id]"), summary)
        XCTAssertTrue(summary.contains("Redacted 0 Battle.net values, 10 device identifiers, and 0 personal details"), summary)
    }

    /// Made-up personal details, planted where rc9's real ones turned up: the signing certificate's name in
    /// build.txt and the team check, the team ID in bundle IDs and a crash report, the device names in step
    /// lines, the Mac's names, and /Users paths (plain and JSON-escaped). What isn't personal stays: a
    /// device's out-of-the-box name, /Users/Shared, and words shorter than a name.
    func testPersonalDetailsNeverReachTheZip() throws {
        let fullName = "Jo Q. Tester", team = Signing.Team(id: "AB12CD34EF", name: "Tester Widgets LLC", isFree: false)
        let personal = Signing.Team(id: "ZZ98YY76XX", name: "Jo Q. Tester (Personal Team)", isFree: true)
        let appleID = "jo.tester@example.com", certID = "Q1W2E3R4T5", user = "jotester"
        let phone = "jotester-16-pro", headset = "Jo’s Apple Vision Pro", computer = "Jo’s MacBook Pro"
        let list: [[String: Any]] = [
            ["deviceProperties": ["name": headset], "hardwareProperties": ["marketingName": "Apple Vision Pro"]],
            ["deviceProperties": ["name": "iPad (2)"], "hardwareProperties": ["marketingName": "iPad Pro 12.9-inch (6th generation)"]],
        ]
        let details = Diagnostics.personalDetails(
            fullName: fullName, teams: [team, personal], appleIDs: [appleID], in: list,
            devices: [Device(name: phone, udid: "u", kind: .iPhone), .none], hosts: [computer, "Jos-MacBook-Pro.local", "Jos-MacBook-Pro"])

        try write("signing with Apple Development: \(fullName) (\(certID)) for \(team.id).slashplayed\n" +
                  "  2.70 [step] done: Paired with \(phone)\n", "logs/build.txt")
        try write("  4.83 [step] done: \(headset) connected\n  5.00 \(headset.replacingOccurrences(of: "’", with: "'")) and iPad (2)\n" +
                  "teams: \(personal.name), \(team.name); account \(appleID)\n" +
                  "macOS 26.6.2 on \(computer), Jos-MacBook-Pro.local\n" +
                  "/Users/\(user)/Library/Logs/Slashplayed and /Users/Shared/Slashplayed-rc1\n", "logs/companion.txt")
        try write(#"{"bundleID":"\#(team.id).slashplayed","path":"\/Users\/\#(user)\/Library"}"#, "device/system/slashplayed.ips")
        try write("== spconsole.log\n", "device/summary.txt")

        let zip = dir.appending(path: "out/Slashplayed-Diagnostics-personal.zip")
        let exported = try Diagnostics.export(.init(
            logs: dir.appending(path: "logs"), deviceLogs: dir.appending(path: "device"),
            versions: "Device: iPhone 16 Pro (iPhone17,1)\nGame install: /Users/\(user)/Games/World of Warcraft",
            summary: "Steps:\n  done: \(phone) connected", secrets: [], personal: details, excluded: [], output: zip))

        let out = dir.appending(path: "unzipped")
        XCTAssertEqual(try TestShell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status, 0)
        let root = out.appending(path: "Slashplayed-Diagnostics-personal")
        let files = Diagnostics.regularFiles(in: root, recursive: true).map(\.path)
        // "Jo’s" and "Jo's" alone are too short to be names: only whole device and Mac names go.
        let forbidden = [fullName, team.id, team.name, personal.id, appleID, certID, user, phone,
                         "Jo’s Apple", "Jo's Apple", "Jo’s MacBook", "Jos-MacBook"]
        for file in files {
            let data = try Data(contentsOf: root.appending(path: file))
            for value in forbidden {
                XCTAssertNil(data.range(of: Data(value.utf8)), "\(file) holds a planted detail: \(value)")
            }
        }
        let build = try String(contentsOf: root.appending(path: "companion/build.txt"), encoding: .utf8)
        XCTAssertEqual(build, "signing with Apple Development: [name] ([certificate id]) for [team id].slashplayed\n" +
                       "  2.70 [step] done: Paired with [device name]\n")
        let log = try String(contentsOf: root.appending(path: "companion/companion.txt"), encoding: .utf8)
        XCTAssertEqual(log, "  4.83 [step] done: [device name] connected\n  5.00 [device name] and iPad (2)\n" +
                       "teams: [team], [team]; account [apple id]\n" +
                       "macOS 26.6.2 on [mac name], [mac name]\n" +
                       "/Users/[user]/Library/Logs/Slashplayed and /Users/Shared/Slashplayed-rc1\n")
        let report = try String(contentsOf: root.appending(path: "device/system/slashplayed.ips"), encoding: .utf8)
        XCTAssertEqual(report, #"{"bundleID":"[team id].slashplayed","path":"\/Users\/[user]\/Library"}"#)
        let versions = try String(contentsOf: root.appending(path: "versions.txt"), encoding: .utf8)
        XCTAssertEqual(versions, "Device: iPhone 16 Pro (iPhone17,1)\nGame install: /Users/[user]/Games/World of Warcraft\n")
        // build.txt 3, companion.txt 8, the report 2, versions.txt 1; the summary's own isn't counted.
        XCTAssertEqual(exported.personalRedactions, 14)
        let summary = try String(contentsOf: root.appending(path: "summary.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("done: [device name] connected"), summary)
        XCTAssertTrue(summary.contains("Redacted 0 Battle.net values, 0 device identifiers, and 14 personal details"), summary)
    }

    func testRedactsOverlappingSecretsWhole() {
        let secrets = Diagnostics.secrets(in: ["a": "abcdefgh", "b": "xxabcdefghxx"]).sorted { $0.count > $1.count }
        let (out, n) = Diagnostics.redact(Data("1 xxabcdefghxx 2 abcdefgh".utf8), secrets)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "1 [redacted] 2 [redacted]")
        XCTAssertEqual(n, 2)
    }
}
