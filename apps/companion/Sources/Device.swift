import Foundation

/// A device the client runs on (a Vision Pro, an M1-or-later iPad or the A17 Pro iPad mini, or an
/// iPhone 15 Pro or later), and the client app's data container
/// on it, through `xcrun devicectl`. The devices are the ones paired with this Mac (Device.paired). Each
/// has its own platform (scripts/platform.sh's SP_PLATFORM), build (Paths.clientDir) and the games
/// (flavors) the user chose to hold on it (File > Games on).
struct Device: Identifiable, Hashable {
    /// The raw value is cached (Device.cached). The iPad and the iPhone share the ios platform and build.
    enum Kind: String { case headset, iPad, iPhone }

    let name: String
    let udid: String
    let kind: Kind

    /// Stands in until a device is paired: actions stop at once with Pipeline's "pair one" message.
    static let none = Device(name: "iPad, iPhone, or Vision Pro", udid: "", kind: .headset)

    /// The device app's bundle ID, from the user's team (Signing.bundleID). Pipeline picks the team before
    /// any action, so it's set by the time anything here runs.
    static var bundleID: String { Signing.bundleID }
    static let xcrun = "/usr/bin/xcrun"

    var id: String { udid }

    /// scripts/platform.sh's SP_PLATFORM (also the name of its bundled resources' and build's dirs).
    var platform: String { kind == .headset ? "xros" : "ios" }

    /// "headset", "iPad" or "iPhone", for the window's wording ("Copy game files to the headset").
    var noun: String { kind == .headset ? "headset" : kind.rawValue }

    /// The SF Symbol onboarding shows for the device.
    var symbol: String {
        switch kind {
        case .headset: "visionpro"
        case .iPad: "ipad"
        case .iPhone: "iphone"
        }
    }

    /// Whether this device's model (productType, from Device.details) can run the client. Every Vision Pro
    /// can.
    func isSupported(model: String?) -> Bool {
        switch kind {
        case .headset: true
        case .iPad: Self.isSupportedIPad(model: model)
        case .iPhone: Self.isSupportedIPhone(model: model)
        }
    }

    /// Why this device's model can't run the client, as onboarding and the device menus word it; nil when
    /// it can or the model isn't known. The Mac client is built for the M1's instruction set, so an older
    /// chip stops it at its first newer instruction, a moment after it loads (a 2018 iPad Pro did).
    func unsupportedReason(model: String?) -> String? {
        guard !isSupported(model: model) else { return nil }
        return kind == .iPhone ? "Not supported: Slashplayed needs an iPhone 15 Pro or later."
            : "Not supported: Slashplayed needs an iPad with an M1 chip or later, or the A17 Pro iPad mini."
    }

    /// The device an action works on: `target` (the one it was started for), else `pin` (the Device menu's
    /// UDID, "" for Automatic), whether or not either can run the client: they were picked by name, and the
    /// action then says why not. Automatic passes over a model known not to run it (`models`, by UDID): a
    /// reachable device, the last one used (`last`) if several are, else the last one used, or the first,
    /// to wait for. Only when no paired device can run the client does it pick from all of them, so the
    /// action says why. `.none` when nothing is paired.
    static func choose(from devices: [Device], target: String?, pin: String, last: String?,
                       reachable: Set<String>, models: [String: String]) -> Device {
        if let d = devices.first(where: { $0.udid == target }) ?? devices.first(where: { $0.udid == pin }) { return d }
        let supported = devices.filter { $0.isSupported(model: models[$0.udid]) }
        let pool = supported.isEmpty ? devices : supported
        let up = pool.filter { reachable.contains($0.udid) }
        return up.first { $0.udid == last } ?? up.first ?? pool.first { $0.udid == last } ?? pool.first ?? .none
    }

    // MARK: Games

    /// UserDefaults key of the games the user chose for the device: an array of Flavor raw values.
    var gamesKey: String { "games.\(udid)" }

    /// The flavors the user chose to hold on the device (File > Games on), Classic Era until they choose.
    /// Never empty.
    var flavors: [Flavor] {
        let chosen = Set((UserDefaults.standard.stringArray(forKey: gamesKey) ?? []).compactMap(Flavor.init))
        return chosen.isEmpty ? [.classicEra] : Flavor.allCases.filter(chosen.contains)
    }

    func setFlavors(_ flavors: [Flavor]) {
        guard !flavors.isEmpty else { return }
        UserDefaults.standard.set(Flavor.allCases.filter(flavors.contains).map(\.rawValue), forKey: gamesKey)
    }

