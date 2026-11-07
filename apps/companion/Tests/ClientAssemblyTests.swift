import Security
import XCTest

/// ClientAssembly's app, its templates and stamps, and the client-shaped loadertest fixture (Loadertest.client)
/// the bind check's tests share. No Blizzard file is read.
final class ClientAssemblyTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-client-assembly-tests-\(getpid())")
    static var fixture: URL { try! Loadertest.client }

    /// Builds the fixture (once per test process: BindCheckTests shares it).
    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = fixture
    }

    /// Stand-ins for the app's licenses/ (bundle-resources.sh copies scripts/build-idevice.sh's and
    /// fetch-font.sh's) and the start screen's font.
    static func writeLicenses(in res: URL) throws {
        let dir = res.appending(path: "licenses")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ClientAssembly.licenseFiles { try Data("license".utf8).write(to: dir.appending(path: name)) }
        try Data("font".utf8).write(to: res.appending(path: ClientAssembly.fontFile))
    }

    /// An exports.json that provides exactly the imports of `client` (universal or thin), so the bind
    /// check passes on it, minus any symbol in `except`.
    static func writeManifest(for client: URL, to output: URL, except: Set<String> = []) throws {
        let thin = output.deletingLastPathComponent().appending(path: "manifest-thin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: thin) }
        try run(["lipo", "-thin", "arm64", client.path, "-output", thin.path])
        var installName: [String: String] = [:]
        for name in try MachO.loadedDylibs(Data(contentsOf: thin)) {
            installName[String(name.split(separator: "/").last!.prefix { $0 != "." })] = name
        }
        var libraries: [String: [String: Any]] = [:]
        for line in try run(["dyld_info", "-imports", thin.path]).split(separator: "\n") {
            guard let m = line.firstMatch(of: #/^\s+(?:0x[0-9A-Fa-f]+\s+)?(\S+)\s+\(from (\S+)\)/#), !except.contains(String(m.1)) else { continue }
            let name = try XCTUnwrap(installName[String(m.2)])
            libraries[name, default: ["target": "@rpath/test.dylib", "symbols": [String]()]]["symbols"] =
                (libraries[name]?["symbols"] as? [String] ?? []) + [String(m.1)]
        }
        try JSONSerialization.data(withJSONObject: ["platform": "xros", "sdk": "test", "libraries": libraries])
            .write(to: output)
    }

    /// A .build.info shaped like the install's (every column, three products, a second row for one), with
    /// made-up keys and versions: our own bytes.
    static let buildInfo = """
        Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0
        us|1|00112233445566778899aabbccddeeff|ffeeddccbbaa99887766554433221100|0123456789abcdef0123456789abcdef||tpr/wow|a.example b.example|https://a.example/?maxhosts=4|Windows x86_64 US? enUS speech?:Windows x86_64 US? enUS text?|||1.2.3.45678||wow_classic_era
        eu|1|deadbeefdeadbeefdeadbeefdeadbeef||||||||||9.9.9.99999||wow
        us|1|cafebabecafebabecafebabecafebabe||||||||||10.0.0.11111||wow

        """
    static let stamp = ClientAssembly.Stamp(product: "wow_classic_era", branch: "us",
                                            buildKey: "00112233445566778899aabbccddeeff", version: "1.2.3.45678")

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let result = try TestShell.run(ClientAssembly.xcrun, args)
        guard result.status == 0 else { throw Failure("xcrun \(args.joined(separator: " ")) failed") }
        return result.text
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func dir(_ name: String) throws -> URL {
        let d = Self.scratch.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testFixtureIsShapedLikeAClient() throws {
        let thin = try dir("thin").appending(path: "a")
        try Self.run(["lipo", "-thin", "arm64", Self.fixture.path, "-output", thin.path])
        let names = try MachO.loadedDylibs(Data(contentsOf: thin))
        XCTAssertTrue(names.contains("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"))
        XCTAssertTrue(names.contains("/usr/lib/libSystem.B.dylib"))
    }

    func testTemplatesFillIn() throws {
        let client = Self.repo.appending(path: "apps/client")
        for platform in [ClientAssembly.Platform.xros, .ios] {
            let info = ClientAssembly.infoPlist(template: try String(contentsOf: client.appending(path: "Info.plist"), encoding: .utf8),
                                                bundleID: "ABCDE12345.slashplayed", platform: platform, version: "1.0.1")
            XCTAssertFalse(info.contains("@"))
            XCTAssertTrue(info.contains("<key>CFBundleShortVersionString</key><string>1.0.1</string>"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any])
            XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "ABCDE12345.slashplayed")
            XCTAssertEqual(plist["MinimumOSVersion"] as? String, platform.minOS)
            XCTAssertEqual(plist["CFBundleSupportedPlatforms"] as? [String], [platform.plistPlatform])
            XCTAssertEqual(plist["UILaunchScreen"] != nil, platform == .ios)
            // Every device the app installs on names its icon (iPhone: CFBundleIcons, iPad: ~ipad).
            let icons = plist["CFBundleIcons"] as? [String: Any]
            XCTAssertNotNil(icons?["CFBundlePrimaryIcon"])
            XCTAssertEqual((plist["CFBundleIcons~ipad"] != nil), platform == .ios)
            XCTAssertEqual(plist["UISupportedInterfaceOrientations~iphone"] as? [String],
                           platform == .ios ? ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"] : nil)
        }
        let ents = ClientAssembly.entitlements(template: try String(contentsOf: client.appending(path: "entitlements.plist"), encoding: .utf8),
                                               team: "ABCDE12345", bundleID: "ABCDE12345.slashplayed")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(ents.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["application-identifier"] as? String, "ABCDE12345.ABCDE12345.slashplayed")
        XCTAssertEqual(plist["com.apple.developer.team-identifier"] as? String, "ABCDE12345")

        // The free-team test's dropped entitlements: nothing dropped leaves the text alone.
        XCTAssertEqual(try ClientAssembly.removing([], from: ents), ents)
        let va = "com.apple.developer.kernel.extended-virtual-addressing"
        let dropped = try ClientAssembly.removing([va], from: ents)
        let left = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(dropped.utf8), format: nil) as? [String: Any])
        XCTAssertNil(left[va])
        XCTAssertEqual(left["com.apple.developer.kernel.increased-memory-limit"] as? Bool, true)
        XCTAssertEqual(left["application-identifier"] as? String, "ABCDE12345.ABCDE12345.slashplayed")
    }

    /// The stamp is .build.info's build columns for the product, as a one-row table that reads back as
    /// .build.info does; the last row wins, as GameStore.buildInfo takes it.
    func testStampFromBuildInfo() throws {
        let root = try dir("stamp")
        try Self.buildInfo.write(to: root.appending(path: ".build.info"), atomically: true, encoding: .utf8)
        let rows = try GameStore.buildInfo(root)
        let stamp = try ClientAssembly.Stamp.from(product: "wow_classic_era", row: rows["wow_classic_era"])
        XCTAssertEqual(stamp, Self.stamp)
        XCTAssertEqual(stamp.text, "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\n"
                       + "wow_classic_era|us|00112233445566778899aabbccddeeff|1.2.3.45678\n")
        XCTAssertEqual(try ClientAssembly.Stamp.from(product: "wow", row: rows["wow"]).version, "10.0.0.11111")
        XCTAssertThrowsError(try ClientAssembly.Stamp.from(product: "wow_anniversary", row: rows["wow_anniversary"]))
        XCTAssertThrowsError(try ClientAssembly.Stamp.from(product: "wow_classic_era", row: ["Build Key": "", "Version": "1"]))
        // Its own file reads back as a .build.info with the one row.
        let back = try dir("stamp-back")
        try stamp.text.write(to: back.appending(path: ".build.info"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try GameStore.buildInfo(back), ["wow_classic_era": ["Product": "wow_classic_era", "Branch": "us",
                                                                          "Build Key": "00112233445566778899aabbccddeeff",
                                                                          "Version": "1.2.3.45678"]])
    }

    /// seed-client.sh's awk writes the same stamp for the fixture .build.info (flavor.sh's product for the
    /// flavor included), so the two producers agree byte for byte without a client.
    func testSeedClientWritesTheSameStamp() throws {
        let root = try dir("stamp-sh")
        try Self.buildInfo.write(to: root.appending(path: ".build.info"), atomically: true, encoding: .utf8)
        let script = try String(contentsOf: Self.repo.appending(path: "apps/client/seed-client.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: #"awk -F'|' -v p="$P" '"#)).upperBound
        let end = try XCTUnwrap(script.range(of: #"' "$INFO" > "$OUT/spbuild-$F""#, range: start..<script.endIndex)).lowerBound
        let awk = script[start..<end]
        let result = try TestShell.run("/usr/bin/awk", ["-F|", "-v", "p=wow_classic_era", String(awk),
                                                         root.appending(path: ".build.info").path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.text, Self.stamp.text)
    }

    func testRootCAsExport() async throws {
        let out = try dir("roots").appending(path: "sproots.plist")
        try await ClientAssembly.exportRootCAs(to: out)
        let ders = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: out), format: nil) as? [Data])
        XCTAssertGreaterThan(ders.count, 50)
        for der in ders { XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData)) }
    }

    func testAssemblesTheApp() async throws {
        let base = try dir("assemble")
        let res = base.appending(path: "xros"), templates = Self.repo.appending(path: "apps/client")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.repo.appending(path: "shims/generated/rewrite-map.txt"), to: res.appending(path: "rewrite-map.txt"))
        try Data("launcher".utf8).write(to: res.appending(path: "slashplayed"))
        try Data("helper".utf8).write(to: res.appending(path: "SPJitHelper"))
        try Data("shim".utf8).write(to: res.appending(path: "libspAppKit.dylib"))
        try FileManager.default.createDirectory(at: res.appending(path: "icon"), withIntermediateDirectories: true)
        try Data("car".utf8).write(to: res.appending(path: "icon/Assets.car"))
        try Data("{}".utf8).write(to: res.appending(path: "exports.json"))
        try Self.writeLicenses(in: res)
        let app = base.appending(path: "Slashplayed.app"), ents = base.appending(path: "entitlements.plist")
        let helperEnts = base.appending(path: "helper-entitlements.plist")
        try await ClientAssembly.assemble(app: app, platform: .xros, platformResources: res, templates: templates,
                                          addons: Self.repo.appending(path: "addon"), team: "ABCDE12345",
                                          bundleID: "ABCDE12345.slashplayed", entitlements: ents, helperEntitlements: helperEnts)
        // No game client (no wow-* or spbuild-*): the launcher loads each from Library/spgames.
        let files = Set(try FileManager.default.subpathsOfDirectory(atPath: app.path))
        XCTAssertEqual(files, Set<String>(["slashplayed", "Frameworks", "Frameworks/libspAppKit.dylib", "Assets.car", "Info.plist",
                              "sproots.plist", "PlugIns", "PlugIns/SPJitHelper.appex", "PlugIns/SPJitHelper.appex/SPJitHelper",
                              "PlugIns/SPJitHelper.appex/Info.plist", "flavors.plist", "wow.icns",
                              "exports.json", "rewrite-map.txt", "licenses",
                              "licenses/idevice.txt", "licenses/rust-std.html", "licenses/goodmountain.txt",
                              "Goodmountain-Regular.otf", "addons", "addons/SPMovie", "addons/SPHover"])
                       .union(ClientAssembly.addonFiles.map { "addons/" + $0 }))
        // The addons the launcher places (sp_addons_place), byte for byte as addon/ has them.
        for file in ClientAssembly.addonFiles {
            XCTAssertEqual(try Data(contentsOf: app.appending(path: "addons/" + file)),
                           try Data(contentsOf: Self.repo.appending(path: "addon/" + file)), file)
        }
        // The launcher's bind check of a newer build reads the same manifest as the companion's.
        XCTAssertEqual(try Data(contentsOf: app.appending(path: "exports.json")), try Data(contentsOf: res.appending(path: "exports.json")))
        // The launcher opens the client's libraries through the same rewrite map (spguestlaunch.m).
        XCTAssertEqual(try Data(contentsOf: app.appending(path: "rewrite-map.txt")), try Data(contentsOf: res.appending(path: "rewrite-map.txt")))
        // The client's setup dialog only needs its icon's path to resolve: an empty file, as build.sh writes it.
        XCTAssertEqual(try Data(contentsOf: app.appending(path: "wow.icns")), Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: ents.path))
        // The helper's bundle ID extends the app's (an extension's must), in its Info.plist and entitlements.
        let helperInfo = try XCTUnwrap(NSDictionary(contentsOf: app.appending(path: "PlugIns/SPJitHelper.appex/Info.plist")))
        XCTAssertEqual(helperInfo["CFBundleIdentifier"] as? String, "ABCDE12345.slashplayed.helper")
        XCTAssertEqual(helperInfo["CFBundleExecutable"] as? String, "SPJitHelper")
        XCTAssertEqual(helperInfo["CFBundleSupportedPlatforms"] as? [String], ["XROS"])
        let helperEntitlements = try XCTUnwrap(NSDictionary(contentsOf: helperEnts))
        XCTAssertEqual(helperEntitlements["application-identifier"] as? String, "ABCDE12345.ABCDE12345.slashplayed.helper")
        XCTAssertNil(helperEntitlements["com.apple.developer.kernel.increased-memory-limit"])
    }

    /// The stamp ClientBuild makes from the patch service's version row is the one seed-client.sh makes from an
    /// install of that build.
    func testStampFromVersionRowMatchesBuildInfo() throws {
        let key = String(repeating: "a1", count: 16), cdnKey = String(repeating: "b2", count: 16)
        let row = ["Branch": "us", "Build Key": key, "CDN Key": cdnKey, "Version": "1.15.9.70003", "Product": "wow_classic_era"]
        let version = BlizzardCDN.Version(region: "us", buildConfig: key, cdnConfig: cdnKey, keyRing: "", buildID: "70003",
                                          versionsName: "1.15.9.70003", productConfig: "")
        XCTAssertEqual(ClientAssembly.Stamp.from(product: "wow_classic_era", version: version),
                       try ClientAssembly.Stamp.from(product: "wow_classic_era", row: row))
        XCTAssertEqual(ClientAssembly.Stamp.from(product: "wow_classic_era", version: version).text,
                       "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\nwow_classic_era|us|\(key)|1.15.9.70003\n")
    }

    /// The developer disk image's files come from its one cryptex identity, as push-ddi.sh picks them.
    func testDeveloperDiskImageFiles() throws {
        func identity(_ variant: String, _ prefix: String) -> [String: Any] {
            let keys = ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"]
            return ["Info": ["Variant": variant],
                    "Manifest": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["Info": ["Path": "\(prefix)/\($0)"]]) })]
        }
        let manifest: [String: Any] = ["BuildIdentities": [identity("Other", "no"), identity("Developer Disk Image Cryptex", "ddi")]]
        XCTAssertEqual(try DeveloperDiskImage.cryptexFiles(manifest),
                       ["BuildManifest.plist", "ddi/Cryptex1,GenericDmg", "ddi/Cryptex1,GenericTrustCache",
                        "ddi/Cryptex1,CryptexInfoPlist", "ddi/Cryptex1,GenericVolume"])
        XCTAssertThrowsError(try DeveloperDiskImage.cryptexFiles(["BuildIdentities": [identity("Other", "no")]]))
        XCTAssertThrowsError(try DeveloperDiskImage.cryptexFiles(["BuildIdentities": [identity("Developer Disk Image Cryptex", "../up")]]))
    }
}
