import CryptoKit
import Foundation
import Security

/// The device app (Paths.clientApp: one build per platform), assembled by ClientAssembly as
/// apps/client/build.sh does, and each game's client beside it on the device. The app holds no game: it's
/// rebuilt only when this companion's resources, the bundle ID, or the entitlements change, or its profile
/// is about to run out (isComplete), so the iPad and the iPhone share one build whatever games they have.
/// Every game's client comes from Blizzard's CDN (BlizzardCDN: the arm64 slice of the build the patch
/// service names, check), whether or not the Mac has the game installed, so the Mac's install is only ever
/// what a device may copy its game data from. The Mac copies the slice, unchanged, into the device's
/// Library/spgames when the device's is missing or older (clientCopy, copyClient), after checking its
/// imports against the bundled shims (BindCheck), so a patch this version doesn't know stops on the Mac
/// with BindCheck.Unsupported rather than crashing on the device. The app is signed with the profile and
/// identity Xcode makes for the user's team and the device (Signing); the client isn't signed at all. The
/// build runs on the Mac alone; installing waits for the device. A finished build is marked build-complete
/// and given a new build-id; what each device holds is this Mac's record of the build it installed there and
/// the folder the install made (installNeed), since a device's app may have been deleted or come from
/// another Mac.
enum ClientBuild {
    private static func buildComplete(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "build-complete") }
    private static func buildIDFile(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "build-id") }
    /// What builds before the install record left beside a build not yet installed; deleted at the next build.
    private static func legacyNeedsInstall(_ device: Device) -> URL { Paths.clientDir(device).appending(path: "needs-install") }
    /// In build-complete: a digest of everything the build takes from this app's bundle
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

    /// The device's last build finished, from this companion's bundled launcher, helper, and shims
    /// (resourcesMark), under the current bundle ID (a new team or prefix means a rebuild), with the same
    /// entitlements left out (a free team's), and a profile that isn't about to run out
    /// (Signing.renewWithin: a free team's lasts 7 days), so Play renews it in time. The games ticked for the
    /// device don't come into it: the app holds none. A build-complete from before that, which listed them,
    /// isn't complete, so the first Play after the upgrade builds the app without its images.
    static func isComplete(_ device: Device) -> Bool {
        guard let text = try? String(contentsOf: buildComplete(device), encoding: .utf8) else { return false }
        let built = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        guard built == Set([Signing.bundleID, resourcesMark(device)] + Signing.droppedEntitlements) else { return false }
        return profile(device).map { $0.expires.timeIntervalSinceNow > Signing.renewWithin } ?? false
    }

    /// The device build's profile (its embedded.mobileprovision: what's on the device once isInstalled,
    /// and until then the next action installs it).
    static func profile(_ device: Device) -> Signing.ProfileInfo? {
        (try? Data(contentsOf: Paths.clientApp(device).appending(path: "embedded.mobileprovision"))).flatMap(Signing.profileInfo)
    }

    /// The build's ID, new at each build (nil before its first, or for a build from before the ID).
    static func buildID(_ device: Device) -> String? {
        (try? String(contentsOf: buildIDFile(device), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What this Mac last installed on a device: the build (buildID), the app's bundle URL on the device
    /// right after (Device.AppState; empty if devicectl didn't list it then), and its bundle ID (empty in a
    /// record from before it was kept). A team change makes a new bundle ID (Signing.bundleID), a new app
    /// beside the old one, which the old app's record says nothing about.
    struct Installed: Equatable {
        var build: String
        var url: String
        var bundleID = ""
    }

    static func installedKey(_ device: Device) -> String { "installedClient.\(device.udid)" }

    static func installed(_ device: Device, _ defaults: UserDefaults = .standard) -> Installed? {
        guard let d = defaults.dictionary(forKey: installedKey(device)), let build = d["build"] as? String else { return nil }
        return Installed(build: build, url: d["url"] as? String ?? "", bundleID: d["bundleID"] as? String ?? "")
    }

    static func setInstalled(_ record: Installed, for device: Device, _ defaults: UserDefaults = .standard) {
        defaults.set(["build": record.build, "url": record.url, "bundleID": record.bundleID], forKey: installedKey(device))
    }

    /// What Update Games on This Device left in this Mac's settings, which nothing needs now that a device
    /// updates and installs its games with no signing identity (apps/client/sppatch.m), deleted: each
    /// device's setting (updateGames.*), the identity last pushed to it (identityPushed.*,
    /// identityPushedSource.*), the source's test override (signingSource), and the games each install
    /// record listed (installedClient.*'s flavors: the app holds none). Run at every start, with
    /// forgetCertificate, for two releases, as the launcher's forget_identity is. Returns the keys it changed
    /// (never a value), for the log; empty once there's nothing left.
    @discardableResult
    static func forgetDeviceUpdates(_ defaults: UserDefaults = .standard) -> [String] {
        var gone: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            if ["updateGames.", "identityPushed.", "identityPushedSource."].contains(where: key.hasPrefix) || key == "signingSource" {
                defaults.removeObject(forKey: key)
                gone.append(key)
            } else if key.hasPrefix("installedClient."), var record = value as? [String: Any], record["flavors"] != nil {
                record["flavors"] = nil
                defaults.set(record, forKey: key)
                gone.append(key + ".flavors")
            }
        }
        return gone.sorted()
    }

    /// The Slashplayed certificate a paid team's devices signed their game updates with, deleted from this
    /// Mac: its own keychain under Application Support (certificate/: the key Slashplayed made and only
    /// Slashplayed used), that keychain's password in the login keychain, and the profiles made for it
    /// (client-*/certificate-profile.mobileprovision, signing-certificate/). Nothing is read from either
    /// keychain, and the request in Downloads (a public key) is left. The certificate itself stays valid on
    /// developer.apple.com until it's revoked there. Returns what it deleted, by name, for the log.
    @discardableResult
    static func forgetCertificate(support: URL = Paths.support) -> [String] {
        var gone: [String] = []
        let fm = FileManager.default
        let certificate = support.appending(path: "certificate")
        for name in (try? fm.contentsOfDirectory(atPath: certificate.path)) ?? [] {
            var keychain: SecKeychain?
            if name.hasSuffix(".keychain-db"), SecKeychainOpen(certificate.appending(path: name).path, &keychain) == errSecSuccess,
               let keychain {
                SecKeychainDelete(keychain)
            }
            gone.append("certificate/" + name)
        }
        if fm.fileExists(atPath: certificate.path) { try? fm.removeItem(at: certificate) }
        // The keychain's password, one item per keychain file the certificate had (SecItemDelete takes them all).
        if SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "Slashplayed certificate keychain"] as CFDictionary)
            == errSecSuccess {
            gone.append("the certificate keychain's password")
        }
        for dir in (try? fm.contentsOfDirectory(atPath: support.path))?.filter({ $0.hasPrefix("client-") }) ?? [] {
            for name in ["certificate-profile.mobileprovision", "signing-certificate"] {
                let url = support.appending(path: "\(dir)/\(name)")
                guard fm.fileExists(atPath: url.path) else { continue }
                try? fm.removeItem(at: url)
                gone.append("\(dir)/\(name)")
            }
        }
        return gone.sorted()
    }

    /// Why the build is installed on a device (installNeed), or that it's there.
    enum InstallNeed: Equatable {
        case upToDate
        /// devicectl lists no app with the bundle ID: never installed, or deleted on the device.
        case notOnDevice
        /// This Mac never installed a build there: the app (if any) is another Mac's, or an older companion's.
        case notFromThisMac
        /// This Mac installed an earlier build (a renewed profile, a new companion, a new team), or the shared
        /// build the iPad and the iPhone both get was rebuilt since, for the other one. Or it holds the last
        /// build, but that build isn't complete (isComplete), so the next build replaces it.
        case olderBuild
        /// The app is in another folder than the install this Mac made: installed again since (another Mac,
        /// Xcode, or deleted and installed again).
        case replaced
    }

    /// The decision, from the build's ID, this Mac's record for the device, the app's bundle ID now
    /// (Signing.bundleID), and the app on it. A device that couldn't be asked counts as holding what the
    /// record says. A record of another bundle ID (before a team change) is no record. The games don't come
    /// into it: a game ticked or unticked is a client copied or left alone, never a new app. A build that
    /// isn't `complete` (isComplete) is one Play and Setup Assistant's Update rebuild before they install
    /// (Pipeline.updateBuild), so a device holding it isn't up to date either: Setup Assistant's install step
    /// said "up to date" for an iPhone that the next Play rebuilt for a new companion's resources.
    static func installNeed(build: String?, record: Installed?, bundleID: String = "", app: Device.AppState,
                            complete: Bool = true) -> InstallNeed {
        if app == .missing { return .notOnDevice }
        guard let record, record.bundleID.isEmpty || bundleID.isEmpty || record.bundleID == bundleID else { return .notFromThisMac }
        guard let build, record.build == build, complete else { return .olderBuild }
        if case .present(let url) = app, !record.url.isEmpty, url != record.url { return .replaced }
        return .upToDate
    }

    /// installNeed for the device, which is asked (~1 s) unless `askDevice` is false (setup, for a device
    /// that isn't reachable: this Mac's record alone). Asked even when the build is installed anyway, so the
    /// reason given is true: rc19's free-team install, a new bundle ID, read "an earlier build than this
    /// one" for an app that wasn't there.
    static func installNeed(_ device: Device, askDevice: Bool = true) async -> InstallNeed {
        let build = buildID(device), record = installed(device), bundleID = Signing.bundleID
        let app = askDevice ? await device.app(bundleID) : .unknown
        return installNeed(build: build, record: record, bundleID: bundleID, app: app, complete: isComplete(device))
    }

    /// Whether the build is the one this Mac last installed on the device (the record alone, no device call).
    static func isInstalled(_ device: Device) -> Bool {
        guard let build = buildID(device), let record = installed(device) else { return false }
        return record.build == build && (record.bundleID.isEmpty || record.bundleID == Signing.bundleID)
    }

    /// Blizzard's patch service and CDN, for each game's client (downloads cached in Paths.cdn).
    static var cdn: BlizzardCDN { BlizzardCDN(cache: Paths.cdn) }

    /// What `check` found: each game's current build on Blizzard's patch service, the build the Mac copies
    /// (clientCopy), and the games it couldn't check.
    struct Check {
        var latest: [Flavor: BlizzardCDN.Version] = [:]
        /// Why the patch service couldn't be asked (offline, a timeout). Such a game's client isn't copied:
        /// the device plays the one it has, or fetches its own.
        var unchecked: [Flavor: String] = [:]
    }

    /// Asks the patch service for the current build of each of the device's games (one request each,
    /// about 80 ms).
    static func check(_ device: Device) async throws -> Check {
        var check = Check()
        for flavor in device.flavors {
            do {
                check.latest[flavor] = try await cdn.version(product: flavor.product, region: flavor.region)
            } catch let e as CancellationError {
                throw e
            } catch {
                check.unchecked[flavor] = error.localizedDescription
            }
        }
        return check
    }

    // MARK: The device's game clients

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

    /// What the Mac does about a game's client on the device (Library/spgames/wow-<flavor>), from the stamp
    /// beside it (nil: none) and the build the Mac sends (`mac`, Blizzard's current one): copy it when the
    /// device's is missing or older. The device is the record, so this Mac keeps none of its own, and a newer
    /// build the device fetched itself, or one whose version can't be told apart, is never replaced
    /// (`newerOnDevice`: its game data's row and configs stay the device's too, GameFiles.plan's `ahead`).
    /// The same build or version is the same client, as the launcher's sp_update_caught_up counts it:
    /// another region's build of a version isn't copied over.
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

    /// Copies `flavor`'s client of `version` (the CDN's arm64 slice, cached) into the device's
    /// Library/spgames (`copyClient(_:stamp:...)`), with its .build.info row from the patch service. Returns
    /// the slice's size.
    @discardableResult
    static func copyClient(_ flavor: Flavor, version: BlizzardCDN.Version, to device: Device, against exports: BindCheck.Manifest,
                           log: (String) -> Void, beforeWrite: () async throws -> Void) async throws -> Int64 {
        let (slice, stamp) = try await clientSlice(flavor, version: version, log: log)
        let cdn = try await cdn.connected(product: flavor.product, region: flavor.region)
        guard let cdns = cdn.cdns else { throw Failure("Blizzard's patch service lists no CDN for \(flavor.name).") }
        let row = GameStore.buildInfoText([BlizzardCDN.buildInfoLine(product: flavor.product, version: version, cdns: cdns,
                                                                     tags: flavor.tags)])
        try await copyClient(slice, stamp: stamp, row: row, flavor: flavor, against: exports, platform: device.platform,
                             log: log, beforeWrite: beforeWrite) { try await device.copy($0, to: $1) }
        return Int64((try? slice.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// `flavor`'s client of `version` from Blizzard's CDN: its arm64 slice, cached in Paths.cdn, and the
    /// stamp for it.
    private static func clientSlice(_ flavor: Flavor, version: BlizzardCDN.Version,
                                    log: (String) -> Void) async throws -> (URL, ClientAssembly.Stamp) {
        let product = flavor.product, region = flavor.region
        let start = Date()
        let slice = try await cdn.connected(product: product, region: region)
            .slice(product: product, region: region, buildConfig: version.buildConfig, cdnConfig: version.cdnConfig,
                   executable: flavor.clientPath).slice
        let size = (try? slice.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log("\(flavor.rawValue) \(version.versionsName): the client's arm64 slice from Blizzard's CDN "
            + "(\(size / 1_000_000) MB, \(String(format: "%.1f", Date().timeIntervalSince(start))) s, cached)")
        return (slice, .from(product: product, version: version))
    }

    /// The copy of one game's client, for the launcher that loads the unchanged client with spguest
    /// (apps/client/spguestlaunch.m), through `write` (Device.copy: a file to a path in the app's data
    /// container). First the bind check (BindCheck.require: `slice` against the bundled shims' `exports`), so
    /// a client with an import nothing provides stops here with BindCheck.Unsupported and nothing of it
    /// reaches the device. Then the slice as wow-<flavor>, its .build.info `row` (spbuildinfo-<flavor>, as an
    /// update on the device keeps it), spsource-<flavor> (`mac`), and `stamp` last, so a stamp is only ever
    /// beside a whole client of its build. devicectl can't delete, so the stamp is emptied first, whatever
    /// the device's listing showed (a stamp it couldn't parse included): a copy cut short leaves no stamp
    /// naming the old build beside the new client. `beforeWrite` runs once the slice binds, just before the
    /// first write (the caller stops a client running on the device there), so a check or a download that
    /// fails touches nothing on the device.
    static func copyClient(_ slice: URL, stamp: ClientAssembly.Stamp, row: String, flavor: Flavor,
                           against exports: BindCheck.Manifest, platform: String, log: (String) -> Void,
                           beforeWrite: () async throws -> Void, write: (URL, String) async throws -> Void) async throws {
        try await BindCheck.require(slice, flavor: flavor.rawValue, against: exports, platform: platform, onLine: log)
        try await beforeWrite()
        let staging = FileManager.default.temporaryDirectory.appending(path: "spgames-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        func staged(_ name: String, _ text: String) throws -> URL {
            let url = staging.appending(path: name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let dir = "Library/spgames/", stampPath = dir + ClientAssembly.Stamp.fileName(flavor.rawValue)
        try await write(try staged("empty", ""), stampPath)
        try await write(slice, dir + "wow-\(flavor.rawValue)")
        try await write(try staged("row", row), dir + "spbuildinfo-\(flavor.rawValue)")
        try await write(try staged("source", "mac\n"), dir + sourceFile(flavor))
        try await write(try staged("stamp", stamp.text), stampPath)
    }

    /// UserDefaults key of the device's clients newer than Blizzard's current build (ClientCopy.newerOnDevice),
    /// as the last action found them (flavor -> version), for the main window.
    static func aheadKey(_ device: Device) -> String { "updatedOnDevice.\(device.udid)" }

    /// The device's games whose client is newer than the one this Mac sends, by version, as last seen.
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

    /// Builds the device app (ClientAssembly) and signs it, without installing. The log goes to
    /// ~/Library/Logs/Slashplayed/build.txt too. `beforeSigning` runs once the app is assembled, before
    /// Xcode provisions for the device, which has to be unlocked then (Pipeline.waitForUnlock).
    static func build(_ device: Device, beforeSigning: () async throws -> Void = {},
                      onLine: @escaping (String) -> Void) async throws {
        let logFile = LogFile(Paths.logs.appending(path: "build.txt"), t0: Date())
        let log = { (line: String) in
            logFile.write(line)
            DispatchQueue.main.async { onLine(line) }
        }
        do {
            try await assembleAndSign(device, beforeSigning: beforeSigning, log: log)
        } catch {
            log("failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func assembleAndSign(_ device: Device, beforeSigning: () async throws -> Void,
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
        let entitlements = dir.appending(path: "entitlements.plist")
        let helperEntitlements = dir.appending(path: "helper-entitlements.plist")
        let dropped = Signing.dropped(for: team)
        log("assembling the app for \(platform.name)")
        try await ClientAssembly.assemble(app: app, platform: platform, platformResources: Paths.platformResources(device),
                                          templates: Paths.resource("client"), addons: Paths.resource("addons"),
                                          team: team.id, bundleID: bundleID,
                                          entitlements: entitlements, helperEntitlements: helperEntitlements,
                                          droppedEntitlements: dropped)
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
        let shims = try FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Frameworks").path)
            .filter { $0.hasSuffix(".dylib") }.sorted().map { app.appending(path: "Frameworks/\($0)").path }
        log("signing")
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", identity.hash] + shims)
        // Inside out: the helper is sealed into the app's signature, so it's signed before the app.
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", helperIdentity.hash, "--entitlements", helperEntitlements.path, helper.path])
        try await Shell.run("/usr/bin/codesign", ["-f", "-s", identity.hash, "--entitlements", entitlements.path, app.path])
        try ([bundleID, resourcesMark(device)] + dropped).joined(separator: " ").write(to: buildComplete(device), atomically: true, encoding: .utf8)
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
        setInstalled(Installed(build: build, url: url, bundleID: bundleID), for: device)
    }

}
