import Foundation

/// Brings the game files in the device app's Documents/ up to date with the Mac install, laid out as
/// apps/client/seed.sh lays them out: Documents/.build.info and Data/ (the Mac's World of Warcraft/,
/// shared by every flavor), and each flavor's own folder (.flavor.info, a first-run Config.wtf, the
/// SPMovie addon, and on the headset SPHover). A file is copied when the device's copy is missing or differs in size
/// or mtime: devicectl keeps the Mac's mtime, so after a patch only the files Battle.net touched are
/// copied. devicectl can't delete files, so the index files a patch replaced are listed for the device's
/// launcher to delete at its next start (Library/spdelete.txt, apps/client/launcher.m).
/// A device that holds only some of the installed flavors gets only the data.NNN archives their builds
/// use (GameStore, as seed.sh's SP_DATA_PRODUCTS), worked out again at each sync since a patch
/// can put blocks in new archives; every other file in Data/ is copied as usual. Archives on the device
/// that none of them use (a flavor was unticked) are listed for deletion the same way.
/// Copying is a per-device choice (Device.copiesGameFiles). Without it the device's client streams its
/// game data from Blizzard itself, into the same Documents/Data/, and the companion sends only what it
/// needs to start (plan), from Blizzard's CDN: no game install on the Mac is needed. Since both write the
/// store, a copy never mixes them: the store goes whole or not at all. A copy of the store cut short is
/// finished at the next sync whether or not the device copies (copyMarker).
enum GameFiles {
    struct Copy {
        var source: URL
        var destination: String
        var size: Int64
        /// The size of the device's copy it replaces (0 if none), for the space check.
        var replacing: Int64
        /// Why it's copied, for the log (Reason.summary).
        var reason: Reason = .missing
    }

    /// Why a file is copied: the device has none, its copy is another size, or (a file not named by its
    /// content) the same size with another date. Sizes and dates only, so the log says what a copy was
    /// for without reading a file: the acceptance run's 24 GB copy of a streamed store read, from the
    /// log alone, like a full store re-sent.
    enum Reason: Equatable {
        case missing
        case size(device: Int64)
        case date(device: Date)
    }

    /// The device file (Library/spcopying.txt) that says whether a copy of the store finished. The
    /// device's client and a copy both write the store, and their archives and indexes don't mix: the
    /// client reads the newest index of each bucket, so a store the client streamed whose archives a copy
    /// then replaced, stopped before the Mac's indexes went, has every game quit as "damaged" (the
    /// iPhone, 2026-10-29). No order of copies avoids that window and devicectl can't rename, so the copy
    /// says it's under way (`copying`) before the store's first file and that it finished (`done`) after
    /// its last; one cut short at any point leaves `copying`. Then the next sync finishes it, even for a
    /// device that doesn't copy, and the launcher won't load a game over it (apps/client/launcher.m,
    /// copy_unfinished). Told apart by size, from the device's file list, without a fetch.
    static let copyMarker = "Library/spcopying.txt"
    static let copyMarkerCopying = "copying\n", copyMarkerDone = "done\n"

    /// Whether the device's copy marker (its size; nil if it has none) says a copy of the store stopped.
    static func copyUnfinished(markerSize: Int64?) -> Bool {
        markerSize == Int64(copyMarkerCopying.utf8.count)
    }

    /// Whether a sync copies the Mac's game files: when the device copies them (`asked`), or to finish a
    /// copy of the store cut short (`unfinished`), whatever the device's setting, if there's a game
    /// install on the Mac to finish it from.
    static func copies(asked: Bool, unfinished: Bool, macInstall: Bool) -> Bool {
        asked || unfinished && macInstall
    }

    /// Whether `copies` needs to know if there's a Mac install, which means reading it: only to finish a
    /// copy that stopped on a device that doesn't copy (one that copies has had its install read already).
    static func readsInstall(asked: Bool, unfinished: Bool) -> Bool {
        !asked && unfinished
    }

