import XCTest

/// Whether Play, Update Client, and Copy Game Files install the device app (ClientBuild.installNeed): from
/// this Mac's record of what it installed on the device and the app devicectl lists there, never the games
/// ticked for it (the app holds none); and the plain message for a copy into a data container that isn't there (Device.AppMissing).
/// rc6's run on a second Mac found the iPhone with the first Mac's app (only Classic Era) called "the latest
/// client", and then, with the app deleted, the same, then devicectl's container error.
final class ClientInstallTests: XCTestCase {
    private let here = "file:///private/var/containers/Bundle/Application/AAAA/Slashplayed.app/"
    private let there = "file:///private/var/containers/Bundle/Application/BBBB/Slashplayed.app/"

    private func record(build: String = "b1", url: String? = nil) -> ClientBuild.Installed {
        ClientBuild.Installed(build: build, url: url ?? here)
    }

    private func need(build: String? = "b1", record: ClientBuild.Installed?, app: Device.AppState) -> ClientBuild.InstallNeed {
        ClientBuild.installNeed(build: build, record: record, app: app)
    }

    /// The install this Mac made, still there: nothing to do, also when the device couldn't be asked.
    func testTheSameInstallIsUpToDate() {
        XCTAssertEqual(need(record: record(), app: .present(url: here)), .upToDate)
        XCTAssertEqual(need(record: record(), app: .unknown), .upToDate)
        // No URL was listed right after the install: the record alone decides.
        XCTAssertEqual(need(record: record(url: ""), app: .present(url: there)), .upToDate)
    }

    /// Deleted on the device: installed again, whatever the record says (rc6: "has the latest client" with
    /// no app, then CoreDeviceError 7000 copying the developer disk image).
    func testAnAppDeletedOnTheDeviceIsInstalled() {
        XCTAssertEqual(need(record: record(), app: .missing), .notOnDevice)
        XCTAssertEqual(need(record: nil, app: .missing), .notOnDevice)
    }

    /// A device this Mac never installed on: its app may be another Mac's, with other games (rc6: the
    /// iPhone's had only Classic Era, and Play for TBC Anniversary started Classic Era).
    func testAnotherMacsAppIsReplaced() {
        XCTAssertEqual(need(record: nil, app: .present(url: here)), .notFromThisMac)
        XCTAssertEqual(need(record: nil, app: .unknown), .notFromThisMac)
        // This Mac installed it, but it was installed again since (another Mac, Xcode, deleted and installed):
        // every install puts the app in a new folder.
        XCTAssertEqual(need(record: record(), app: .present(url: there)), .replaced)
    }

    /// A team change makes a new bundle ID, so a new app beside the old one: the old app's record says
    /// nothing about it (rc19's free-team install read "an earlier build than this one" for an app that
    /// wasn't there). A record from before the bundle ID was kept still counts.
    func testARecordOfAnotherBundleIDIsNoRecord() {
        func need(_ record: ClientBuild.Installed, _ app: Device.AppState) -> ClientBuild.InstallNeed {
            ClientBuild.installNeed(build: "b1", record: record, bundleID: "FREE.slashplayed", app: app)
        }
        var paid = record()
        paid.bundleID = "PAID.slashplayed"
        XCTAssertEqual(need(paid, .missing), .notOnDevice)
        XCTAssertEqual(need(paid, .unknown), .notFromThisMac)
        var free = record()
        free.bundleID = "FREE.slashplayed"
        XCTAssertEqual(need(free, .present(url: here)), .upToDate)
        XCTAssertEqual(need(record(), .present(url: here)), .upToDate)
    }

    /// The iPad and the iPhone share the build: one's install doesn't make the other up to date, and a
    /// rebuild (a renewed profile, a new companion) is installed on each again.
    func testAnotherBuildIsInstalled() {
        XCTAssertEqual(need(build: "b2", record: record(), app: .present(url: here)), .olderBuild)
        XCTAssertEqual(need(build: nil, record: record(), app: .present(url: here)), .olderBuild)
    }

