import XCTest

/// What the sync decides before it copies anything (GameFiles.plan): the device's .build.info against
/// the Mac's (GameStore.deviceBuildInfo), the device's own indexes against the Mac's (GameStore.outranking),
/// whether a device copies at all (Device.copiesGameFiles), and what an update the device made itself
/// (Library/spgames) means for both (ClientBuild.clientCopy). Made-up builds and keys, no Blizzard file.
final class CopyGameFilesTests: XCTestCase {
    private let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0"

    private func table(_ rows: [String]) -> String { ([header] + rows).map { $0 + "\n" }.joined() }

    func testVersions() {
        XCTAssertTrue(GameStore.isVersion("1.15.9.70003", newerThan: "1.15.9.69722"))
        XCTAssertTrue(GameStore.isVersion("1.15.10.1", newerThan: "1.15.9.70003"))
        XCTAssertTrue(GameStore.isVersion("12.1.5.70575", newerThan: "2.5.6.70006"))  // as numbers, not text
        XCTAssertFalse(GameStore.isVersion("1.15.9.69722", newerThan: "1.15.9.70003"))
        XCTAssertFalse(GameStore.isVersion("1.15.9.70003", newerThan: "1.15.9.70003"))
        XCTAssertTrue(GameStore.isVersion("1.15.9.1", newerThan: "1.15.9"))
        XCTAssertFalse(GameStore.isVersion("1.15.9", newerThan: "1.15.9.0"))
        // Can't be told apart: never newer.
        XCTAssertFalse(GameStore.isVersion("1.15.x", newerThan: "1.15.9"))
        XCTAssertFalse(GameStore.isVersion("", newerThan: "1.15.9"))
    }

    /// The device has what the Mac has, an older build, or nothing: the Mac's text, byte for byte, so
    /// a device already up to date gets nothing sent.
    func testMacWinsUnlessTheDeviceIsNewer() {
        let mac = table(["us|1|aaaa|1.15.9.70003|wow_classic_era", "us|1|bbbb|12.1.5.70575|wow"])
        for device in [nil, mac, table(["us|1|cccc|1.15.9.69722|wow_classic_era", "us|1|dddd|12.1.0.1|wow"]), ""] {
            let merged = GameStore.deviceBuildInfo(mac: mac, device: device)
            XCTAssertEqual(merged.text, mac)
            XCTAssertEqual(merged.newer, [])
        }
    }

    /// A product the device has a newer build of keeps the device's row, in the Mac's place for it and
    /// laid out by the Mac's columns; the others are the Mac's; a product only the device has is kept.
    func testTheDevicesNewerBuildIsKept() {
        let mac = table(["us|1|aaaa|1.15.9.70003|wow_classic_era", "eu|0|aaaa|1.15.9.70003|wow_classic_era",
                         "us|1|bbbb|12.1.5.70575|wow"])
        // The device's table has its columns in another order and one the Mac lacks.
        let device = "Product!STRING:0|Version!STRING:0|Build Key!HEX:16|Branch!STRING:0|Extra!STRING:0\n"
            + "wow_classic_era|1.15.10.71000|eeee|us|x\nwow|12.1.0.1|ffff|us|y\nwow_anniversary|2.5.6.70006|9999|us|z\n"
        let merged = GameStore.deviceBuildInfo(mac: mac, device: device)
        XCTAssertEqual(merged.newer, ["wow_classic_era"])
        XCTAssertEqual(merged.text, table(["us||eeee|1.15.10.71000|wow_classic_era", "us|1|bbbb|12.1.5.70575|wow",
                                           "us||9999|2.5.6.70006|wow_anniversary"]))
        // Written back to the device and merged again, nothing changes.
        XCTAssertEqual(GameStore.deviceBuildInfo(mac: mac, device: merged.text).text, merged.text)
        XCTAssertEqual(GameStore.BuildInfo(merged.text)?.byProduct["wow_classic_era"]?["Build Key"], "eeee")
    }

    func testLineEndingsAreKept() {
        let mac = header + "\r\nus|1|aaaa|1.15.9.70003|wow_classic_era\r\n"
        let device = table(["us|1|eeee|1.15.10.1|wow_classic_era"])
        XCTAssertEqual(GameStore.deviceBuildInfo(mac: mac, device: device).text,
                       header + "\r\nus|1|eeee|1.15.10.1|wow_classic_era\r\n")
    }