    /// The copies in the order they go: the configs, the CDN indexes, the archives, and the rest, then the
    /// store's indexes, then .build.info (the old indexes stay readable for as long as they can), and, when
    /// any of the store goes, `marker` (the copy marker saying `copying`) just before its first file: a
    /// copy stopped before that left the store as it was, and finishing it would copy a whole store to a
    /// device that doesn't copy. The `done` marker isn't among them: the sync sends it once every copy
    /// succeeded (Plan.markDone).
    static func ordered(_ copies: [Copy], marker: () throws -> Copy) rethrows -> [Copy] {
        func rank(_ c: Copy) -> Int {
            c.destination.hasSuffix("/.build.info") ? 2 : c.destination.hasSuffix(".idx") ? 1 : 0
        }
        var sorted = copies.enumerated().sorted { (rank($0.1), $0.0) < (rank($1.1), $1.0) }.map(\.1)
        if let first = sorted.firstIndex(where: isStore) { sorted.insert(try marker(), at: first) }
        return sorted
    }

    /// A copy into the store: Data/'s archives and indexes, not its configs and CDN indexes.
    static func isStore(_ c: Copy) -> Bool {
        let prefix = "Documents/Data/"
        return c.destination.hasPrefix(prefix) && !namedByContent(String(c.destination.dropFirst(prefix.count)))
    }

    /// How long the install must go untouched before syncing, so a running Battle.net update finishes first.
    static let quietPeriod: TimeInterval = 120

    /// The most recently changed file in Data/ and .build.info, and when, if it changed within the quiet period.
    static func recentWrite() -> (path: String, date: Date)? {
        var newest: (String, Date)?
        for (url, info) in macFiles(Flavor.installRoot.appending(path: "Data")) + [(buildInfo, attributes(buildInfo))] {
            // Battle.net rewrites each CASC folder's shmem whenever it starts or checks versions.
            guard url.lastPathComponent != "shmem", let date = info?.date else { continue }
            if newest == nil || date > newest!.1 { newest = (url.lastPathComponent, date) }
        }
        guard let newest, Date().timeIntervalSince(newest.1) < quietPeriod else { return nil }
        return newest
    }

    struct Plan {
        var copies: [Copy]
        /// Device paths to delete: index files the Mac no longer has.
        var staleIndexes: [String]
        var staleIndexBytes: Int64
        /// Device archives (Documents/Data/data/data.NNN) none of the device's flavors use.
        var unusedArchives: [String]
        var unusedArchiveBytes: Int64
        /// Unused archives weren't looked for, since a chosen flavor isn't installed on the Mac.
        var keptArchives: Bool
        /// Why the device's game store (the archives and their indexes) wasn't copied, when copying
        /// was asked for; nil if it was (or copying wasn't asked for).
        var storeKept: StoreKept?
        /// The device's games Battle.net updated on this Mac that haven't run here since (with the dates,
        /// for the log); when there are any, storeKept is macUnplayed or a reason ahead of it.
        var unplayed: [Unplayed] = []
        /// The device's last copy of the store stopped before it finished (copyMarker) and this one finishes
        /// it, though the device doesn't copy game files (`copy` was false).
        var finishing = false
        /// The device's last copy of the store stopped before it finished and this sync can't finish it
        /// (storeKept says why; nil: there's no game install on the Mac). The game can't start until it is.
        var unfinished = false
        /// Sent after every copy succeeded (the sync's last, before the deletions): the copy marker saying
        /// the store's copy finished. Nil when the store isn't copied, or nothing of it goes and no copy
        /// of it was left unfinished.
        var markDone: Copy?

        var deletions: [String] { staleIndexes + unusedArchives }

        /// The space the copies take beyond the files they replace.
        var copyGrowth: Int64 { copies.reduce(0) { $0 + max($1.size - $1.replacing, 0) } }
    }

    enum StoreKept: Equatable {
        /// The device has a newer build of these products (.build.info's Product) than its client images.
        case newerOnDevice([String])
        /// The Mac's install of these products is another build than the device's images (Battle.net
        /// hasn't updated it to Blizzard's current one yet), so its data isn't the images' build.
        case macDiffers([String])
        /// Battle.net updated these products on this Mac to the images' build, but they haven't run here
        /// since, so their data in the shared store may not be finished (Unplayed).
        case macUnplayed([String])
        /// The device's client wrote this many index files that outrank the Mac's (GameStore.outranking).
        case deviceWrote(Int)
    }

