import Foundation
import Observation

/// The steps behind the Play button. Each one shows as a line in the window; the current one is the
/// headline. The flavor is the one the menu by Play picks, or with Play with My Mac's Battle.net, whichever
/// game Battle.net launches. The device is the one the Device menu picks, or (Automatic) whichever paired
/// device is reachable, the last one used if several are.
@MainActor @Observable
final class Pipeline {
    static let shared = Pipeline()

    enum StepID: CaseIterable {
        case battleNet, token, build, device, install, files, sendLogin, start, prepare, running

        /// Play with My Mac's Battle.net's alone: the window doesn't list them otherwise (freshSteps).
        static let battleNetOnly: Set<StepID> = [.battleNet, .token]
    }

    enum StepState {
        case pending, active, waitingOnUser, done, failed
    }

    struct Step: Identifiable {
        let id: StepID
        var title: String
        var state: StepState = .pending
        var detail: String?
        /// 0...1, for a step that copies.
        var progress: Double?
    }

    /// UserDefaults keys: the Device menu's choice (a UDID, or "" for Automatic), and the device last used.
    static let devicePinKey = "device"
    static let lastDeviceKey = "lastDevice"

    private(set) var device: Device
    /// The paired devices (Device.paired), for the Device menu; refreshed with the device.
    private(set) var devices = Device.cached
    private(set) var steps: [Step]
    private(set) var flavor: Flavor?
    private(set) var deviceAvailable: Bool?
    /// The Device menu's choice: a UDID, or "" for Automatic. Takes effect at the next action.
    var devicePin: String = UserDefaults.standard.string(forKey: Pipeline.devicePinKey) ?? "" {
        didSet {
            UserDefaults.standard.set(devicePin, forKey: Self.devicePinKey)
            if !isBusy { Task { await chooseDevice() } }
        }
    }
    /// The teams signed in to Xcode (Signing.teams), for Settings' team; read again with the device, and
    /// asked of Apple by refreshTeams.
    private(set) var teams = Signing.teams()
    /// Whether refreshTeams is asking Xcode for the teams.
    private(set) var fetchingTeams = false
    /// Settings' (or onboarding's) team (Signing.teamKey): what the device app is signed with, and its bundle ID's
    /// prefix unless one is set. "" until the first action picks one (Signing.resolveTeam).
    var teamID: String = UserDefaults.standard.string(forKey: Signing.teamKey) ?? "" {
        didSet { UserDefaults.standard.set(teamID, forKey: Signing.teamKey) }
    }
    private(set) var log: [String] = []
    /// The device's games (Settings > Games). Change them with setGame.
    private(set) var games: [Flavor]
    /// The game Play starts on the device (Device.playGame; the menu by Play). Change it with setPlayGame.
    private(set) var playGame: Flavor?
    /// Whether Play copies game files to the device (Device.copiesGameFiles). Change it with setCopiesGameFiles.
    private(set) var copiesGameFiles: Bool
    /// Whether the device may update its games itself (Device.updatesGames), which puts a signing identity on
    /// it (DeviceIdentity). Change it with setUpdatesGames.
    private(set) var updatesGames: Bool
    /// The device's games an update on it put ahead of the image the companion installed (ClientBuild.
    /// deviceUpdate), by version, as the last action found them: the main window says so.
    private(set) var updatedOnDevice: [Flavor: String]
    /// What's wrong with the signing identity a device updates its games with (sendIdentityIfNeeded: expired,
    /// revoked, or a replacement the person refused to export) and what to do, for the main window; nil when
    /// nothing is, as of the last Play or Update Client.
    var identityNotice: String? { identityNotices[device.udid] }
    private var identityNotices: [String: String] = [:]
    /// The Slashplayed certificate's standing (DeviceIdentity.standing), for Settings; nil until checked.
    private(set) var certificateStanding: DeviceIdentity.Standing?
    /// Moves on whenever any device's games change: views that list every device's games (onboarding,
    /// Settings) read it, since Device.flavors is in UserDefaults, which SwiftUI doesn't watch.
    private(set) var gamesRevision = 0
    /// The Slashplayed certificate (SlashplayedCertificate: a paid team's key for devices, B), for Settings:
    /// its state is in a keychain, which SwiftUI doesn't watch, so it's read again whenever this moves on.
    private(set) var certificate = SlashplayedCertificate.state
    /// What the games need on the device (GameFiles.size); nil while it's worked out, or if that failed.
    private(set) var gamesSize: Int64?
    /// The device's free space, as its Settings app counts it (Device.freeSpaceNow: now for an iPad or
    /// iPhone the Mac can reach, else when the client last started).
    var freeSpace: FreeSpace? { freeSpaces[device.udid] }
    /// Every device's, by UDID, as last read: Settings' Games warns about Retail by them.
    private(set) var freeSpaces: [String: FreeSpace] = [:]
    /// The devices Slashplayed was last found missing on (deleted there, or never installed), by UDID: the
    /// free-space read of its data container (Device.AppMissing) or the install check says so, and an
    /// install clears it. The idle heading then says to press Play, not to open Slashplayed on the device.
    private var appMissing: Set<String> = []
    var deviceAppMissing: Bool { appMissing.contains(device.udid) }
    /// Each iPad's and iPhone's USB link, by UDID, as last read (refreshUSBLink); none while it isn't on USB.
    private var usbLinks: [String: USBLink] = [:]
    /// Each device's copy speed (bytes/s), as measured by the running or last copy over its current link
    /// (syncGameFiles; dropped when the link changes): a copy faster than USB 2 can go hides the cable line.
    private var copyRates: [String: Double] = [:]
    /// Each paired device's model (productType), by UDID, from the last device listing (Device.paired).
    private var models: [String: String] = [:]
    /// Why `device` can't run the client (Device.unsupportedReason), by its model as last listed: the
    /// device menus list it disabled, and an action on it stops at once (start). Nil when it can, or before
    /// its model is known.
    func unsupportedReason(_ device: Device) -> String? { device.unsupportedReason(model: models[device.udid]) }
    /// The device copies game files from this Mac over a USB 2 link it could beat with a USB 3 cable
    /// (USBLink.slowCable): the main window says so by the device's status, whether or not a copy is running.
    var slowCable: Bool {
        USBLink.slowCable(usbLinks[device.udid], kind: device.kind, model: models[device.udid],
                          copying: copiesGameFiles && !Flavor.installed.isEmpty, copyRate: copyRates[device.udid])
    }
    /// Space the last sync listed for deletion (unticked games' archives, old indexes), freed when the
    /// client next starts.
    private(set) var pendingFree: Int64 = 0
    /// An action (Play through the game session, a sync, a build, an export) is running. Sparkle holds a
    /// scheduled update prompt until it's false again (Updater).
    private(set) var isBusy = false {
        didSet { if isBusy != oldValue { Updater.shared.busyChanged(isBusy) } }
    }
    /// The client is running on the device.
    private(set) var isRunning = false
    /// A launch failed after the token was sent; it can be retried without a new one.
    private(set) var canRetryLaunch = false
    /// When the device build's profile runs out (ClientBuild.profile), for the main window's warning
    /// within Signing.renewWithin of it. A free team's lasts 7 days; the next Play or Update Client renews it.
    private(set) var profileExpires: Date?
    /// The last build stopped on a game version this companion doesn't support yet (BindCheck): the
    /// pre-filled "New game patch broke it" issue to offer.
    private(set) var unsupportedIssue: URL?
    /// The folder the last Pull Device Logs saved to (DeviceLogs), to show in Finder.
    private(set) var pulledLogs: URL?
    /// Export Diagnostics is running (isBusy too), and the zip it last wrote, to show in Finder.
    private(set) var isExporting = false
    /// What the export is doing, for the window while it runs: pulling the device's logs can take minutes.
    private(set) var exportStatus: String?
    private(set) var diagnosticsZip: URL?
    /// Why the last Export Diagnostics failed, or what it left out (the device's logs).
    private(set) var diagnosticsNote: String?

    private var task: Task<Void, Never>?
    /// The device an action was started for (start(on:)), ahead of the Device menu's choice, until the
    /// action has picked it.
    private var target: String?
    private let launcher = ClientLauncher()
    private var launch: TokenRelay.Launch?
    /// The user pressed Stop Client.
    private var stopping = false
    private var sizeTask: Task<Void, Never>?
    /// Each game's current build on Blizzard's patch service, from the build step's check
    /// (ClientBuild.check), for the files step's .build.info rows.
    private var latest: [Flavor: BlizzardCDN.Version] = [:]
    /// The products whose update on the device is ahead of its installed image (checkDeviceUpdates), for the
    /// files step: their .build.info rows and configs stay the device's.
    private var aheadProducts: [String] = []
    /// The log, and each step's outcome, for this run of the app.
    private let logFile = LogFile(Paths.logs.appending(path: "companion.txt"), t0: Date())
    /// GameFiles.size by games and install date.
    private var sizeCache: [String: Int64] = [:]