    /// The chosen flavors installed on the Mac: the ones whose game data can be copied from it. Every
    /// chosen flavor is built and playable, installed or not (ClientBuild takes its client from Blizzard).
    var installedFlavors: [Flavor] { Flavor.installed.filter(flavors.contains) }

    /// UserDefaults key of the game Play starts on the device (the menu by Play): a Flavor raw value.
    var playGameKey: String { "playGame.\(udid)" }

    /// The game Play starts: the one last played or picked, while it's still chosen, else the first chosen
    /// one. Never nil in practice, as flavors is never empty.
    var playGame: Flavor? {
        let picked = UserDefaults.standard.string(forKey: playGameKey).flatMap(Flavor.init)
        return picked.flatMap { flavors.contains($0) ? $0 : nil } ?? flavors.first
    }

    func setPlayGame(_ flavor: Flavor) {
        UserDefaults.standard.set(flavor.rawValue, forKey: playGameKey)
    }

    // MARK: Copying game files

    /// Whether a new device copies its game files from the Mac (Settings > Games, File > Games on). Off:
    /// the device's client streams its game data from Blizzard itself (measured on the iPhone, Classic Era
    /// from an empty store: character select in 2.5 minutes, then smooth play; docs/research.md).
    static let copiesGameFilesByDefault = false

    /// UserDefaults key of the device's choice: a Bool, unset until it's made.
    var copyGameFilesKey: String { "copyGameFiles.\(udid)" }

    /// Whether Play copies the Mac's game files to the device. Off, it only sends what the client needs to
    /// start (GameFiles.plan). File > Copy Game Files copies either way.
    var copiesGameFiles: Bool { copiesGameFiles(UserDefaults.standard) }