    /// A game's build as the companion writes it to a device: the build of its client image, as its
    /// .build.info line (BlizzardCDN.buildInfoLine) and the configs that line names (build, CDN, and
    /// Retail's KeyRing; key -> bytes, from Blizzard's CDN).
    struct Build {
        var product: String
        var buildKey: String
        var line: String
        var configs: [String: Data]
    }

    /// The flavor's `version` (its image's build) from Blizzard: the cdns row for its line, and the configs.
    static func build(_ flavor: Flavor, version: BlizzardCDN.Version) async throws -> Build {
        let cdn = try await ClientBuild.cdn.connected(product: flavor.product, region: flavor.region)
        guard let cdns = cdn.cdns else { throw Failure("Blizzard's patch service lists no CDN for \(flavor.name).") }
        var configs: [String: Data] = [:]
        for key in [version.buildConfig, version.cdnConfig, version.keyRing] where !key.isEmpty {
            configs[key] = try await cdn.configData(key)
        }
        return Build(product: flavor.product, buildKey: version.buildConfig,
                     line: BlizzardCDN.buildInfoLine(product: flavor.product, version: version, cdns: cdns, tags: flavor.tags),
                     configs: configs)
    }

    /// What brings the device up to date for `flavors`, and the old index files to delete. `builds` are the
    /// builds of the device's client images (Build): their .build.info rows and configs are sent whether or
    /// not the store is copied, so the device's game data always names the build of its images; an empty
    /// list leaves .build.info as it is. With `copy`, the Mac's game files too: its configs and CDN indexes,
    /// and the store (the archives and their indexes) as one, all or nothing, archives first and .build.info
    /// last. The store goes only when every chosen game the Mac has is the build of its image
    /// (`images`: product -> Build Key) and has run on the Mac since Battle.net put that build there
    /// (Unplayed); otherwise the device's client fetches what its build needs itself.
    /// Without `copy`, only what the client needs to start and stream the rest: .build.info, the configs,
    /// and each flavor's folder. Either way the device's .build.info is read first, and a product whose
    /// build on the device is newer than its image's keeps its row (GameStore.deviceBuildInfo), as does one
    /// in `ahead`, whose image an update on the device made is a later build (ClientBuild.deviceUpdate; the
    /// caller leaves its build out of `builds`): nothing of an older build goes to either. A copy of the
    /// store the device's copy marker says stopped is finished as if `copy` were true (Plan.finishing),
    /// when there's a game install on the Mac and nothing keeps the store (Plan.unfinished otherwise).
    /// `macInstall` says whether there's one (Pipeline: a time-limited read, GameInstall), asked only then
    /// (readsInstall): without `copy` and an unfinished copy, nothing here touches the Mac's install.
    static func plan(_ flavors: [Flavor], on device: Device, copy asked: Bool, builds: [Build],
                     images: [String: String], ahead: [String] = [],
                     macInstall: () async throws -> Bool) async throws -> Plan {
        let onDevice = try await device.files(in: "Documents", recursive: true)
            .reduce(into: [:]) { $0["Documents/" + $1.key] = $1.value }
        let library = try await device.files(in: "Library", recursive: false)
        let unfinished = copyUnfinished(markerSize: library[(copyMarker as NSString).lastPathComponent]?.size)
        let copy = copies(asked: asked, unfinished: unfinished,
                          macInstall: readsInstall(asked: asked, unfinished: unfinished) ? try await macInstall() : false)
        let finishing = copy && !asked
        var mac: (date: Date, table: GameStore.BuildInfo)?
        if copy {
            guard let text = try? String(contentsOf: buildInfo, encoding: .utf8), let date = attributes(buildInfo)?.date,
                  let table = GameStore.BuildInfo(text) else {
                throw Failure("There's no game install on this Mac to copy game files from (no \(buildInfo.path)).")
            }
            mac = (date, table)
        }
        let deviceDate = onDevice["Documents/.build.info"]?.date
        var deviceText: String?
        if deviceDate != nil {
            let url = try staging("device-build-\(device.udid).info")
            try? FileManager.default.removeItem(at: url)
            try await Device.retrying { try await device.fetch("Documents/.build.info", to: url) }
            deviceText = try String(contentsOf: url, encoding: .utf8)
        }
        let merged = builds.isEmpty ? nil
            : GameStore.deviceBuildInfo(mac: GameStore.buildInfoText(builds.map(\.line)), device: deviceText)
        let newer = Set((merged?.newer ?? []) + ahead).sorted()
        let data = Flavor.installRoot.appending(path: "Data")
        let macData = mac == nil ? [] : macFiles(data).map { (url: $0.0, relative: String($0.0.path.dropFirst(data.path.count + 1))) }

        // Indexes the device's client wrote since the last copy (newer than its .build.info, which
        // devicectl gave the Mac's date): never deleted, and if they'd outrank the Mac's, the store stays.
        let prefix = "Documents/Data/"
        var written: [String] = []
        if let since = deviceDate {
            for (path, info) in onDevice where path.hasPrefix(prefix) && path.hasSuffix(".idx") && info.date > since {
                written.append(String(path.dropFirst(prefix.count)))
            }
        }
        // Not after a copy cut short: the client's indexes then point into archives the copy replaced.
        let outranking = unfinished ? []
            : GameStore.outranking(device: written, mac: macData.map(\.relative).filter { $0.hasSuffix(".idx") })
        let macRows = mac?.table.byProduct ?? [:]
        let differs = device.installedFlavors.map(\.product).filter { p in macRows[p]?["Build Key"] != images[p] }
        let unplayed = !copy ? [] : unplayedSincePatch(root: Flavor.installRoot, rows: macRows, games:
            device.installedFlavors.filter { !differs.contains($0.product) }.map { ($0.product, $0.folder) })
        let storeKept = storeKept(copy: copy, newer: newer, differs: differs, unplayed: unplayed.map(\.product),
                                  outranking: outranking.count)
        let copyStore = copy && storeKept == nil

        var copies: [Copy] = [], considered: Set<String> = []
        /// Copied when the device's copy is missing or differs in size or, unless `sizeOnly`, date
        /// (`sizeOnly`: a file named by its content, or one the companion generates that only changes with
        /// its size). The first source for a destination wins (a config from Blizzard over the Mac's).
        func consider(_ source: URL, _ destination: String, sizeOnly: Bool = false) {
            guard considered.insert(destination).inserted, let info = attributes(source),
                  let reason = whyCopy(have: onDevice[destination], source: info, sizeOnly: sizeOnly) else { return }
            copies.append(Copy(source: source, destination: destination, size: info.size,
                               replacing: onDevice[destination]?.size ?? 0, reason: reason))
        }
        let current = flavors.filter { !newer.contains($0.product) }
        // The configs the builds' rows name, from Blizzard: named by their content, so one the device
        // has (the same name and size) is the same file.
        for build in builds where !newer.contains(build.product) {
            for (key, bytes) in build.configs.sorted(by: { $0.key < $1.key }) {
                let url = try staging("config-\(key)")
                try bytes.write(to: url)
                consider(url, prefix + configPath(key), sizeOnly: true)
            }
        }
        let archives = copyStore && device.holdsDataSubset ? try await archives(device.installedFlavors) : nil
        for (url, relative) in macData {
            // Configs and CDN indexes are named by their content, so a copy only ever adds, and one the
            // device has is the same file whatever its date; the rest of Data/ is the store.
            let byContent = namedByContent(relative)
            if !byContent {
                guard copyStore else { continue }
                if let archives, let n = relative.firstMatch(of: /^data\/data\.([0-9]{3})$/), !archives.contains(Int(n.1)!) {
                    continue
                }
            }
            consider(url, prefix + relative, sizeOnly: byContent)
        }
        if let merged, merged.text != deviceText {
            // Dated a second after the device's (or after the Mac's, when the store is copied), so it never
            // has the device's file's size and date: devicectl skips a copy whose source matches the
            // destination in both (a same-size version swap was left unsent). And no later than that, so
            // the indexes the device's client writes stay newer than it (written, above).
            let url = try staging("build-\(device.udid).info")
            try merged.text.write(to: url, atomically: true, encoding: .utf8)
            let base = deviceDate.map { max($0, copyStore ? mac!.date : $0) } ?? (copyStore ? mac!.date : Date())
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(1)], ofItemAtPath: url.path)
            consider(url, "Documents/.build.info")
        }
        for flavor in current {
            try planFlavor(flavor, hover: device.kind == .headset, onDevice: onDevice, consider: { consider($0, $1, sizeOnly: $2) })
        }
        func marker(_ text: String) throws -> Copy {
            let url = try staging("spcopying-\(device.udid)-\(text.dropLast()).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return Copy(source: url, destination: copyMarker, size: Int64(text.utf8.count),
                        replacing: library[(copyMarker as NSString).lastPathComponent]?.size ?? 0)
        }
        let sorted = try ordered(copies, marker: { try marker(copyMarkerCopying) })
        let stale = copyStore ? staleIndexes(onDevice: onDevice, data: data, before: min(mac!.date, deviceDate ?? .distantPast)) : []
        let keptArchives = archives != nil && !device.missingFlavors.isEmpty
        let unused = keptArchives ? [] : archives.map { unusedArchives(onDevice: onDevice, using: $0, data: data) } ?? []
        let bytes = { (paths: [String]) in paths.reduce(Int64(0)) { $0 + (onDevice[$1]?.size ?? 0) } }
        return Plan(copies: sorted, staleIndexes: stale, staleIndexBytes: bytes(stale),
                    unusedArchives: unused, unusedArchiveBytes: bytes(unused), keptArchives: keptArchives,
                    storeKept: storeKept, unplayed: unplayed, finishing: finishing && copyStore, unfinished: unfinished && !copyStore,
                    // Also when nothing of the store is left to copy: a copy stopped after its last file.
                    markDone: copyStore && (unfinished || sorted.contains(where: isStore)) ? try marker(copyMarkerDone) : nil)
    }

    /// Whether the device's copy of a file (`have`, nil when it has none) is replaced by `source`: when it's
    /// missing or another size, or, unless `sizeOnly`, dated a second or more apart. A device's dates are
    /// devicectl's copy of the Mac's, so a date only says something about a file whose name doesn't.
    static func needsCopy(have: (size: Int64, date: Date)?, source: (size: Int64, date: Date), sizeOnly: Bool) -> Bool {
        whyCopy(have: have, source: source, sizeOnly: sizeOnly) != nil
    }

    /// needsCopy's answer with its reason: nil when the device's copy stays.
    static func whyCopy(have: (size: Int64, date: Date)?, source: (size: Int64, date: Date), sizeOnly: Bool) -> Reason? {
        guard let have else { return .missing }
        guard have.size == source.size else { return .size(device: have.size) }
        return !sizeOnly && abs(have.date.timeIntervalSince(source.date)) >= 1 ? .date(device: have.date) : nil
    }

    /// The log's account of a plan's copies of the store (the archives and their indexes, data/ and the
    /// per-product folders, not the configs, CDN indexes, or generated files): how many for each reason,
    /// and the first `limit` of each with the device's size or date against the Mac's. Empty when the
    /// store isn't copied.
    static func storeSummary(_ copies: [Copy], limit: Int = 5) -> [String] {
        let prefix = "Documents/Data/"
        let store = copies.filter(isStore)
        guard !store.isEmpty else { return [] }
        let missing = store.filter { $0.reason == .missing }
        let sized = store.filter { if case .size = $0.reason { true } else { false } }
        let dated = store.filter { if case .date = $0.reason { true } else { false } }
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        let day = ISO8601DateFormatter()
        func name(_ c: Copy) -> String { String(c.destination.dropFirst(prefix.count)) }
        var lines = ["store: \(SetupStatus.count(store.count, "file")), \(bytes(store.reduce(0) { $0 + $1.size })): \(missing.count) not on the device, \(sized.count) another size, \(dated.count) the same size with another date"]
        for c in sized.prefix(limit) {
            if case .size(let device) = c.reason { lines.append("store: \(name(c)): device \(bytes(device)), Mac \(bytes(c.size))") }
        }
        for c in dated.prefix(limit) {
            if case .date(let device) = c.reason {
                let mac = (try? c.source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                lines.append("store: \(name(c)): device \(day.string(from: device)), Mac \(mac.map(day.string) ?? "?")")
            }
        }
        if !missing.isEmpty {
            lines.append("store: not on the device: \(missing.prefix(limit).map(name).joined(separator: " "))\(missing.count > limit ? " …" : "")")
        }
        return lines
    }

    /// A file in Data/ (`relative` to it) named by its content: the configs (config/ab/cd/<key>) and the
    /// CDN indexes (indices/<key>.index). Everything else there (the archives, their .idx files, and the
    /// per-product .idx folders) keeps its name as its content changes.
    static func namedByContent(_ relative: String) -> Bool {
        relative.hasPrefix("config/") || relative.hasPrefix("indices/")
    }

    /// Why a copy leaves the device's store as it is (nil: it's copied, or copying wasn't asked for), in this
    /// order: a product is newer on the device (its .build.info row, or an update it made), the Mac's install
    /// isn't the images' build, it is but hasn't run on the Mac since Battle.net put it there (`unplayed`),
    /// or the device's client wrote `outranking` indexes of its own.
    static func storeKept(copy: Bool, newer: [String], differs: [String], unplayed: [String] = [],
                          outranking: Int) -> StoreKept? {
        !copy ? nil : !newer.isEmpty ? .newerOnDevice(newer)
            : !differs.isEmpty ? .macDiffers(differs) : !unplayed.isEmpty ? .macUnplayed(unplayed)
            : outranking > 0 ? .deviceWrote(outranking) : nil
    }

    /// A game Battle.net updated on this Mac that hasn't run here since. Battle.net's update doesn't leave
    /// a game's part of the shared store finished: it finishes it after the game's next session on the Mac
    /// (its Agent logs an update of the game as each session closes). Copied before that, the store can
    /// hold the game's build in .build.info, with the same Build Key as the device's image, and still not
    /// be readable by it: TBC Anniversary 2.5.6.70577, patched on 2026-10-26 and then not run on the Mac
    /// while Retail's patch rewrote the shared archives, quit on the iPhone after a full copy with "Invalid
    /// schema … for Table StartupFiles". Its first session on the Mac, through Battle.net, was followed by
    /// an update rewriting two archives, ten shared indexes, and the game's own; a copy of those 1.64 GB
    /// and it played. Battle.net's own state (download and patch complete, playable) said nothing.
    /// `patched` is when its build arrived (Data/config/<Build Key>, written as the update starts);
    /// `lastRun` when the game last ran here (the newest file in its folder's Logs/, which the client
    /// writes each session), nil if it never has.
    struct Unplayed: Equatable {
        var product: String
        var patched: Date
        var lastRun: Date?
    }

    /// The files step's line for StoreKept.macUnplayed: the games by name, on the device (its noun).
    static func unplayedLine(_ games: [String], device: String) -> String {
        let one = games.count == 1
        return "This Mac's \(SetupStatus.list(games)) \(one ? "hasn't" : "haven't") run since Battle.net updated \(one ? "it" : "them"), so \(one ? "its" : "their") game data may be unfinished and the \(device)'s was left as it is; the game fetches what it needs itself. Play \(one ? "it" : "each") once on this Mac through Battle.net, and the next Play copies \(one ? "it" : "them")."
    }

    /// Whether a game whose build arrived at `patched` (nil: unknown, so nothing says it's unfinished) and
    /// that last ran at `lastRun` (nil: never) hasn't run since.
    static func unplayed(patched: Date?, lastRun: Date?) -> Bool {
        guard let patched else { return false }
        return lastRun.map { $0 < patched } ?? true
    }

    /// The `games` (product, folder) whose builds in `rows` (the install's .build.info by product) are
    /// unplayed on the install at `root`. Dates only: nothing in the store is read.
    static func unplayedSincePatch(root: URL, rows: [String: [String: String]],
                                   games: [(product: String, folder: String)]) -> [Unplayed] {
        games.compactMap { game in
            guard let key = rows[game.product]?["Build Key"], key.count > 4,
                  let patched = attributes(root.appending(path: "Data/" + configPath(key)))?.date else { return nil }
            let logs = root.appending(path: "\(game.folder)/Logs")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
            let lastRun = names.compactMap { attributes(logs.appending(path: $0))?.date }.max()
            return unplayed(patched: patched, lastRun: lastRun)
                ? Unplayed(product: game.product, patched: patched, lastRun: lastRun) : nil
        }
    }

    /// config/ab/cd/abcd…, where a config is in Data/.
    static func configPath(_ key: String) -> String { "config/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)" }

    /// The archives on the device not in `used` (a successful GameStore run for the device's flavors,
    /// never empty). Only data.NNN files, and only ones the Mac has too, so nothing the device's
    /// client made itself is deleted.
    private static func unusedArchives(onDevice: [String: (size: Int64, date: Date)], using used: Set<Int>,
                                       data: URL) -> [String] {
        guard !used.isEmpty else { return [] }
        return onDevice.keys.sorted().filter { path in
            guard let n = path.firstMatch(of: /^Documents\/Data\/data\/data\.([0-9]{3})$/) else { return false }
            return !used.contains(Int(n.1)!) &&
                FileManager.default.fileExists(atPath: data.appending(path: "data/data.\(n.1)").path)
        }
    }

    /// What the flavors need on a device, from the Mac's install: the archives they use (all of them if
    /// they're every installed flavor), the rest of Data/, and .build.info. Slow (GameStore reads every
    /// index; a few seconds), so the caller caches it.
    static func size(of flavors: [Flavor]) async throws -> Int64 {
        let subset = !Flavor.installed.allSatisfy(flavors.contains)
        let used = subset ? try await archives(flavors.filter(Flavor.installed.contains)) : nil
        return try await Task.detached {
            let data = Flavor.installRoot.appending(path: "Data")
            var total = attributes(buildInfo)?.size ?? 0
            for (url, info) in macFiles(data) {
                let relative = String(url.path.dropFirst(data.path.count + 1))
                if let used, let n = relative.firstMatch(of: /^data\/data\.([0-9]{3})$/), !used.contains(Int(n.1)!) {
                    continue
                }
                total += info?.size ?? 0
            }
            try Task.checkCancellation()
            return total
        }.value
    }

    /// When the install last changed (its .build.info), to know when a cached size is out of date.
    static var installDate: Date? { GameInstall.known?.buildInfoDate }

    /// The index files in the device's Documents/Data/ that a patch replaced on the Mac (Retail 12.1.0 ->
    /// 12.1.5 left 0.33 GB): local CASC indexes (.idx) and CDN archive indexes (indices/*.index) the Mac
    /// doesn't have. Only files older than `before` (the older of the Mac's .build.info and the device's,
    /// which has the Mac's date from the last copy), so nothing the device's client wrote since then; and
    /// an .idx only when the Mac has another index for its bucket (the first two hex digits of the name,
    /// e.g. 0a00000012.idx), which the sync copies, so a bucket never loses its last index, even if the
    /// Mac's Data/ is half gone.
    private static func staleIndexes(onDevice: [String: (size: Int64, date: Date)], data: URL, before patched: Date) -> [String] {
        let prefix = "Documents/Data/"
        var macBuckets: [String: Set<String>] = [:]  // directory -> buckets
        var deletions: [String] = []
        for (path, info) in onDevice.sorted(by: { $0.key < $1.key }) where path.hasPrefix(prefix) && info.date < patched {
            let relative = String(path.dropFirst(prefix.count))
            let dir = (relative as NSString).deletingLastPathComponent
            let name = (relative as NSString).lastPathComponent
            guard name.hasSuffix(".idx") || (dir == "indices" && name.hasSuffix(".index")),
                  !FileManager.default.fileExists(atPath: data.appending(path: relative).path) else { continue }
            if name.hasSuffix(".index") {
                deletions.append(path)
                continue
            }
            if macBuckets[dir] == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: data.appending(path: dir).path)) ?? []
                macBuckets[dir] = Set(names.filter { $0.hasSuffix(".idx") && $0.count == 14 }.map { String($0.prefix(2)) })
            }
            if name.count == 14, macBuckets[dir]!.contains(String(name.prefix(2))) { deletions.append(path) }
        }
        return deletions
    }

    /// Writes the delete list for the launcher (replacing any older one, so a file the Mac has again is
    /// never deleted) to Library/spdelete.txt.
    static func sendDeletions(_ paths: [String], to device: Device) async throws {
        let url = try staging("spdelete.txt")
        try paths.map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        try await device.copy(url, to: "Library/spdelete.txt")
    }

    /// The data.NNN archives the flavors' current builds use (GameStore; reads every index, a few seconds).
    private static func archives(_ flavors: [Flavor]) async throws -> Set<Int> {
        let usage = try await Task.detached {
            try GameStore.archives(root: Flavor.installRoot, products: flavors.map(\.product))
        }.value
        guard !usage.archives.isEmpty else {
            throw Failure("Found no game store archives for \(flavors.map(\.name).joined(separator: ", ")).")
        }
        return usage.archives
    }

    /// Makes sure the device has Library/spidentity, the small identity file login needs from the Mac
    /// (MacIdentity); without it login sits at "Connecting". A new device needs it once. True if it was sent.
    static func sendIdentityIfMissing(to device: Device) async throws -> Bool {
        if try await device.files(in: "Library", recursive: false)["spidentity"] != nil { return false }
        let out = try staging("spidentity")
        try MacIdentity.contents().write(to: out)
        try await device.copy(out, to: "Library/spidentity")
        return true
    }

    /// The game's .flavor.info, as Battle.net writes it in the game's folder: its product, as a one-column
    /// table.
    static func flavorInfo(_ flavor: Flavor) -> String { "Product Flavor!STRING:0\n\(flavor.product)\n" }

    private static func planFlavor(_ flavor: Flavor, hover: Bool, onDevice: [String: (size: Int64, date: Date)],
                                   consider: (URL, String, Bool) -> Void) throws {
        let folder = "Documents/\(flavor.folder)"
        let info = try staging(".flavor-\(flavor.rawValue).info")
        try flavorInfo(flavor).write(to: info, atomically: true, encoding: .utf8)
        consider(info, "\(folder)/.flavor.info", true)

        // The region and locale the Battle.net launcher would set, only if the device has no Config.wtf.
        if onDevice["\(folder)/WTF/Config.wtf"] == nil {
            let url = try staging("Config-\(flavor.rawValue).wtf")
            try "SET portal \"us\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\n".write(to: url, atomically: true, encoding: .utf8)
            consider(url, "\(folder)/WTF/Config.wtf", false)
        }

        // The addons (addon/install.sh), as they are: each TOC lists every flavor's Interface number, so
        // one copy suits each flavor's folder. SPMovie (a tap opens a cinematic's skip dialog) on every
        // device. SPHover only on the headset: the iPad and iPhone have a real pointer (hover; on the iPad
        // also pointer lock for mouselook; on the iPhone through AssistiveTouch).
        for name in hover ? ["SPMovie", "SPHover"] : ["SPMovie"] {
            let dir = Paths.addon(name)
            for file in ["\(name).toc", "\(name).lua"] {
                consider(dir.appending(path: file), "\(folder)/Interface/AddOns/\(name)/\(file)", false)
            }
        }
    }

    // MARK: Files

    private static var buildInfo: URL { Flavor.installRoot.appending(path: ".build.info") }

    private static func attributes(_ url: URL) -> (size: Int64, date: Date)? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              v.isRegularFile == true, let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return (Int64(size), date)
    }

    /// Every regular file under `dir`.
    private static func macFiles(_ dir: URL) -> [(URL, (size: Int64, date: Date)?)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys:
            [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var files: [(URL, (size: Int64, date: Date)?)] = []
        for case let url as URL in e {
            if let info = attributes(url) { files.append((url, info)) }
        }
        return files
    }

    /// A scratch file for generated content (Config.wtf, the addon TOC, spidentity).
    private static func staging(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spstaging")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
    }
}