    /// Only an index the device wrote with a version above every one the Mac has for its bucket (folder
    /// and first two hex digits) would shadow the Mac's after a copy.
    func testIndexesThatOutrankTheMacs() {
        let mac = ["data/0000000012.idx", "data/0100000064.idx", "wow_classic_era/0000000019.idx", "data/data.000"]
        let device = ["data/0000000013.idx",            // above the Mac's 12: outranks
                      "data/0000000012.idx",            // the same name: the copy replaces it
                      "data/010000000b.idx",            // below the Mac's 64
                      "data/0200000001.idx",            // a bucket the Mac doesn't have
                      "wow_classic_era/0000000013.idx", // below that folder's 19
                      "ecache/0000000001.idx",          // a folder the Mac doesn't have
                      "data/shmem", "data/0000000099.idx.tmp"]
        XCTAssertEqual(GameStore.outranking(device: device, mac: mac),
                       ["data/0000000013.idx", "data/0200000001.idx", "ecache/0000000001.idx"])
        XCTAssertEqual(GameStore.outranking(device: [], mac: mac), [])
    }

    /// A config or CDN index the device has with the same name and size is the same file, whatever its date
    /// (a Play re-sent all 1512 indexes over dates alone); the store's files and generated ones still go by
    /// date too.
    func testContentNamedFilesGoBySizeOnly() {
        for relative in ["indices/0123456789abcdef0123456789abcdef.index", "config/01/23/0123456789abcdef0123456789abcdef"] {
            XCTAssertTrue(GameFiles.namedByContent(relative), relative)
        }
        for relative in ["data/data.051", "data/020000006b.idx", "wow_classic_era/0000000019.idx",
                         "ecache/0100000003.idx", "wow_classic_era/index.lock.0"] {
            XCTAssertFalse(GameFiles.namedByContent(relative), relative)
        }
        let mac = (size: Int64(4096), date: Date(timeIntervalSince1970: 1_800_000_000))
        let later = (size: mac.size, date: mac.date.addingTimeInterval(86_400))
        XCTAssertFalse(GameFiles.needsCopy(have: later, source: mac, sizeOnly: true))
        XCTAssertTrue(GameFiles.needsCopy(have: later, source: mac, sizeOnly: false))
        XCTAssertFalse(GameFiles.needsCopy(have: (mac.size, mac.date.addingTimeInterval(0.5)), source: mac, sizeOnly: false))
        XCTAssertTrue(GameFiles.needsCopy(have: (mac.size + 1, mac.date), source: mac, sizeOnly: true))
        XCTAssertTrue(GameFiles.needsCopy(have: nil, source: mac, sizeOnly: true))
    }

