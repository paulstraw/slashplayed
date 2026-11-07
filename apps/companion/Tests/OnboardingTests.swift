import XCTest

/// The checks onboarding and Settings make on their own (no Xcode, devices or real install): finding the
/// game install from the folder the user picked, which iPads can run the client, and bundle ID prefixes.
final class OnboardingTests: XCTestCase {
    /// A made-up install in a scratch folder: empty files where Battle.net puts each client executable.
    private func makeInstall(_ flavors: [Flavor]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "sp-onboarding-\(UUID().uuidString)/World of Warcraft")
        for f in flavors {
            let exe = f.clientExecutable(in: root)
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: exe.path, contents: Data())
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testInstalledFlavorsInAFolder() throws {
        let root = try makeInstall([.classicEra, .retail])
        XCTAssertEqual(Flavor.installed(in: root), [.classicEra, .retail])
        // _classic_ (MoP Classic) alone isn't Classic Era, and the other way round.
        XCTAssertEqual(Flavor.installed(in: try makeInstall([.classic])), [.classic])
        XCTAssertEqual(Flavor.installed(in: try makeInstall([.classicEra, .classic])), [.classicEra, .classic])
    }

    /// The install itself, a flavor's folder in it, or a client app in that: all mean the install.
    func testPickedFolderFindsTheInstall() throws {
        let root = try makeInstall([.anniversary, .retail])
        XCTAssertEqual(Flavor.installRoot(picked: root)?.path, root.path)
        XCTAssertEqual(Flavor.installRoot(picked: root.appending(path: "_retail_"))?.path, root.path)
        XCTAssertEqual(Flavor.installRoot(picked: root.appending(path: "_anniversary_/World of Warcraft Classic.app"))?.path, root.path)
        XCTAssertNil(Flavor.installRoot(picked: root.deletingLastPathComponent().deletingLastPathComponent()))
        let mists = try makeInstall([.classic])
        XCTAssertEqual(Flavor.installRoot(picked: mists.appending(path: "_classic_"))?.path, mists.path)
    }

    func testSupportedIPads() {
        for model in ["iPad14,5", "iPad14,9", "iPad16,3", "iPad15,4", "iPad17,1"] {
            XCTAssertTrue(Device.isSupportedIPad(model: model), model)
            XCTAssertFalse(Device.isUntestedIPad(model: model), model)
        }
        // Under 8 GB: Air 4 and the 10th generation (A14), mini 6 (A15), the 11th generation (A16). And the
        // 2018 Pro (A12X), short of the M1's instruction set.
        for model in ["iPad13,1", "iPad13,2", "iPad13,18", "iPad13,19", "iPad14,1", "iPad14,2", "iPad15,7", "iPad15,8", "iPad8,1"] {
            XCTAssertFalse(Device.isSupportedIPad(model: model), model)
            XCTAssertFalse(Device.isUntestedIPad(model: model), model)
        }
        XCTAssertTrue(Device.isSupportedIPad(model: nil))
        XCTAssertFalse(Device.isUntestedIPad(model: nil))
    }

    func testM1IPadsAllowedButUntested() {
        // The 11-inch 3rd-generation Pro, the 12.9-inch 5th-generation Pro, and the 5th-generation Air.
        let m1 = ["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
                  "iPad13,16", "iPad13,17"]
        let iPad = Device(name: "", udid: "", kind: .iPad)
        for model in m1 {
            XCTAssertTrue(Device.isSupportedIPad(model: model), model)
            XCTAssertTrue(Device.isUntestedIPad(model: model), model)
            XCTAssertNil(iPad.unsupportedReason(model: model), model)
            XCTAssertNotNil(iPad.untestedNote(model: model), model)
        }
        // The A14 iPads numbered among them stay refused.
        for model in ["iPad13,1", "iPad13,2", "iPad13,18", "iPad13,19"] {
            XCTAssertFalse(Device.isSupportedIPad(model: model), model)
        }
        // The A17 Pro mini 7 (8 GB, the iPhone 15 Pro's chip) is allowed, untested, and named as itself.
        for model in ["iPad16,1", "iPad16,2"] {
            XCTAssertTrue(Device.isSupportedIPad(model: model), model)
            XCTAssertTrue(Device.isUntestedIPad(model: model), model)
            XCTAssertNil(iPad.unsupportedReason(model: model), model)
            XCTAssertEqual(iPad.untestedNote(model: model)?.contains("the A17 Pro iPad mini"), true, model)
        }
        XCTAssertEqual(iPad.untestedNote(model: "iPad13,16")?.contains("an M1 iPad"), true)
        XCTAssertNil(iPad.untestedNote(model: "iPad14,5"))
        XCTAssertNil(iPad.untestedNote(model: nil))
        XCTAssertNil(Device(name: "", udid: "", kind: .iPhone).untestedNote(model: "iPad13,16"))
    }