    init() {
        // A devicectl call that's tried again after a dropped connection says so here, wherever it ran.
        Device.log = { line in Task { @MainActor in Pipeline.shared.appendLog(line) } }
        let last = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        let devices = Device.cached
        // Before anything lists devices again, so only ones known before this version keep copying.
        Device.keepCopyingOnKnownDevices(devices)
        let device = devices.first { $0.udid == last } ?? devices.first ?? .none
        self.device = device
        games = device.flavors
        playGame = device.playGame
        copiesGameFiles = device.copiesGameFiles
        updatesGames = device.updatesGames
        updatedOnDevice = ClientBuild.aheadOnDevice(device)
        steps = Self.freshSteps(device)
        launcher.onLog = { [weak self] in self?.appendLog($0) }
        // A launch made again after a drop waits for the unlock as the first one did: the headset may have
        // been taken off since (rc16's run).
        launcher.beforeRelaunch = { [weak self] in _ = try await self?.waitForUnlock(.start, to: "start the client") }
        launcher.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .starting(let attempt):
                if attempt > 1 { self.set(.prepare, .pending, title: "Prepare code pages") }
                self.set(.start, .active, title: "Starting client on \(self.device.noun)…",
                         detail: attempt > 1 ? "devicectl didn't attach to its console; attempt \(attempt) of \(ClientLauncher.attempts)." : nil)
            case .pairing:
                self.set(.start, .active, title: "Pair on the \(self.device.noun)",
                         detail: "Slashplayed pairs with the headset once. On the headset, open Settings > General > "
                             + "Remote Devices and type the code it shows into Slashplayed.")
            case .waitingForVPN:
                self.set(.start, .active, title: "Turn on LocalDevVPN on the \(self.device.noun)",
                         detail: "It's off, and Slashplayed reaches the \(self.device.noun)'s developer services through it. "
                             + "Slashplayed opens it to turn it on; the game starts once it's on.")
            case .newerBuild(let flavor):
                self.set(.start, .waitingOnUser, title: "A newer \(flavor.name) is out",
                         detail: "Blizzard put out a newer build since the \(self.device.noun)'s game was built. Stop the client and "
                             + "press Play again to build it; or press Play Anyway on the \(self.device.noun).")
            case .preparing:
                // The launcher deleted the listed files and wrote the free space.
                self.pendingFree = 0
                Task { await self.refreshFreeSpace() }
                self.set(.start, .done, title: "Client started")
                self.set(.prepare, .active, title: "Preparing code pages…",
                         detail: "The helper on the \(self.device.noun) is attached; this takes a few seconds.")
            }
        }
        // The first line of companion.txt, at launch: which companion and Mac, before anything else runs.
        let info = Bundle.main.infoDictionary ?? [:]
        appendLog("[companion] Slashplayed Companion \(info["CFBundleShortVersionString"] as? String ?? "?") "
                  + "(\(info["CFBundleVersion"] as? String ?? "?")) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); "
                  + (Onboarding.isDone ? "device: \(device == .none ? "none yet" : device.name)" : "setup isn't finished, so Setup Assistant opens"))
        // The install's snapshot (GameInstall) is last run's until this read comes back.
        GameInstall.shared.onChange = { [weak self] in self?.installChanged() }
        GameInstall.refresh()
        refreshGamesSize()
        Task { await watchDevice() }
    }

    // MARK: Games

    /// Ticks or unticks a game for any paired device (onboarding and Settings list them all). The last one
    /// can't be unticked.
    func setGame(_ flavor: Flavor, on: Bool, for device: Device) {
        let current = device.flavors
        let new = on ? current + [flavor] : current.filter { $0 != flavor }
        guard !isBusy, !new.isEmpty else { return }
        device.setFlavors(new)
        gamesRevision += 1
        if device == self.device {
            games = device.flavors
            playGame = device.playGame
            refreshGamesSize()
        }
    }

    /// Picks the game Play starts on the device; also while the client runs, for the Play that stops it.
    func setPlayGame(_ flavor: Flavor) {
        guard !isBusy || isRunning else { return }
        device.setPlayGame(flavor)
        playGame = device.playGame
    }

    /// Turns Copy Game Files from This Mac on or off for a device (Settings > Games).
    func setCopiesGameFiles(_ on: Bool, for device: Device) {
        guard !isBusy else { return }
        device.setCopiesGameFiles(on)
        gamesRevision += 1
        if device == self.device {
            copiesGameFiles = on
            steps = Self.freshSteps(device)
            refreshGamesSize()
        }
    }

    /// Turns Update Games on This Device on or off for a device (Settings, onboarding), once the person
    /// has read what it sends (the caller asks). Takes effect at the next Play, Update Client, or
    /// -push-identity with the device reachable: on sends the identity, off asks the device to delete it.
    func setUpdatesGames(_ on: Bool, for device: Device) {
        guard !isBusy else { return }
        storeUpdatesGames(on, for: device)
    }

    /// The setting itself, also for sendIdentityIfNeeded, which turns it off while it runs (isBusy).
    private func storeUpdatesGames(_ on: Bool, for device: Device) {
        device.setUpdatesGames(on)
        gamesRevision += 1
        if device == self.device { updatesGames = on }
    }

    /// The game install changed (Settings, onboarding, or a read found it changed: GameInstall.onChange):
    /// what the games need is worked out again.
    func installChanged() {
        refreshGamesSize()
        // The files step's title says whether Play copies, which needs a game here.
        if !isBusy { steps = Self.freshSteps(device) }
    }

    /// Asks Xcode for every signed-in account's teams (Signing.fetchTeams, ~2 s), for Settings' menu: an
    /// account added in Xcode since, a Personal Team included, shows without a relaunch. Also when the
    /// preferences list no account: the fetch brings them up to date with Xcode's accounts.
    func refreshTeams() async {
        guard !fetchingTeams else {
            teams = Signing.teams()
            return
        }
        fetchingTeams = true
        defer { fetchingTeams = false }
        await Signing.fetchTeams(stub: Paths.resource("signing"),
                                 work: FileManager.default.temporaryDirectory.appending(path: "Slashplayed-team-list")) {
            self.appendLog("[companion] \($0)")
        }
        teams = Signing.teams()
    }

    /// Checks a typed Team ID with a real stub build (Signing.verifyTeam, ~10-30 s) and keeps it as the
    /// entered team, listed with Xcode's (Signing.merged). Choosing it is the caller's: Settings asks first.
    func verifyTeamID(_ id: String) async throws -> Signing.Team {
        let work = FileManager.default.temporaryDirectory.appending(path: "Slashplayed-team-check")
        defer { try? FileManager.default.removeItem(at: work) }
        // Its xcodebuild lines go to ~/Library/Logs/Slashplayed/team-check.txt (in Export Diagnostics).
        let logFile = LogFile(Paths.logs.appending(path: "team-check.txt"), t0: Date())
        let team = try await Signing.verifyTeam(id, stub: Paths.resource("signing"), work: work) { logFile.write($0) }
        Signing.enteredTeam = team
        teams = Signing.teams()
        appendLog("[companion] team: \(team.id) checked with Xcode\(team.isFree ? " (a free Personal Team)" : "")")
        return team
    }

    /// Lists the paired devices and Xcode's teams again now, rather than at the next 15 s check.
    func refreshDevices() async {
        if !isBusy { await chooseDevice() }
    }

    /// Works out what the games need, off the main thread (a few seconds), unless it's cached. Only for a
    /// device that copies them (the main window shows the size only then): it reads all of the install's
    /// Data/, which a stalled drive would hold.
    private func refreshGamesSize() {
        sizeTask?.cancel()
        let games = copiesGameFiles ? games.filter(Flavor.installed.contains) : []
        let key = games.map(\.rawValue).joined(separator: "+") + "@\(Flavor.installRoot.path)@\(GameFiles.installDate?.timeIntervalSince1970 ?? 0)"
        if let cached = sizeCache[key] {
            gamesSize = cached
            return
        }
        gamesSize = nil
        guard !games.isEmpty else { return }
        sizeTask = Task {
            guard let size = try? await GameFiles.size(of: games), !Task.isCancelled else { return }
            sizeCache[key] = size
            gamesSize = size
        }
    }

    private func refreshFreeSpace() async {
        let device = device
        let (free, missing) = await device.freeSpaceAndApp()
        freeSpaces[device.udid] = free
        setAppMissing(missing, on: device)
    }

    private func setAppMissing(_ missing: Bool, on device: Device) {
        guard missing != appMissing.contains(device.udid) else { return }
        if missing {
            appMissing.insert(device.udid)
            appendLog("[companion] Slashplayed isn't on the \(device.noun) (deleted there, or not installed yet); Play installs it")
        } else {
            appMissing.remove(device.udid)
        }
    }

    /// Every reachable device's free space, for Settings' Games (a device that's away keeps its last).
    func refreshAllFreeSpace() async {
        let reachable = await Device.paired()?.reachable ?? []
        for device in devices where reachable.contains(device.udid) {
            if let free = await device.freeSpaceNow() { freeSpaces[device.udid] = free }
        }
    }

    /// The step the headline shows: the failed one, else the one in progress, else the last finished.
    var current: Step? {
        steps.first { $0.state == .failed } ??
            steps.first { $0.state == .active || $0.state == .waitingOnUser } ??
            steps.last { $0.state == .done }
    }

    // MARK: Actions

    /// Play: the game the menu by Play picks, signed in on the device (its saved Battle.net sign-in, or its
    /// sign-in screen the first time), with no Battle.net on the Mac.
    func play() {
        if isRunning { return afterStopping(play) }
        start(StepID.allCases.filter { !StepID.battleNetOnly.contains($0) }) { try await self.playSteps(viaBattleNet: false) }
    }

    /// Play with My Mac's Battle.net: the game Battle.net launches, with the launch credentials it makes,
    /// relayed to the device. The way in if the device's own sign-in stops working.
    func playWithBattleNet() {
        if isRunning { return afterStopping(playWithBattleNet) }
        start(StepID.allCases) { try await self.playSteps(viaBattleNet: true) }
    }

    /// Play (either kind) while the client runs: the window offers it, so another game starts without
    /// Stop Client first (the rc6 run). Stops the client the way Stop Client does, waits for that run to
    /// end, then starts `next`.
    private func afterStopping(_ next: @escaping () -> Void) {
        let running = task
        appendLog("[companion] Play while the client runs: stopping it first")
        cancel()
        Task {
            await running?.value
            next()
        }
    }

    /// Copies the Mac's game files to the device for its games, without playing, whether or not Play
    /// copies them (Device.copiesGameFiles). The files go into the app's data container, so the app is
    /// built and installed first if it isn't yet.
    func copyGameFiles() {
        start([.build, .device, .install, .files]) {
            try await self.updateBuild(for: nil)
            try await self.waitForDevice()
            try await self.installBuild()
            try await self.checkDeviceUpdates()
            try await self.syncGameFiles(self.device.flavors, copy: true)
        }
    }

    /// Rebuilds the device's client if Blizzard has a newer build of any of its games, and installs it,
    /// without playing.
    func updateClient() {
        start([.build, .device, .install]) {
            try await self.updateBuild(for: nil)
            try await self.waitForDevice()
            try await self.installBuild()
            try await self.checkDeviceUpdates()
            try await self.setUpHelper()
            try await self.sendIdentityIfNeeded()
        }
    }

    /// Setup Assistant's install step: what Play does before it starts the client, for every game ticked
    /// for `device`, so Slashplayed opens on the device alone afterwards. The build, the install, the
    /// helper's disk image and (iPad, iPhone) USB pairing, the signing identity if asked for, each game's
    /// build files, and the login identity file (the addons come with the app). Never a copy of the Mac's game files, which
    /// can take an hour: the device streams, and Play copies when copying is on.
    func installForSetup(on device: Device) {
        start([.build, .device, .install, .files, .sendLogin], on: device) {
            try await self.updateBuild(for: nil)
            try await self.waitForDevice()
            try await self.installBuild()
            try await self.checkDeviceUpdates()
            try await self.setUpHelper()
            try await self.sendIdentityIfNeeded()
            try await self.syncGameFiles(self.device.flavors, copy: false)
            try await self.sendLoginFiles(nil)
        }
    }

    /// -push-identity: what Play and Update Client do about the device's signing identity (DeviceIdentity),
    /// alone, with what's built and installed now. The log says what it did. Setup Assistant's last step
    /// runs it for the device whose Update Games on This Device it just changed (`device`).
    func pushIdentity(to device: Device? = nil) {
        start([.device], on: device) {
            try await self.waitForDevice()
            try await self.sendIdentityIfNeeded()
        }
    }

    /// Settings' Make Certificate Request (and -certificate-request): the Slashplayed certificate's key (made
    /// once) and its request, saved to SlashplayedCertificate.requestFile for the person to upload. Returns
    /// the file; throws, logged, if the key or keychain couldn't be made.
    @discardableResult
    func makeCertificateRequest() throws -> URL {
        do {
            let file = try SlashplayedCertificate.makeRequest()
            certificate = SlashplayedCertificate.state
            appendLog("[companion] certificate: saved the Slashplayed certificate request to \(file.path) (the key stays in Slashplayed's own keychain, off the search list)")
            return file
        } catch {
            appendLog("[companion] certificate: couldn't make the certificate request: \(error.localizedDescription)")
            throw error
        }
    }

    /// Settings' Choose Certificate (or a drop): the .cer the person downloaded, checked against the key and
    /// the team, and kept.
    func addCertificate(_ file: URL) throws {
        do {
            let team = try Signing.resolveTeam()
            let cert = try SlashplayedCertificate.add(try Data(contentsOf: file), team: team.id)
            certificate = SlashplayedCertificate.state
            appendLog("[companion] certificate: kept \(cert.name), valid until \(cert.validUntil), for devices that update games themselves")
        } catch {
            appendLog("[companion] certificate: \(file.lastPathComponent) wasn't taken: \(error.localizedDescription)")
            throw error
        }
    }

    /// Stop Using the Slashplayed Certificate (or Start Over before there is one): deletes the key, the
    /// certificate, and the request here, and turns Update Games on This Device off for every device it was
    /// sent to, so each one's next Play, Update Client, or -push-identity asks it to delete its copy
    /// (DeviceIdentity.decide's .forget). Returns those devices' names, for the message.
    @discardableResult
    func stopUsingCertificate() -> [String] {
        guard !isBusy else { return [] }
        var sentTo: [String] = []
        // Another copy's certificate may have gone to devices too (that copy sent it, and kept the record here).
        let hash: String? = switch certificate {
        case .ready(let cert), .otherCopy(let cert?): cert.hash
        default: nil
        }
        if let hash {
            for device in devices where UserDefaults.standard.string(forKey: DeviceIdentity.pushedKey(device)) == hash {
                storeUpdatesGames(false, for: device)
                sentTo.append(device.name)
            }
        }
        SlashplayedCertificate.remove()
        certificate = SlashplayedCertificate.state
        appendLog("[companion] certificate: " + SlashplayedCertificate.deletedLine(sentTo: sentTo))
        return sentTo
    }

    /// Pair Again (and -pair): a new RemotePairing record for the app. An iPad or iPhone gets one made
    /// over USB (Pairing). The headset makes its own, so its record is cleared instead (an empty file:
    /// devicectl can't delete), and its next launch shows the pairing screen (apps/client/sppair.m).
    func pairDevice() {
        start([.device]) {
            try await self.waitForDevice()
            if self.device.kind == .headset {
                self.set(.device, .active, title: "Clearing \(self.device.name)'s pairing…")
                do {
                    try await Pairing.clear(on: self.device)
                } catch let e as CancellationError {
                    throw e
                } catch is Device.AppMissing {
                    // Nothing to clear: a fresh install pairs at its first launch.
                    self.setAppMissing(true, on: self.device)
                    throw StepFailure(.device, "Press Play: it installs Slashplayed on the headset, which pairs when it first opens.",
                                      title: "Slashplayed isn't on the headset")
                } catch {
                    throw StepFailure(.device, error.localizedDescription)
                }
                self.set(.device, .done, title: "Cleared \(self.device.name)'s pairing",
                         detail: "The next time Slashplayed opens on the headset, it asks to pair: open Settings > General > Remote Devices and type the code it shows. The old Slashplayed entry there can be removed; leave this Mac's.")
                return
            }
            self.set(.device, .active, title: "Pairing with \(self.device.name) over USB…")
            do {
                let size = try await Pairing.send(to: self.device)
                self.appendLog("[companion] sent \(Pairing.devicePath) (\(size) bytes)")
            } catch let e as CancellationError {
                throw e
            } catch is Device.AppMissing {
                // The record goes in the app's data container; Play installs the app and pairs as it does.
                self.setAppMissing(true, on: self.device)
                throw StepFailure(.device, "Press Play: it installs Slashplayed on the \(self.device.noun) and pairs it over USB.",
                                  title: "Slashplayed isn't on the \(self.device.noun)")
            } catch {
                // Not "<device> not found": waitForDevice found it, and over Wi-Fi the record just can't be made.
                throw StepFailure(.device, error.localizedDescription, title: "Couldn't pair with the \(self.device.noun)")
            }
            self.set(.device, .done, title: "Paired with \(self.device.name)")
        }
    }

    /// Fetches the device's console logs, the client's logs and error reports and the system's crash
    /// reports about the app into ~/Library/Logs/Slashplayed/triage/, and puts the summary in the log.
    func pullDeviceLogs() {
        start([.device], anyModel: true) {
            try await self.waitForDevice()
            self.set(.device, .active, title: "Pulling logs from \(self.device.name)…", detail: "Listing the logs on the \(self.device.noun)…")
            let pulled = try await DeviceLogs.pull(from: self.device, flavors: self.device.flavors) { done, total in
                self.set(.device, .active, title: "Pulling logs from \(self.device.name)…",
                         detail: "\(done) of \(SetupStatus.count(total, "file"))", progress: total > 0 ? Double(done) / Double(total) : nil)
            }
            pulled.summary.split(separator: "\n", omittingEmptySubsequences: false).forEach { self.appendLog(String($0)) }
            self.pulledLogs = pulled.dir
            self.set(.device, .done, title: "Pulled \(SetupStatus.count(pulled.fetched.count, "log")) from \(self.device.name)",
                     detail: pulled.failed.isEmpty ? nil : "\(pulled.failed.count) couldn't be copied; see the log.")
        }
    }

    /// Zips the companion's logs, the device's (when it's reachable), the versions of everything and the
    /// window's steps, with Battle.net's values blanked out (Diagnostics), into
    /// ~/Library/Logs/Slashplayed/diagnostics/. Leaves the steps as they are, so a failure stays on screen,
    /// and needs neither Xcode's account nor the device: it's for when something's wrong.
    func exportDiagnostics() {
        guard !isBusy else { return }
        let window = steps.filter { $0.state != .pending }.map { step in
            "  \(step.state): \(step.title)" + (step.detail.map { " — " + $0.replacingOccurrences(of: "\n", with: " / ") } ?? "")
        }
        isBusy = true
        isExporting = true
        diagnosticsZip = nil
        diagnosticsNote = nil
        task = Task {
            defer {
                isBusy = false
                isExporting = false
                exportStatus = nil
                task = nil
            }
            let device = device
            var summary = ["Steps in the window:"] + (window.isEmpty ? ["  (none run yet)"] : window)
            do {
                var deviceLogs: URL?
                if device != .none, await device.isAvailable() {
                    appendLog("[companion] pulling logs from \(device.name) for the diagnostics")
                    exportStatus = "Pulling the \(device.noun)'s logs first. This can take a few minutes…"
                    do {
                        deviceLogs = try await DeviceLogs.pull(from: device, flavors: device.flavors) { done, total in
                            self.exportStatus = "Pulling the \(device.noun)'s logs first: \(done) of \(SetupStatus.count(total, "file"))…"
                        }.dir
                    } catch let e as CancellationError {
                        throw e
                    } catch {
                        diagnosticsNote = "The \(device.noun)'s logs couldn't be pulled: \(error.localizedDescription)"
                    }
                } else {
                    diagnosticsNote = device == .none ? nil
                        : "The \(device.noun) wasn't reachable, so its logs aren't included. Wake or connect it and export again for those."
                }
                if let note = diagnosticsNote { summary += ["", note] }
                exportStatus = "Zipping the logs…"
                let list = (try? await Device.json(["list", "devices"]))?["devices"] as? [[String: Any]] ?? []
                let entry = list.first { ($0["hardwareProperties"] as? [String: Any])?["udid"] as? String == device.udid }
                // Every device's identifiers and names, not only this one's: the logs name the others too.
                // Every team Xcode lists, signed in or not, and the chosen one: older logs name them.
                let accounts = Signing.xcodeAccounts()
                let stored = UserDefaults.standard.string(forKey: Signing.teamKey)
                let teams = accounts.known + (stored.map { [Signing.Team(id: $0, name: $0, isFree: false)] } ?? [])
                let appleIDs = Signing.accounts(appleIDLists: Signing.preferences("com.apple.dt.Xcode")["DVTDeveloperAccountManagerAppleIDLists"]).usernames
                let input = Diagnostics.Input(
                    logs: Paths.logs, deviceLogs: deviceLogs,
                    versions: Diagnostics.versions(device: device, deviceInfo: entry, xcode: await Diagnostics.xcodeVersion()),
                    summary: summary.joined(separator: "\n"), secrets: Diagnostics.netBattleSecrets(),
                    deviceIDs: Diagnostics.deviceIdentifiers(in: list, devices: Device.cached + devices + [device]),
                    personal: Diagnostics.personalDetails(fullName: NSFullUserName(), teams: teams, appleIDs: Array(appleIDs),
                                                          in: list, devices: Device.cached + devices + [device],
                                                          hosts: Diagnostics.macNames()),
                    excluded: [TokenRelay.exportDirectory], output: Diagnostics.outputURL())
                try Task.checkCancellation()
                let exported = try await Task.detached { try Diagnostics.export(input) }.value
                diagnosticsZip = exported.zip
                appendLog("[companion] diagnostics saved to \(exported.zip.path). \(Diagnostics.redactedLine(exported))")
            } catch is CancellationError {
                diagnosticsNote = "Export Diagnostics was cancelled."
            } catch {
                diagnosticsNote = "Export Diagnostics failed: \(error.localizedDescription)"
                appendLog("[companion] \(diagnosticsNote!)")
            }
        }
    }

    /// Starts an action: picks the device (`chosen` if given, else as chooseDevice does), then shows the
    /// steps `ids` (nil: Play's, freshSteps) and runs `body`. A device whose model can't run the client
    /// stops it before anything is built or installed, unless `anyModel` (pulling its logs, which say why):
    /// otherwise a pinned or last-used A12X iPad Pro built, installed, and launched, and the client died at
    /// its first instruction the chip lacks.
    private func start(_ ids: [StepID]?, on chosen: Device? = nil, anyModel: Bool = false,
                       _ body: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        target = chosen?.udid
        flavor = nil
        launch = nil
        latest = [:]
        aheadProducts = []
        canRetryLaunch = false
        unsupportedIssue = nil
        pulledLogs = nil
        diagnosticsZip = nil
        diagnosticsNote = nil
        log.removeAll()
        steps = Self.freshSteps(device, ids)
        run {
            await self.chooseDevice()
            self.target = nil
            self.steps = Self.freshSteps(self.device, ids)
            if !anyModel, let reason = self.unsupportedReason(self.device) {
                self.appendLog("[companion] \(self.device.name) (\(self.models[self.device.udid] ?? "?")): \(reason)")
                throw StepFailure(.device, reason + " Pick another device in the device menu.",
                                  title: "\(self.device.name) can't run Slashplayed")
            }
            // An M1 iPad goes ahead, but its log says it's a first run on that chip, so a report says so.
            if let note = self.device.untestedNote(model: self.models[self.device.udid]) {
                self.appendLog("[companion] \(self.device.name) (\(self.models[self.device.udid] ?? "?")): \(note)")
            }
            // Before the device: its app's data container is named by the bundle ID, from the team.
            do {
                try await Signing.checkXcode()
                self.teamID = try await Signing.resolveTeam(fetchingWith: Paths.resource("signing")) { self.appendLog("[companion] \($0)") }.id
            } catch let p as Signing.Problem {
                throw StepFailure(.device, p.message, title: p.title)
            }
            guard self.device != .none else {
                throw StepFailure(.device, "No device is paired with this Mac. Pair your iPad, iPhone, or Vision Pro in Xcode " +
                                  "(Xcode > Open Developer Tool > Device Hub) with Developer Mode on.")
            }
            try await body()
        }
    }

    func retryLaunch() {
        guard !isBusy, let launch else { return }
        canRetryLaunch = false
        for id in [StepID.start, .prepare, .running] { reset(id) }
        run { try await self.launchSteps(launch) }
    }

    func cancel() {
        if isRunning { stopping = true }
        task?.cancel()
        Task { await launcher.stop() }
    }

    // MARK: Steps

    private func playSteps(viaBattleNet: Bool) async throws {
        let launch: TokenRelay.Launch, tokenFile: URL?
        if viaBattleNet {
            // Battle.net launches the client from the install, so a drive that doesn't answer is said first.
            _ = try await readInstall(for: .battleNet,
                fix: "Play with My Mac's Battle.net starts the game from it. Try again once the drive answers, or press Play to sign in on the \(device.noun) instead.")
            (launch, tokenFile) = try await battleNetSteps()
            device.setPlayGame(launch.flavor)
            playGame = device.playGame
        } else {
            // Chosen after the device (start), whose games the menu lists.
            guard let game = playGame else {
                throw StepFailure(.build, "Tick a game for the \(device.noun) in Settings > Games.")
            }
            launch = TokenRelay.Launch(flavor: game, arguments: game.launcherArguments)
            tokenFile = nil
        }
        defer { if let tokenFile { try? FileManager.default.removeItem(at: tokenFile) } }
        flavor = launch.flavor

        // The Mac-side work first, so the device only has to be awake for the copying.
        try await updateBuild(for: launch.flavor)
        try await waitForDevice()
        try await installBuild()
        try await checkDeviceUpdates()
        try await setUpHelper()
        try await sendIdentityIfNeeded()
        // Copying needs a game install here; without one, the device's client fetches its data itself. With
        // copying off the install isn't read at all (GameInstall.reads), so a stalled drive can't hold Play.
        var copies = false
        if device.copiesGameFiles { copies = try await !readInstall(for: .files, fix: copyFix).flavors.isEmpty }
        try await syncGameFiles([launch.flavor], copy: copies)

        try await sendLoginFiles(tokenFile)
        self.launch = launch

        try await launchSteps(launch)
    }

    /// The small identity file login needs from the Mac, if the device hasn't got it, and with Play with
    /// My Mac's Battle.net, its launch credentials (`tokenFile`).
    private func sendLoginFiles(_ tokenFile: URL?) async throws {
        set(.sendLogin, .active, title: tokenFile == nil ? "Checking the login files on \(device.noun)…" : "Sending login token to \(device.noun)…")
        do {
            if try await GameFiles.sendIdentityIfMissing(to: device) {
                appendLog("[companion] sent Library/spidentity (the small identity file login needs from the Mac)")
            }
            if let tokenFile { try await device.copy(tokenFile, to: "Library/spnetbattle.plist") }
        } catch let e as CancellationError {
            throw e
        } catch {
            throw StepFailure(.sendLogin, error.localizedDescription)
        }
        set(.sendLogin, .done, title: tokenFile == nil ? "Login files in place" : "Login token sent")
    }

    /// Battle.net's part of Play with My Mac's Battle.net: the launch it makes (killed at once), and its
    /// launch credentials exported to a file only this user can read, which the caller deletes.
    private func battleNetSteps() async throws -> (TokenRelay.Launch, URL) {
        if let (_, flavor) = TokenRelay.runningClient() {
            throw StepFailure(.battleNet, "\(flavor.name) is already running on this Mac. Quit it, then try again.")
        }
        let oldTimestamp = await TokenRelay.tokenTimestamp()
        set(.battleNet, .waitingOnUser, title: "Waiting for “Play” click in Battle.net…",
            detail: "Pick the game in Battle.net and click Play. The Mac client is closed as soon as it starts.")
        let launch = try await TokenRelay.catchClientLaunch()
        // Battle.net's arguments can carry credential values, so only the option names (the "-x" or
        // "--x" part, before any "=") and a count go in the log.
        let names = launch.arguments.filter { $0.hasPrefix("-") }.map { String($0.prefix { $0 != "=" }) }
        appendLog("[companion] caught the \(launch.flavor.name) client, \(SetupStatus.count(launch.arguments.count, "argument")), options: \(names.joined(separator: " "))")
        guard device.flavors.contains(launch.flavor) else {
            let others = device.flavors.map(\.name).joined(separator: " or ")
            throw StepFailure(.battleNet, "\(launch.flavor.name) isn't on the \(device.name). Tick it in Settings > Games, or pick \(others) in Battle.net.")
        }
        guard launch.hasToken else {
            throw StepFailure(.battleNet, "Battle.net launched \(launch.flavor.name) without -launcherlogin, so it made no new token. Restart Battle.net and try again.")
        }
        set(.battleNet, .done, title: "Battle.net launched \(launch.flavor.name)")

        set(.token, .active, title: "Waiting for Battle.net to write the login token…")
        guard try await TokenRelay.waitForNewToken(after: oldTimestamp) else {
            throw StepFailure(.token, "Battle.net didn't write a new token within 15 s. Restart Battle.net and try again.")
        }
        let tokenFile = try await TokenRelay.export()
        set(.token, .done, title: "Got a new login token")
        return (launch, tokenFile)
    }

    /// Holds `step` while the device is locked (Device.lock; one that can't be asked isn't held), as
    /// "Put on the headset to <purpose>" or "Unlock the iPad to <purpose>". The client starts only on an
    /// unlocked device, and Xcode's provisioning for it waits a minute for a locked one and then fails
    /// (rc8's run: Play rebuilding with the headset on the desk). A lockState call that met a Wi-Fi drop is
    /// asked again, keeping whatever the step shows, up to maxDrops in a row (the Mac made a new tunnel
    /// within 22 s in rc15's run; each call takes about 5 s); then the device counts as one that can't be
    /// asked. Returns whether it waited.
    @discardableResult
    private func waitForUnlock(_ step: StepID, to purpose: String) async throws -> Bool {
        var waited = false, drops = 0
        wait: while true {
            switch await device.lock() {
            case .unlocked, .unknown:
                break wait
            case .dropped:
                drops += 1
                appendLog("[companion] the connection to the \(device.noun) dropped while asking whether it's locked; asking again")
                if drops >= Self.maxLockDrops {
                    appendLog("[companion] the \(device.noun)'s lock state couldn't be read \(drops) times; going on")
                    break wait
                }
            case .locked:
                drops = 0
                if !waited { appendLog("[companion] the \(device.noun) is locked; waiting for it to \(purpose)") }
                waited = true
                switch device.kind {
                case .headset:
                    set(step, .waitingOnUser, title: "Put on the headset to \(purpose)",
                        detail: "This can only happen while you wear the headset (it's locked now).")
                case .iPad, .iPhone:
                    set(step, .waitingOnUser, title: "Unlock the \(device.noun) to \(purpose)",
                        detail: "This can only happen while the \(device.noun) is unlocked. Setting Auto-Lock to Never (Settings > Display & Brightness) keeps it from locking during a long copy.")
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        if waited { appendLog("[companion] the \(device.noun) is unlocked") }
        return waited
    }

    /// How many lockState drops in a row waitForUnlock sits through: about 2 minutes at ~7 s a call.
    static let maxLockDrops = 16

    private func launchSteps(_ launch: TokenRelay.Launch) async throws {
        try await waitForUnlock(.start, to: "start the client")
        do {
            try await launcher.launch(launch.flavor, on: device, arguments: launch.arguments)
        } catch let e as CancellationError {
            throw e
        } catch {
            canRetryLaunch = true
            // A free team's app opens only once its developer is trusted on the device, a step Xcode can't do.
            let free = Signing.teams().first { $0.id == teamID }?.isFree == true
            let trust = free ? " If the \(device.noun) says “Untrusted Developer”: on it, open Settings > General > VPN & Device Management, tap your Apple ID under Developer App, tap Trust, then press Retry Launch." : ""
            throw StepFailure(steps.first { $0.state == .active }?.id ?? .start, error.localizedDescription + trust)
        }
        set(.prepare, .done, title: "Code pages prepared")
        set(.running, .active, title: "Running on \(device.noun)", detail: "Playing \(launch.flavor.name). Logs are in ~/Library/Logs/Slashplayed/.")
        isRunning = true
        stopping = false
        let status = await launcher.waitForExit()
        isRunning = false
        if stopping {
            set(.running, .done, title: "Client stopped")
        } else if let code = launcher.exitCode, code != 0 {
            throw StepFailure(.running, ClientStop.message(code: code, alert: launcher.lastAlert))
        } else {
            set(.running, .done, title: "Client exited", detail: status == 0 ? nil : "devicectl exited with status \(status).")
        }
    }

    /// Rebuilds the device's client (Mac only) when its last build didn't finish, or Blizzard has a newer
    /// build of `flavor` (nil: any of the device's games) than its image (ClientBuild.check). The build
    /// takes each client from Blizzard's CDN and checks it against the bundled shims first (BindCheck).
    /// When the patch service can't be reached, a game that has an image keeps it.
    private func updateBuild(for flavor: Flavor?) async throws {
        set(.build, .active, title: "Checking the client build…", detail: "Asking Blizzard for each game's current build.")
        let check = try await ClientBuild.check(device)
        latest = check.latest
        for (f, why) in check.unchecked.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            appendLog("[companion] couldn't ask Blizzard for \(f.name)'s current build: \(why)")
        }
        let stale = check.stale
        let complete = ClientBuild.isComplete(device)
        let wanted = flavor.map { stale.contains($0) } ?? !stale.isEmpty
        let versioned = { (f: Flavor) in check.latest[f].map { "\(f.name) \($0.versionsName)" } ?? f.name }
        switch ClientBuild.buildAction(wanted: wanted, complete: complete, drill: BindCheck.drillImport) {
        case .build: break
        case .drill(let withheld):
            set(.build, .active, title: "Checking the client build…", detail: "Patch drill: withholding \(withheld) from the bundled shims.")
            do {
                try await ClientBuild.drill(device, flavors: flavor.map { [$0] } ?? device.flavors, latest: check.latest,
                                            withheld: withheld) { [weak self] in self?.appendLog("[companion] \($0)") }
            } catch let e as CancellationError {
                throw e
            } catch let e as BindCheck.Unsupported {
                throw unsupported(e, latest: check.latest)
            } catch {
                throw StepFailure(.build, error.localizedDescription)
            }
            // Not reached: a withheld symbol always fails the check (BindCheck.check).
            throw StepFailure(.build, "The patch drill's bind check passed with \(withheld) withheld.")
        case .upToDate:
            let unchecked = check.unchecked.isEmpty ? nil
                : "Blizzard couldn't be reached to check for a newer build, so the one built is played."
            let others = stale.isEmpty ? nil
                : "\(stale.map(versioned).joined(separator: ", ")) is out too; it's built when you play it or use Update Client."
            let notes = [unchecked, others].compactMap { $0 }
            set(.build, .done, title: "Client build is up to date", detail: notes.isEmpty ? nil : notes.joined(separator: "\n"))
            return
        }
        // Every ticked game is rebuilt; the title names one only when it alone changed (a patch).
        let target = stale.count == 1 ? stale.first : nil
        // No patch, but the games changed (File > Games on): the build gets just the ticked ones.
        let games = device.flavors.map(\.name).joined(separator: " + ")
        let title = target.map { "Building the client for \(versioned($0))…" } ?? "Building the client with \(games)…"
        set(.build, .active, title: title,
            detail: "About a minute, on this Mac, with the game's client from Blizzard. The \(device.noun) isn't needed yet.")
        let start = Date()
        do {
            try await ClientBuild.build(device, latest: check.latest, beforeSigning: {
                // Xcode registers the device and makes its profile now, which needs it unlocked.
                if try await self.waitForUnlock(.build, to: "sign the client") {
                    self.set(.build, .active, title: title, detail: "Signing the client for the \(self.device.noun).")
                }
            }) { [weak self] in self?.appendLog($0) }
        } catch let e as CancellationError {
            throw e
        } catch let e as BindCheck.Unsupported {
            throw unsupported(e, latest: check.latest)
        } catch let p as Signing.Problem {
            throw StepFailure(.build, p.message, title: p.title)
        } catch {
            throw StepFailure(.build, error.localizedDescription)
        }
        profileExpires = ClientBuild.profile(device)?.expires
        set(.build, .done, title: target.map { "Built the client for \(versioned($0))" } ?? "Built the client with \(games)",
            detail: "In \(Self.duration(Date().timeIntervalSince(start))).")
    }

    /// The build step's failure for a client this version can't run (a game patch, or the patch drill), with
    /// Report It…'s pre-filled issue (unsupportedIssue), whose URL is logged too.
    private func unsupported(_ e: BindCheck.Unsupported, latest: [Flavor: BlizzardCDN.Version]) -> StepFailure {
        let f = Flavor(rawValue: e.flavor)
        let name = f?.name ?? e.flavor, build = f.flatMap { latest[$0]?.versionsName } ?? "(unknown build)"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let issue = BindCheck.issueURL(flavorName: name, build: build, companionVersion: version, unsupported: e)
        unsupportedIssue = issue
        appendLog("[companion] Report It… opens \(issue.absoluteString)")
        return StepFailure(.build, BindCheck.message(flavorName: name, build: build, unsupported: e))
    }

    /// Installs the build unless the device holds the one this Mac last installed there (ClientBuild.installNeed):
    /// a record on this Mac alone isn't enough, as the app may have been deleted on the device or installed
    /// again from another Mac, and the iPad and the iPhone share the build. Before every copy into the app's
    /// data container (setUpHelper and after), which needs the app there.
    private func installBuild() async throws {
        let device = device
        set(.install, .active, title: "Checking the client on the \(device.noun)…")
        let need = await ClientBuild.installNeed(device)
        let games = device.flavors.map(\.name).joined(separator: ", ")
        let why: String
        switch need {
        case .upToDate:
            set(.install, .done, title: "The \(device.noun) has the latest client")
            return
        case .notOnDevice:
            setAppMissing(true, on: device)
            why = "Slashplayed isn't on the \(device.noun) (not installed yet, or deleted there)"
        case .notFromThisMac: why = "this Mac hasn't installed Slashplayed on the \(device.noun) before (it may have another Mac's, with other games)"
        case .olderBuild: why = "the \(device.noun) has an earlier build than this one"
        case .otherGames:
            let had = ClientBuild.installed(device)?.flavors.compactMap(Flavor.init).map(\.name).joined(separator: ", ") ?? ""
            why = "the \(device.noun)'s Slashplayed has \(had), not the games ticked for it"
        case .replaced: why = "Slashplayed was installed on the \(device.noun) again since this Mac installed it (from another Mac or Xcode)"
        }
        appendLog("[companion] installing the client: \(why); this build has \(games)")
        set(.install, .active, title: "Installing the client on the \(device.noun)…")
        do {
            try await ClientBuild.install(device) { [weak self] in self?.appendLog($0) }
        } catch let e as CancellationError {
            throw e
        } catch let p as Signing.Problem {
            throw StepFailure(.install, p.message, title: p.title)
        } catch {
            throw StepFailure(.install, error.localizedDescription)
        }
        setAppMissing(false, on: device)
        set(.install, .done, title: "Installed the new client")
    }

    /// The updates the device made itself (Library/spgames, ClientBuild.deviceUpdates), once the companion's
    /// image is installed: Play, Update Client (the weekly re-sign on a free team), and Copy Game Files. One
    /// the installed image has caught up with is deleted by the launcher at its next start (spcdn.m's
    /// sp_update_caught_up, the same rule); one ahead of it keeps its game data's row and configs
    /// (aheadProducts, for the files step) and is named in the main window. Nothing here stops the action:
    /// a device that can't be read is logged, and .build.info's own check (GameStore.deviceBuildInfo) still
    /// keeps a newer row.
    private func checkDeviceUpdates() async throws {
        let device = device
        do {
            let updates = try await ClientBuild.deviceUpdates(device)
            var ahead: [Flavor: String] = [:]
            for (flavor, update) in updates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let image = ClientBuild.builtStamp(device, flavor)
                let installed = image.map { "\(flavor.name) \($0.version)" } ?? "no \(flavor.name)"
                switch ClientBuild.deviceUpdate(image: image, update: update) {
                case .caughtUp:
                    appendLog("[companion] \(flavor.name) \(update.version) was updated on the \(device.noun), and its app now has \(installed): the \(device.noun) deletes its update at Slashplayed's next start")
                case .ahead:
                    ahead[flavor] = update.version
                    appendLog("[companion] \(flavor.name) \(update.version) was updated on the \(device.noun), ahead of its app's \(installed): it plays that, and its game data's build stays \(update.version)")
                }
            }
            aheadProducts = ahead.keys.map(\.product).sorted()
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: ahead.map { ($0.key.rawValue, $0.value) }),
                                      forKey: ClientBuild.aheadKey(device))
            if device == self.device { updatedOnDevice = ahead }
        } catch let e as CancellationError {
            throw e
        } catch {
            appendLog("[companion] couldn't read the games the \(device.noun) updated itself (Library/spgames): \(error.localizedDescription)")
        }
    }

    /// What the client's JIT helper needs on the device (apps/client/spjit.m), in the app's data
    /// container: the developer disk image, for when the device has none mounted (DeveloperDiskImage), and
    /// on an iPad or iPhone the RemotePairing record (Pairing; the headset pairs itself). Each is copied
    /// only when it's missing or, for the image, Xcode has a newer one.
    /// It borrows the install step's row for its progress and puts the row back as it was afterwards,
    /// without set(): installBuild already logged the step as done, and a second "[step] done:" line
    /// read as a second install.
    private func setUpHelper() async throws {
        let installed = steps.first { $0.id == .install }
        set(.install, .active, title: "Checking the \(device.noun)'s developer disk image…")
        // Each failure is headed for what failed: the install itself went fine by now, and "Couldn't install
        // the client" over a pairing record that needs USB sent people looking at the wrong thing.
        do {
            if let version = try await DeveloperDiskImage.sendIfNeeded(to: device, onLine: { [weak self] in self?.appendLog("[companion] \($0)") }) {
                appendLog("[companion] copied the developer disk image (\(version)) to \(DeveloperDiskImage.deviceDir)")
            }
        } catch let e as CancellationError {
            throw e
        } catch {
            throw StepFailure(.install, error.localizedDescription, title: "Couldn't copy the developer disk image to the \(device.noun)")
        }
        do {
            // Missing, or emptied (a headset's Pair Again, or an iPad or iPhone whose launcher found it rejected).
            if device.kind != .headset,
               (try await device.files(in: "Library", recursive: false)[(Pairing.devicePath as NSString).lastPathComponent]?.size ?? 0) == 0 {
                set(.install, .active, title: "Pairing with the \(device.noun) over USB…")
                let size = try await Pairing.send(to: device)
                appendLog("[companion] sent \(Pairing.devicePath) (\(size) bytes)")
            }
        } catch let e as CancellationError {
            throw e
        } catch {
            throw StepFailure(.install, error.localizedDescription, title: "Couldn't pair with the \(device.noun)")
        }
        if let installed, let i = steps.firstIndex(where: { $0.id == .install }) { steps[i] = installed }
    }

    /// Sends the device the signing identity it updates games with, or asks it to forget it, as
    /// DeviceIdentity.decide says, from Update Games on This Device, the team, the identity the device's app
    /// is signed with, and the device's Library/spidentity.txt. Borrows the install step's row as
    /// setUpHelper does. Nothing here stops Play: a refused export turns the setting off (the person said no
    /// to macOS's prompt), and any other failure is logged and tried again at the next action.
    private func sendIdentityIfNeeded() async throws {
        let device = device, on = device.updatesGames
        let pushed = UserDefaults.standard.string(forKey: DeviceIdentity.pushedKey(device))
        // Nothing was sent and nothing is wanted: no need to ask the device.
        guard on || pushed != nil else {
            setIdentityNotice(nil, for: device)
            appendLog("[companion] identity: Update Games on This Device is off for \(device.name), and nothing was sent to it")
            return
        }
        let installed = steps.first { $0.id == .install }
        defer { if let installed, let i = steps.firstIndex(where: { $0.id == .install }) { steps[i] = installed } }
        set(.install, .active, title: "Checking the \(device.noun)'s signing identity…")
        do {
            let state = try await DeviceIdentity.deviceState(device)
            let source = DeviceIdentity.source ?? .b
            var identity: (hash: String, validUntil: String)?
            var certificate: SecCertificate?
            var notice: String?
            if on, source == .a, FileManager.default.fileExists(atPath: Paths.clientApp(device).path) {
                let signer = try await Signing.signer(of: Paths.clientApp(device),
                                                      work: FileManager.default.temporaryDirectory.appending(path: "spsigner-\(UUID().uuidString)"))
                certificate = DeviceIdentity.certificate(hash: signer.hash)
                if let day = DeviceIdentity.validUntil(hash: signer.hash) { identity = (signer.hash, day) }
                else { appendLog("[companion] identity: \(signer.name)'s certificate isn't in this Mac's keychain") }
            }
            let certificateState = SlashplayedCertificate.state
            if on, source == .b, case .ready(let cert) = certificateState {
                identity = (cert.hash, cert.validUntil)
                certificate = SlashplayedCertificate.current().flatMap(SlashplayedCertificate.certificate(in:))
            }
            // A key another copy of the companion made can't be exported here: say what to do, rather than try and
            // have the export refused (rc9). The setting stays on, so a new certificate is sent at the next Play.
            if on, source == .b, case .otherCopy = certificateState {
                notice = Self.otherCopyNotice(device)
                appendLog("[companion] identity: the Slashplayed certificate's key was made by another copy of Slashplayed Companion, which this copy can't use: nothing is sent")
            }
            // Before each push and at every Play and Update Client (so a free team's weekly re-sign): an identity
            // that has expired or been revoked isn't sent, and the window says what to do.
            if identity != nil, let certificate {
                let standing = await DeviceIdentity.standing(of: certificate)
                if source == .b { certificateStanding = standing }
                switch standing {
                case .good:
                    break
                case .unknown(let why):
                    appendLog("[companion] identity: whether the certificate is still good couldn't be checked (\(why)); going on")
                case .expired, .revoked:
                    let what = standing == .revoked ? "was revoked on developer.apple.com" : "has expired"
                    notice = source == .a
                        ? "The certificate Slashplayed signs with \(what), so it isn't sent to the \(device.noun), and updates the \(device.noun) makes with it may not load. Make a new Apple Development certificate in Xcode (Settings > Apple Accounts, your account, the team, Manage Certificates…), then press Play: Slashplayed signs with it and sends it."
                        : "The Slashplayed certificate \(what), so it isn't sent to the \(device.noun), and updates the \(device.noun) makes with it may not load. In Settings > Updates on Devices, stop using it and make a new one."
                    appendLog("[companion] identity: the \(source == .a ? "signing" : "Slashplayed") certificate \(what): nothing is sent")
                    identity = nil
                }
            }
            defer { setIdentityNotice(notice, for: device) }
            let status = state.status.map { "\($0.state.rawValue)" + ($0.validUntil.map { " until \($0)" } ?? "") } ?? "unknown"
            let certificateHash: String? = if case .ready(let cert) = certificateState { cert.hash } else { nil }
            let pushedSource = DeviceIdentity.pushedSource(recorded: UserDefaults.standard.string(forKey: DeviceIdentity.pushedSourceKey(device)),
                                                           pushed: pushed, certificate: certificateHash)
            let decision = DeviceIdentity.decide(on: on, source: source, identity: identity, pushed: pushed,
                                                 pushedSource: pushedSource, status: state.status, pending: state.pending)
            switch decision {
            case .nothing(let why):
                appendLog("[companion] identity: nothing sent to the \(device.noun) (source \(source.rawValue), device: \(status)): \(why)")
                // A regenerated profile (the weekly re-sign, a new build) may have dropped B's certificate: the
                // device's identity is only of use while some profile there lists it.
                if source == .b, let identity, state.status?.state == .present { _ = try await profileListsCertificate(identity.hash) }
            case .turnOff:
                storeUpdatesGames(false, for: device)
                UserDefaults.standard.removeObject(forKey: DeviceIdentity.pushedKey(device))
                UserDefaults.standard.removeObject(forKey: DeviceIdentity.pushedSourceKey(device))
                appendLog("[companion] identity: the signing identity was forgotten in the \(device.noun)'s Settings, so Update Games on This Device is off for \(device.name) now")
            case .forget:
                set(.install, .active, title: "Asking the \(device.noun) to delete its signing identity…")
                try await DeviceIdentity.sendForget(to: device)
                UserDefaults.standard.removeObject(forKey: DeviceIdentity.pushedKey(device))
                UserDefaults.standard.removeObject(forKey: DeviceIdentity.pushedSourceKey(device))
                appendLog("[companion] identity: Update Games on This Device is off; sent \(DeviceIdentity.forgetPath), and the \(device.noun) deletes its signing identity at Slashplayed's next start")
            case .push(let why):
                guard let identity else { return }
                // B's certificate is new to the team, so the device may have no profile that lists it yet.
                if source == .b, try await !profileListsCertificate(identity.hash) { return }
                // Xcode replaced the certificate the app is signed with (A): the device's updates were signed with the
                // old one, and the launcher signs them again with this one at its next start if the old one isn't
                // in the new profile (launcher.m, library_signed). Only when A was sent last: a switch from B to A
                // (the override, or the team's kind) is another identity too, but nothing of Xcode's changed.
                let replaced = source == .a && pushedSource == .a && pushed != identity.hash
                set(.install, .active, title: "Sending the signing identity to the \(device.noun)…",
                    detail: source == .a ? (replaced ? "Xcode replaced the certificate Slashplayed signs with, so the \(device.noun) gets the new one. " : "")
                        + "If macOS asks to allow Slashplayed Companion to export a key from your keychain, choose Allow: it's the key Slashplayed signs with, for the \(device.noun) to sign game updates." : nil)
                appendLog("[companion] identity: sending it to the \(device.noun) (source \(source.rawValue), device: \(status)): \(why)")
                do {
                    let sizes = try await (source == .a
                        ? DeviceIdentity.push(hash: identity.hash, to: device)
                        : DeviceIdentity.push(hash: identity.hash, to: device) { hash, password in
                            guard let store = SlashplayedCertificate.current() else { throw Failure("The Slashplayed certificate isn't set up any more.") }
                            return try SlashplayedCertificate.export(store, hash: hash, password: password)
                        })
                    UserDefaults.standard.set(identity.hash, forKey: DeviceIdentity.pushedKey(device))
                    UserDefaults.standard.set(source.rawValue, forKey: DeviceIdentity.pushedSourceKey(device))
                    appendLog("[companion] identity: sent \(DeviceIdentity.p12Path) (\(sizes.p12) bytes) and \(DeviceIdentity.passwordPath) (\(sizes.password) bytes); the \(device.noun) imports them at Slashplayed's next start")
                } catch let refused as DeviceIdentity.Refused where source == .b {
                    // The store's key asks nothing of the copy that made it, so a refusal means another copy did:
                    // turning the setting off and asking again would only be refused again.
                    notice = Self.otherCopyNotice(device)
                    appendLog("[companion] identity: \(refused.localizedDescription) The Slashplayed certificate's key was made by another copy of Slashplayed Companion; nothing was sent")
                } catch let refused as DeviceIdentity.Refused {
                    storeUpdatesGames(false, for: device)
                    if replaced { notice = "Xcode replaced the certificate Slashplayed signs with, and the export of the new one was refused, so Update Games on This Device is off for \(device.name). Turn it on and press Play to send it: until then, updates the \(device.noun) made may not load." }
                    appendLog("[companion] identity: \(refused.localizedDescription) Nothing was sent, and Update Games on This Device is off for \(device.name) again; turn it on to be asked again.")
                }
            }
        } catch let e as CancellationError {
            throw e
        } catch {
            appendLog("[companion] identity: couldn't check or send the \(device.noun)'s signing identity: \(error.localizedDescription)")
        }
    }

    /// The main window's notice when the Slashplayed certificate's key is another copy's (`.otherCopy`).
    private static func otherCopyNotice(_ device: Device) -> String {
        "The Slashplayed certificate can't be sent to the \(device.noun): another copy of Slashplayed Companion made its key, and this copy can't use it. In Settings > Updates on Devices, stop using it and make a new one."
    }

    private func setIdentityNotice(_ notice: String?, for device: Device) {
        identityNotices[device.udid] = notice
    }

    /// Settings' Slashplayed Certificate, when it's shown: whether the certificate is still good.
    func checkCertificateStanding() async {
        guard case .ready = certificate, let cert = SlashplayedCertificate.current().flatMap(SlashplayedCertificate.certificate(in:)) else {
            certificateStanding = nil
            return
        }
        certificateStanding = await DeviceIdentity.standing(of: cert)
    }

    /// Whether some profile on the device lists the Slashplayed certificate (B), so an image it signs loads
    /// (research/dlopentest, 5.3: any installed profile will do, and installing one needs no reinstall). The
    /// app's own profile does once Xcode has made it since the certificate existed; else a profile the
    /// companion installed (ClientBuild.certificateProfile) that's still on the device. Otherwise Xcode's
    /// cached profile is forgotten and the stub built again, so Xcode fetches the team's current one, which
    /// lists every development certificate the team has, and that one is installed with devicectl. False,
    /// logged, if even that doesn't list it: nothing is sent, and the next action tries again.
    private func profileListsCertificate(_ hash: String) async throws -> Bool {
        let device = device
        let log: (String) -> Void = { [weak self] line in self?.appendLog("[companion] \(line)") }
        if ClientBuild.isInstalled(device),
           let app = try? Data(contentsOf: Paths.clientApp(device).appending(path: "embedded.mobileprovision")),
           SlashplayedCertificate.lists(profile: app, hash: hash) {
            log("identity: the app's profile lists the Slashplayed certificate")
            return true
        }
        let kept = ClientBuild.certificateProfile(device)
        if let data = try? Data(contentsOf: kept), SlashplayedCertificate.lists(profile: data, hash: hash),
           let info = Signing.profileInfo(data), info.expires.timeIntervalSinceNow > Signing.renewWithin,
           try await device.hasProfile(uuid: info.uuid) {
            log("identity: profile \(info.uuid), which Slashplayed installed on the \(device.noun), lists the Slashplayed certificate")
            // devicectl skips a copy whose size and date match, so this costs nothing once it's there.
            try await device.copy(kept, to: DeviceIdentity.profilePath)
            return true
        }
        set(.install, .active, title: "Getting a profile that lists the Slashplayed certificate…")
        log("identity: no profile on the \(device.noun) lists the Slashplayed certificate; asking Xcode for the team's current one")
        if let old = ClientBuild.profile(device) { Signing.forgetCachedProfile(uuid: old.uuid, log: log) }
        let team = try Signing.resolveTeam()
        if try await waitForUnlock(.install, to: "get its profile") {
            set(.install, .active, title: "Getting a profile that lists the Slashplayed certificate…")
        }
        let identity = try await Signing.provision(team: team, bundleID: Signing.bundleID, udid: device.udid,
                                                   stub: Paths.resource("signing"),
                                                   work: Paths.clientDir(device).appending(path: "signing-certificate"),
                                                   dropped: Signing.dropped(for: team), onLine: log)
        guard let data = try? Data(contentsOf: identity.profile), SlashplayedCertificate.lists(profile: data, hash: hash),
              let info = Signing.profileInfo(data) else {
            log("identity: Xcode's profile for \(Signing.bundleID) doesn't list the Slashplayed certificate yet, so nothing was sent to the \(device.noun); the next Play or Update Client asks again")
            return false
        }
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.copyItem(at: identity.profile, to: kept)
        set(.install, .active, title: "Installing a profile that lists the Slashplayed certificate…")
        try await device.installProfile(kept)
        try await device.copy(kept, to: DeviceIdentity.profilePath)
        log("identity: installed profile \(info.uuid) on the \(device.noun), which lists the Slashplayed certificate, and a copy as \(DeviceIdentity.profilePath) for the launcher (the app's own profile is unchanged until its next build)")
        return true
    }

    /// Copies the game files the device is missing or has old copies of (GameFiles), or without `copy` just
    /// what the client needs to start and stream the rest. A copy can take hours,
    /// and Battle.net, still running, can replace files meanwhile: an index file the plan named was deleted
    /// an hour into a 112 GB copy, after a newer one replaced it. So a file gone from the Mac is skipped,
    /// and the files are compared again after the pass and the new differences copied (`pass`, up to 3),
    /// so the device ends with what the Mac has now, and that pass's plan sends the deletions.
    private func syncGameFiles(_ flavors: [Flavor], copy asked: Bool, pass: Int = 1) async throws {
        set(.files, .active, title: "Checking game files…")
        // A copy reads the install throughout; a drive that doesn't answer now is said now, not left to hang.
        if asked && pass == 1 { _ = try await readInstall(for: .files, fix: copyFix) }
        // The copy's progress says when the cable holds it back (showCopy): read the link as it starts.
        refreshUSBLink()
        if pass == 1, let pid = try? await device.clientPID() {
            set(.files, .active, title: "Stopping the client running on the \(device.noun)…")
            await device.kill(pid: pid)
            try await Task.sleep(for: .seconds(2))
        }
        while asked, let write = GameFiles.recentWrite() {
            set(.files, .active, title: "Waiting for Battle.net to finish updating…",
                detail: "\(write.path) changed \(Int(-write.date.timeIntervalSinceNow)) s ago. Game files are copied once the install has been untouched for 2 minutes.")
            try await Task.sleep(for: .seconds(5))
        }
        set(.files, .active, title: "Checking game files…",
            detail: asked ? "Comparing the \(device.noun)'s files with the Mac's." : "Getting the game's build files from Blizzard.")
        let plan: GameFiles.Plan
        do {
            // The rows and configs of the builds the device's images are, for the games whose image is
            // Blizzard's current build (the check's); any other game's row on the device is left as it is.
            var builds: [GameFiles.Build] = [], images: [String: String] = [:]
            // A game the device updated past its image keeps its own (aheadProducts).
            for f in device.flavors {
                guard let built = ClientBuild.builtStamp(device, f) else { continue }
                images[f.product] = built.buildKey
                if let version = latest[f], built == .from(product: f.product, version: version), !aheadProducts.contains(f.product) {
                    builds.append(try await GameFiles.build(f, version: version))
                }
            }
            // Asked only when the device's last copy stopped and copying is off: finishing it needs the install.
            let finishFix = "The last copy of game files to the \(device.noun) stopped before it finished, and finishing it reads the install. Press Play again once the drive answers."
            plan = try await GameFiles.plan(flavors, on: device, copy: asked, builds: builds, images: images, ahead: aheadProducts,
                                            macInstall: { try await self.readInstall(for: .files, fix: finishFix).hasBuildInfo })
        } catch let e as CancellationError {
            throw e
        } catch let e as StepFailure {
            throw e
        } catch {
            throw StepFailure(.files, error.localizedDescription)
        }
        let copies = plan.copies
        // A copy finishing the one before it copies, whatever the device's setting (GameFiles.copyMarker).
        let copy = asked || plan.finishing
        // After the copies, so the indexes that replace the deleted ones are on the device.
        func sendDeletions() async throws {
            do {
                try await GameFiles.sendDeletions(plan.deletions, to: device)
            } catch let e as CancellationError {
                throw e
            } catch {
                throw StepFailure(.files, "Sending the list of old files to delete failed: \(error.localizedDescription)")
            }
            if !plan.staleIndexes.isEmpty {
                appendLog("[companion] \(SetupStatus.count(plan.staleIndexes.count, "old index file")) (\(Self.bytes(plan.staleIndexBytes))) \(plan.staleIndexes.count == 1 ? "is" : "are") deleted when the client next starts")
            }
            if !plan.unusedArchives.isEmpty {
                appendLog("[companion] \(SetupStatus.count(plan.unusedArchives.count, "archive")) no ticked game uses (\(Self.bytes(plan.unusedArchiveBytes))) \(plan.unusedArchives.count == 1 ? "is" : "are") deleted when the client next starts: \(plan.unusedArchives.map { $0.split(separator: "/").last! }.joined(separator: " "))")
            }
            pendingFree = plan.staleIndexBytes + plan.unusedArchiveBytes
        }
        if plan.keptArchives {
            appendLog("[companion] \(device.missingFlavors.map(\.name).joined(separator: ", ")) isn't installed on this Mac, so no unused archives are deleted")
        }
        let deleting = [
            plan.staleIndexes.isEmpty ? nil
                : "\(SetupStatus.count(plan.staleIndexes.count, "old index file")) (\(Self.bytes(plan.staleIndexBytes))) \(plan.staleIndexes.count == 1 ? "is" : "are") removed when the client next starts.",
            plan.unusedArchives.isEmpty ? nil
                : "\(Self.bytes(plan.unusedArchiveBytes)) of game data no ticked game uses (\(SetupStatus.count(plan.unusedArchives.count, "archive"))) is freed when the client next starts.",
        ].compactMap { $0 }.joined(separator: "\n")
        // Why a copy left the store as it was: the device's client keeps it up to date itself.
        let names = { (products: [String]) in
            products.map { p in Flavor.allCases.first { $0.product == p }?.name ?? p }.joined(separator: " and ")
        }
        let kept: String? = switch plan.storeKept {
        case .newerOnDevice(let products)?:
            "The \(device.noun) has a newer build of \(names(products)) than Slashplayed built, so its game data was left as it is; the game updates it itself."
        case .macDiffers(let products)?:
            "This Mac's \(names(products)) isn't the build Blizzard has out now (let Battle.net update it to copy its files), so the \(device.noun)'s game data was left as it is; the game fetches what it needs itself."
        case .macUnplayed(let products)?:
            GameFiles.unplayedLine(products.map { p in Flavor.allCases.first { $0.product == p }?.name ?? p }, device: device.noun)
        case .deviceWrote(let n)?:
            "The game on the \(device.noun) has added data of its own since the last copy (\(SetupStatus.count(n, "index file")) newer than this Mac's), so its game data was left as it is rather than mixed with this Mac's."
        case nil: nil
        }
        if let kept { appendLog("[companion] \(kept)") }
        let day = ISO8601DateFormatter()
        for u in plan.unplayed {
            let game = Flavor.allCases.first { $0.product == u.product }?.name ?? u.product
            appendLog("[companion] \(game) on this Mac: its build arrived \(day.string(from: u.patched)); last run \(u.lastRun.map(day.string) ?? "never")")
        }
        let stopped = "The last copy of game files to the \(device.noun) stopped before it finished"
        if plan.unfinished {
            let why = kept ?? "There's no game install on this Mac to finish it from: choose it in Settings > Game Install, then press Play again."
            appendLog("[companion] \(stopped), and it can't be finished now: \(why)")
            throw StepFailure(.files, "\(stopped), so its game data is incomplete and no game can start. \(why)")
        }
        let finishing = plan.finishing
            ? "\(stopped), so it's finished now (for the games ticked for it), though copying is off for the \(device.noun)." : nil
        if let finishing { appendLog("[companion] \(finishing)") }
        let streaming = copy ? nil : "The game fetches the rest of its data from Blizzard on the \(device.noun) as it needs it."
        let notes = [finishing, kept ?? streaming, deleting.isEmpty ? nil : deleting].compactMap { $0 }.joined(separator: "\n")
        let deletingDetail = notes.isEmpty ? nil : notes
        try await checkSpace(plan, send: sendDeletions)
        // Once every copy succeeded: a copy cut short before this is finished at the next sync.
        func markDone() async throws {
            guard let done = plan.markDone else { return }
            do {
                try await device.copy(done.source, to: done.destination)
            } catch let e as CancellationError {
                throw e
            } catch {
                throw StepFailure(.files, "Marking the copy of game files finished failed: \(error.localizedDescription)")
            }
        }
        guard !copies.isEmpty else {
            try await markDone()
            try await sendDeletions()
            set(.files, .done, title: copy ? "Game files are up to date" : "The game's build files are up to date", detail: deletingDetail)
            return
        }
        let total = copies.reduce(Int64(0)) { $0 + $1.size }
        appendLog("[companion] copying \(SetupStatus.count(copies.count, "file")), \(Self.bytes(total))")
        // Why the store's files go (sizes and dates only), so a large copy can be told apart from a re-send.
        for line in GameFiles.storeSummary(copies) { appendLog("[companion] \(line)") }
        var done: Int64 = 0
        var copyTime: TimeInterval = 0
        var gone: [String] = []  // planned, but no longer on the Mac
        let copying = copy  // the loop's `copy` is the file
        for (i, copy) in copies.enumerated() {
            guard FileManager.default.fileExists(atPath: copy.source.path) else {
                gone.append(copy.destination)
                continue
            }
            // Progress within a file is estimated at the rate so far (until there's enough to go on, 27 MB/s
            // to the headset over Wi-Fi, 34 MB/s to the iPad over USB; the iPhone is taken to be the same).
            let measured = done > 100_000_000 ? Double(done) / copyTime : nil
            let rate = measured ?? (device.kind == .headset ? 27e6 : 34e6)
            if let measured { copyRates[device.udid] = measured }
            let start = Date(), doneBefore = done, n = i + 1
            let ticker = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    // The cable line follows the link during a copy too (another cable, a step up): every 5 s.
                    if tick % 10 == 0 { self?.refreshUSBLink() }
                    tick += 1
                    let inFile = min(Double(copy.size), Date().timeIntervalSince(start) * rate)
                    self?.showCopy(copying: copying, done: Double(doneBefore) + inFile, total: total, rate: rate,
                                   file: "file \(n) of \(copies.count): \(copy.destination.split(separator: "/").suffix(2).joined(separator: "/"))")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { ticker.cancel() }
            do {
                try await device.copy(copy.source, to: copy.destination)
            } catch let e as CancellationError {
                throw e
            } catch {
                // Deleted while it was being copied: the same as gone before.
                if !FileManager.default.fileExists(atPath: copy.source.path) {
                    gone.append(copy.destination)
                    continue
                }
                throw StepFailure(.files, "Copying \(copy.destination) failed: \(error.localizedDescription)")
            }
            done += copy.size
            copyTime += Date().timeIntervalSince(start)
        }
        if !gone.isEmpty {
            appendLog("[companion] \(SetupStatus.count(gone.count, "file")) went from the Mac during the copy (Battle.net replaced them): \(gone.map { $0.split(separator: "/").last! }.joined(separator: " "))")
            guard pass < 3 else {
                throw StepFailure(.files, "Battle.net kept changing the game files during the copy. Wait for it to finish updating, then press Play again.")
            }
            // The next pass's plan has the replacements, and the deletions for what this one copied.
            return try await syncGameFiles(flavors, copy: asked, pass: pass + 1)
        }
        try await markDone()
        try await sendDeletions()
        let rate = copyTime > 0 ? Double(total) / copyTime : 0
        set(.files, .done, title: copy ? "Copied \(Self.bytes(total)) of game files" : "Sent the game's build files (\(Self.bytes(total)))",
            detail: "\(SetupStatus.count(copies.count, "file")) in \(Self.duration(copyTime)) (\(Self.bytes(Int64(rate)))/s)" +
                (deletingDetail.map { "\n" + $0 } ?? ""))
        await refreshFreeSpace()
    }

    /// Stops a sync whose copies need more than the device has free (Device.freeSpaceNow; for the headset,
    /// when the client last started; less a margin, for what's changed since), rather than fill the device partway through. The deletions are
    /// still sent, so the next client start frees what they hold.
    private func checkSpace(_ plan: GameFiles.Plan, send sendDeletions: () async throws -> Void) async throws {
        let growth = plan.copyGrowth
        guard growth > 0 else { return }
        set(.files, .active, title: "Checking space on the \(device.noun)…")
        guard let free = await device.freeSpaceNow() else {
            appendLog("[companion] the \(device.noun)'s free space isn't known yet (the client writes it when it starts); copying \(Self.bytes(growth)) unchecked")
            return
        }
        freeSpaces[device.udid] = free
        let margin: Int64 = 2_000_000_000
        guard growth > free.bytes - margin else { return }
        try await sendDeletions()
        let games = device.flavors.map(\.name).joined(separator: " + ")
        var message = "\(games) needs \(Self.bytes(growth)) more on the \(device.name), but it has \(free.text). Untick a game in Settings > Games, or free space on the \(device.noun)."
        if plan.unusedArchiveBytes > 0 {
            message += " The \(Self.bytes(plan.unusedArchiveBytes)) of games you unticked is only freed when the client next starts: untick the new game for now, play once, then tick it again."
        }
        throw StepFailure(.files, message)
    }

    /// With copying off, the files are each game's build files, not game data: the title says
    /// so, as the step's done title does ("Copying game files" read as copying on, the rc6 run).
    /// A copy of game files held back by a USB 2 cable says so under its progress (USBLink.slowCable),
    /// unless the main window already says so by the device's status (slowCable: copying is on), so the
    /// line shows once (the rc10 run). That leaves File > Copy Game Files with copying off.
    private func showCopy(copying: Bool, done: Double, total: Int64, rate: Double, file: String) {
        let left = Self.duration((Double(total) - done) / rate)
        let slow = !slowCable && USBLink.slowCable(usbLinks[device.udid], kind: device.kind, model: models[device.udid],
                                                   copying: copying, copyRate: copyRates[device.udid])
        set(.files, .active, title: copying ? "Copying game files to the \(device.noun)…" : "Sending the game's build files to the \(device.noun)…",
            detail: "\(Self.bytes(Int64(done))) of \(Self.bytes(total)) · about \(left) left\n\(file)" +
                (slow ? "\n" + USBLink.slowCableLine : ""),
            progress: done / Double(total))
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(max(Int(seconds), 1)) s" : "\(Int((seconds / 60).rounded())) min"
    }

    private func waitForDevice() async throws {
        set(.device, .active, title: "Looking for the \(device.noun)…")
        while !(await device.isAvailable()) {
            deviceAvailable = false
            switch device.kind {
            case .headset:
                set(.device, .waitingOnUser, title: "Waiting for headset…",
                    detail: "Wake the headset (put it on) and make sure it's on the same network as this Mac.")
            case .iPad, .iPhone:
                set(.device, .waitingOnUser, title: "Waiting for the \(device.noun)…",
                    detail: "Connect the \(device.noun) to this Mac with its USB cable.")
            }
            try await Task.sleep(for: .seconds(3))
        }
        deviceAvailable = true
        UserDefaults.standard.set(device.udid, forKey: Self.lastDeviceKey)
        set(.device, .done, title: "\(device.name) connected")
    }

    /// Picks the device for the next action (Device.choose): the one it was started for (start(on:)), else
    /// the Device menu's, else a reachable paired device that can run the client, the last one used if
    /// several are (else the last one used, or the first paired, to wait for).
    private func chooseDevice() async {
        let paired = await Device.paired()
        let teams = Signing.teams()
        if teams != self.teams { self.teams = teams }
        if let paired, paired.devices != devices {
            devices = paired.devices
            Device.cached = paired.devices
        }
        let available = paired?.reachable ?? []
        // Before choosing: Automatic passes over a model known not to run the client.
        if let paired { models.merge(paired.models) { $1 } }
        let chosen = Device.choose(from: devices, target: target, pin: devicePin,
                                   last: UserDefaults.standard.string(forKey: Self.lastDeviceKey),
                                   reachable: available, models: models)
        let wasAvailable = deviceAvailable, changed = chosen != device
        if changed || profileExpires == nil {
            profileExpires = ClientBuild.profile(chosen)?.expires
        }
        if changed {
            device = chosen
            canRetryLaunch = false
            games = device.flavors
            playGame = device.playGame
            copiesGameFiles = device.copiesGameFiles
            updatesGames = device.updatesGames
            updatedOnDevice = ClientBuild.aheadOnDevice(device)
            pendingFree = 0
            refreshGamesSize()
            if !isBusy { steps = Self.freshSteps(device) }
        }
        deviceAvailable = available.contains(device.udid)
        if deviceAvailable == true, changed || wasAvailable != true { await refreshFreeSpace() }
        refreshUSBLink()
    }

    /// Reads the device's USB link again (USBLink.now: an IOKit read, no devicectl), logging it when it
    /// changes: plugged in, unplugged, or another cable.
    private func refreshUSBLink() {
        guard device.kind != .headset else { return }
        let link = USBLink.now(udid: device.udid)
        guard link != usbLinks[device.udid] else { return }
        usbLinks[device.udid] = link
        copyRates[device.udid] = nil  // measured over the old link
        let usb3 = USBLink.supportsUSB3(kind: device.kind, model: models[device.udid])
        appendLog("[companion] the \(device.noun)'s USB link: " + (link.map { $0.text + (usb3 ? " (the \(device.noun) can do USB 3)" : "") } ?? "none"))
    }

    // MARK: Plumbing

    /// Reads the Mac's game install now (GameInstall.read, within its limit) for `step`, which needs it.
    /// One that doesn't answer fails the step saying so, with `fix`, and is logged: the read itself may
    /// stay stuck in the kernel, but Play doesn't wait on it.
    private func readInstall(for step: StepID, fix: String) async throws -> GameInstall.Snapshot {
        do {
            return try await GameInstall.read()
        } catch let e as GameInstall.NotResponding {
            appendLog("[companion] \(e.logLine)")
            throw StepFailure(step, "\(e.localizedDescription) \(fix)", title: "The game install isn't responding")
        }
    }

    /// What to do when copying can't read the install.
    private var copyFix: String {
        "Copying game files reads it. Press Play again once the drive answers, or turn off Copy Game Files from This Mac for the \(device.noun) (Settings > Games) to stream instead."
    }

    private struct StepFailure: Error {
        var step: StepID
        var message: String
        /// Instead of the step's failedTitle.
        var title: String?
        init(_ step: StepID, _ message: String, title: String? = nil) {
            self.step = step
            self.message = message
            self.title = title
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        isBusy = true
        task = Task {
            do {
                try await body()
            } catch is CancellationError {
                if let step = steps.first(where: { $0.state == .active || $0.state == .waitingOnUser }) {
                    set(step.id, .failed, title: "Cancelled", detail: nil)
                }
            } catch let f as StepFailure {
                set(f.step, .failed, title: f.title ?? failedTitle(f.step), detail: f.message)
            } catch {
                let id = steps.first { $0.state == .active || $0.state == .waitingOnUser }?.id ?? steps.first?.id ?? .build
                set(id, .failed, title: failedTitle(id), detail: error.localizedDescription)
            }
            isBusy = false
            isRunning = false
            task = nil
        }
    }

    private func failedTitle(_ id: StepID) -> String {
        switch id {
        case .battleNet: "Battle.net didn't start the game"
        case .token: "No new login token"
        case .device: "\(device.name) not found"
        case .build: "Couldn't rebuild the client"
        case .install: "Couldn't install the client"
        case .files: "Couldn't update the game files"
        case .sendLogin: "Couldn't send the login files"
        case .start: "The client didn't start"
        case .prepare: "Preparing code pages failed"
        case .running: "The client stopped"
        }
    }

    private func set(_ id: StepID, _ state: StepState, title: String, detail: String? = nil, progress: Double? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        steps[i].title = title
        steps[i].detail = detail
        steps[i].progress = progress
        if state == .done || state == .failed {
            logFile.write("[step] \(state == .done ? "done" : "FAILED"): \(title)" + (detail.map { " — " + $0.replacingOccurrences(of: "\n", with: " / ") } ?? ""))
        }
    }

    private func reset(_ id: StepID) {
        guard let i = steps.firstIndex(where: { $0.id == id }),
              let fresh = Self.freshSteps(device, StepID.allCases).first(where: { $0.id == id }) else { return }
        steps[i] = fresh
    }

    /// A line for the Log pane and companion.txt. Onboarding's checks use it too (Onboarding.logLine), so a
    /// user who never gets as far as Play still leaves a trace in Export Diagnostics.
    func appendLog(_ line: String) {
        log.append(line)
        logFile.write(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    /// While nothing runs, checks every 15 s which device is reachable, for the badge (and Automatic).
    /// While something does, only the USB link is read again (an IOKit read, no devicectl), so the cable
    /// line doesn't keep what it read before a long Play (a USB 2 line stayed up through a USB 3 copy).
    private func watchDevice() async {
        while true {
            if !isBusy {
                await chooseDevice()
                // In the background: a game Battle.net installed or removed shows; a stalled drive holds nothing.
                GameInstall.refresh()
            } else {
                refreshUSBLink()
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// The steps `ids` lists, in order; nil: Play's, which the idle window shows. The Battle.net steps are
    /// Play with My Mac's Battle.net's alone, so they're listed only for it: on the default path (a Mac with
    /// no Battle.net, the sign-in on the device) they read as steps to do (the rc6 run).
    static func freshSteps(_ device: Device, _ ids: [StepID]? = nil) -> [Step] {
        let ids = ids ?? StepID.allCases.filter { !StepID.battleNetOnly.contains($0) }
        return allSteps(device).filter { ids.contains($0.id) }
    }

    private static func allSteps(_ device: Device) -> [Step] {
        let the = "the \(device.noun)"
        return [Step(id: .battleNet, title: "Click Play in Battle.net"),
                Step(id: .token, title: "Get a new login token"),
                Step(id: .build, title: "Check the client build"),
                Step(id: .device, title: "Find \(the)"),
                Step(id: .install, title: "Install the client on \(the)"),
                // Copying needs a game here (playSteps), whatever the device's setting.
                Step(id: .files, title: device.copiesGameFiles && !Flavor.installed.isEmpty ? "Copy game files to \(the)" : "Send the game's build files to \(the)"),
                Step(id: .sendLogin, title: "Send the login files to \(the)"),
                Step(id: .start, title: "Start the client on \(the)"),
                Step(id: .prepare, title: "Prepare code pages"),
                Step(id: .running, title: "Play on \(the)")]
    }
}