    /// Why each file goes, and the log's account of the store's: a streamed store (smaller archives, some
    /// missing) reads as that, not as a full store re-sent; configs and CDN indexes aren't the store.
    func testCopyReasons() {
        let mac = (size: Int64(1 << 30), date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(GameFiles.whyCopy(have: nil, source: mac, sizeOnly: false), .missing)
        XCTAssertEqual(GameFiles.whyCopy(have: (4096, mac.date), source: mac, sizeOnly: true), .size(device: 4096))
        let later = mac.date.addingTimeInterval(60)
        XCTAssertEqual(GameFiles.whyCopy(have: (mac.size, later), source: mac, sizeOnly: false), .date(device: later))
        XCTAssertNil(GameFiles.whyCopy(have: (mac.size, later), source: mac, sizeOnly: true))
        XCTAssertNil(GameFiles.whyCopy(have: mac, source: mac, sizeOnly: false))

        let source = URL(fileURLWithPath: "/nonexistent")
        func copy(_ path: String, _ reason: GameFiles.Reason) -> GameFiles.Copy {
            GameFiles.Copy(source: source, destination: "Documents/Data/" + path, size: mac.size, replacing: 0, reason: reason)
        }
        XCTAssertEqual(GameFiles.storeSummary([copy("indices/0123.index", .missing), copy("config/01/23/0123", .missing)]), [])
        let lines = GameFiles.storeSummary([
            copy("data/data.000", .size(device: 4096)), copy("data/data.001", .missing),
            copy("data/0000000003.idx", .date(device: later)), copy("indices/0123.index", .missing),
        ])
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("store: 3 files, "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(": 1 not on the device, 1 another size, 1 the same size with another date"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("store: data/data.000: device "), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("store: data/0000000003.idx: device \(ISO8601DateFormatter().string(from: later)), Mac "), lines[2])
        XCTAssertEqual(lines[3], "store: not on the device: data/data.001")
    }

    /// A copy of the store stopped at any point leaves the device's copy marker saying so, so the next sync
    /// finishes it whatever the device's setting (and the launcher won't load a game over it); a finished
    /// one says it finished. The iPhone's case (2026-10-29): the client streamed its own store, a copy
    /// replaced its archives and was stopped before the Mac's indexes went. A simulated device, no
    /// Blizzard file: each cut point applies the copies before it.
    func testACopyCutShortIsFinishedNextTime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sp-copy-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String, _ text: String) throws -> URL {
            let url = dir.appending(path: name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let copying = try file("copying", GameFiles.copyMarkerCopying), done = try file("done", GameFiles.copyMarkerDone)
        func marker(_ url: URL) -> GameFiles.Copy {
            GameFiles.Copy(source: url, destination: GameFiles.copyMarker, size: Int64((try? Data(contentsOf: url))?.count ?? 0), replacing: 0)
        }
        let blank = URL(fileURLWithPath: "/nonexistent")
        func copy(_ destination: String) -> GameFiles.Copy {
            GameFiles.Copy(source: blank, destination: destination, size: 1, replacing: 0)
        }
        // In the plan's order of consideration: configs, the store, .build.info, then a game's folder.
        let planned = ["Documents/Data/config/01/23/0123abcd", "Documents/Data/indices/0123abcd.index",
                       "Documents/Data/data/data.000", "Documents/Data/data/0000000083.idx", "Documents/Data/data/data.001",
                       "Documents/Data/wow_classic_era/000000001b.idx", "Documents/Data/ecache/data.000",
                       "Documents/.build.info", "Documents/_classic_era_/.flavor.info"].map(copy)
        let ordered = GameFiles.ordered(planned, marker: { marker(copying) })
        XCTAssertEqual(ordered.map(\.destination), [
            "Documents/Data/config/01/23/0123abcd", "Documents/Data/indices/0123abcd.index", GameFiles.copyMarker,
            "Documents/Data/data/data.000",
            "Documents/Data/data/data.001", "Documents/Data/ecache/data.000", "Documents/_classic_era_/.flavor.info",
            "Documents/Data/data/0000000083.idx", "Documents/Data/wow_classic_era/000000001b.idx", "Documents/.build.info"])

        // The marker the device has after the first `cut` copies (and `done` once they all went), and
        // whether the next sync then copies, for a device that copies and one that doesn't.
        let all = ordered + [marker(done)]
        let storeFiles = Set(ordered.filter(GameFiles.isStore).map(\.destination))
        let markerAt = try XCTUnwrap(ordered.firstIndex { $0.destination == GameFiles.copyMarker })
        for cut in 0...all.count {
            var device: [String: Int64] = [:]
            for c in all.prefix(cut) { device[c.destination] = c.size }
            let unfinished = GameFiles.copyUnfinished(markerSize: device[GameFiles.copyMarker])
            let some = !storeFiles.isDisjoint(with: device.keys)
            // Any of the store without the done marker: finished next time. Before any of it (the marker
            // goes just before its first file), the store is as it was, and nothing is finished.
            XCTAssertEqual(unfinished, some && cut < all.count || cut == markerAt + 1, "cut after \(cut)")
            XCTAssertTrue(GameFiles.copies(asked: true, unfinished: unfinished, macInstall: true))
            XCTAssertEqual(GameFiles.copies(asked: false, unfinished: unfinished, macInstall: true), unfinished, "cut after \(cut)")
            XCTAssertFalse(GameFiles.copies(asked: false, unfinished: unfinished, macInstall: false))
        }

        // Nothing of the store (the device streams it): no marker, so a device that never copied has none.
        let buildFiles = GameFiles.ordered([copy("Documents/Data/config/01/23/0123abcd"), copy("Documents/.build.info")],
                                           marker: { marker(copying) })
        XCTAssertFalse(buildFiles.contains { $0.destination == GameFiles.copyMarker })
        XCTAssertFalse(GameFiles.copyUnfinished(markerSize: nil))
        XCTAssertFalse(GameFiles.copyUnfinished(markerSize: Int64(GameFiles.copyMarkerDone.utf8.count)))
    }

    /// A device first seen now doesn't copy (the client streams); ones known before copying became a
    /// choice keep copying; a choice made sticks, and the settling runs once.
    func testCopyingIsOptIn() throws {
        let name = "sp-copy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let known = Device(name: "Known", udid: "known", kind: .iPhone)
        let chose = Device(name: "Chose", udid: "chose", kind: .iPad)
        let new = Device(name: "New", udid: "new", kind: .headset)

        XCTAssertFalse(Device.copiesGameFilesByDefault)
        XCTAssertFalse(known.copiesGameFiles(defaults))
        chose.setCopiesGameFiles(false, defaults)
        Device.keepCopyingOnKnownDevices([known, chose], defaults)
        XCTAssertTrue(known.copiesGameFiles(defaults))
        XCTAssertFalse(chose.copiesGameFiles(defaults))

        // Later, with the new device in the list: it gets the default, and the known one's choice holds.
        known.setCopiesGameFiles(false, defaults)
        Device.keepCopyingOnKnownDevices([known, chose, new], defaults)
        XCTAssertFalse(new.copiesGameFiles(defaults))
        XCTAssertFalse(known.copiesGameFiles(defaults))
        new.setCopiesGameFiles(true, defaults)
        XCTAssertTrue(new.copiesGameFiles(defaults))
    }

    private func stamp(_ key: String, _ version: String) -> ClientAssembly.Stamp {
        ClientAssembly.Stamp(product: "wow_classic_era", branch: "us", buildKey: key, version: version)
    }

    /// The Mac copies a game's client when the device's stamp is missing or older than the build it sends,
    /// and never over the same build or a newer one the device fetched itself. The launcher's rule
    /// (sp_update_caught_up, which retires a client the game data has caught up with) agrees on which is newer.
    func testCopiesTheClientOnlyOverAnOlderOrMissingOne() {
        let mac = stamp("bbbb", "1.15.9.70003")
        let cases: [(ClientAssembly.Stamp?, ClientBuild.ClientCopy)] = [
            (stamp("aaaa", "1.15.9.69722"), .copy),            // older
            (stamp("aaaa", "1.15.8.80000"), .copy),            // older, with a larger last part
            (stamp("bbbb", "1.15.9.70003"), .upToDate),        // the same
            (stamp("cccc", "1.15.9.70003"), .upToDate),        // the same version, another region's build
            (stamp("dddd", "1.15.10.71000"), .newerOnDevice),  // the device updated itself past it
            (stamp("eeee", "1.15.x"), .newerOnDevice),         // can't be told apart: kept
            (nil, .copy),                                      // missing
        ]
        let row = { (s: ClientAssembly.Stamp) in ["Product": s.product, "Branch": s.branch, "Build Key": s.buildKey, "Version": s.version] }
        for (device, expected) in cases {
            XCTAssertEqual(ClientBuild.clientCopy(device: device, mac: mac), expected, "\(String(describing: device))")
            if let device {
                XCTAssertEqual(sp_update_caught_up(row(mac), row(device)), expected != .newerOnDevice, "\(device)")
            }
        }
        XCTAssertFalse(sp_update_caught_up(["Version": "1.15.9.70003"], ["Build Key": "bbbb", "Version": "1.15.9.70003"]))
    }

    /// A game whose client on the device is newer keeps the device's store whole, ahead of the other reasons.
    func testAnUpdateAheadKeepsTheStore() {
        XCTAssertEqual(GameFiles.storeKept(copy: true, newer: ["wow_classic_era"], differs: ["wow"], outranking: 3),
                       .newerOnDevice(["wow_classic_era"]))
        XCTAssertEqual(GameFiles.storeKept(copy: true, newer: [], differs: ["wow"], outranking: 3), .macDiffers(["wow"]))
        XCTAssertEqual(GameFiles.storeKept(copy: true, newer: [], differs: [], outranking: 3), .deviceWrote(3))
        XCTAssertNil(GameFiles.storeKept(copy: true, newer: [], differs: [], outranking: 0))
        XCTAssertNil(GameFiles.storeKept(copy: false, newer: ["wow_classic_era"], differs: [], outranking: 0))
        // A game Battle.net patched that hasn't run on the Mac since: after the build checks, before the
        // device's own indexes.
        XCTAssertEqual(GameFiles.storeKept(copy: true, newer: [], differs: ["wow"], unplayed: ["wow_anniversary"], outranking: 3),
                       .macDiffers(["wow"]))
        XCTAssertEqual(GameFiles.storeKept(copy: true, newer: [], differs: [], unplayed: ["wow_anniversary"], outranking: 3),
                       .macUnplayed(["wow_anniversary"]))
        XCTAssertNil(GameFiles.storeKept(copy: false, newer: [], differs: [], unplayed: ["wow_anniversary"], outranking: 0))
    }

    /// A game Battle.net updated on the Mac and that hasn't run there since keeps the store from going
    /// (rc19's 6.2 B.1: TBC Anniversary's "Invalid schema … StartupFiles" after a full copy). Told from the
    /// dates alone: when its build config arrived, against the newest file in its folder's Logs/. A fixture
    /// install of our own files, dated as rc19's was.
    func testAGamePatchedButNotRunSinceKeepsTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sp-unplayed-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_792_000_000)
        func file(_ relative: String, at offset: TimeInterval) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        let day: TimeInterval = 86_400
        let keys = ["wow_anniversary": "68581f70aaaa", "wow_classic_era": "5604ce35bbbb", "wow_classic": "91b4109fcccc", "wow": "0149337ddddd"]
        for (product, key) in keys { try file("Data/" + GameFiles.configPath(key), at: product == "wow" ? 4 * day : 0) }
        try file("_anniversary_/Logs/Client.log", at: -2 * day)       // ran before its patch, not since: rc19's case
        try file("_classic_era_/Logs/Client.log", at: 5 * day)        // ran after it
        try file("_classic_era_/Logs/Tact.log", at: -2 * day)
        try file("_retail_/Logs/Client.log", at: 3 * day)             // ran, then Retail was patched
        // MoP Classic has no Logs/: it never ran on this Mac.
        let rows = keys.mapValues { ["Build Key": $0] }
        let games = [("wow_classic_era", "_classic_era_"), ("wow_anniversary", "_anniversary_"),
                     ("wow_classic", "_classic_"), ("wow", "_retail_")].map { (product: $0.0, folder: $0.1) }
        let found = GameFiles.unplayedSincePatch(root: root, rows: rows, games: games)
        XCTAssertEqual(found.map(\.product), ["wow_anniversary", "wow_classic", "wow"])
        XCTAssertEqual(found.first?.lastRun, base.addingTimeInterval(-2 * day))
        XCTAssertNil(found.first { $0.product == "wow_classic" }?.lastRun)
        XCTAssertEqual(found.last?.patched, base.addingTimeInterval(4 * day))

        // Once Anniversary runs on the Mac (its session's logs), it's no longer held.
        try file("_anniversary_/Logs/Client.log", at: day)
        XCTAssertFalse(GameFiles.unplayedSincePatch(root: root, rows: rows, games: games).map(\.product).contains("wow_anniversary"))
        // No build config for a row (or no row): nothing says it's unfinished.
        XCTAssertTrue(GameFiles.unplayedSincePatch(root: root, rows: ["wow_classic": ["Build Key": "ffffffffeeee"]], games: games).isEmpty)
        XCTAssertTrue(GameFiles.unplayedSincePatch(root: root, rows: [:], games: games).isEmpty)
        XCTAssertFalse(GameFiles.unplayed(patched: nil, lastRun: nil))
        XCTAssertTrue(GameFiles.unplayed(patched: base, lastRun: nil))
        XCTAssertFalse(GameFiles.unplayed(patched: base, lastRun: base))

        XCTAssertEqual(GameFiles.unplayedLine(["TBC Anniversary"], device: "iPhone"),
                       "This Mac's TBC Anniversary hasn't run since Battle.net updated it, so its game data may be unfinished and the iPhone's was left as it is; the game fetches what it needs itself. Play it once on this Mac through Battle.net, and the next Play copies it.")
        XCTAssertTrue(GameFiles.unplayedLine(["Classic Era", "MoP Classic", "Retail"], device: "headset")
            .hasPrefix("This Mac's Classic Era, MoP Classic, and Retail haven't run since Battle.net updated them, so their"))
    }

