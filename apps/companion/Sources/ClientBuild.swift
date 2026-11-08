import CryptoKit
import Foundation

/// The device app (Paths.clientApp: one build per platform), assembled by ClientAssembly as
/// apps/client/build.sh does, and kept in step with Blizzard's current build of each game. Every game's
/// client comes from Blizzard's CDN (BlizzardCDN: the arm64 slice of the build the patch service names),
/// whether or not the Mac has the game installed, so the Mac's install is only ever what a device may copy
/// its game data from. Each image is stamped with that build (ClientAssembly.Stamp), and a game whose stamp
/// isn't the patch service's current build is rebuilt (check). The build checks every client's imports
/// against the bundled shims first (BindCheck), so a patch this version doesn't know stops it on the Mac
/// with BindCheck.Unsupported rather than crashing on the device. It's signed with the profile and identity
/// Xcode makes for the user's team and the device (Signing). The build runs on the Mac alone; installing
/// waits for the device. A finished build is marked build-complete and given a new build-id; what each
/// device holds is this Mac's record of the build it installed there and the folder the install made
/// (installNeed), since the iPad and the iPhone share one build, and a device's app may have been deleted
/// or come from another Mac. A device's build holds the games ticked for it.
enum ClientBuild {
    private static func buildComplete(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "build-complete") }
    private static func buildIDFile(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "build-id") }
    /// What builds before the install record left beside a build not yet installed; deleted at the next build.
    private static func legacyNeedsInstall(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "needs-install") }
    /// In build-complete with the flavors: a digest of everything the build takes from this app's bundle
    /// (the platform's launcher, JIT helper, shims, and icon, the Info.plist and entitlements templates, and
    /// the addons). A companion with different ones, after an update or in development, rebuilds the device
    /// app instead of leaving the old launcher and shims on it. A build from before the digest has none.
    private static func resourcesMark(_ device: Device) -> String {
        if let mark = resourceMarks.value[device.platform] { return mark }
        var hash = SHA256()
        // The addons too: the device app carries them, and its launcher puts them in each game's folder, so a
        // changed addon reaches the device with a rebuild.
        for root in [Paths.platformResources(device), Paths.resource("client"), Paths.resource("addons")] {
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { String($0.path.dropFirst(root.path.count)) }.sorted()
            for path in files {
                // The name too, so a file moved or renamed changes the digest.
                hash.update(data: Data((path + "\0").utf8))
                hash.update(data: (try? Data(contentsOf: root.appending(path: path), options: .mappedIfSafe)) ?? Data())
            }
        }
        let mark = "resources-" + hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        resourceMarks.value[device.platform] = mark
        return mark
    }
    /// The bundle doesn't change while the app runs, so each platform's digest is made once.
    private static let resourceMarks = Locked<[String: String]>([:])

    /// The device's last build finished, and holds exactly the games ticked for it (a game
    /// ticked or unticked in Settings > Games means a rebuild), from this companion's bundled launcher, helper,
    /// and shims (resourcesMark), under the current bundle ID (a new team or prefix does too), with the
    /// same entitlements left out (a free team's), and a profile that isn't
    /// about to run out (Signing.renewWithin: a free team's lasts 7 days), so Play renews it in time.
    static func isComplete(_ device: Device) -> Bool {
        guard let text = try? String(contentsOf: buildComplete(device), encoding: .utf8) else { return false }
        let built = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        guard built == Set(device.flavors.map(\.rawValue) + [Signing.bundleID, resourcesMark(device)] + Signing.droppedEntitlements) else { return false }
        return profile(device).map { $0.expires.timeIntervalSinceNow > Signing.renewWithin } ?? false
    }

    /// The device build's profile (its embedded.mobileprovision: what's on the device once isInstalled,
    /// and until then the next action installs it).
    static func profile(_ device: Device) -> Signing.ProfileInfo? {
        (try? Data(contentsOf: Paths.clientApp(device).appending(path: "embedded.mobileprovision"))).flatMap(Signing.profileInfo)
    }

    /// The profile the companion installed on the device beside the app's own, so the Slashplayed
    /// certificate (B) is listed before the app's next build (Pipeline.profileListsCertificate).
    static func certificateProfile(_ device: Device) -> URL {
        Paths.clientDir(device).appending(path: "certificate-profile.mobileprovision")
    }

    /// The build's ID, new at each build (nil before its first, or for a build from before the ID).
    static func buildID(_ device: Device) -> String? {
        (try? String(contentsOf: buildIDFile(device), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What this Mac last installed on a device: the build (buildID), its games, the app's bundle URL on the
    /// device right after (Device.AppState; empty if devicectl didn't list it then), and its bundle ID (empty
    /// in a record from before it was kept). A team change makes a new bundle ID (Signing.bundleID), a new
    /// app beside the old one, which the old app's record says nothing about.
    struct Installed: Equatable {
        var build: String
        var flavors: [String]
        var url: String
        var bundleID = ""
    }

    static func installedKey(_ device: Device) -> String { "installedClient.\(device.udid)" }

    static func installed(_ device: Device, _ defaults: UserDefaults = .standard) -> Installed? {
        guard let d = defaults.dictionary(forKey: installedKey(device)), let build = d["build"] as? String else { return nil }
        return Installed(build: build, flavors: d["flavors"] as? [String] ?? [], url: d["url"] as? String ?? "",
                         bundleID: d["bundleID"] as? String ?? "")
    }

    static func setInstalled(_ record: Installed, for device: Device, _ defaults: UserDefaults = .standard) {
        defaults.set(["build": record.build, "flavors": record.flavors, "url": record.url, "bundleID": record.bundleID],
                     forKey: installedKey(device))
    }

    /// Why the build is installed on a device (installNeed), or that it's there.
    enum InstallNeed: Equatable {
        case upToDate
        /// devicectl lists no app with the bundle ID: never installed, or deleted on the device.
        case notOnDevice
        /// This Mac never installed a build there: the app (if any) is another Mac's, or an older companion's.
        case notFromThisMac
        /// This Mac installed an earlier build (a patch, a renewed profile, a new companion), or the shared
        /// build the iPad and the iPhone both get was rebuilt since, for the other one's games or a patch.
        case olderBuild
        /// The games this Mac installed there aren't the ones ticked for it now (File > Games on). A rebuild
        /// for them (isComplete) makes a new build too; this says why when the record is all there is.
        case otherGames
        /// The app is in another folder than the install this Mac made: installed again since (another Mac,
        /// Xcode, or deleted and installed again).
        case replaced
    }

    /// The decision, from the build's ID, the games ticked for the device, this Mac's record for it, the
    /// app's bundle ID now (Signing.bundleID), and the app on it. A device that couldn't be asked counts as
    /// holding what the record says. A record of another bundle ID (before a team change) is no record.
    static func installNeed(build: String?, games: [Flavor], record: Installed?, bundleID: String = "",
                            app: Device.AppState) -> InstallNeed {
        if app == .missing { return .notOnDevice }
        guard let record, record.bundleID.isEmpty || bundleID.isEmpty || record.bundleID == bundleID else { return .notFromThisMac }
        if Set(record.flavors) != Set(games.map(\.rawValue)) { return .otherGames }
        guard let build, record.build == build else { return .olderBuild }
        if case .present(let url) = app, !record.url.isEmpty, url != record.url { return .replaced }
        return .upToDate
    }

    /// installNeed for the device, which is asked (~1 s) unless `askDevice` is false (setup, for a device
    /// that isn't reachable: this Mac's record alone). Asked even when the build is installed anyway, so the
    /// reason given is true: rc19's free-team install, a new bundle ID, read "an earlier build than this
    /// one" for an app that wasn't there.
    static func installNeed(_ device: Device, askDevice: Bool = true) async -> InstallNeed {
        let build = buildID(device), record = installed(device), games = device.flavors, bundleID = Signing.bundleID
        let app = askDevice ? await device.app(bundleID) : .unknown
        return installNeed(build: build, games: games, record: record, bundleID: bundleID, app: app)
    }

    /// Whether the build is the one this Mac last installed on the device (the record alone, no device call).
    static func isInstalled(_ device: Device) -> Bool {
        guard let build = buildID(device), let record = installed(device) else { return false }
        return record.build == build && (record.bundleID.isEmpty || record.bundleID == Signing.bundleID)
    }

    /// Blizzard's patch service and CDN, for each game's client (downloads cached in Paths.cdn).
    static var cdn: BlizzardCDN { BlizzardCDN(cache: Paths.cdn) }

    /// What `check` found: each game's current build on Blizzard's patch service, the games whose image
    /// isn't that build (or that have none), and the games it couldn't check.
    struct Check {
        var latest: [Flavor: BlizzardCDN.Version] = [:]
        var stale: [Flavor] = []
        /// Why the patch service couldn't be asked (offline, a timeout). Such a game counts as stale only
        /// when it has no image: one that has can still be played.
        var unchecked: [Flavor: String] = [:]
    }

    /// Asks the patch service for the current build of each of the device's games (one request each,
    /// about 80 ms) and compares it with the image's stamp.
    static func check(_ device: Device) async throws -> Check {
        var check = Check()
        for flavor in device.flavors {
            let built = builtStamp(device, flavor)
            do {
                let version = try await cdn.version(product: flavor.product, region: flavor.region)
                check.latest[flavor] = version
                if built != .from(product: flavor.product, version: version) { check.stale.append(flavor) }
            } catch let e as CancellationError {
                throw e
            } catch {
                check.unchecked[flavor] = error.localizedDescription
                if built == nil { check.stale.append(flavor) }
            }
        }
        return check
    }

    /// The build the device's image of the game was made from (its spbuild-<flavor>); nil if the build has
    /// no image of it, or one from before the stamp.
    static func builtStamp(_ device: Device, _ flavor: Flavor) -> ClientAssembly.Stamp? {
        let app = Paths.clientApp(device)
        guard FileManager.default.fileExists(atPath: app.appending(path: "wow-\(flavor.rawValue)").path),
              let text = try? String(contentsOf: app.appending(path: ClientAssembly.Stamp.fileName(flavor.rawValue)), encoding: .utf8),
              let row = GameStore.BuildInfo(text)?.byProduct[flavor.product] else { return nil }
        return try? .from(product: flavor.product, row: row)
    }

    // MARK: Updates the device made

    /// An update the device made itself (Update on its patch screen: Library/spgames/wow-<flavor>, stamped
    /// spgames/spbuild-<flavor>) against the image the companion installed. `ahead`: a later build than the
    /// installed image (or there's none), so the launcher may load it: its game data's row and configs are the
    /// device's, never taken back. `caughtUp`: the installed image is that build or a later one, so the
    /// launcher deletes the update at its next start. One rule on both sides: apps/client/spcdn.m's
    /// sp_update_caught_up.
    enum DeviceUpdate: Equatable {
        case ahead, caughtUp
    }

    static func deviceUpdate(image: ClientAssembly.Stamp?, update: ClientAssembly.Stamp) -> DeviceUpdate {
        guard let image else { return .ahead }
        return image.buildKey == update.buildKey || image.version == update.version
            || GameStore.isVersion(image.version, newerThan: update.version) ? .caughtUp : .ahead
    }

    /// A game's client in the device's Library/spgames: the stamp beside wow-<flavor>, and where it came
    /// from, spsource-<flavor>'s one word (`source`): `mac` (this Mac's copyClient), `updated` or `installed`
    /// (the device fetched it: apps/client/sppatch.m), or nil without one.
    struct DeviceClient: Equatable {
        var stamp: ClientAssembly.Stamp
        var source: String?
        var fromMac: Bool { source == "mac" }
    }

    /// The device's clients of its games: each Library/spgames stamp beside its client, pulled with
    /// devicectl as GameFiles pulls .build.info. Empty when there are none (no Library/spgames). An empty
    /// stamp (copyClient's, while it copies) is none.
    static func deviceClients(_ device: Device) async throws -> [Flavor: DeviceClient] {
        // devicectl fails on a folder that isn't there, so Library is listed whole (under a hundred files).
        let library = try await device.files(in: "Library", recursive: true)
        var clients: [Flavor: DeviceClient] = [:]
        for flavor in Flavor.allCases {
            let stamp = "spgames/" + ClientAssembly.Stamp.fileName(flavor.rawValue)
            guard (library[stamp]?.size ?? 0) > 0, library["spgames/wow-\(flavor.rawValue)"] != nil else { continue }
            let url = FileManager.default.temporaryDirectory.appending(path: "spgames-\(device.udid)-\(flavor.rawValue)")
            try? FileManager.default.removeItem(at: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try await Device.retrying { try await device.fetch("Library/" + stamp, to: url) }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let row = GameStore.BuildInfo(text)?.byProduct[flavor.product],
                  let client = try? ClientAssembly.Stamp.from(product: flavor.product, row: row) else { continue }
            // The word, when there's one: a few bytes, pulled as the stamp is.
            var source: String?
            if (library["spgames/" + sourceFile(flavor)]?.size ?? 0) > 0 {
                try? FileManager.default.removeItem(at: url)
                try await Device.retrying { try await device.fetch("Library/spgames/" + sourceFile(flavor), to: url) }
                source = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            clients[flavor] = DeviceClient(stamp: client, source: source?.isEmpty == false ? source : nil)
        }
        return clients
    }

    // MARK: The game clients the Mac copies

    /// What the Mac does about a game's client on the device (Library/spgames/wow-<flavor>), from the stamp
    /// beside it (nil: none) and the build the Mac sends (`mac`): copy it when the device's is missing or
    /// older. The device is the record, so this Mac keeps none of its own, and a newer build the device
    /// fetched itself, or one whose version can't be told apart, is never replaced. The same build or
    /// version is the same client, as sp_update_caught_up counts it: another region's build of a version
    /// isn't copied over.
    enum ClientCopy: Equatable {
        case copy, upToDate, newerOnDevice
    }

    static func clientCopy(device: ClientAssembly.Stamp?, mac: ClientAssembly.Stamp) -> ClientCopy {
        guard let device else { return .copy }
        if device.buildKey == mac.buildKey || device.version == mac.version { return .upToDate }
        return GameStore.isVersion(mac.version, newerThan: device.version) ? .copy : .newerOnDevice
    }

    /// Where a client in Library/spgames came from, one word: `mac` for copyClient's (DeviceClient.source).
    static func sourceFile(_ flavor: Flavor) -> String { "spsource-\(flavor.rawValue)" }

    /// Copies `flavor`'s client of `version` into the device's Library/spgames, for the launcher that loads
    /// the unchanged client with spguest (apps/client/spguest.c): the CDN's arm64 slice as wow-<flavor>, then its
    /// .build.info row (spbuildinfo-<flavor>, as an update on the device keeps it), spsource-<flavor>
    /// (`mac`), and the stamp last, so a stamp is only ever beside a whole client of its build. devicectl
    /// can't delete, so the stamp is emptied first, whatever the listing said was there (one it couldn't
    /// parse included): a copy cut short leaves no stamp naming the old build beside the new client.
    /// `beforeWrite` runs once the slice is in hand, just before the first write (the caller stops a client
    /// running on the device there), so a download that fails touches nothing on it. Returns the slice's size.
    @discardableResult
    static func copyClient(_ flavor: Flavor, version: BlizzardCDN.Version, to device: Device, log: (String) -> Void,
                           beforeWrite: () async throws -> Void) async throws -> Int64 {
        let (slice, stamp) = try await clientSlice(flavor, latest: [flavor: version], log: log)
        let cdn = try await cdn.connected(product: flavor.product, region: flavor.region)
        guard let cdns = cdn.cdns else { throw Failure("Blizzard's patch service lists no CDN for \(flavor.name).") }
        let row = GameStore.buildInfoText([BlizzardCDN.buildInfoLine(product: flavor.product, version: version, cdns: cdns,
                                                                     tags: flavor.tags)])
        let staging = FileManager.default.temporaryDirectory.appending(path: "spgames-copy-\(device.udid)-\(flavor.rawValue)")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        func staged(_ name: String, _ text: String) throws -> URL {
            let url = staging.appending(path: name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let dir = "Library/spgames/", stampPath = dir + ClientAssembly.Stamp.fileName(flavor.rawValue)
        try await beforeWrite()
        try await device.copy(try staged("empty", ""), to: stampPath)
        try await device.copy(slice, to: dir + "wow-\(flavor.rawValue)")
        try await device.copy(try staged("row", row), to: dir + "spbuildinfo-\(flavor.rawValue)")
        try await device.copy(try staged("source", "mac\n"), to: dir + sourceFile(flavor))
        try await device.copy(try staged("stamp", stamp.text), to: stampPath)
        return Int64((try? slice.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// UserDefaults key of the device's updates that are ahead of its installed image, as the last action
    /// found them (flavor -> version), for the main window.
    static func aheadKey(_ device: Device) -> String { "updatedOnDevice.\(device.udid)" }

    /// The device's games an update on it put ahead of the companion's image, by version, as last seen.
    static func aheadOnDevice(_ device: Device, _ defaults: UserDefaults = .standard) -> [Flavor: String] {
        let stored = defaults.dictionary(forKey: aheadKey(device)) as? [String: String] ?? [:]
        return stored.reduce(into: [:]) { out, e in if let f = Flavor(rawValue: e.key) { out[f] = e.value } }
    }

    /// The version of the Mac's install of the game, as Battle.net shows it (12.1.5), from the install's
    /// snapshot (GameInstall); nil if it isn't installed.
    static func version(_ flavor: Flavor) -> String? {
        GameInstall.known?.games[flavor.rawValue]?.version
    }

    /// The build of the Mac's install of the game, as the client reports it (1.15.9.70003), from the snapshot.
    static func gameBuild(_ flavor: Flavor) -> String? {
        GameInstall.known?.games[flavor.rawValue]?.build
    }

    /// Builds the device's games (ClientAssembly) from their builds in `latest` (check's; a game not in it
    /// is asked for again) and signs the app, without installing. The log goes to
    /// ~/Library/Logs/Slashplayed/build.txt too. `beforeSigning` runs once the images are assembled, before
    /// Xcode provisions for the device, which has to be unlocked then (Pipeline.waitForUnlock).
    static func build(_ device: Device, latest: [Flavor: BlizzardCDN.Version],
                      beforeSigning: () async throws -> Void = {},
                      onLine: @escaping (String) -> Void) async throws {
        let logFile = LogFile(Paths.logs.appending(path: "build.txt"), t0: Date())
        let log = { (line: String) in
            logFile.write(line)
            DispatchQueue.main.async { onLine(line) }
        }
        do {
            try await assembleAndSign(device, latest: latest, beforeSigning: beforeSigning, log: log)
        } catch {
            log("failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// `flavor`'s client from Blizzard's CDN: the arm64 slice of the build `latest` names (or the patch
    /// service's current one), cached in Paths.cdn, and the stamp for it.
    private static func clientSlice(_ flavor: Flavor, latest: [Flavor: BlizzardCDN.Version],
                                    log: (String) -> Void) async throws -> (URL, ClientAssembly.Stamp) {
        let product = flavor.product, region = flavor.region
        let version: BlizzardCDN.Version
        if let known = latest[flavor] { version = known } else { version = try await cdn.version(product: product, region: region) }
        let start = Date()
        let slice = try await cdn.connected(product: product, region: region)
            .slice(product: product, region: region, buildConfig: version.buildConfig, cdnConfig: version.cdnConfig,
                   executable: flavor.clientPath).slice
        let size = (try? slice.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log("\(flavor.rawValue) \(version.versionsName): the client's arm64 slice from Blizzard's CDN "
            + "(\(size / 1_000_000) MB, \(String(format: "%.1f", Date().timeIntervalSince(start))) s, cached)")
        return (slice, .from(product: product, version: version))
    }

    /// What Play or Update Client does about the device's build: build it when a game it wants is out of
    /// date or the last build didn't finish; otherwise, with the patch drill set (BindCheck.drillImport, a
    /// pre-release only), check the clients alone (`drill`), so the drill fires on an up-to-date build too
    /// without waiting for a patch or throwing away a good build.
    enum BuildAction: Equatable {
        case upToDate, build
        /// The drill's withheld symbol.
        case drill(String)
    }

    static func buildAction(wanted: Bool, complete: Bool, drill: String?) -> BuildAction {
        if wanted || !complete { return .build }
        return drill.map { .drill($0) } ?? .upToDate
    }

    /// The patch drill on an up-to-date build: the bind check the build makes, of `flavors`' clients (the
    /// cached CDN slices the build was made from) against the bundled shims with `withheld` withheld. Throws
    /// BindCheck.Unsupported as the build would; the build itself isn't touched.
    static func drill(_ device: Device, flavors: [Flavor], latest: [Flavor: BlizzardCDN.Version], withheld: String,
                      onLine: (String) -> Void) async throws {
        let exports = try BindCheck.Manifest(Paths.platformResources(device).appending(path: "exports.json"))
        exports.withheld = [withheld]
        onLine("patch drill: withholding \(withheld) from the bundled shims (the build is up to date, so only its bind check runs)")
        for flavor in flavors {
            let (slice, _) = try await clientSlice(flavor, latest: latest, log: onLine)
            // The CDN's slice is the thinned image the build's check sees (ClientAssembly.prepareClient).
            try await BindCheck.require(slice, flavor: flavor.rawValue, against: exports, platform: device.platform,
                                        onLine: onLine)
        }
    }

    private static func assembleAndSign(_ device: Device, latest: [Flavor: BlizzardCDN.Version],
                                        beforeSigning: () async throws -> Void,
                                        log: @escaping (String) -> Void) async throws {
        guard let platform = ClientAssembly.Platform.named(device.platform) else {
            throw Failure("No build settings for the \(device.platform) platform.")
        }
        let team = try Signing.resolveTeam(), bundleID = Signing.bundleID
        let dir = Paths.clientDir(device), app = Paths.clientApp(device)
        // Renewing: the old profile would be reused as long as Xcode has it cached, so it's forgotten first.
        if let old = profile(device), old.expires.timeIntervalSinceNow <= Signing.renewWithin {
            Signing.forgetCachedProfile(uuid: old.uuid, log: log)
            // The helper's was made with it and runs out with it.
            let helperProfile = app.appending(path: "PlugIns/\(ClientAssembly.helperName).appex/embedded.mobileprovision")
            if let h = (try? Data(contentsOf: helperProfile)).flatMap(Signing.profileInfo) {
                Signing.forgetCachedProfile(uuid: h.uuid, log: log)
            }
        }
        try? FileManager.default.removeItem(at: buildComplete(device))
        try? FileManager.default.removeItem(at: buildIDFile(device))
        try? FileManager.default.removeItem(at: legacyNeedsInstall(device))
        let flavors = device.flavors
        let entitlements = dir.appending(path: "entitlements.plist")
        let helperEntitlements = dir.appending(path: "helper-entitlements.plist")
        let dropped = Signing.dropped(for: team)
        var clients: [(flavor: String, executable: URL, stamp: ClientAssembly.Stamp)] = []
        for flavor in flavors {
            let (slice, stamp) = try await clientSlice(flavor, latest: latest, log: log)
            clients.append((flavor.rawValue, slice, stamp))
        }
        try await ClientAssembly.assemble(app: app, clients: clients,
                                          platform: platform, platformResources: Paths.platformResources(device),
                                          templates: Paths.resource("client"), addons: Paths.resource("addons"),
                                          team: team.id, bundleID: bundleID,
                                          entitlements: entitlements, helperEntitlements: helperEntitlements,
                                          droppedEntitlements: dropped, onLine: log)
        try await beforeSigning()
        let identity = try await Signing.provision(team: team, bundleID: bundleID, udid: device.udid,
                                                   stub: Paths.resource("signing"), work: dir.appending(path: "signing"),
                                                   dropped: dropped, onLine: log)
        // The JIT helper's own profile: an extension's App ID is its own bundle ID (on a free team, one more
        // of its weekly App IDs the first time, but not one of a device's three app slots).
        let helperIdentity = try await Signing.provision(team: team, bundleID: ClientAssembly.helperBundleID(bundleID),
                                                         udid: device.udid, stub: Paths.resource("signing"),
                                                         work: dir.appending(path: "signing-helper"),
                                                         dropped: Signing.helperDropped, onLine: log)
        let helper = app.appending(path: "PlugIns/\(ClientAssembly.helperName).appex")
        try FileManager.default.copyItem(at: identity.profile, to: app.appending(path: "embedded.mobileprovision"))
        try FileManager.default.copyItem(at: helperIdentity.profile, to: helper.appending(path: "embedded.mobileprovision"))
        let images = try FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Frameworks").path)
            .filter { $0.hasSuffix(".dylib") }.sorted().map { app.appending(path: "Frameworks/\($0)").path }
            + flavors.map { app.appending(path: "wow-\($0.rawValue)").path }
        log("signing")
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", identity.hash] + images)
        // Inside out: the helper is sealed into the app's signature, so it's signed before the app.
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", helperIdentity.hash, "--entitlements", helperEntitlements.path, helper.path])
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", identity.hash, "--entitlements", entitlements.path, app.path])
        try (flavors.map(\.rawValue) + [bundleID, resourcesMark(device)] + dropped).joined(separator: " ").write(to: buildComplete(device), atomically: true, encoding: .utf8)
        try UUID().uuidString.write(to: buildIDFile(device), atomically: true, encoding: .utf8)
        if let p = profile(device) {
            log("profile \(p.uuid) expires \(p.expires.formatted(date: .abbreviated, time: .shortened))")
            if p.expires.timeIntervalSinceNow <= Signing.renewWithin {
                log("Xcode gave a profile that runs out within \(Int(Signing.renewWithin / 3600)) hours; the next Play rebuilds again")
            }
        }
        log("built \(app.path)")
    }

    /// Installs the build on the device, and records it (installed). An install cut by a dropped connection
    /// is tried again (Device.retryingDrops): installing the same app again is safe.
    static func install(_ device: Device, log: @escaping (String) -> Void = { _ in }) async throws {
        if await device.developerMode() == false {
            throw Signing.Problem(title: "Developer Mode is off on the \(device.noun)",
                                  message: "Turn on Developer Mode on the \(device.name) (Settings > Privacy & Security > Developer Mode), restart it when asked, then try again.")
        }
        try await device.retryingDrops(during: "the install", log: log) {
            try await Shell.run(Device.xcrun, ["devicectl", "device", "install", "app", "--device", device.udid,
                                               Paths.clientApp(device).path])
        }
        guard let build = buildID(device) else { return }
        let bundleID = Signing.bundleID
        let url: String = if case .present(let url) = await device.app(bundleID) { url } else { "" }
        setInstalled(Installed(build: build, flavors: device.flavors.map(\.rawValue), url: url, bundleID: bundleID), for: device)
    }

}