    func testSupportedIPhones() {
        // 15 Pro, 15 Pro Max, 16 Pro (the tested one), 16e, 17.
        for model in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,5", "iPhone18,3"] {
            XCTAssertTrue(Device.isSupportedIPhone(model: model), model)
        }
        // 15, 15 Plus, 14 Pro, 13, SE 3, 7.
        for model in ["iPhone15,4", "iPhone15,5", "iPhone15,2", "iPhone14,5", "iPhone14,6", "iPhone9,1"] {
            XCTAssertFalse(Device.isSupportedIPhone(model: model), model)
        }
        XCTAssertTrue(Device.isSupportedIPhone(model: nil))
        // Each kind uses its own check.
        XCTAssertFalse(Device(name: "", udid: "", kind: .iPhone).isSupported(model: "iPhone15,4"))
        XCTAssertFalse(Device(name: "", udid: "", kind: .iPad).isSupported(model: "iPad13,1"))
        XCTAssertTrue(Device(name: "", udid: "", kind: .headset).isSupported(model: "RealityDevice14,1"))
    }

    func testOlderIPadProsUnsupported() {
        // The 2018 (A12X) and 2020 (A12Z) iPad Pros: the client stopped at an instruction the A12X lacks.
        for model in ["iPad8,1", "iPad8,3", "iPad8,5", "iPad8,8", "iPad8,9", "iPad8,12"] {
            XCTAssertFalse(Device.isSupportedIPad(model: model), model)
        }
        // A model that doesn't parse is unknown, so allowed.
        XCTAssertTrue(Device.isSupportedIPad(model: "iPad"))
    }

    func testUnsupportedReason() {
        let iPad = Device(name: "", udid: "", kind: .iPad), iPhone = Device(name: "", udid: "", kind: .iPhone)
        XCTAssertEqual(iPad.unsupportedReason(model: "iPad8,1"), "Not supported: Slashplayed needs an iPad with an M1 chip or later, or the A17 Pro iPad mini.")
        XCTAssertEqual(iPhone.unsupportedReason(model: "iPhone15,4"), "Not supported: Slashplayed needs an iPhone 15 Pro or later.")
        XCTAssertNil(iPad.unsupportedReason(model: "iPad14,5"))
        XCTAssertNil(iPad.unsupportedReason(model: nil))
        XCTAssertNil(Device(name: "", udid: "", kind: .headset).unsupportedReason(model: "RealityDevice14,1"))
    }

    func testChooseDevice() {
        let headset = Device(name: "Vision Pro", udid: "h", kind: .headset)
        let old = Device(name: "Old iPad", udid: "o", kind: .iPad)
        let iPhone = Device(name: "iPhone", udid: "p", kind: .iPhone)
        let all = [headset, old, iPhone]
        let models = ["h": "RealityDevice14,1", "o": "iPad8,1", "p": "iPhone17,1"]
        func choose(target: String? = nil, pin: String = "", last: String? = nil, reachable: Set<String> = [],
                    devices: [Device] = all, models: [String: String] = models) -> Device {
            Device.choose(from: devices, target: target, pin: pin, last: last, reachable: reachable, models: models)
        }
        // Automatic passes over the old iPad, reachable and last used or not.
        XCTAssertEqual(choose(last: "o", reachable: ["o", "p"]), iPhone)
        XCTAssertEqual(choose(last: "o", reachable: ["o"]), headset)
        XCTAssertEqual(choose(last: "o"), headset)
        XCTAssertEqual(choose(last: "p", reachable: ["h", "p"]), iPhone)
        XCTAssertEqual(choose(reachable: ["h", "p"]), headset)
        // Unknown models count as supported.
        XCTAssertEqual(choose(last: "o", reachable: ["o"], models: [:]), old)
        // A pin or a target is kept, so the action can say why it stops.
        XCTAssertEqual(choose(pin: "o", reachable: ["p"]), old)
        XCTAssertEqual(choose(target: "o", pin: "p"), old)
        // A pin that isn't paired any more falls back to Automatic.
        XCTAssertEqual(choose(pin: "gone", reachable: ["p"]), iPhone)
        // With only unsupported devices, one is still picked.
        XCTAssertEqual(choose(reachable: ["o"], devices: [old]), old)
        XCTAssertEqual(choose(devices: []), .none)
    }

    func testBundlePrefixes() {
        for p in ["", "ABCDE12345", "com.example", "my-team.games"] {
            XCTAssertTrue(Signing.isValidBundlePrefix(p), p)
        }
        for p in ["com..example", ".com", "com.", "has space", "under_score", "émoji"] {
            XCTAssertFalse(Signing.isValidBundlePrefix(p), p)
        }
    }

    /// companion.txt gets a step's outcome once: the first answer, and each change after (a fix, a new
    /// problem), not every 3 s poll that answers the same, and nothing while it's still checking.
    func testSetupLogsEachNewOutcomeOnce() {
        let ok = SetupStatus.ok("Xcode 27.1 is installed and selected.")
        let signedOut = SetupStatus.problem("No Apple account in Xcode", "Open Xcode > Settings > Apple Accounts.\nSign in.")
        XCTAssertEqual(ok.logLine("Xcode", was: nil), "[setup] Xcode: ok — Xcode 27.1 is installed and selected.")
        XCTAssertNil(ok.logLine("Xcode", was: ok))
        XCTAssertNil(SetupStatus.checking.logLine("Apple developer account", was: nil))
        XCTAssertEqual(signedOut.logLine("Apple developer account", was: .checking),
                       "[setup] Apple developer account: No Apple account in Xcode — Open Xcode > Settings > Apple Accounts. / Sign in.")
        XCTAssertNil(signedOut.logLine("Apple developer account", was: signedOut))
        XCTAssertNotNil(SetupStatus.ok("Signed").logLine("Apple developer account", was: signedOut))
    }

    /// The install step passes once one device holds this Mac's install, naming those that do; with none,
    /// it says whether one needs an update or none has it.
    func testFirstInstallPassesWithOneDevice() {
        XCTAssertEqual(SetupStatus.firstInstall([("iPad", .notOnDevice), ("iPhone", .notFromThisMac)]),
                       .problem("Slashplayed isn't on a device yet", "Press Install for the device you'll play on."))
        XCTAssertFalse(SetupStatus.firstInstall([]).isOK)
        XCTAssertEqual(SetupStatus.firstInstall([("iPad", .olderBuild), ("iPhone", .upToDate)]), .ok("Slashplayed is on iPhone."))
        XCTAssertEqual(SetupStatus.firstInstall([("Vision Pro", .upToDate), ("iPad", .upToDate), ("iPhone", .upToDate)]),
                       .ok("Slashplayed is on Vision Pro, iPad, and iPhone."))
        XCTAssertEqual(SetupStatus.firstInstall([("Vision Pro", .olderBuild), ("iPad", .notOnDevice), ("iPhone", .replaced)]),
                       .problem("Slashplayed on Vision Pro and iPhone needs an update", "Press Update for the device you'll play on."))
    }

    /// "Not installed" only for a device without the app: rc7's iPad had an older build of the shared one
    /// and read "Not installed". One this Mac didn't install may be another Mac's or not there, so it's
    /// worded to be true either way.
    func testInstallStateSaysWhatTheDeviceHolds() {
        func state(_ need: ClientBuild.InstallNeed, _ wake: String? = nil) -> String { SetupStatus.installState(need, wake: wake).text }
        func button(_ need: ClientBuild.InstallNeed) -> String? { SetupStatus.installState(need, wake: nil).button }
        XCTAssertEqual(state(.upToDate), "Installed")
        XCTAssertNil(button(.upToDate))
        XCTAssertEqual(state(.notOnDevice), "Not installed")
        XCTAssertEqual(state(.notOnDevice, "Connect it with USB first."), "Not installed. Connect it with USB first.")
        XCTAssertEqual(button(.notOnDevice), "Install")
        XCTAssertEqual(state(.notFromThisMac), "Not installed from this Mac")
        XCTAssertEqual(button(.notFromThisMac), "Install")
        XCTAssertEqual(state(.olderBuild), "Installed, needs an update")
        XCTAssertEqual(state(.olderBuild, "Put on the headset first."), "Installed, needs an update. Put on the headset first.")
        XCTAssertEqual(state(.replaced), "Installed from another Mac or Xcode, needs an update")
        for need in [ClientBuild.InstallNeed.olderBuild, .replaced] {
            XCTAssertEqual(button(need), "Update", "\(need)")
        }
        XCTAssertEqual(SetupStatus.logName(.olderBuild), "an earlier build")
    }

    func testListsUseTheSerialComma() {
        XCTAssertEqual(SetupStatus.list([]), "")
        XCTAssertEqual(SetupStatus.list(["a"]), "a")
        XCTAssertEqual(SetupStatus.list(["a", "b"], or: true), "a or b")
        XCTAssertEqual(SetupStatus.list(["a", "b", "c"]), "a, b, and c")
    }

    /// Counts are singular for one: a delta copy of one file read "Copied 20 KB of game files — 1 files in 1 s".
    func testCountsAreSingularForOne() {
        XCTAssertEqual(SetupStatus.count(1, "file"), "1 file")
        XCTAssertEqual(SetupStatus.count(0, "file"), "0 files")
        XCTAssertEqual(SetupStatus.count(141, "old index file"), "141 old index files")
    }

    /// Stop Using It names one device in the singular: "Paul's Apple Vision Pro delete their copies" (rc9).
    func testStopUsingItAgreesWithItsDevices() {
        XCTAssertEqual(SlashplayedCertificate.deletedLine(sentTo: []), "deleted the Slashplayed certificate and its key from this Mac")
        XCTAssertEqual(SlashplayedCertificate.deletedLine(sentTo: ["Vision Pro"]),
                       "deleted the Slashplayed certificate and its key from this Mac; Vision Pro deletes its copy at its next Play or Update Client")
        XCTAssertEqual(SlashplayedCertificate.deletedLine(sentTo: ["Vision Pro", "iPad"]),
                       "deleted the Slashplayed certificate and its key from this Mac; Vision Pro and iPad delete their copies at their next Play or Update Client")
    }

    /// Retail on an iPad or iPhone: space is only warned about when the device is short of it, by the free
    /// space the companion shows (a 1 TB iPhone with 810 GB free was told it was more than most have).
    func testRetailNoteGoesByFreeSpace() {
        XCTAssertEqual(Flavor.retailNote(noun: "iPhone", free: FreeSpace(bytes: 810_790_000_000)), "Retail has been played on an iPhone 16 Pro.")
        let free = ByteCountFormatter.string(fromByteCount: 120_000_000_000, countStyle: .file)
        XCTAssertEqual(Flavor.retailNote(noun: "iPad", free: FreeSpace(bytes: 120_000_000_000)),
                       "Retail can take about 150 GB, and the iPad has \(free) free. Retail runs hot on an iPad, near its memory limit.")
        XCTAssertEqual(Flavor.retailNote(noun: "iPad", free: FreeSpace(bytes: 120_000_000_000, atLeast: true)),
                       "Retail can take about 150 GB, and the iPad has at least \(free) free. Retail runs hot on an iPad, near its memory limit.")
        XCTAssertTrue(Flavor.retailNote(noun: "iPad", free: nil).contains("free space isn't known yet"))
    }

    /// The launcher's spfree.txt: rc10's two lines (Settings' figure, then free outright), an older
    /// launcher's one, and junk.
    func testLauncherFreeSpaceFile() {
        XCTAssertEqual(FreeSpace.Launcher("774823397924\n585728000000\n"), FreeSpace.Launcher(free: 774_823_397_924, outright: 585_728_000_000))
        XCTAssertEqual(FreeSpace.Launcher("805900000000"), FreeSpace.Launcher(free: 805_900_000_000, outright: nil))
        XCTAssertNil(FreeSpace.Launcher(""))
        XCTAssertNil(FreeSpace.Launcher("lots"))
    }

    /// One measure, the one the device's Settings shows: lockdown's figure leaves out what iOS can clear (the
    /// rc9 run's iPhone: 610 GB in the footer, 805 GB in Settings), so the launcher's difference is added to it.
    /// Figures from the iPhone on 2026-10-28.
    func testFreeSpaceIsSettingsMeasure() {
        let launcher = FreeSpace.Launcher(free: 774_823_397_924, outright: 585_728_000_000)
        // Lockdown now, plus what iOS could clear at the last start.
        XCTAssertEqual(FreeSpace.now(lockdown: 588_716_797_952, launcher: launcher),
                       FreeSpace(bytes: 588_716_797_952 + 774_823_397_924 - 585_728_000_000))
        // The headset (no lockdown), or a device usbmuxd doesn't list: the launcher's own, as of its start.
        XCTAssertEqual(FreeSpace.now(lockdown: nil, launcher: launcher), FreeSpace(bytes: 774_823_397_924))
        // Before Slashplayed has started there, or with an older launcher's one line: lockdown's, as a floor.
        XCTAssertEqual(FreeSpace.now(lockdown: 588_716_797_952, launcher: nil), FreeSpace(bytes: 588_716_797_952, atLeast: true))
        XCTAssertEqual(FreeSpace.now(lockdown: 588_716_797_952, launcher: FreeSpace.Launcher(free: 805_900_000_000, outright: nil)),
                       FreeSpace(bytes: 588_716_797_952, atLeast: true))
        XCTAssertNil(FreeSpace.now(lockdown: nil, launcher: nil))
        XCTAssertTrue(FreeSpace(bytes: 1, atLeast: true).text.hasPrefix("at least "))
    }
}