    /// The install this Mac made, of a build that isn't complete (isComplete: a new companion's launcher and
    /// shims, another team, a profile about to run out): Play builds again before it installs (updateBuild),
    /// so Setup Assistant's install step offers Update too, not "Installed" (it said "up to date" for an
    /// iPhone the next Play rebuilt for a new companion's resources). A missing app still says so.
    func testAnIncompleteBuildIsNotUpToDate() {
        func need(_ record: ClientBuild.Installed?, _ app: Device.AppState, complete: Bool) -> ClientBuild.InstallNeed {
            ClientBuild.installNeed(build: "b1", record: record, app: app, complete: complete)
        }
        for app in [Device.AppState.present(url: here), .unknown] {
            XCTAssertEqual(need(record(), app, complete: false), .olderBuild)
            XCTAssertEqual(SetupStatus.installState(need(record(), app, complete: false), wake: nil).button, "Update")
            XCTAssertEqual(need(record(), app, complete: true), .upToDate)
        }
        XCTAssertEqual(need(record(), .missing, complete: false), .notOnDevice)
        XCTAssertEqual(need(nil, .present(url: here), complete: false), .notFromThisMac)
    }

    /// devicectl's listing of every app: a listing without the device's built-in apps is cut short and says
    /// nothing (rc7: the headset's Slashplayed and LocalDevVPN "missing" for one session, listed the next),
    /// so setup doesn't say "Not installed" and Play doesn't install again for it.
    func testAListingCutShortSaysNothing() {
        let settings: [String: Any] = ["bundleIdentifier": "com.apple.Preferences", "defaultApp": true, "removable": false]
        let maps: [String: Any] = ["bundleIdentifier": "com.apple.Maps", "defaultApp": true, "removable": true]
        let ours: [String: Any] = ["bundleIdentifier": "TEAM.slashplayed", "defaultApp": false, "removable": true, "url": here]
        XCTAssertEqual(Device.appState("TEAM.slashplayed", in: [settings, maps, ours]), .present(url: here))
        XCTAssertEqual(Device.appState("TEAM.slashplayed", in: [settings, maps]), .missing)
        XCTAssertEqual(Device.appState("TEAM.slashplayed", in: []), .unknown)
        // Only removable apps listed, ours among them or not: still cut short.
        XCTAssertEqual(Device.appState("TEAM.slashplayed", in: [maps]), .unknown)
        XCTAssertEqual(Device.appState("TEAM.slashplayed", in: [maps, ours]), .unknown)
        XCTAssertEqual(need(record: record(), app: Device.appState("TEAM.slashplayed", in: [])), .upToDate)
    }

    /// The client the companion stops before a copy is this team's: with two teams' apps on one iPhone, Play
    /// stopped the other's running game (2026-11-09). Executables as devicectl lists them.
    func testClientPIDIsThisTeamsApp() {
        let other: [String: Any] = ["executable": there + "slashplayed", "processIdentifier": 29429]
        let ours: [String: Any] = ["executable": here + "slashplayed", "processIdentifier": 29783]
        let launchd: [String: Any] = ["executable": "file:///sbin/launchd", "processIdentifier": 1]
        XCTAssertEqual(Device.clientPID(in: [launchd, other, ours], app: .present(url: here)), 29783)
        XCTAssertNil(Device.clientPID(in: [launchd, other], app: .present(url: here)))
        XCTAssertNil(Device.clientPID(in: [launchd, other], app: .missing))
        // An app listing cut short says nothing about which: any Slashplayed's, as before.
        XCTAssertEqual(Device.clientPID(in: [launchd, other], app: .unknown), 29429)
    }

