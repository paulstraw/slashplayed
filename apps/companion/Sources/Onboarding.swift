import AppKit
import Foundation
import Observation

/// First-run setup, one step at a time: everything Play needs that the user has to do by hand, checked
/// for them, with what to do when it isn't so. The main window replaces it once the user finishes (the
/// defaults key `onboarded`); Help > Setup Assistant shows it again. Play checks the same things itself
/// (Pipeline.start), so a setting changed later fails there with the same advice. A game install on the
/// Mac isn't one of them: every game's client comes from Blizzard's CDN (ClientBuild) and the game on the
/// device fetches its own data, so the install step only says what the Mac has, for the two things that
/// use it (Copy Game Files from This Mac and Play with My Mac's Battle.net), and always passes. The last
/// two steps act rather than check: the first install on each device (Pipeline.installForSetup), after
/// which Slashplayed opens on the device alone, and, optionally, Update Games on This Device.
@MainActor @Observable
final class Onboarding {
    static let doneKey = "onboarded"

    enum StepID: Int, CaseIterable, Identifiable {
        case xcode, account, device, helper, games, install, firstInstall, updates

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .xcode: "Xcode"
            case .account: "Apple Account"
            case .device: "Your devices"
            case .helper: "LocalDevVPN"
            case .games: "Games"
            case .install: "Game on this Mac (optional)"
            case .firstInstall: "Install Slashplayed"
            case .updates: "Updates on the device (optional)"
            }
        }
    }

    typealias Status = SetupStatus

    /// A paired device as the device step shows it.
    struct DeviceInfo: Identifiable {
        let device: Device
        let reachable: Bool
        let model: String?
        let developerMode: Bool?
        var id: String { device.udid }
        var supported: Bool { device.isSupported(model: model) }
    }

    let pipeline: Pipeline
    /// The step on screen; nil once every step is through (Ready).
    private(set) var current: StepID? = .xcode
    private(set) var status: [StepID: Status] = [:]
    private(set) var teams: [Signing.Team] = []
    /// Whether Xcode listed an Apple ID at the account step's last check.
    private(set) var signedIn = false
    private(set) var devices: [DeviceInfo] = []
    /// GameFiles.size by games ("classic_era+retail") for the games step; missing while worked out.
    private(set) var sizes: [String: Int64] = [:]
    /// Whether each connected device has LocalDevVPN (missing: not asked yet, or not connected).
    private(set) var localDevVPN: [String: Bool] = [:]
    /// Each device's free space, as its Settings counts it, once known (Device.freeSpaceNow).
    private(set) var freeSpace: [String: FreeSpace] = [:]
    /// Each usable device's install (ClientBuild.installNeed, the device asked when reachable), as of the
    /// install step's last check; missing while it's asked.
    private(set) var installed: [String: ClientBuild.InstallNeed] = [:]
    /// The device the install step is installing on (Pipeline.installForSetup), or pushing an identity to.
    private(set) var installing: String?
    private(set) var xcode: URL?

    private var watch: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
    }

    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    func status(_ id: StepID) -> Status { status[id] ?? .checking }

    // MARK: Navigation

    /// Starts at the first step (or the launch argument -setup-step <n>'s, 0-based, 8 for Ready: for
    /// checking a step, or a screenshot of it), and keeps checking the one on screen (every 3 s) for
    /// things the user fixes elsewhere: Xcode, its accounts, pairing, LocalDevVPN. Not the install step:
    /// the 3 s check would replace what it says about a folder the user picked that holds no game.
    func begin() {
        let args = CommandLine.arguments
        let first = args.firstIndex(of: "-setup-step").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        if let first {
            // The steps before it are checked first, for the games step's device list and the side list.
            current = StepID(rawValue: first)
            pipeline.appendLog("[setup] showing step \(first + 1) of \(StepID.allCases.count) (-setup-step)")
            Task {
                // The one shown first, then the ones before it.
                if let shown = current { await check(shown) }
                for step in StepID.allCases where step.rawValue < first { await check(step) }
            }
        } else {
            go(to: .xcode)
        }
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let step = self.current, [.xcode, .account, .device, .helper].contains(step) else { continue }
                await self.check(step)
            }
        }
    }

    func stop() {
        watch?.cancel()
        sizeTask?.cancel()
    }

    func go(to step: StepID?) {
        current = step
        pipeline.appendLog("[setup] showing \(step.map { "step \($0.rawValue + 1) of \(StepID.allCases.count), \($0.title)" } ?? "Ready")")
        guard let step else { return }
        Task { await check(step) }
    }

    func next() {
        guard let current else { return }
        go(to: StepID(rawValue: current.rawValue + 1))
    }

    func back() {
        guard let current else { return go(to: StepID.allCases.last) }
        if current.rawValue > 0 { go(to: StepID(rawValue: current.rawValue - 1)) }
    }

    /// Whether the team Slashplayed signs with is a free Personal Team, as of the account step.
    var teamIsFree: Bool { teams.first { $0.id == pipeline.teamID }?.isFree == true }

    /// Ready: the main window takes over.
    func finish() {
        pipeline.appendLog("[setup] finished: the main window takes over")
        stop()
        Self.isDone = true
    }

    // MARK: Checks

    func check(_ step: StepID) async {
        let result: Status
        switch step {
        case .xcode: result = await checkXcode()
        case .account: result = await checkAccount()
        case .device: result = await checkDevices()
        case .helper: result = await checkHelper()
        case .games: result = await checkGames()
        case .install: result = checkInstall()
        case .firstInstall: result = await checkFirstInstall()
        case .updates: result = await checkUpdates()
        }
        if let line = result.logLine(step.title, was: status[step]) { pipeline.appendLog(line) }
        status[step] = result
    }

    private func checkXcode() async -> Status {
        do {
            xcode = try await Signing.checkXcode()
            let version = xcode.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            return .ok("Xcode \(version ?? "") is installed and selected.")
        } catch let p as Signing.Problem {
            xcode = nil
            return .problem(p.title, p.message)
        } catch {
            return .problem("Couldn't check Xcode", error.localizedDescription)
        }
    }

    /// Xcode in /Applications, which the select command names.
    var xcodeInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Xcode.app") }

    /// The team from Xcode's preferences (Signing.pick), then the live check (Signing.checkTeam): the
    /// preferences can list an account whose sign-in is gone (Signing.xcodeListsAccount), which only a
    /// build finds out. Each check (the 3 s poll, Check Again) reads the preferences afresh, so a sign-in
    /// or sign-out in Xcode shows without a relaunch.
    private func checkAccount() async -> Status {
        var accounts = Signing.xcodeAccounts()
        // Signed out too: the preferences can list no account while Xcode has one, until a fetch rewrites them.
        if needsFetch(accounts) {
            await fetchTeams(accounts)
            accounts = Signing.xcodeAccounts()
        }
        teams = accounts.teams
        signedIn = accounts.signedIn
        // The team Play would sign with (and store), without storing it: picking it here does.
        let team: Signing.Team
        do {
            team = try Signing.pick(accounts, stored: pipeline.teamID)
            if pipeline.teamID != team.id { pipeline.teamID = team.id }
        } catch let p as Signing.Problem {
            // Signed out: the next sign-in is checked with a build again, whoever it is.
            if !accounts.signedIn { lastLiveCheck = nil }
            return .problem(p.title, p.message.replacingOccurrences(of: "in Settings > Signing", with: "below"))
        } catch {
            return .problem("Couldn't read Xcode's accounts", error.localizedDescription)
        }
        if let problem = await liveCheck(team, appleIDs: accounts.appleIDs) { return problem }
        let free = team.isFree ? " It's a free Personal Team: its signature lasts 7 days, and Play signs the app again after that." : ""
        return .ok("Slashplayed signs with \(team.name) (\(team.id)), as \(Signing.bundleID).\(free)")
    }

    /// The accounts the teams were last asked of Apple for (Signing.fetchTeams), and when.
    private var lastFetch: (key: String, at: Date)?
    private var fetchRunning = false

    /// Xcode's teams are asked for again when an account is added or removed, and, while none is listed
    /// (offline, say), every liveCheckRetry. Not at each 3 s poll: each ask is a ~2 s build.
    private func needsFetch(_ accounts: Signing.XcodeAccounts) -> Bool {
        guard !fetchRunning, let last = lastFetch, last.key == accounts.accountsKey else { return !fetchRunning }
        return accounts.teams.isEmpty && Date().timeIntervalSince(last.at) >= Self.liveCheckRetry
    }

    private func fetchTeams(_ accounts: Signing.XcodeAccounts) async {
        fetchRunning = true
        defer { fetchRunning = false }
        lastFetch = (accounts.accountsKey, Date())
        await pipeline.refreshTeams()
    }

    /// The live check's last answer: the team and bundle ID it checked, when, and its problem (nil: it
    /// passed). A pass holds for the session; a failure is checked again after liveCheckRetry, since the
    /// step polls every 3 s and a build takes 5–30 s.
    private var lastLiveCheck: (key: String, at: Date, problem: Status?)?
    private var liveCheckRunning = false
    static let liveCheckRetry: TimeInterval = 20

    /// What the live check depends on: the team, its free flag (which entitlements), the bundle ID, and
    /// how many Apple IDs Xcode lists (an account added or removed is checked again).
    static func liveCheckKey(_ team: Signing.Team, appleIDs: Int) -> String {
        "\(team.id) \(Signing.bundleID(forTeam: team.id)) \(team.isFree) \(appleIDs)"
    }

    /// Runs Signing.checkTeam for `team` unless it already passed (or failed moments ago); nil when it
    /// passed. While a check runs, another caller gets "checking" rather than a second build.
    private func liveCheck(_ team: Signing.Team, appleIDs: Int) async -> Status? {
        let key = Self.liveCheckKey(team, appleIDs: appleIDs)
        if let last = lastLiveCheck, last.key == key,
           last.problem == nil || Date().timeIntervalSince(last.at) < Self.liveCheckRetry { return last.problem }
        guard !liveCheckRunning else { return status[.account] ?? .checking }
        liveCheckRunning = true
        defer { liveCheckRunning = false }
        let work = FileManager.default.temporaryDirectory.appending(path: "Slashplayed-account-check")
        defer { try? FileManager.default.removeItem(at: work) }
        // Its xcodebuild lines go to ~/Library/Logs/Slashplayed/team-check.txt (in Export Diagnostics).
        let logFile = LogFile(Paths.logs.appending(path: "team-check.txt"), t0: Date())
        var problem: Status?
        do {
            try await Signing.checkTeam(team, stub: Paths.resource("signing"), work: work) { logFile.write($0) }
        } catch let p as Signing.Problem {
            problem = .problem(p.title, p.message)
        } catch {
            problem = .problem("Couldn't check signing with \(team.name)", error.localizedDescription)
        }
        lastLiveCheck = (key, Date(), problem)
        return problem
    }

    /// Picks a team here (several are signed in).
    func pickTeam(_ id: String) {
        pipeline.appendLog("[setup] team \(id) picked")
        pipeline.teamID = id
        Task { await check(.account) }
    }

    /// Whether the account step asks for a Team ID: Xcode lists an Apple ID but no team
    /// (Signing.xcodeListsAccount), as of the last check.
    var needsTeamID: Bool { teams.isEmpty && signedIn }
    private(set) var verifyingTeam = false
    private(set) var teamIDError: String?

    /// Checks a typed Team ID with a real stub build (Pipeline.verifyTeamID, ~10-30 s) and, if Xcode can
    /// sign with it, makes it the team.
    func useTeamID(_ typed: String) async {
        let id = typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        verifyingTeam = true
        teamIDError = nil
        defer { verifyingTeam = false }
        do {
            let team = try await pipeline.verifyTeamID(id)
            pipeline.teamID = team.id
            // That build was the live check: the account step needn't run another.
            lastLiveCheck = (Self.liveCheckKey(team, appleIDs: Signing.xcodeAccounts().appleIDs), Date(), nil)
            await check(.account)
        } catch let p as Signing.Problem {
            teamIDError = "\(p.title). \(p.message)"
        } catch {
            teamIDError = error.localizedDescription
        }
        pipeline.appendLog("[setup] typed Team ID \(id): " + (teamIDError ?? "checked with Xcode, and Slashplayed signs with it"))
    }

    private func checkDevices() async -> Status {
        guard let paired = await Device.paired() else {
            return .problem("Couldn't list devices", "devicectl, which comes with Xcode, didn't answer. Check the Xcode step, then try again.")
        }
        let details = await Device.details()
        devices = paired.devices.map {
            DeviceInfo(device: $0, reachable: paired.reachable.contains($0.udid),
                       model: details[$0.udid]?.model, developerMode: details[$0.udid]?.developerMode)
        }
        await pipeline.refreshDevices()
        // How to pair each kind of device is always on screen (OnboardingView's PairingHelp), so a second
        // device can be added after the first.
        if devices.isEmpty {
            return .problem("No device is paired yet", "Pair one as below. It shows up here on its own.")
        }
        let usable = devices.filter { $0.supported && $0.developerMode != false }
        if usable.isEmpty {
            if devices.allSatisfy({ !$0.supported }) {
                return .problem(devices.count == 1 ? "This \(devices[0].device.noun) can't run Slashplayed" : "These devices can't run Slashplayed",
                                "Slashplayed needs an iPad with an M1 chip or later, an iPhone 15 Pro or later, or a Vision Pro.")
            }
            return .problem("Developer Mode is off",
                            "On the device: Settings > Privacy & Security > Developer Mode (it shows there once the device is paired), then restart it when asked and confirm.")
        }
        return .ok("\(Self.list(usable.map(\.device.name))) \(usable.count == 1 ? "is" : "are") ready. To add another device, pair it as below.")
    }

    /// LocalDevVPN on each usable device that's connected: without it the JIT helper can't prepare the game
    /// (apps/client/spjit.m). The pairing itself needs nothing here: the first Play pairs an iPad or iPhone
    /// over USB (Pipeline.setUpHelper), and the headset pairs itself on its first launch (sppair.m). A
    /// device that isn't connected can't be asked, which doesn't hold the step up.
    private func checkHelper() async -> Status {
        if devices.isEmpty { _ = await checkDevices() }
        let usable = devices.filter { $0.supported && $0.developerMode != false }
        guard !usable.isEmpty else { return .problem("No device to set up", "Go back to the device step.") }
        for d in usable where d.reachable {
            if let has = await d.device.hasApp(Device.localDevVPN) { localDevVPN[d.id] = has }
        }
        let missing = usable.filter { localDevVPN[$0.id] == false }
        if !missing.isEmpty {
            return .problem("Install LocalDevVPN on \(Self.list(missing.map(\.device.name), or: true))",
                            "It's free on the App Store. Open it once and allow its VPN configuration.")
        }
        let found = usable.filter { localDevVPN[$0.id] == true }.map(\.device.name)
        let unknown = usable.filter { localDevVPN[$0.id] == nil }.map(\.device.name)
        let away = unknown.isEmpty ? "" : " \(Self.list(unknown)) \(unknown.count == 1 ? "isn't" : "aren't") connected, so it wasn't checked: install LocalDevVPN there too."
        // The step's lead says there's nothing to do now (OnboardingView); this says where it was found.
        return .ok((found.isEmpty ? "" : "LocalDevVPN is installed on \(Self.list(found)).") + away)
    }

    /// What the Mac has installed, if anything. Always passes: without an install every game still plays,
    /// streamed, and signs in on the device.
    private func checkInstall() -> Status {
        let root = Flavor.installRoot
        let installed = Flavor.installed
        guard !installed.isEmpty else {
            return .ok("Nothing to do: no game in \(root.path), and none is needed.")
        }
        let games = installed.map { f in ClientBuild.version(f).map { "\(f.name) \($0)" } ?? f.name }
        return .ok("Found \(Self.list(games)) in \(root.path).")
    }

    /// Takes a folder the user picked as the game install (Flavor.installRoot(picked:)).
    func pickInstall(_ folder: URL) -> Bool {
        guard let root = Flavor.installRoot(picked: folder) else {
            status[.install] = .problem("No game in \(folder.path)",
                                        "Choose the World of Warcraft folder Battle.net installed into (it holds _classic_era_, _anniversary_, _classic_, or _retail_), or skip this step.")
            return false
        }
        Self.setInstall(root)
        pipeline.installChanged()
        sizes = [:]
        status[.install] = checkInstall()
        return true
    }

    /// Stores the game install (nil: the default).
    static func setInstall(_ root: URL?) {
        if let root, root.standardizedFileURL != Flavor.defaultInstallRoot.standardizedFileURL {
            UserDefaults.standard.set(root.path, forKey: Flavor.installRootKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Flavor.installRootKey)
        }
        // Read now, as picking it just did (Flavor.installRoot(picked:)), so what's shown next is this
        // install's, not nothing until the next background read.
        GameInstall.shared.remember(.read(Flavor.installRoot))
    }

    private func checkGames() async -> Status {
        if devices.isEmpty { _ = await checkDevices() }
        let installed = Flavor.installed
        let usable = devices.filter { $0.supported && $0.developerMode != false }
        // A device the user hasn't chosen for yet holds Classic Era (Device.flavors), installed here or
        // not; when the Mac has other games and not that one, the first game it has.
        for d in usable where d.device.installedFlavors.isEmpty {
            if let first = installed.first { pipeline.setGame(first, on: true, for: d.device) }
        }
        refreshSizes()
        Task {
            for d in usable where d.reachable {
                if let free = await d.device.freeSpaceNow() { freeSpace[d.id] = free }
            }
        }
        guard !usable.isEmpty else { return .problem("No device to choose for", "Go back to the device step.") }
        return .ok("You can change these later in Settings (⌘,).")
    }

    /// The usable devices, in the device step's order.
    var usable: [DeviceInfo] { devices.filter { $0.supported && $0.developerMode != false } }

    /// Passes once one device holds this Mac's install: it can be played on, and the others can be
    /// installed later (from here, or by Play). A device that isn't connected counts as what this Mac's
    /// record of it says (ClientBuild.installNeed).
    private func checkFirstInstall() async -> Status {
        if devices.isEmpty { _ = await checkDevices() }
        guard !usable.isEmpty else { return .problem("No device to install on", "Go back to the device step.") }
        for d in usable {
            let need = await ClientBuild.installNeed(d.device, askDevice: d.reachable)
            if installed[d.id] != need {
                pipeline.appendLog("[setup] Slashplayed on \(d.device.name): \(SetupStatus.logName(need))"
                                   + (d.reachable ? "" : " (not reachable: this Mac's record)"))
            }
            installed[d.id] = need
        }
        return .firstInstall(usable.map { ($0.device.name, installed[$0.id] ?? .notOnDevice) })
    }

    /// The first install on `device` (Pipeline.installForSetup), then the step's check again.
    func install(on device: Device) {
        guard !pipeline.isBusy else { return }
        pipeline.appendLog("[setup] installing on \(device.name)")
        installing = device.udid
        pipeline.installForSetup(on: device)
        afterPipeline { await self.check(.firstInstall) }
    }

    /// The last step's toggle: Update Games on This Device for `device`, sent to it at once
    /// (Pipeline.pushIdentity), so it can update without a Play from this Mac first.
    func setUpdatesGames(_ on: Bool, for device: Device) {
        guard !pipeline.isBusy else { return }
        pipeline.setUpdatesGames(on, for: device)
        pipeline.appendLog("[setup] Update Games on This Device \(on ? "on" : "off") for \(device.name)")
        installing = device.udid
        pipeline.pushIdentity(to: device)
        afterPipeline { await self.check(.updates) }
    }

    /// Runs `then` once the action just started has finished.
    private func afterPipeline(_ then: @escaping () async -> Void) {
        Task {
            while pipeline.isBusy { try? await Task.sleep(for: .milliseconds(500)) }
            installing = nil
            await then()
        }
    }

    /// Optional, so it always passes: what's on now.
    private func checkUpdates() async -> Status {
        if devices.isEmpty { _ = await checkDevices() }
        let on = usable.filter { $0.device.updatesGames }.map(\.device.name)
        return .ok(on.isEmpty ? "Off on every device. You can turn it on later in Settings."
                   : "On for \(Self.list(on)).")
    }

    static func list(_ names: [String], or: Bool = false) -> String { SetupStatus.list(names, or: or) }

    /// Ticks or unticks a game for a device here.
    func setGame(_ flavor: Flavor, on: Bool, for device: Device) {
        pipeline.setGame(flavor, on: on, for: device)
        refreshSizes()
    }

    /// Works out (a few seconds each, off the main thread) each installed game's size alone and each
    /// device's chosen installed games' size together (shared archives counted once): what a copy from
    /// this Mac sends. A game that isn't installed here has no size to show; it streams.
    private func refreshSizes() {
        let installed = Flavor.installed
        var wanted = installed.map { [$0] }
        for d in devices { wanted.append(d.device.installedFlavors) }
        let missing = wanted.filter { !$0.isEmpty && sizes[Self.key($0)] == nil }
        guard !missing.isEmpty else { return }
        sizeTask?.cancel()
        sizeTask = Task {
            for games in missing where sizes[Self.key(games)] == nil {
                guard let size = try? await GameFiles.size(of: games), !Task.isCancelled else { return }
                sizes[Self.key(games)] = size
            }
        }
    }

    static func key(_ games: [Flavor]) -> String { games.map(\.rawValue).joined(separator: "+") }

    func size(_ games: [Flavor]) -> Int64? { sizes[Self.key(games)] }

    /// A device's games, read so a view showing them updates when they change (Pipeline.gamesRevision).
    func games(_ d: DeviceInfo) -> [Flavor] {
        _ = pipeline.gamesRevision
        return d.device.flavors
    }

    /// What to warn about a device's games: Retail on an iPad or iPhone, and more than the free space once known.
    func warnings(for d: DeviceInfo) -> [String] {
        var warnings: [String] = []
        if d.device.kind != .headset, games(d).contains(.retail) {
            warnings.append(Flavor.retailNote(noun: d.device.noun, free: freeSpace[d.id]))
        }
        // Only a device that copies the Mac's game files needs room for them up front.
        if d.device.copiesGameFiles, let free = freeSpace[d.id], let need = size(d.device.installedFlavors), need > free.bytes {
            warnings.append("These need \(Self.bytes(need)); the \(d.device.noun) has \(free.text). Files already there count, so the copy may still fit; if not, it stops before it starts.")
        }
        return warnings
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
