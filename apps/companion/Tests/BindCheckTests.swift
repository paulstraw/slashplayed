import XCTest

/// The bind check on loadertest fixtures: one shaped like a client (Loadertest.client), and the same with
/// one extra import (AppKit's NSApplicationLoad, which loadertest doesn't use) standing in for a game patch
/// that adds an import the shims don't provide. The manifest is made from the first fixture's own imports.
/// No Blizzard file is read, except by the opt-in check at the end.
final class BindCheckTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-bind-check-tests-\(getpid())")
    static var fixture: URL { try! Loadertest.client }
    static var patched: URL {
        try! Loadertest.fixture(named: "sploader-macos-patched", extra: """
            #include <stdbool.h>
            extern bool NSApplicationLoad(void);
            bool sp_patch_import(void) { return NSApplicationLoad(); }
            """)
    }
    static var manifest: URL { scratch.appending(path: "exports.json") }
    static let extraImport = BindCheck.Unresolved(library: "AppKit", symbol: "_NSApplicationLoad")

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = patched
        try! ClientAssemblyTests.writeManifest(for: fixture, to: manifest)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func thin(_ client: URL) throws -> URL {
        let out = Self.scratch.appending(path: "thin-\(UUID().uuidString)")
        try ClientAssemblyTests.run(["lipo", "-thin", "arm64", client.path, "-output", out.path])
        return out
    }

    func testEveryImportResolves() async throws {
        let result = try await BindCheck.check(thin(Self.fixture), against: BindCheck.Manifest(Self.manifest))
        XCTAssertTrue(result.ok, "\(result.unresolved)")
        XCTAssertGreaterThan(result.total, 50)
    }

    func testOneUnknownImportIsReported() async throws {
        let base = try await BindCheck.check(thin(Self.fixture), against: BindCheck.Manifest(Self.manifest))
        let result = try await BindCheck.check(thin(Self.patched), against: BindCheck.Manifest(Self.manifest))
        XCTAssertEqual(result.unresolved, [Self.extraImport])
        XCTAssertEqual(result.total, base.total + 1)
    }

    /// The patch drill (BindCheck.drillImport): a withheld symbol the client imports is reported under its
    /// library; one it doesn't import is still reported, as the drill's.
    func testWithheldSymbolsAreReported() async throws {
        let manifest = try BindCheck.Manifest(Self.manifest)
        manifest.withheld = ["_NSApp"]
        var result = try await BindCheck.check(thin(Self.fixture), against: manifest)
        XCTAssertEqual(result.unresolved, [BindCheck.Unresolved(library: "AppKit", symbol: "_NSApp")])
        manifest.withheld = ["_spNotImported"]
        result = try await BindCheck.check(thin(Self.fixture), against: manifest)
        XCTAssertEqual(result.unresolved, [BindCheck.Unresolved(library: "patch drill", symbol: "_spNotImported")])
    }

    /// The drills (drillImport, deviceDrill) are honoured in Debug builds and pre-release versions only: a
    /// release companion ignores the setting.
    func testDrillsAreIgnoredInARelease() throws {
        let suite = "com.strawdynamics.slashplayed.companion.tests.drill-\(getpid())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["SPPatchDrillImport", "SPDevicePatchDrill"] {
            XCTAssertNil(BindCheck.drill(key, in: defaults, version: "0.1.0-rc5", debug: true), "unset")
            defaults.set("_NSApp", forKey: key)
            XCTAssertNil(BindCheck.drill(key, in: defaults, version: "0.1.0", debug: false), "a release")
            XCTAssertEqual(BindCheck.drill(key, in: defaults, version: "0.1.0-rc5", debug: false), "_NSApp")
            XCTAssertEqual(BindCheck.drill(key, in: defaults, version: "0.1.0-test", debug: false), "_NSApp")
            XCTAssertEqual(BindCheck.drill(key, in: defaults, version: "0.1.0", debug: true), "_NSApp")
            defaults.set("", forKey: key)
            XCTAssertNil(BindCheck.drill(key, in: defaults, version: "0.1.0-rc5", debug: true), "empty")
        }
    }

    /// require, the check the copy step stops on (a game patch, or the drill): Unsupported with the withheld import, its
    /// count logged and each unresolved import listed; nothing thrown for a client that binds.
    func testRequireThrowsUnsupportedForAWithheldImport() async throws {
        let manifest = try BindCheck.Manifest(Self.manifest)
        let client = try thin(Self.fixture)
        var lines: [String] = []
        try await BindCheck.require(client, flavor: "classic_era", against: manifest, platform: manifest.platform) { lines.append($0) }
        XCTAssertEqual(lines.count, 1)
        manifest.withheld = ["_NSApp"]
        lines = []
        do {
            try await BindCheck.require(client, flavor: "classic_era", against: manifest, platform: manifest.platform) { lines.append($0) }
            XCTFail("the drill's import was withheld")
        } catch let e as BindCheck.Unsupported {
            XCTAssertEqual(e.flavor, "classic_era")
            XCTAssertEqual(e.unresolved, [BindCheck.Unresolved(library: "AppKit", symbol: "_NSApp")])
            XCTAssertEqual(lines.last, "UNRESOLVED AppKit _NSApp")
        }
    }

    func testAnImportFromALibraryTheManifestLacksIsReported() async throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.manifest)) as? [String: Any])
        var libraries = try XCTUnwrap(json["libraries"] as? [String: Any])
        libraries["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"] = nil
        let trimmed = Self.scratch.appending(path: "exports-no-appkit.json")
        try JSONSerialization.data(withJSONObject: json.merging(["libraries": libraries]) { $1 }).write(to: trimmed)
        let result = try await BindCheck.check(thin(Self.fixture), against: BindCheck.Manifest(trimmed))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.unresolved.allSatisfy { $0.library == "AppKit" }, "\(result.unresolved)")
    }

    /// The whole path the companion takes for a game patch: the copy step's check of the patched client
    /// stops with BindCheck.Unsupported before anything of it reaches the device, and that becomes the message
    /// and the pre-filled issue, without the caller's beforeWrite (which stops a client running on the
    /// device). A client that binds is written in the order the launcher relies on, after beforeWrite: the old
    /// stamp emptied first, then the client, its row, its spsource, and the stamp last.
    func testTheCopyStopsOnAnUnknownImport() async throws {
        let manifest = try BindCheck.Manifest(Self.manifest)
        let stamp = ClientAssemblyTests.stamp, row = "Branch!STRING:0|Version!STRING:0\nus|1.2.3.45678\n"
        var written: [(path: String, bytes: Data)] = [], lines: [String] = []
        var beforeWrites: [Int] = []  // how much was written each time beforeWrite ran
        func copy(_ client: URL) async throws {
            try await ClientBuild.copyClient(client, stamp: stamp, row: row, flavor: .classicEra, against: manifest, platform: "xros",
                                             log: { lines.append($0) }, beforeWrite: { beforeWrites.append(written.count) }) { file, path in
                written.append((path, try Data(contentsOf: file)))
            }
        }
        do {
            try await copy(thin(Self.patched))
            XCTFail("copied a client with an unknown import")
        } catch let e as BindCheck.Unsupported {
            XCTAssertEqual(written.map(\.path), [], "nothing reaches the device")
            XCTAssertEqual(beforeWrites, [], "a client running on the device isn't stopped")
            XCTAssertEqual(e.flavor, "classic_era")
            XCTAssertEqual(e.platform, "xros")
            XCTAssertEqual(e.unresolved, [Self.extraImport])
            XCTAssertTrue(lines.contains("UNRESOLVED AppKit _NSApplicationLoad"), "\(lines)")

            let message = BindCheck.message(flavorName: "Classic Era", build: "1.15.9.70003", unsupported: e)
            XCTAssertEqual(message, """
                Classic Era 1.15.9.70003 isn't supported by this version of Slashplayed yet. Check for updates; if there isn't one, report it.
                It imports 1 function the shims don't provide:
                  AppKit _NSApplicationLoad
                """)
            let url = BindCheck.issueURL(flavorName: "Classic Era", build: "1.15.9.70003", companionVersion: "0.1.0", unsupported: e)
            let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(c.host, "github.com")
            XCTAssertEqual(c.path, "/paulstraw/slashplayed/issues/new")
            let query = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["template": "game_patch.yml", "title": "Classic Era 1.15.9.70003 isn't supported",
                                   "flavor": "Classic Era", "game-build": "1.15.9.70003", "platform": "xros",
                                   "companion-version": "0.1.0", "imports": "AppKit _NSApplicationLoad\n"])
        }

        let client = try thin(Self.fixture)
        try await copy(client)
        let dir = "Library/spgames/"
        XCTAssertEqual(beforeWrites, [0], "beforeWrite runs once, before anything is written")
        XCTAssertEqual(written.map(\.path), [dir + "spbuild-classic_era", dir + "wow-classic_era", dir + "spbuildinfo-classic_era",
                                             dir + "spsource-classic_era", dir + "spbuild-classic_era"])
        XCTAssertEqual(written.map { String(decoding: $0.bytes, as: UTF8.self) }.suffix(3), [row, "mac\n", stamp.text])
        XCTAssertEqual(written[1].bytes, try Data(contentsOf: client), "the client, unchanged")
        XCTAssertEqual(written[0].bytes, Data(), "the old stamp, emptied")
    }

    func testIssueURLStaysShortWithManyImports() {
        let many = (0..<2000).map { BindCheck.Unresolved(library: "libSystem", symbol: "_sp_missing_\($0)") }
        let e = BindCheck.Unsupported(flavor: "retail", platform: "ios", total: 3000, unresolved: many)
        let url = BindCheck.issueURL(flavorName: "Retail", build: "12.1.5.1", companionVersion: "0.1.0", unsupported: e)
        XCTAssertLessThan(url.absoluteString.utf8.count, 8000)
        XCTAssertTrue(url.absoluteString.contains("more"))
        XCTAssertTrue(BindCheck.message(flavorName: "Retail", build: "12.1.5.1", unsupported: e).hasSuffix("… and 1990 more"))
    }

    /// Opt-in, local only (reads the installed clients): the bind check on each installed flavor against
    /// the built build/<platform>/exports.json (shims/build.sh <platform>) for both platforms, which must
    /// agree with scripts/recon/check_exports.py. Run with TEST_RUNNER_SP_CHECK_INSTALLED=1 (SP_INSTALL as
    /// for build.sh).
    func testInstalledClientsResolve() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SP_CHECK_INSTALLED"] == "1" else { throw XCTSkip("set SP_CHECK_INSTALLED=1 to check the installed clients") }
        let install = URL(fileURLWithPath: env["SP_INSTALL"] ?? "/Applications/World of Warcraft")
        let clients = Flavor.installed(in: install).map { ($0.rawValue, $0.clientExecutable(in: install)) }
        XCTAssertFalse(clients.isEmpty)
        for platform in ["xros", "ios"] {
            let manifest = try BindCheck.Manifest(ClientAssemblyTests.repo.appending(path: "build/\(platform)/exports.json"))
            for (flavor, client) in clients {
                let result = try await BindCheck.check(thin(client), against: manifest)
                print("bind check: \(platform) \(flavor) \(result.total - result.unresolved.count)/\(result.total)")
                XCTAssertTrue(result.ok, "\(platform) \(flavor): \(result.unresolved)")
            }
        }
    }
}