    /// devicectl lockState's JSON, as captured: an unlocked iPhone answers passcodeRequired; an unworn
    /// headset fails with "the device was still locked" (rc8's run), which counts as locked so Play waits
    /// before provisioning and launching; a Wi-Fi tunnel drop under the call (rc16's run) is a drop, which
    /// the wait asks again instead of taking for unlocked; any other failure says nothing.
    func testLockState() {
        XCTAssertEqual(Device.lock(lockState: ["result": ["passcodeRequired": false, "unlockedSinceBoot": true]]), .unlocked)
        XCTAssertEqual(Device.lock(lockState: ["result": ["passcodeRequired": true, "unlockedSinceBoot": true]]), .locked)
        let stillLocked: [String: Any] = [
            "error": ["code": 10003, "domain": "com.apple.dt.CoreDeviceError",
                      "userInfo": ["NSLocalizedDescription": ["string": "The operation failed because the device was still locked."]]],
            "errorSignature": "(com.apple.dt.CoreDeviceError 10003 (com.apple.dt.RemotePairingError 1016))",
            "info": ["outcome": "failed"],
        ]
        XCTAssertEqual(Device.lock(lockState: stillLocked), .locked)
        for drop in Self.lockStateDrops {
            XCTAssertEqual(Device.lock(lockState: drop), .dropped, "\(drop)")
        }
        XCTAssertEqual(Device.lock(lockState: ["error": ["code": 4, "domain": "com.apple.dt.CoreDeviceError"],
                                               "errorSignature": "(com.apple.dt.CoreDeviceError 4)"]), .unknown)
        XCTAssertEqual(Device.lock(lockState: [:]), .unknown)
    }

    /// The unworn headset's lockState failures at a tunnel drop, the `error` of each as devicectl wrote it
    /// (rc16's run: two probes, 4 of about 70 calls).
    static let lockStateDrops: [[String: Any]] = [
        ["error": ["code": -402653181, "domain": "com.apple.mobiledevice"], "info": ["outcome": "failed"]],
        ["error": ["code": 60, "domain": "Network.NWError"], "errorSignature": "(Network.NWError 60)",
         "info": ["outcome": "failed"]],
        ["error": ["code": -1, "domain": "com.apple.dt.CoreDeviceError",
                   "userInfo": ["NSLocalizedDescription": ["string": "An unknown error occurred."],
                                "NSUnderlyingError": ["error": [
                                    "code": -402653052, "domain": "com.apple.mobiledevice",
                                    "userInfo": ["NSLocalizedDescription": ["string": "This device is no longer connected."]]]]]],
         "errorSignature": "(com.apple.dt.CoreDeviceError -1 (com.apple.mobiledevice -402653052))",
         "info": ["outcome": "failed"]],
    ]

    /// Each device has its own record, and it reads back as written.
    func testRecordsArePerDevice() throws {
        let name = "sp-install-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let phone = Device(name: "Phone", udid: "phone", kind: .iPhone), pad = Device(name: "Pad", udid: "pad", kind: .iPad)
        XCTAssertNil(ClientBuild.installed(pad, defaults))
        var withBundle = record()
        withBundle.bundleID = "TEAM.slashplayed"
        ClientBuild.setInstalled(withBundle, for: pad, defaults)
        XCTAssertEqual(ClientBuild.installed(pad, defaults), withBundle)
        XCTAssertNil(ClientBuild.installed(phone, defaults))
        XCTAssertEqual(ClientBuild.installNeed(build: "b1", record: ClientBuild.installed(phone, defaults),
                                               app: .present(url: there)), .notFromThisMac)
    }