    func copiesGameFiles(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: copyGameFilesKey) as? Bool ?? Self.copiesGameFilesByDefault
    }

    func setCopiesGameFiles(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: copyGameFilesKey)
    }

    /// Set once the devices known before copying became a choice were given it.
    static let copyGameFilesSettledKey = "copyGameFilesSettled"

    /// Copying used to be the only way: devices this companion already knew (`known`, Device.cached)
    /// keep copying. Runs once; a device first seen after that gets the default.
    static func keepCopyingOnKnownDevices(_ known: [Device], _ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: copyGameFilesSettledKey) else { return }
        for device in known where defaults.object(forKey: device.copyGameFilesKey) == nil {
            device.setCopiesGameFiles(true, defaults)
        }
        defaults.set(true, forKey: copyGameFilesSettledKey)
    }

    /// Chosen flavors the Mac doesn't have: a copy brings none of their game data (the device's client
    /// fetches it), and while there are any no archive is deleted (their archives can't be told apart from
    /// unused ones).
    var missingFlavors: [Flavor] { flavors.filter { !Flavor.installed.contains($0) } }

    /// Whether the device holds only some of the shared store's archives (casc_archives.py): not every
    /// flavor installed on the Mac is chosen.
    var holdsDataSubset: Bool { !Flavor.installed.allSatisfy(flavors.contains) }

    /// The space free on the device when the client last started, as the launcher wrote it to
    /// Library/spfree.txt (FreeSpace.Launcher). Nil if the client hasn't started since the launcher began
    /// writing it. The window asks freeSpaceNow (Pairing.swift), which brings it up to date for an iPad or
    /// iPhone usbmuxd lists.
    /// Throws AppMissing when Slashplayed isn't on the device (the window's idle heading then says to
    /// press Play to install it); nil for anything else that stops the read.
    func launcherFreeSpace() async throws(AppMissing) -> FreeSpace.Launcher? {
        let library: [String: (size: Int64, date: Date)]
        do {
            library = try await files(in: "Library", recursive: false)
        } catch let e as AppMissing {
            throw e
        } catch {
            return nil
        }
        guard library["spfree.txt"] != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spfree-\(udid)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "spfree.txt")
        try? FileManager.default.removeItem(at: url)
        guard (try? await fetch("Library/spfree.txt", to: url)) != nil,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FreeSpace.Launcher(text)
    }

    /// Runs `body` up to 3 times, 3 s apart, for calls that are safe to repeat. The connection sometimes
    /// fails once (as the headset was taken off: "The system failed to get a list of files on the remote
    /// device"); the same call works a moment later. A dropped connection is thrown at once, for the
    /// retryingDrops around it, which waits long enough for a new tunnel.
    static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        for _ in 1..<3 {
            do {
                return try await body()
            } catch let e as CancellationError {
                throw e
            } catch let e as AppMissing {
                // It won't come back by itself.
                throw e
            } catch where connectionDropped(error) || error is Signing.Problem {
                throw error
            } catch {
                try await Task.sleep(for: .seconds(3))
            }
        }
        return try await body()
    }

    /// Runs devicectl with its JSON result on stdout (its own messages go to stderr) and returns the
    /// "result" object.
    static func json(_ args: [String]) async throws -> [String: Any] {
        let r = try await Shell.run(xcrun, ["devicectl"] + args + ["--json-output", "-"])
        let obj = try JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        return obj?["result"] as? [String: Any] ?? [:]
    }

    /// LocalDevVPN, the loopback VPN the client's JIT helper reaches the device's own developer services
    /// through (apps/client/spjit.m), and its App Store page.
    static let localDevVPN = "com.jkcoxson.LocalDevVPN"
    static let localDevVPNStore = URL(string: "https://apps.apple.com/app/id6755608044")!

    /// Whether an app is installed, any app, not only ones this Mac installed (~1 s). Nil if
    /// the device couldn't be asked.
    func hasApp(_ bundleID: String) async -> Bool? {
        switch await app(bundleID) {
        case .missing: false
        case .present: true
        case .unknown: nil
        }
    }

    /// An app on the device, as devicectl lists it. `present`'s bundle URL is the folder the install put
    /// it in: every install, even of the same app, makes a new one (checked on the iPhone, 2026-10-25), so
    /// it says whether the app is still the install this Mac made (ClientBuild.installNeed).
    enum AppState: Equatable {
        case missing, present(url: String), unknown
    }

    /// The app's state on the device (~1 s on the headset or USB). The whole listing, not one filtered by
    /// bundle ID, so an answer cut short can be told from a missing app (appState).
    func app(_ bundleID: String) async -> AppState {
        guard let result = try? await Self.json(["device", "info", "apps", "--device", udid, "--include-all-apps"]),
              let apps = result["apps"] as? [[String: Any]] else { return .unknown }
        return Self.appState(bundleID, in: apps)
    }

    /// The app's state in devicectl's listing of every app. A listing without the device's built-in apps
    /// (Settings and the rest: default and not removable, 25 on the headset and 29 on the iPhone) is cut
    /// short, and says nothing about the app: rc7's run saw the headset's Slashplayed and LocalDevVPN
    /// both "missing" in one session and listed in the next, which made setup say "Not installed" and would
    /// have made Play install again.
    static func appState(_ bundleID: String, in apps: [[String: Any]]) -> AppState {
        guard apps.contains(where: { $0["defaultApp"] as? Bool == true && $0["removable"] as? Bool == false }) else {
            return .unknown
        }
        guard let app = apps.first(where: { $0["bundleIdentifier"] as? String == bundleID }) else { return .missing }
        return .present(url: app["url"] as? String ?? "")
    }

    /// What a copy into, or a read of, the app's data container fails with when the app isn't installed
    /// (deleted on the device, or never installed from this Mac), instead of devicectl's "The specified file
    /// could not be transferred (CoreDeviceError 7000) … (ContainerLookupErrorDomain error -1.)".
    struct AppMissing: LocalizedError {
        var noun: String
        var errorDescription: String? {
            "Slashplayed isn't installed on the \(noun). It may have been deleted there. Press Play to install it again."
        }

        /// Whether devicectl's error says the app's data container isn't there.
        static func matches(_ error: Error) -> Bool {
            let text = (error as? CommandFailed).map { $0.result.stderr } ?? error.localizedDescription
            return text.contains("ContainerLookupErrorDomain")
        }
    }

    /// What devicectl's errors say when the Mac's tunnel to a device over Wi-Fi dropped under a call. An
    /// unworn headset's tunnel fails its heartbeat every 30–75 s and remotepairingd makes a new one within
    /// 2–22 s (the Mac's log, rc14 and rc15), and a call that straddles a drop fails with whichever of these
    /// its step met (CoreDevice's analytics lines name each): an install with IXRemoteErrorDomain 6 (rc14) or
    /// 5 over com.apple.mobiledevice -402652910, kAMDRemoteConnectError (rc15); a copy from the device with
    /// remoteservices -1 (rc15's identity check); a file listing with "failed to get a list of files"
    /// (CoreDevice.ActionError 3, a probe of the unworn headset, each at a tunnel's cancel); the device usage
    /// assertion every call takes first, and lockState, with mobiledevice -402653181 (0xE8000003) or
    /// -402653149 (0xE8000023, "Could not start service": the probe's lockState) or -402653052 (0xE8000084, "This
    /// device is no longer connected", under CoreDeviceError -1: rc16's lockState), CoreDeviceError 4011 or
    /// 4000, or the tunnel's own timeout or reset. Left out: CoreDeviceError 10003 (locked: Pipeline.waitForUnlock), 7000 (no
    /// such file), and 4016 (the device isn't reachable at all).
    static let dropSigns = [
        "IXRemoteErrorDomain error 6", "Connection interrupted", "remote side was unexpectedly closed",
        "com.apple.mobiledevice error -402652910", "Failed to connect to remote device",
        "com.apple.dt.remoteservices.error error -1", "connection to the remote device was interrupted",
        "failed to get a list of files on the remote device",
        "com.apple.mobiledevice error -402653181", "Failed to allocate RSD device", "Could not allocate a resource",
        "com.apple.mobiledevice error -402653149",
        "com.apple.mobiledevice error -402653052", "This device is no longer connected",
        "CoreDeviceError error 4011", "on-device services are no longer available",
        "CoreDeviceError error 4000", "disconnected immediately after connecting",
        "connection to this device could not be established",
        "Network.NWError error 60", "Network.NWError error 54",
    ]

    /// Whether devicectl's error (or its stderr, `text`) says the connection dropped partway (dropSigns).
    static func connectionDropped(_ error: Error) -> Bool {
        connectionDropped(text: (error as? CommandFailed).map { $0.result.stderr } ?? error.localizedDescription)
    }

    static func connectionDropped(text: String) -> Bool {
        dropSigns.contains { text.contains($0) }
    }

    /// What a devicectl call (`what`: "the install", "a copy", "the launch") says when the connection
    /// dropped every time it was tried, instead of devicectl's dump.
    func connectionDroppedProblem(during what: String) -> Signing.Problem {
        let keep = kind == .headset ? "Keep it nearby and awake" : "Keep it nearby and unlocked, or connect it with a USB cable"
        return Signing.Problem(title: "Lost the connection to the \(noun)",
                               message: "The connection to the \(noun) dropped during \(what). \(keep), then press Play again.")
    }

    /// How many times retryingDrops tries a call, and how long it waits between: 30 s in all, past the
    /// longest the Mac took to make a new tunnel (22 s, rc15). Repeating a call is safe for every call
    /// that uses it (an install of the same app, a copy of the same file, a listing).
    static let dropAttempts = 4
    static let dropWait: Duration = .seconds(10)
    /// Where retryingDrops says it's trying again: companion.txt, set by Pipeline.
    static var log: (String) -> Void = { _ in }

    /// Runs `body`, a devicectl call on this device, up to `attempts` times while devicectl says the
    /// connection dropped (connectionDropped), `wait` apart, then fails with connectionDroppedProblem.
    /// Any other error is thrown as it is.
    func retryingDrops<T>(during what: String, attempts: Int = Device.dropAttempts, wait: Duration = Device.dropWait,
                          log: (String) -> Void = Device.log, _ body: () async throws -> T) async throws -> T {
        for attempt in 1...attempts {
            do {
                return try await body()
            } catch where Self.connectionDropped(error) {
                guard attempt < attempts else { break }
                log("[companion] the connection to the \(noun) dropped during \(what); trying again (\(attempt + 1) of \(attempts))")
                try await Task.sleep(for: wait)
            }
        }
        throw connectionDroppedProblem(during: what)
    }

    /// Runs a devicectl call on the app's data container, with a missing app's error made AppMissing. A copy
    /// says so itself (AppMissing.matches), but a file listing of a container that isn't there fails with
    /// "The system failed to get a list of files on the remote device" (CoreDevice.ActionError 3; a probe of
    /// the iPhone with a bundle ID it doesn't have, 2026-10-31), the very text a Wi-Fi drop gives a listing
    /// (dropSigns). So an error that looks like a drop asks the device for its apps (~1 s): an app that isn't
    /// listed is AppMissing, at once, rather than a drop retried for 30 s (rc19's run, with the app deleted
    /// on the iPhone, on Wi-Fi and on USB). A real drop usually cuts that listing too (unknown), and stays one.
    private func inContainer<T>(_ domain: Domain, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch where domain == .app {
            if await Self.appMissing(error, app: { await app(Self.bundleID) }) { throw AppMissing(noun: noun) }
            throw error
        }
    }

    /// Whether a devicectl call on the app's data container failed because the app isn't there
    /// (inContainer): its own error says so, or it looks like a drop and the device lists no such app
    /// (`app`, asked only then).
    static func appMissing(_ error: Error, app: () async -> AppState) async -> Bool {
        if AppMissing.matches(error) { return true }
        guard connectionDropped(error) else { return false }
        return await app() == .missing
    }

    /// What lockState says about a device. On the headset, unlocked means worn (lockState passcodeRequired:
    /// true once it's taken off); a launch while it's locked is held until it's put on, and then the client
    /// starts with no debugger attached and dies at the prepare stop. On the iPad it's the screen lock; a
    /// launch while locked fails at once (FBSOpenApplicationErrorDomain 7). Xcode's provisioning for the
    /// device waits a minute for a locked one, then fails.
    enum Lock: Equatable {
        case unlocked, locked
        /// The call met a Wi-Fi tunnel drop (dropSigns), which says nothing about the lock: ask again.
        /// An unworn headset's lockState drops about 1 call in 17 (rc16's run: mobiledevice -402653181 and
        /// -402653052, Network.NWError 60), and taking one for "unlocked" launched on a locked headset.
        case dropped
        /// devicectl couldn't be asked, or answered something else.
        case unknown
    }

    func lock() async -> Lock {
        // check: false, as a locked headset makes devicectl fail, with the answer in its JSON (lock(lockState:)).
        guard let r = try? await Shell.run(Self.xcrun, ["devicectl", "device", "info", "lockState", "--device", udid,
                                                   "--json-output", "-"], check: false),
              let output = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] else { return .unknown }
        return Self.lock(lockState: output)
    }

    /// devicectl lockState's whole JSON output, said as a Lock. An unworn headset doesn't answer
    /// passcodeRequired: the call fails with "The operation failed because the device was still locked"
    /// (CoreDeviceError 10003, from RemotePairingError 1016 "The device has not been unlocked recently";
    /// rc8's run, 2026-10-26), which is locked too. A failure with a drop sign, in the error's domain and
    /// code or anywhere in its text, is a drop.
    static func lock(lockState output: [String: Any]) -> Lock {
        if let required = (output["result"] as? [String: Any])?["passcodeRequired"] as? Bool { return required ? .locked : .unlocked }
        guard let error = output["error"] as? [String: Any] else { return .unknown }
        let signature = output["errorSignature"] as? String ?? ""
        if error["domain"] as? String == "com.apple.dt.CoreDeviceError" && error["code"] as? Int == 10003
            || signature.contains("RemotePairingError 1016") {
            return .locked
        }
        // The text devicectl prints says "<domain> error <code>" for the error and each underlying one; the
        // JSON has them apart, nested in userInfo's NSUnderlyingError.
        var text = signature
        var next: [String: Any]? = error
        while let e = next {
            text += "\n\(e["domain"] as? String ?? "") error \((e["code"] as? Int).map(String.init) ?? "")"
            next = ((e["userInfo"] as? [String: Any])?["NSUnderlyingError"] as? [String: Any])?["error"] as? [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: error), let all = String(data: data, encoding: .utf8) {
            text += "\n" + all
        }
        return connectionDropped(text: text) ? .dropped : .unknown
    }

    /// The paired devices the client can run on (Vision Pros, iPads and iPhones, not simulators), headsets
    /// first, and which of them CoreDevice can reach now. Unworn on a desk all day, the headset stays
    /// reachable (files copy, apps install) though apps don't launch; an iPad or iPhone while on USB. And
    /// each one's model (productType, iPhone17,1), by UDID, for the cable line (USBLink.supportsUSB3). Nil if
    /// devicectl couldn't be asked.
    static func paired() async -> (devices: [Device], reachable: Set<String>, models: [String: String])? {
        guard let result = try? await json(["list", "devices"]),
              let list = result["devices"] as? [[String: Any]] else { return nil }
        var devices: [Device] = [], reachable: Set<String> = [], models: [String: String] = [:]
        for d in list {
            let hardware = d["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = d["connectionProperties"] as? [String: Any] ?? [:]
            let kind: Kind
            switch (hardware["platform"] as? String, hardware["deviceType"] as? String) {
            case ("visionOS", _): kind = .headset
            case ("iOS", "iPad"): kind = .iPad
            case ("iOS", "iPhone"): kind = .iPhone
            default: continue
            }
            guard let udid = hardware["udid"] as? String, hardware["reality"] as? String != "simulated",
                  connection["pairingState"] as? String == "paired" else { continue }
            let name = (d["deviceProperties"] as? [String: Any])?["name"] as? String
            devices.append(Device(name: name ?? (kind == .headset ? "Vision Pro" : kind.rawValue), udid: udid, kind: kind))
            models[udid] = hardware["productType"] as? String
            // An unreachable device has no transport.
            if connection["transportType"] != nil { reachable.insert(udid) }
        }
        devices.sort { ($0.kind == .headset ? 0 : 1, $0.name) < ($1.kind == .headset ? 0 : 1, $1.name) }
        return (devices, reachable, models)
    }

    /// Whether Developer Mode is on (devicectl's developerModeStatus). Nil if devicectl doesn't say, as it
    /// doesn't for a device it hasn't connected to lately.
    func developerMode() async -> Bool? {
        guard let list = (try? await Self.json(["list", "devices"]))?["devices"] as? [[String: Any]],
              let d = list.first(where: { ($0["hardwareProperties"] as? [String: Any])?["udid"] as? String == udid }),
              let status = (d["deviceProperties"] as? [String: Any])?["developerModeStatus"] as? String else { return nil }
        return status == "enabled"
    }

    /// What onboarding shows about each paired device, by UDID: its model (productType, iPad14,5) and
    /// whether Developer Mode is on (nil when devicectl doesn't say). One devicectl call for all of them.
    static func details() async -> [String: (model: String?, developerMode: Bool?)] {
        guard let list = (try? await json(["list", "devices"]))?["devices"] as? [[String: Any]] else { return [:] }
        var details: [String: (model: String?, developerMode: Bool?)] = [:]
        for d in list {
            let hardware = d["hardwareProperties"] as? [String: Any] ?? [:]
            guard let udid = hardware["udid"] as? String else { continue }
            let status = (d["deviceProperties"] as? [String: Any])?["developerModeStatus"] as? String
            details[udid] = (hardware["productType"] as? String, status.map { $0 == "enabled" })
        }
        return details
    }

    /// Whether an iPad model (productType) can run the client: iPad14 and up (M2 or later, and the A17 Pro
    /// iPad mini, iPad16,1 and 16,2), less the A-chip iPads with under 8 GB numbered among them, plus the
    /// M1 iPads (isM1IPad). Two limits, as isSupportedIPhone's: the Mac client is built for the M1's
    /// instruction set, which the A12X/A12Z Pros lack (the client stopped at an undefined instruction on
    /// one), and it needs 8 GB, as the M2 iPads have, which the mini 6 (iPad14,1 and 14,2, A15, 4 GB), the
    /// 11th-generation iPad (iPad15,7 and 15,8, A16, 6 GB), and the A14 iPads numbered iPad13 (the
    /// 4th-generation Air, the 10th-generation iPad, 4 GB) lack. The mini 7 has the iPhone 15 Pro's A17 Pro
    /// and 8 GB, so it meets both. True for an unknown model, so only a known older one is warned about.
    static func isSupportedIPad(model: String?) -> Bool {
        guard let model, let m = model.firstMatch(of: /^iPad(\d+),(\d+)$/), let major = Int(m.1) else { return true }
        let under8GB: Set<String> = ["iPad14,1", "iPad14,2", "iPad15,7", "iPad15,8"]
        return (major >= 14 && !under8GB.contains(model)) || isM1IPad(model: model)
    }

    /// The M1 iPads: the 11-inch 3rd-generation Pro (iPad13,4 to 13,7), the 12.9-inch 5th-generation Pro
    /// (iPad13,8 to 13,11), and the 5th-generation Air (iPad13,16 and 13,17), as Xcode's simulator device
    /// types list them. They share iPad13 with A14 iPads that can't run the client, so they're listed. The M1
    /// predates TXM (it protects code with PPL), and the JIT path (debugger-prepare plus the RW alias,
    /// docs/internals/loading.md) runs there as on TXM devices. All have 8 GB or more, as the M2 iPads do.
    static func isM1IPad(model: String?) -> Bool {
        guard let model else { return false }
        return ["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
                "iPad13,16", "iPad13,17"].contains(model)
    }

    /// Whether an iPhone model (productType) is an iPhone 15 Pro or later: iPhone16,1 and up (15 Pro and
    /// Pro Max, every iPhone 16 including the 16e, the 17s). All have 8 GB, as the M2 iPads do, and a chip
    /// at least as recent; the iPhone 15 and 15 Plus (iPhone15,4 and 15,5, A16, 6 GB) are below. Only an
    /// iPhone 16 Pro (iPhone17,1) is tested. True for an unknown model, as isSupportedIPad.
    static func isSupportedIPhone(model: String?) -> Bool {
        guard let model, let m = model.firstMatch(of: /^iPhone(\d+),(\d+)$/), let major = Int(m.1) else { return true }
        return major >= 16
    }

    func isAvailable() async -> Bool { await Self.paired()?.reachable.contains(udid) ?? false }

    /// The devices last listed (UserDefaults "devices"), so the window and the Device menu have them before
    /// devicectl answers.
    static var cached: [Device] {
        get {
            (UserDefaults.standard.array(forKey: "devices") as? [[String]] ?? []).compactMap { a in
                a.count == 3 ? Kind(rawValue: a[2]).map { Device(name: a[0], udid: a[1], kind: $0) } : nil
            }
        }
        set { UserDefaults.standard.set(newValue.map { [$0.name, $0.udid, $0.kind.rawValue] }, forKey: "devices") }
    }

    /// Where on the device a file is: the app's data container, or the system's crash, jetsam and
    /// resource reports (all apps', read-only).
    enum Domain {
        case app, crashLogs

        var args: [String] {
            switch self {
            case .app: ["--domain-type", "appDataContainer", "--domain-identifier", Device.bundleID]
            case .crashLogs: ["--domain-type", "systemCrashLogs"]
            }
        }
    }

    /// Copies a Mac file into the app's data container, at `destination` (e.g. Library/x.plist).
    func copy(_ source: URL, to destination: String) async throws {
        try await retryingDrops(during: "a copy to the \(noun)") {
            try await Self.retrying {
                try await inContainer(.app) {
                    try await Shell.run(Self.xcrun, ["devicectl", "device", "copy", "to", "--device", udid] + Domain.app.args +
                                        ["--source", source.path, "--destination", destination])
                }
            }
        }
    }

    /// Copies a device file (a path in `domain`, e.g. Documents/spconsole.log) to `destination` on the Mac.
    func fetch(_ source: String, to destination: URL, from domain: Domain = .app) async throws {
        try await retryingDrops(during: "a copy from the \(noun)") {
            try await inContainer(domain) {
                try await Shell.run(Self.xcrun, ["devicectl", "device", "copy", "from", "--device", udid] + domain.args +
                                    ["--source", source, "--destination", destination.path])
            }
        }
    }

    /// The files under `subdirectory` of the app's data container (Documents, Library), or of `domain`
    /// (nil: all of it), by path relative to it.
    func files(in subdirectory: String?, recursive: Bool, domain: Domain = .app) async throws -> [String: (size: Int64, date: Date)] {
        let result = try await retryingDrops(during: "a file listing") {
            try await Self.retrying {
                try await inContainer(domain) {
                    try await Self.json(["device", "info", "files", "--device", udid] + domain.args +
                                        (subdirectory.map { ["--subdirectory", $0] } ?? []) + (recursive ? ["--recurse"] : []))
                }
            }
        }
        let iso = ISO8601DateFormatter(), isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var files: [String: (size: Int64, date: Date)] = [:]
        for f in result["files"] as? [[String: Any]] ?? [] {
            guard (f["resources"] as? [String: Any])?["isDirectory"] as? Bool == false,
                  let path = f["relativePath"] as? String,
                  let meta = f["metadata"] as? [String: Any],
                  let size = (meta["size"] as? NSNumber)?.int64Value,
                  let dateString = meta["lastModDate"] as? String,
                  let date = isoFraction.date(from: dateString) ?? iso.date(from: dateString) else { continue }
            files[path] = (size, date)
        }
        return files
    }

    /// The running client's pid (the launcher, this team's Slashplayed.app/slashplayed), if any.
    func clientPID() async throws -> Int? {
        let result = try await Self.json(["device", "info", "processes", "--device", udid])
        return Self.clientPID(in: result["runningProcesses"] as? [[String: Any]] ?? [], app: await app(Self.bundleID))
    }

    /// The client's pid in devicectl's process listing: the one running from this team's app (`app`, its
    /// bundle folder), since a device can hold two teams' Slashplayed.app, and Play stopped the paid team's
    /// running game before copying into the free team's (2026-11-09). A listing of apps cut short says
    /// nothing, so then any Slashplayed's is taken, as before, rather than copy under a running client.
    static func clientPID(in processes: [[String: Any]], app: AppState) -> Int? {
        if app == .missing { return nil }
        let executable = if case .present(let url) = app, let folder = URL(string: url) {
            folder.appending(path: "slashplayed").absoluteString
        } else { String?.none }
        return processes.first {
            let path = $0["executable"] as? String ?? ""
            return executable.map { path == $0 } ?? path.hasSuffix("/Slashplayed.app/slashplayed")
        }?["processIdentifier"] as? Int
    }

    /// Whether a provisioning profile is installed on the device (device-wide, not only this app's).
    /// devicectl doesn't say which certificates each lists; the Mac's copy of a profile does.
    func hasProfile(uuid: String) async throws -> Bool {
        Self.listsProfile(try await retryingDrops(during: "a profile check") {
            try await Self.json(["device", "profile", "list", "--device", udid, "--type", "provisioning"])
        }, uuid: uuid)
    }

    /// devicectl's `profile list` result names a profile. Upper case there, while the profile's own plist
    /// (Signing.profileInfo) and Xcode's file names have it in lower case, so the case is ignored: an exact
    /// match missed a profile the companion had just installed, and it installed the same one again.
    static func listsProfile(_ result: [String: Any], uuid: String) -> Bool {
        (result["provisioningProfiles"] as? [[String: Any]] ?? []).contains {
            ($0["uuid"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    /// Installs a provisioning profile device-wide, beside the app's own, with no reinstall (about a second).
    func installProfile(_ profile: URL) async throws {
        try await retryingDrops(during: "a profile install") {
            try await Shell.run(Self.xcrun, ["devicectl", "device", "profile", "install", "--device", udid, profile.path])
        }
    }

    func kill(pid: Int) async {
        _ = try? await Shell.run(Self.xcrun, ["devicectl", "device", "process", "signal", "--device", udid,
                                              "--pid", String(pid), "--signal", "SIGKILL"], check: false)
    }
}

/// A device's free space, by the measure its Settings app shows (iPhone Storage), which counts space iOS can
/// clear (caches, offloadable data) as free. Lockdown's figure, the only one the Mac can read, leaves that out:
/// 610 GB on an iPhone whose Settings said 805 GB (the rc9 run), so the footer, Settings' Games, onboarding,
/// and a copy's check disagreed with the device. The launcher writes both of the device's own figures at
/// each start (launcher.m write_free_space); their difference, added to lockdown's, gives Settings' now.
struct FreeSpace: Equatable {
    var bytes: Int64
    /// Only lockdown's figure is known (Slashplayed hasn't started on the device yet), so Settings shows
    /// more: what iOS can clear.
    var atLeast = false

    /// "805.25 GB free", or "at least 610.03 GB free" before the launcher's first figures.
    var text: String { (atLeast ? "at least " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " free" }

    /// Library/spfree.txt: the bytes free as Settings counts them, then (from rc10's launcher on) the bytes
    /// free outright, a line each.
    struct Launcher: Equatable {
        var free: Int64
        var outright: Int64?

        init(free: Int64, outright: Int64?) { (self.free, self.outright) = (free, outright) }

        init?(_ text: String) {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first, let free = Int64(first) else { return nil }
            self.free = free
            outright = lines.count > 1 ? Int64(lines[1]) : nil
        }
    }

    /// Settings' figure now, from lockdown's figure now and the launcher's last ones: lockdown's plus the
    /// space iOS could clear at the last start (it changes slowly; within ~3 GB of Settings on the iPhone,
    /// 2026-10-28). Without lockdown's, the launcher's own; without the launcher's difference (it hasn't
    /// started there, or an older launcher wrote one line), lockdown's, as a floor.
    static func now(lockdown: Int64?, launcher: Launcher?) -> FreeSpace? {
        guard let lockdown else { return launcher.map { FreeSpace(bytes: $0.free) } }
        guard let launcher, let outright = launcher.outright else { return FreeSpace(bytes: lockdown, atLeast: true) }
        return FreeSpace(bytes: lockdown + max(0, launcher.free - outright))
    }
}
