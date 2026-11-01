import XCTest

/// The Mac's game install as Play sees it (GameInstall): read off the main thread within a time limit,
/// and only when something needs it. The installs are made up in $TMPDIR.
final class GameInstallTests: XCTestCase {
    private func makeInstall(_ flavors: [Flavor], buildInfo: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "sp-install-\(UUID().uuidString)/World of Warcraft")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for f in flavors {
            let exe = f.clientExecutable(in: root)
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: exe.path, contents: Data())
            let plist: NSDictionary = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "1.2.3.4567"]
            try plist.write(to: infoPlist(f, root))
        }
        if let buildInfo { try buildInfo.write(to: root.appending(path: ".build.info"), atomically: true, encoding: .utf8) }
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        return root
    }

    private func infoPlist(_ f: Flavor, _ root: URL) -> URL {
        f.clientExecutable(in: root).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
    }

    /// A GameInstall of its own, kept in scratch defaults (never the app's snapshot).
    private func makeGameInstall() throws -> (GameInstall, UserDefaults) {
        let name = "sp-install-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (GameInstall(defaults: defaults), defaults)
    }

    func testAReadFindsTheGamesRowsAndVersions() async throws {
        let root = try makeInstall([.classicEra, .retail], buildInfo: "Branch!STRING:0|Product!STRING:0|Tags!STRING:0\neu|wow|tag one\n")
        let (install, defaults) = try makeGameInstall()
        let snapshot = try await install.read(root)
        XCTAssertEqual(snapshot.flavors, [.classicEra, .retail])
        XCTAssertEqual(snapshot.games["retail"], .init(version: "1.2.3", build: "1.2.3.4567"))
        XCTAssertEqual(snapshot.rows["wow"]?["Branch"], "eu")
        XCTAssertTrue(snapshot.hasBuildInfo)
        XCTAssertEqual(install.known(root: root), snapshot)
        XCTAssertNil(install.known(root: root.deletingLastPathComponent()), "another install's snapshot isn't this one's")
        // Kept for the next run.
        XCTAssertEqual(GameInstall(defaults: defaults).known(root: root), snapshot)

        let none = try await install.read(try makeInstall([]))
        XCTAssertEqual(none.flavors, [])
        XCTAssertFalse(none.hasBuildInfo)
    }

    /// An install the companion can't read is no install, at once: no wait, no error.
    func testAnUnreadableInstallIsNone() async throws {
        let root = try makeInstall([.anniversary], buildInfo: "Product!STRING:0\nwow_anniversary\n")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        let (install, _) = try makeGameInstall()
        let start = Date()
        let snapshot = try await install.read(root, limit: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(snapshot.flavors, [])
        XCTAssertEqual(snapshot.rows, [:])
    }

    /// A read the install doesn't answer is said within the limit, every time it's asked, with one read
    /// held however often; once the install answers, that read's result is kept. The stall is the reader
    /// held on a semaphore (Foundation doesn't block on a FIFO, and a hung volume can't be made in a test).
    func testAStalledInstallIsSaidWithinTheLimit() async throws {
        let root = try makeInstall([.classicEra])
        let (install, _) = try makeGameInstall()
        let reads = Counter(), drive = DispatchSemaphore(value: 0)
        install.reader = { reads.add(); drive.wait(); return GameInstall.Snapshot.read($0) }

        for _ in 0..<2 {
            let start = Date()
            do {
                // A quarter second, not the app's 5: the limit's length isn't what's tested, and both waits
                // are sat out. The upper bound is loose for a loaded CI runner.
                _ = try await install.read(root, limit: 0.25)
                XCTFail("a stalled install answered")
            } catch let e as GameInstall.NotResponding {
                XCTAssertEqual(e.root, root.path)
            }
            let waited = Date().timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(waited, 0.2)
            XCTAssertLessThan(waited, 2)
        }
        XCTAssertEqual(reads.value, 1, "a read of a stalled install is waited on, not started again")
        XCTAssertNil(install.known(root: root))

        // The drive answers: the held read finishes and its result is kept; the next read is a new one.
        drive.signal()
        for _ in 0..<50 where install.known(root: root) == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(install.known(root: root)?.flavors, [.classicEra])
        drive.signal()
        let again = try await install.read(root, limit: 3)
        XCTAssertEqual(again.flavors, [.classicEra])
        XCTAssertEqual(reads.value, 2)
    }

    /// Play reads the install only for a copy, a copy's finish, or the Battle.net fallback; the files
    /// step asks whether there's one only to finish a copy on a device that doesn't copy.
    func testWhenTheInstallIsRead() {
        XCTAssertFalse(GameInstall.reads(copies: false, finishingCopy: false, battleNet: false))
        XCTAssertTrue(GameInstall.reads(copies: true, finishingCopy: false, battleNet: false))
        XCTAssertTrue(GameInstall.reads(copies: false, finishingCopy: true, battleNet: false))
        XCTAssertTrue(GameInstall.reads(copies: false, finishingCopy: false, battleNet: true))

        XCTAssertFalse(GameFiles.readsInstall(asked: false, unfinished: false))
        XCTAssertTrue(GameFiles.readsInstall(asked: false, unfinished: true))
        // A device that copies had its install read before the plan.
        XCTAssertFalse(GameFiles.readsInstall(asked: true, unfinished: true))
        XCTAssertFalse(GameFiles.readsInstall(asked: true, unfinished: false))
    }

    func testTheMessageNamesTheDrive() {
        XCTAssertEqual(GameInstall.NotResponding.place("/Volumes/T7-A/World of Warcraft"), "the T7-A drive")
        XCTAssertEqual(GameInstall.NotResponding.place("/Applications/World of Warcraft"), "/Applications/World of Warcraft")
        let e = GameInstall.NotResponding(root: "/Volumes/T7-A/World of Warcraft", seconds: 5)
        XCTAssertTrue(e.localizedDescription.hasPrefix("The game install on the T7-A drive isn't responding (nothing in 5 s)."), e.localizedDescription)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