    /// An older companion's Update Games on This Device settings go, and so do the games its install records
    /// listed; the record itself, and every other setting, stays. Run again, it finds nothing.
    func testUpdateGamesOnThisDevicesSettingsAreForgotten() throws {
        let name = "sp-install-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let phone = Device(name: "Phone", udid: "phone", kind: .iPhone), pad = Device(name: "Pad", udid: "pad", kind: .iPad)
        defaults.set(true, forKey: "updateGames.phone")
        defaults.set("ABCDEF", forKey: "identityPushed.phone")
        defaults.set("A", forKey: "identityPushedSource.phone")
        defaults.set("B", forKey: "signingSource")
        defaults.set(["build": "b1", "flavors": ["classic_era", "retail"], "url": here, "bundleID": "TEAM.slashplayed"],
                     forKey: ClientBuild.installedKey(phone))
        ClientBuild.setInstalled(record(), for: pad, defaults)
        defaults.set(["classic_era", "retail"], forKey: "games.phone")
        defaults.set("retail", forKey: "playGame.phone")
        defaults.set(false, forKey: "updateGamesSoon")  // not one of its keys, only alike

        XCTAssertEqual(ClientBuild.forgetDeviceUpdates(defaults),
                       ["identityPushed.phone", "identityPushedSource.phone", "installedClient.phone.flavors", "signingSource", "updateGames.phone"])
        for key in ["updateGames.phone", "identityPushed.phone", "identityPushedSource.phone", "signingSource"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNil(defaults.dictionary(forKey: ClientBuild.installedKey(phone))?["flavors"])
        XCTAssertEqual(ClientBuild.installed(phone, defaults), ClientBuild.Installed(build: "b1", url: here, bundleID: "TEAM.slashplayed"))
        XCTAssertEqual(ClientBuild.installed(pad, defaults), record())
        XCTAssertEqual(defaults.stringArray(forKey: "games.phone"), ["classic_era", "retail"])
        XCTAssertEqual(defaults.string(forKey: "playGame.phone"), "retail")
        XCTAssertNotNil(defaults.object(forKey: "updateGamesSoon"))
        XCTAssertEqual(ClientBuild.forgetDeviceUpdates(defaults), [])
    }

    /// devicectl's error for a copy into the data container of an app that isn't installed (as rc6's
    /// companion.txt has it), and others that aren't that.
    func testAMissingContainerIsRecognised() {
        func failed(_ stderr: String) -> CommandFailed {
            CommandFailed(command: "xcrun devicectl device copy", result: CommandResult(status: 1, stdout: Data(), stderr: stderr))
        }
        let missing = failed("""
            ERROR: The specified file could not be transferred. (com.apple.dt.CoreDeviceError error 7000 (0x1B58))
            ----
            The operation couldn’t be completed. (ContainerLookupErrorDomain error -1.)
            """)
        XCTAssertTrue(Device.AppMissing.matches(missing))
        XCTAssertFalse(Device.AppMissing.matches(failed("ERROR: The operation couldn’t be completed. (CoreDevice.ActionError error 3.)")))
        XCTAssertFalse(Device.AppMissing.matches(Failure("Developer Mode is off")))
        let message = Device.AppMissing(noun: "iPhone").localizedDescription
        XCTAssertTrue(message.hasPrefix("Slashplayed isn't installed on the iPhone."), message)
        XCTAssertFalse(message.contains("devicectl"), message)
    }

    /// With Slashplayed deleted on the device, a listing of its data container fails with the text a Wi-Fi
    /// drop gives a listing, so rc19's companion retried it as a drop for 30 s, on Wi-Fi and on USB. It's
    /// told apart by asking the device for its apps, only for an error that looks like a drop. The texts are
    /// devicectl's, from a probe of the iPhone with a bundle ID it doesn't have (2026-10-31).
    func testAMissingAppIsNotADrop() async {
        func failed(_ stderr: String) -> CommandFailed {
            CommandFailed(command: "xcrun devicectl device info files", result: CommandResult(status: 1, stdout: Data(), stderr: stderr))
        }
        let listing = failed("""
            ERROR: The operation couldn’t be completed. (CoreDevice.ActionError error 3.)
                   NSDebugDescription = This operation could not be performed due to an error in StreamingAction: The system failed to get a list of files on the remote device.
            """)
        let copyFrom = failed("""
            ERROR: An unknown error occurred. (com.apple.dt.CoreDeviceError error -1 (0xFFFFFFFF))
                   ----------------------------------------
                       The operation couldn’t be completed. (ContainerLookupErrorDomain error -1.)
            """)
        XCTAssertTrue(Device.connectionDropped(listing), "the listing's text is a drop sign too")
        var asked = 0
        func answer(_ state: Device.AppState) -> () async -> Device.AppState { { asked += 1; return state } }
        let missing = await Device.appMissing(listing, app: answer(.missing))
        XCTAssertTrue(missing)
        let present = await Device.appMissing(listing, app: answer(.present(url: here)))
        XCTAssertFalse(present, "the app is there: a real drop, retried")
        let unknown = await Device.appMissing(listing, app: answer(.unknown))
        XCTAssertFalse(unknown, "a drop usually cuts the app listing too: still a drop")
        XCTAssertEqual(asked, 3)
        let fromCopy = await Device.appMissing(copyFrom, app: answer(.present(url: here)))
        XCTAssertTrue(fromCopy, "a copy's own error says so")
        let other = await Device.appMissing(Failure("Developer Mode is off"), app: answer(.missing))
        XCTAssertFalse(other)
        XCTAssertEqual(asked, 3, "the device is asked only for an error that looks like a drop")
    }

    /// The main window's idle heading: open Slashplayed on the device, or, with it gone from there, Play.
    func testIdleHeadingWithTheAppMissing() {
        XCTAssertEqual(SetupStatus.idleHeading(noun: "iPhone", appMissing: false).title, "Open Slashplayed on the iPhone to play")
        XCTAssertEqual(SetupStatus.idleHeading(noun: "iPhone", appMissing: true).title, "Press Play to install Slashplayed on the iPhone")
        XCTAssertTrue(SetupStatus.idleHeading(noun: "iPhone", appMissing: true).detail.hasPrefix("Slashplayed isn't on the iPhone"))
    }

    /// devicectl's error for an install cut by a dropped connection: rc14's, to the unworn headset over
    /// Wi-Fi, as its companion.txt and the Mac's unified log have it, laid out as devicectl prints it.
    private let dropped = CommandFailed(command: "xcrun devicectl device install", result: CommandResult(status: 1, stdout: Data(), stderr: """
        ERROR: Connection with the remote side was unexpectedly closed : <dictionary: 0x1f9c4a028> { count = 1, transaction: 0, voucher = 0x0, contents =
        \t"XPCErrorDescription" => <string: 0x1f9c4a190> { string cache = 0x0, length = 22, contents = "Connection interrupted" }
        } (IXRemoteErrorDomain error 6 (0x06))
            SourceFileLine = 300
            NSLocalizedFailureReason = Unhandled error domain IXRemoteErrorDomain, code 6
            FunctionName = _IXHandleConnectionForInstallMessagesFromRemoteService_block_invoke
        """))

    /// Every drop shape captured on the unworn headset over Wi-Fi, each at a tunnel's cancel in the Mac's
    /// log (Device.dropSigns), as the call's stderr or the window's one line had it.
    private let drops: [(String, Error)] = [
        ("rc14's install", CommandFailed(command: "xcrun devicectl device install", result: CommandResult(status: 1, stdout: Data(), stderr: """
            ERROR: Connection with the remote side was unexpectedly closed : <dictionary: 0x1f9c4a028> { count = 1, transaction: 0, voucher = 0x0, contents =
            \t"XPCErrorDescription" => <string: 0x1f9c4a190> { string cache = 0x0, length = 22, contents = "Connection interrupted" }
            } (IXRemoteErrorDomain error 6 (0x06))
                SourceFileLine = 300
                NSLocalizedFailureReason = Unhandled error domain IXRemoteErrorDomain, code 6
            """))),
        // The window's one line, the end of devicectl's text (CommandFailed keeps its last 400 characters).
        ("rc15's install", Failure("""
            Couldn't install the client — xcrun devicectl device install exited with status 1: unctionName = _DiscoverRemoteDevice NSLocalizedFailureReason = Unhandled error domain IXRemoteErrorDomain, code 5 SourceFileLine = 68 ---------------------------------------- Failed to connect to remote device with UUID: <CFUUID 0x9da927de0> <uuid> (com.apple.mobiledevice error -402652910 (0xE8000112)) FunctionName = _AMDeviceCopyRemoteDeviceWithError LineNumber = 697
            """)),
        ("rc15's identity copy", CommandFailed(command: "xcrun devicectl device copy", result: CommandResult(status: 1, stdout: Data(), stderr: """
            ERROR: An unknown error occurred. (com.apple.dt.CoreDeviceError error -1 (0xFFFFFFFF))
            ----------------------------------------
            The connection to the remote device was interrupted. (com.apple.dt.remoteservices.error error -1 (0xFFFFFFFF))
            """))),
        ("a probe's file listing", CommandFailed(command: "xcrun devicectl device info files", result: CommandResult(status: 1, stdout: Data(), stderr: """
            ERROR: The operation couldn’t be completed. (CoreDevice.ActionError error 3.)
                   NSDebugDescription = This operation could not be performed due to an error in StreamingAction: The system failed to get a list of files on the remote device.
            """))),
        ("a probe's lockState", CommandFailed(command: "xcrun devicectl device info lockState", result: CommandResult(status: 1, stdout: Data(), stderr: """
            ERROR: The operation couldn’t be completed. (Network.NWError error 60 - Operation timed out)
                   NSDescription = Operation timed out
            """))),
        ("a probe's lockState: service", CommandFailed(command: "xcrun devicectl device info lockState", result: CommandResult(status: 1, stdout: Data(), stderr: """
            ERROR: An unknown error occurred. (com.apple.dt.CoreDeviceError error -1 (0xFFFFFFFF))
                   ----------------------------------------
                       Could not start service on device (com.apple.mobiledevice error -402653149 (0xE8000023))
            """))),
        // CoreDevice's own descriptions of the usage assertion every call takes first, from the Mac's log.
        ("the usage assertion: RSD", Failure("An unknown error occurred. (com.apple.dt.CoreDeviceError error -1 (0xFFFFFFFF)) Failed to allocate RSD device. (com.apple.mobiledevice error -402653181 (0xE8000003))")),
        ("the usage assertion: services", Failure("CoreDevice on-device services are no longer available on the device. (com.apple.dt.CoreDeviceError error 4011 (0xFAB))")),
        ("the usage assertion: reconnect", Failure("The device disconnected immediately after connecting. (com.apple.dt.CoreDeviceError error 4000 (0xFA0))")),
    ]

    func testADroppedConnectionIsRecognised() {
        for (what, error) in drops {
            XCTAssertTrue(Device.connectionDropped(error), what)
            // Its one-line form, as the window shows it.
            XCTAssertTrue(Device.connectionDropped(Failure(error.localizedDescription)), what)
        }
        func failed(_ stderr: String) -> CommandFailed {
            CommandFailed(command: "xcrun devicectl", result: CommandResult(status: 1, stdout: Data(), stderr: stderr))
        }
        // Not drops: a locked device (captured from the locked iPad), a missing app, an unreachable device.
        XCTAssertFalse(Device.connectionDropped(failed("ERROR: The operation failed because the device was still locked. (com.apple.dt.CoreDeviceError error 10003 (0x2713))")))
        XCTAssertFalse(Device.connectionDropped(failed("ERROR: The specified file could not be transferred. (com.apple.dt.CoreDeviceError error 7000 (0x1B58))\n----\nThe operation couldn’t be completed. (ContainerLookupErrorDomain error -1.)")))
        XCTAssertFalse(Device.connectionDropped(failed("ERROR: Not able to fulfill the requested usage assertion requirements. (com.apple.dt.CoreDeviceError error 4016 (0xFB0))")))
        XCTAssertFalse(Device.connectionDropped(failed("ERROR: The operation couldn’t be completed. (CoreDevice.ActionError error 3.)")))
        XCTAssertFalse(Device.connectionDropped(Failure("Developer Mode is off")))
        XCTAssertFalse(Device.connectionDropped(CancellationError()))
    }

    /// The plain heading and fix, per kind of device, never devicectl's text.
    func testADroppedConnectionSaysWhatToDo() {
        let headset = Device(name: "Vision Pro", udid: "h", kind: .headset).connectionDroppedProblem(during: "the install")
        XCTAssertEqual(headset.title, "Lost the connection to the headset")
        XCTAssertEqual(headset.message, "The connection to the headset dropped during the install. Keep it nearby and awake, then press Play again.")
        for kind in [Device.Kind.iPad, .iPhone] {
            let p = Device(name: "D", udid: "d", kind: kind).connectionDroppedProblem(during: "a copy")
            XCTAssertEqual(p.title, "Lost the connection to the \(kind.rawValue)")
            XCTAssertTrue(p.message.contains("dropped during a copy"), p.message)
            XCTAssertTrue(p.message.contains("connect it with a USB cable"), p.message)
            XCTAssertFalse(p.message.contains("XPC") || p.message.contains("devicectl"), p.message)
        }
    }

    /// A dropped call is tried again and then works, whichever shape the drop had; one that keeps dropping
    /// ends in the plain problem; any other error isn't retried.
    func testADroppedCallIsTriedAgain() async throws {
        let device = Device(name: "Vision Pro", udid: "h", kind: .headset)
        var tries = 0, lines: [String] = []
        for (what, error) in drops {
            tries = 0
            let result = try await device.retryingDrops(during: "the install", wait: .zero, log: { _ in }) {
                tries += 1
                if tries == 1 { throw error }
                return "installed"
            }
            XCTAssertEqual(result, "installed", what)
            XCTAssertEqual(tries, 2, what)
        }

        tries = 0
        try await device.retryingDrops(during: "the install", wait: .zero, log: { lines.append($0) }) {
            tries += 1
            if tries < Device.dropAttempts { throw dropped }
        }
        XCTAssertEqual(tries, Device.dropAttempts)
        XCTAssertEqual(lines.count, Device.dropAttempts - 1)
        XCTAssertTrue(lines[0].contains("dropped during the install; trying again (2 of \(Device.dropAttempts))"), lines[0])

        tries = 0
        do {
            try await device.retryingDrops(during: "a copy", wait: .zero, log: { _ in }) { tries += 1; throw dropped }
            XCTFail("no error")
        } catch let p as Signing.Problem {
            XCTAssertEqual(p.title, "Lost the connection to the headset")
            XCTAssertTrue(p.message.contains("during a copy"), p.message)
        }
        XCTAssertEqual(tries, Device.dropAttempts)

        tries = 0
        do {
            try await device.retryingDrops(during: "the install", wait: .zero, log: { _ in }) { tries += 1; throw Failure("other") }
            XCTFail("no error")
        } catch let f as Failure {
            XCTAssertEqual(f.message, "other")
        }
        XCTAssertEqual(tries, 1)
    }

    /// Device.retrying, inside retryingDrops for a copy or a listing, leaves a drop to it (no 3 s retries of
    /// its own) and passes its plain problem through.
    func testRetryingLeavesDropsToRetryingDrops() async throws {
        var tries = 0
        do {
            _ = try await Device.retrying { tries += 1; throw dropped }
            XCTFail("no error")
        } catch {
            XCTAssertTrue(Device.connectionDropped(error))
        }
        XCTAssertEqual(tries, 1)

        tries = 0
        let problem = Device(name: "Vision Pro", udid: "h", kind: .headset).connectionDroppedProblem(during: "a copy")
        do {
            _ = try await Device.retrying { tries += 1; throw problem }
            XCTFail("no error")
        } catch let p as Signing.Problem {
            XCTAssertEqual(p.title, problem.title)
        }
        XCTAssertEqual(tries, 1)
    }
}