    /// The build of a game updated on the device is left out of what the companion writes, so the device's
    /// row stays as it is, even one older than the companion's image (an update whose row wasn't written yet):
    /// nothing goes back to an older build, and the other games' rows are the companion's.
    func testAnUpdatedGamesRowStaysTheDevices() {
        let device = table(["us|1|aaaa|1.15.9.69722|wow_classic_era", "us|1|dddd|12.1.0.1|wow"])
        let companion = table(["us|1|bbbb|12.1.5.70575|wow"])  // its Classic Era build left out (ahead)
        let merged = GameStore.deviceBuildInfo(mac: companion, device: device)
        XCTAssertEqual(merged.text, table(["us|1|bbbb|12.1.5.70575|wow", "us|1|aaaa|1.15.9.69722|wow_classic_era"]))
    }

    /// What the main window shows is what the last action stored, per device; unknown games are dropped.
    func testUpdatesAheadAreKeptPerDevice() throws {
        let name = "sp-ahead-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let phone = Device(name: "Phone", udid: "phone", kind: .iPhone), pad = Device(name: "Pad", udid: "pad", kind: .iPad)
        XCTAssertEqual(ClientBuild.aheadOnDevice(phone, defaults), [:])
        defaults.set(["classic_era": "1.15.9.70003", "gone": "1.0"], forKey: ClientBuild.aheadKey(phone))
        XCTAssertEqual(ClientBuild.aheadOnDevice(phone, defaults), [.classicEra: "1.15.9.70003"])
        XCTAssertEqual(ClientBuild.aheadOnDevice(pad, defaults), [:])
    }
}
