import CryptoKit
import XCTest
import zlib

/// The launcher's addon manager (apps/client/spaddons.m) against zips, catalogs, and GitHub releases made
/// here, served from memory. No addon's real files are read.
final class AddonsTests: XCTestCase {
    var root: URL!
    var game: URL { root.appending(path: "Documents/_retail_") }
    var addons: URL { game.appending(path: "Interface/AddOns") }
    var record: URL { root.appending(path: "Library/spaddons-retail.json") }
    var staging: URL { root.appending(path: "Library/spaddons-staging") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sp-addons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: addons, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // ---- making zips

    /// A zip of stored entries, each name as given (unsafe ones included), with Unix modes when given.
    static func zip(_ entries: [(String, Data, mode: UInt32?)]) -> Data {
        /// Little-endian fields, each (value, bytes).
        func le(_ fields: [(Int, Int)]) -> Data {
            var d = Data()
            for (v, n) in fields { d += (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
            return d
        }
        var out = Data(), central = Data()
        for (name, data, mode) in entries {
            let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = out.count, n = Data(name.utf8)
            out += le([(0x04034b50, 4), (20, 2), (0, 2), (0, 2), (0, 4), (crc, 4), (data.count, 4), (data.count, 4), (n.count, 2), (0, 2)])
            out += n + data
            let made = mode == nil ? 20 : 0x0314  // version 2.0 made by Unix (3), so the mode counts
            central += le([(0x02014b50, 4), (made, 2), (20, 2), (0, 2), (0, 2), (0, 4), (crc, 4), (data.count, 4), (data.count, 4),
                           (n.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (Int(mode ?? 0) << 16, 4), (offset, 4)])
            central += n
        }
        let cdOffset = out.count
        out += central
        out += le([(0x06054b50, 4), (0, 2), (0, 2), (entries.count, 2), (entries.count, 2), (central.count, 4), (cdOffset, 4), (0, 2)])
        return out
    }

    static func zip(_ files: [String: String]) -> Data {
        zip(files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8), mode: nil) })
    }

    /// A deflated zip, as /usr/bin/zip makes it, of `files` laid out in a scratch folder.
    func deflated(_ files: [String: String]) throws -> Data {
        let dir = root.appending(path: "zip-\(UUID().uuidString)")
        for (name, text) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let out = root.appending(path: "\(UUID().uuidString).zip")
        let r = try TestShell.run("/usr/bin/zip", ["-r", "-X", "-9", out.path, "."], in: dir)
        XCTAssertEqual(r.status, 0)
        try FileManager.default.removeItem(at: dir)
        return try Data(contentsOf: out)
    }

    static func toc(_ title: String, version: String, interface: String = "120105", extra: String = "") -> String {
        "## Interface: \(interface)\n## Title: |cff00ff00\(title)|r\n## Version: \(version)\n\(extra)\nmain.lua\n"
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // ---- serving them

    /// URLs to bytes, as the launcher's SPFetch: a missing one is a 404.
    final class Server: @unchecked Sendable {
        var files: [String: Data] = [:]
        var fetched: [String] = []
        var fetch: SPFetch {
            { [self] url, _, problem in
                fetched.append(url.absoluteString)
                if let d = files[url.absoluteString] { return d }
                problem.pointee = SPCDNNotFound as NSString
                return nil
            }
        }
    }

    func catalog(_ addons: [[String: Any]]) -> NSDictionary {
        let json = try! JSONSerialization.data(withJSONObject: ["schema": 1, "flavors": ["retail": [120000, 129999], "classic": [50500, 50599]],
                                                                 "addons": addons])
        var problem: NSString?
        return sp_addons_catalog(json, &problem)! as NSDictionary
    }

    func entry(_ id: String, _ version: String, _ zip: Data, folders: [String], requires: [String] = [], url: String? = nil,
               sha: String? = nil, flavors: [String] = ["retail"]) -> [String: Any] {
        ["id": id, "name": id.capitalized, "version": version,
         "recipe": ["type": "github-release", "repo": "example/\(id)"],
         "files": [["name": "\(id)-\(version).zip", "url": url ?? "https://example.com/\(id)-\(version).zip", "size": zip.count,
                    "sha256": sha ?? Self.sha(zip), "flavors": flavors, "interfaces": [120105],
                    "folders": folders.map { ["name": $0, "path": "\($0)/"] }, "requires": requires]]]
    }

    func install(_ e: [AnyHashable: Any], _ catalog: NSDictionary?, _ server: Server) -> (String?, String?) {
        var problem: NSString?
        let line = sp_addons_install(e, "retail", catalog as? [AnyHashable: Any], game.path, record.path, staging.path, server.fetch, &problem)
        return (line, problem as String?)
    }

    func list(_ catalog: NSDictionary?) -> [[String: Any]] {
        sp_addons_list(game.path, record.path, catalog as? [AnyHashable: Any], "retail") as! [[String: Any]]
    }

    func text(_ path: String) -> String? { try? String(contentsOf: addons.appending(path: path), encoding: .utf8) }

    func put(_ path: String, _ text: String) throws {
        let url = addons.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // ---- the tests

    /// A zip from a third party can't put anything outside the folder it names: every unsafe entry refuses the
    /// whole zip, and nothing is written.
    func testUnsafeZipsAreRefused() throws {
        let good = ("Evil/Evil.toc", Data(Self.toc("Evil", version: "1").utf8), mode: UInt32?.none)
        let cases: [(String, (String, Data, mode: UInt32?))] = [
            ("parent", ("Evil/../../escape.lua", Data("x".utf8), nil)),
            ("absolute", ("/tmp/escape.lua", Data("x".utf8), nil)),
            ("backslash", ("Evil\\..\\escape.lua", Data("x".utf8), nil)),
            ("dot", ("Evil/./x.lua", Data("x".utf8), nil)),
            ("symlink", ("Evil/link", Data("/etc".utf8), 0o120777)),
        ]
        for (label, bad) in cases {
            let z = Self.zip([good, bad])
            var problem: NSString?
            XCTAssertNil(sp_zip_addon_folders(z, nil, nil, &problem), label)
            XCTAssertNotNil(problem, label)
            problem = nil
            let into = root.appending(path: "unpack-\(label)")
            XCTAssertFalse(sp_zip_unpack(z, [["name": "Evil", "path": "Evil/"]], into.path, &problem), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: into.appending(path: "Evil/link").path), label)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escape.lua").path))
        // Slashplayed's own folders, and names WoW wouldn't load, can't be installed over even from a good zip.
        for name in ["SPMovie", "spkeyboard", "..", "A/B"] {
            var problem: NSString?
            XCTAssertFalse(sp_zip_unpack(Self.zip(["\(name)/x.lua": "x"]), [["name": name, "path": "\(name)/"]],
                                         root.appending(path: "u").path, &problem), name)
        }
        // A flipped byte fails the entry's CRC.
        var damaged = Self.zip(["Evil/Evil.toc": Self.toc("Evil", version: "1")])
        damaged[50] ^= 0xff  // in the TOC's bytes, past the local header and name
        var problem: NSString?
        XCTAssertFalse(sp_zip_unpack(damaged, [["name": "Evil", "path": "Evil/"]], root.appending(path: "d").path, &problem))
    }

    /// The folders a zip installs are its top-level folders with a TOC named after them; what it requires is the
    /// dependencies it doesn't hold. Deflated entries come out byte for byte.
    func testZipFolders() throws {
        let z = try deflated(["Grid2/Grid2.toc": Self.toc("Grid2", version: "4.1", extra: "## Dependencies: Ace3, Grid2Lib"),
                              "Grid2/Grid2_Mists.toc": Self.toc("Grid2", version: "4.1", interface: "50504"),
                              "Grid2/main.lua": String(repeating: "print('grid')\n", count: 200),
                              "Grid2Lib/Grid2Lib.toc": Self.toc("Lib", version: "1", extra: "## RequiredDeps: LibStub"),
                              "Docs/readme.txt": "not an addon", "README.md": "top-level file"])
        var interfaces: NSArray?, requires: NSArray?, problem: NSString?
        let folders = sp_zip_addon_folders(z, &interfaces, &requires, &problem) as? [[String: String]]
        XCTAssertEqual(folders, [["name": "Grid2", "path": "Grid2/"], ["name": "Grid2Lib", "path": "Grid2Lib/"]], problem as String? ?? "")
        XCTAssertEqual(interfaces as? [Int], [50504, 120105])
        XCTAssertEqual(requires as? [String], ["Ace3", "LibStub"])
        let into = root.appending(path: "unpacked")
        XCTAssertTrue(sp_zip_unpack(z, folders!, into.path, &problem), problem as String? ?? "")
        XCTAssertEqual(try String(contentsOf: into.appending(path: "Grid2/main.lua"), encoding: .utf8),
                       String(repeating: "print('grid')\n", count: 200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: into.appending(path: "Docs").path))
    }

    /// Install, update, and remove a catalog addon: its folders are swapped in, a folder its new version
    /// drops is deleted, and folders no record owns (added by hand, or Slashplayed's own) are never touched.
    func testInstallUpdateRemove() throws {
        try put("SPMovie/SPMovie.lua", "ours")
        try put("MyHack/MyHack.toc", Self.toc("My Hack", version: "0.1"))
        let server = Server()
        let v1 = Self.zip(["Grid2/Grid2.toc": Self.toc("Grid2", version: "1"), "Grid2/old.lua": "v1",
                           "Grid2Options/Grid2Options.toc": Self.toc("Grid2 Options", version: "1")])
        let e1 = entry("grid2", "1.0", v1, folders: ["Grid2", "Grid2Options"])
        server.files["https://example.com/grid2-1.0.zip"] = v1
        var cat = catalog([e1])
        let offered = sp_addons_offered(cat as? [AnyHashable: Any], "retail") as! [[String: Any]]
        XCTAssertEqual(offered.map { $0["id"] as? String }, ["grid2"])
        XCTAssertTrue(sp_addons_offered(cat as? [AnyHashable: Any], "classic_era").isEmpty)

        var (line, problem) = install(offered[0], cat, server)
        XCTAssertEqual(line, "installed grid2 1.0 (Grid2 Grid2Options, \(v1.count) bytes)", problem ?? "")
        XCTAssertEqual(text("Grid2/old.lua"), "v1")
        var rows = list(cat)
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["grid2", "folder:MyHack"])
        XCTAssertEqual(rows[0]["source"] as? String, "catalog")
        XCTAssertNil(rows[0]["update"])
        XCTAssertEqual(rows[1]["name"] as? String, "My Hack")  // its TOC's title, color codes gone

        // A new version that drops Grid2Options and adds Grid2Raid, deflated this time.
        let v2 = try deflated(["Grid2/Grid2.toc": Self.toc("Grid2", version: "2"), "Grid2/new.lua": "v2",
                               "Grid2Raid/Grid2Raid.toc": Self.toc("Grid2 Raid", version: "2")])
        server.files["https://example.com/grid2-2.0.zip"] = v2
        cat = catalog([entry("grid2", "2.0", v2, folders: ["Grid2", "Grid2Raid"])])
        rows = list(cat)
        XCTAssertEqual(rows[0]["update"] as? Bool, true)
        XCTAssertEqual(rows[0]["latest"] as? String, "2.0")
        (line, problem) = install((sp_addons_offered(cat as? [AnyHashable: Any], "retail") as! [[String: Any]])[0], cat, server)
        XCTAssertEqual(line, "updated grid2 1.0 to 2.0 (Grid2 Grid2Raid, \(v2.count) bytes); deleted Grid2Options", problem ?? "")
        XCTAssertNil(text("Grid2/old.lua"))  // the folder was replaced, not merged
        XCTAssertEqual(text("Grid2/new.lua"), "v2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: addons.appending(path: "Grid2Options").path))
        rows = list(cat)
        XCTAssertNil(rows[0]["update"])
        XCTAssertEqual(rows[0]["previous"] as? String, "1.0")
        XCTAssertNotNil(rows[0]["updated"])

        // A download that isn't the catalog's file changes nothing.
        let v3 = Self.zip(["Grid2/Grid2.toc": Self.toc("Grid2", version: "3")])
        server.files["https://example.com/grid2-3.0.zip"] = v3
        cat = catalog([entry("grid2", "3.0", v3, folders: ["Grid2"], sha: String(repeating: "0", count: 64))])
        (line, problem) = install((sp_addons_offered(cat as? [AnyHashable: Any], "retail") as! [[String: Any]])[0], cat, server)
        XCTAssertNil(line)
        XCTAssertEqual(problem, "Grid2’s download isn’t the file the catalog lists, so it wasn’t installed.")
        XCTAssertEqual(text("Grid2/new.lua"), "v2")

        var why: NSString?
        XCTAssertEqual(sp_addons_remove("grid2", game.path, record.path, staging.path, &why), "removed grid2 (Grid2 Grid2Raid)")
        XCTAssertNil(sp_addons_remove("folder:MyHack", game.path, record.path, staging.path, &why))
        let left = try FileManager.default.contentsOfDirectory(atPath: addons.path).sorted()
        XCTAssertEqual(left, ["MyHack", "SPMovie"])
        XCTAssertEqual(text("SPMovie/SPMovie.lua"), "ours")
        // Nothing stays behind in staging.
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [], [])
    }

    /// Folders added by hand that a catalog addon installs are listed as it, with an update when their TOC's
    /// version isn't the catalog's; other folders are each their own, with prefixed ones under them.
    func testHandAddedFolders() throws {
        try put("Grid2/Grid2.toc", Self.toc("Grid2", version: "1.0"))
        try put("Details/Details.toc", Self.toc("Details! Damage Meter", version: "@project-version@", extra: "## Dependencies: LibDFramework"))
        try put("Details_Compare/Details_Compare.toc", Self.toc("Details Compare", version: "1"))
        try put("SPHover/SPHover.toc", Self.toc("SPHover", version: "1"))
        let z = Self.zip(["Grid2/Grid2.toc": Self.toc("Grid2", version: "2.0")])
        let cat = catalog([entry("grid2", "2.0", z, folders: ["Grid2", "Grid2Options"])])
        let rows = list(cat)
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["folder:Details", "hand:grid2"])
        XCTAssertEqual(rows[0]["name"] as? String, "Details! Damage Meter")
        XCTAssertEqual(rows[0]["folders"] as? [String], ["Details", "Details_Compare"])
        XCTAssertEqual(rows[0]["version"] as? String, "")
        XCTAssertEqual(rows[0]["needs"] as? [String], ["LibDFramework"])
        XCTAssertEqual(rows[1]["source"] as? String, "hand")
        XCTAssertEqual(rows[1]["catalog"] as? String, "grid2")
        XCTAssertEqual(rows[1]["version"] as? String, "1.0")
        XCTAssertEqual(rows[1]["update"] as? Bool, true)
    }

    /// A GitHub link: the catalog's entry when it has the repo; else the release.json zip for the game; else
    /// the one zip, checked against the release's digest and the game's Interface range.
    func testGitHubLinks() throws {
        let server = Server()
        let cat = catalog([entry("dbm", "1", Self.zip([:]), folders: ["DBM-Core"])])
        var problem: NSString?
        var e = sp_addons_github("https://github.com/Example/DBM", "retail", cat as? [AnyHashable: Any], server.fetch, &problem) as? [String: Any]
        XCTAssertEqual(e?["id"] as? String, "dbm")
        XCTAssertEqual(server.fetched, [])
        XCTAssertNil(sp_addons_github("not a link", "retail", nil, server.fetch, &problem))
        // owner/repo and the forms of its link all name the repo.
        for link in ["Example/DBM", "github.com/Example/DBM", "https://www.github.com/Example/DBM.git", " https://github.com/Example/DBM/releases "] {
            XCTAssertEqual((sp_addons_github(link, "retail", cat as? [AnyHashable: Any], server.fetch, &problem) as? [String: Any])?["id"] as? String,
                           "dbm", link)
        }

        // release.json picks the game's zip among several.
        let retail = Self.zip(["Kui/Kui.toc": Self.toc("Kui", version: "v9")])
        let api = "https://api.github.com/repos/kesava/kui/releases/latest"
        func asset(_ name: String, _ d: Data, digest: Bool = true) -> [String: Any] {
            ["name": name, "size": d.count, "browser_download_url": "https://dl.example/\(name)"]
                .merging(digest ? ["digest": "sha256:" + Self.sha(d)] : [:]) { a, _ in a }
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["releases": [
            ["filename": "kui-classic.zip", "nolib": false, "metadata": [["flavor": "classic", "interface": 11509]]],
            ["filename": "kui-nolib.zip", "nolib": true, "metadata": [["flavor": "mainline", "interface": 120105]]],
            ["filename": "kui.zip", "nolib": false, "metadata": [["flavor": "mainline", "interface": 120105]]]]])
        server.files[api] = try JSONSerialization.data(withJSONObject: ["tag_name": "v9", "assets": [
            asset("kui-classic.zip", Data("c".utf8)), asset("kui-nolib.zip", Data("n".utf8)), asset("kui.zip", retail),
            asset("release.json", manifest)]])
        server.files["https://dl.example/release.json"] = manifest
        server.files["https://dl.example/kui.zip"] = retail
        e = sp_addons_github("kesava/kui", "retail", cat as? [AnyHashable: Any], server.fetch, &problem) as? [String: Any]
        XCTAssertEqual(e?["id"] as? String, "github:kesava/kui", problem as String? ?? "")
        XCTAssertEqual((e?["file"] as? [String: Any])?["name"] as? String, "kui.zip")
        XCTAssertNil(sp_addons_github("kesava/kui", "anniversary", nil, server.fetch, &problem))
        var (line, why) = install(e!, cat, server)
        XCTAssertEqual(line, "installed github:kesava/kui v9 (Kui, \(retail.count) bytes)", why ?? "")
        XCTAssertEqual(list(cat).first?["source"] as? String, "github")

        // One zip, no digest: its TOCs must be for the game's version (MoP Classic's is no use in Retail).
        let mists = Self.zip(["Old/Old.toc": Self.toc("Old", version: "1", interface: "50504")])
        server.files["https://api.github.com/repos/someone/old/releases/latest"] =
            try JSONSerialization.data(withJSONObject: ["tag_name": "1", "assets": [asset("old.zip", mists, digest: false)]])
        server.files["https://dl.example/old.zip"] = mists
        e = sp_addons_github("someone/old", "retail", cat as? [AnyHashable: Any], server.fetch, &problem) as? [String: Any]
        (line, why) = install(e!, cat, server)
        XCTAssertNil(line)
        XCTAssertEqual(why, "old 1 isn’t for this game’s version (its TOCs name 50504).")
        XCTAssertFalse(FileManager.default.fileExists(atPath: addons.appending(path: "Old").path))

        // The latest release, recorded for the list's update.
        server.files[api] = try JSONSerialization.data(withJSONObject: ["tag_name": "v10", "assets": [asset("kui.zip", retail)]])
        XCTAssertEqual(sp_addons_check_github(record.path, "retail", server.fetch), "kesava/kui v10")
        let row = list(cat).first { $0["id"] as? String == "github:kesava/kui" }
        XCTAssertEqual(row?["update"] as? Bool, true)
        XCTAssertEqual(row?["latest"] as? String, "v10")
    }

    /// The catalog's schema: a newer one says so rather than being misread.
    func testCatalogSchema() {
        var problem: NSString?
        XCTAssertNil(sp_addons_catalog(Data(#"{"schema": 2, "addons": []}"#.utf8), &problem))
        XCTAssertEqual(problem, "The addon catalog needs a newer Slashplayed.")
        XCTAssertNil(sp_addons_catalog(Data("<html>".utf8), &problem))
    }
}
