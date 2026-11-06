import Security
import XCTest

/// ClientAssembly's steps on the client-shaped loadertest fixture (Loadertest.client). No Blizzard file is
/// read, except by the opt-in comparison at the end.
final class ClientAssemblyTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-client-assembly-tests-\(getpid())")
    static var fixture: URL { try! Loadertest.client }
    static var rewriteMap: [(from: String, to: String)] {
        get throws {
            try ClientAssembly.rewriteMap(String(contentsOf: repo.appending(path: "shims/generated/rewrite-map.txt"), encoding: .utf8))
        }
    }

    /// Builds the fixture (once per test process: BindCheckTests and DeviceAssemblyTests share it).
    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = fixture
    }

    /// Stand-ins for the app's licenses/ (bundle-resources.sh copies scripts/build-zsign.sh's, build-idevice.sh's,
    /// and fetch-font.sh's) and the start screen's font.
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
        let data = try Data(contentsOf: Self.fixture)
        XCTAssertTrue(MachO.isFat(data))
        let thin = try dir("thin").appending(path: "a")
        try Self.run(["lipo", "-thin", "arm64", Self.fixture.path, "-output", thin.path])
        let names = try MachO.loadedDylibs(Data(contentsOf: thin))
        XCTAssertTrue(names.contains("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"))
        XCTAssertTrue(names.contains("/usr/lib/libSystem.B.dylib"))
    }

    func testPreparesADeviceImageForEachPlatform() async throws {
        for platform in [ClientAssembly.Platform.xros, .ios] {
            let out = try dir(platform.name).appending(path: "wow-toy")
            let changed = try await ClientAssembly.prepareClient(Self.fixture, to: out, rewriteMap: Self.rewriteMap, platform: platform)
            let d = try Data(contentsOf: out)
            XCTAssertFalse(MachO.isFat(d))
            XCTAssertEqual(MachO.u32(d, 4), 0x0100_000C, "arm64")
            XCTAssertEqual(MachO.u32(d, 12), MachO.bundle)
            let version = try XCTUnwrap(MachO.buildVersion(d))
            XCTAssertEqual(version.platform, platform.machOPlatform)
            XCTAssertEqual(version.minOS >> 16, UInt32(platform.minOS.split(separator: ".")[0]))
            XCTAssertEqual(try ClientAssembly.unrewrittenLoadCommands(out), [])
            let names = try MachO.loadedDylibs(d)
            XCTAssertTrue(names.contains("@rpath/libspAppKit.dylib"))
            XCTAssertTrue(names.contains("@rpath/libspSystem.dylib"))
            XCTAssertEqual(try rpaths(d), ["@executable_path/Frameworks"])
            // Today's linker leaves zero-fill offsets 0 (the client's didn't; the retype test plants one).
            XCTAssertEqual(changed, [])
            XCTAssertFalse(try zeroFillOffsets(d).isEmpty)
            XCTAssertTrue(try zeroFillOffsets(d).allSatisfy { $0 == 0 })
        }
    }

    func testRetypeChangesOnlyTheHeaderAndZeroFillOffsets() throws {
        let thin = try dir("retype").appending(path: "a")
        try Self.run(["lipo", "-thin", "arm64", Self.fixture.path, "-output", thin.path])
        // Give __thread_bss a file offset, as the client's linker did.
        var before = try Data(contentsOf: thin)
        let section = try XCTUnwrap(zeroFillSections(before).first { $0.name == "__thread_bss,__DATA" })
        MachO.setU32(&before, section.header + 48, 0x1234)
        var after = before
        XCTAssertEqual(try MachO.retype(&after), ["__thread_bss,__DATA: zero-fill offset 0x1234 -> 0"])
        XCTAssertEqual(MachO.u32(after, section.header + 48), 0)
        let differing = Set(zip(before.indices, zip(before, after)).filter { $0.1.0 != $0.1.1 }.map(\.0))
        XCTAssertTrue(differing.contains(12))
        XCTAssertTrue(differing.allSatisfy { $0 < 32 + Int(MachO.u32(before, 20)) }, "only load commands change")
        XCTAssertEqual(after.count, before.count)
        // A bundle can't be retyped again.
        XCTAssertThrowsError(try MachO.retype(&after))
    }

    func testUnmappedLibraryIsReportedUnrewritten() async throws {
        let map = try Self.rewriteMap.filter { !$0.from.contains("/AppKit.framework/") }
        let out = try dir("unmapped").appending(path: "wow-toy")
        try await ClientAssembly.prepareClient(Self.fixture, to: out, rewriteMap: map, platform: .xros)
        XCTAssertEqual(try ClientAssembly.unrewrittenLoadCommands(out),
                       ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"])
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

    /// build.sh's awk writes the same stamp for the fixture .build.info (flavor.sh's product for the flavor
    /// included), so the two producers agree byte for byte without a client.
    func testBuildShWritesTheSameStamp() throws {
        let root = try dir("stamp-sh")
        try Self.buildInfo.write(to: root.appending(path: ".build.info"), atomically: true, encoding: .utf8)
        let script = try String(contentsOf: Self.repo.appending(path: "apps/client/build.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: #"awk -F'|' -v p="$P" '"#)).upperBound
        let end = try XCTUnwrap(script.range(of: #"' "$SP_INSTALL/.build.info""#, range: start..<script.endIndex)).lowerBound
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
        try Self.writeManifest(for: Self.fixture, to: res.appending(path: "exports.json"))
        try Self.writeLicenses(in: res)
        let app = base.appending(path: "Slashplayed.app"), ents = base.appending(path: "entitlements.plist")
        let helperEnts = base.appending(path: "helper-entitlements.plist")
        var lines: [String] = []
        try await ClientAssembly.assemble(app: app, clients: [("toy", Self.fixture, Self.stamp)], platform: .xros,
                                          platformResources: res, templates: templates, addons: Self.repo.appending(path: "addon"), team: "ABCDE12345",
                                          bundleID: "ABCDE12345.slashplayed", entitlements: ents,
                                          helperEntitlements: helperEnts) { lines.append($0) }
        let files = Set(try FileManager.default.subpathsOfDirectory(atPath: app.path))
        XCTAssertEqual(files, Set<String>(["wow-toy", "spbuild-toy", "slashplayed", "Frameworks", "Frameworks/libspAppKit.dylib", "Assets.car", "Info.plist",
                              "sproots.plist", "PlugIns", "PlugIns/SPJitHelper.appex", "PlugIns/SPJitHelper.appex/SPJitHelper",
                              "PlugIns/SPJitHelper.appex/Info.plist", "flavors.plist", "wow.icns",
                              "exports.json", "rewrite-map.txt", "licenses", "licenses/zsign.txt", "licenses/openssl.txt",
                              "licenses/idevice.txt", "licenses/rust-std.html", "licenses/spapple.txt", "licenses/goodmountain.txt",
                              "Goodmountain-Regular.otf", "addons", "addons/SPMovie", "addons/SPHover"])
                       .union(ClientAssembly.addonFiles.map { "addons/" + $0 }))
        // The addons the launcher places (sp_addons_place), byte for byte as addon/ has them.
        for file in ClientAssembly.addonFiles {
            XCTAssertEqual(try Data(contentsOf: app.appending(path: "addons/" + file)),
                           try Data(contentsOf: Self.repo.appending(path: "addon/" + file)), file)
        }
        // The launcher's bind check of a newer build reads the same manifest as the companion's.
        XCTAssertEqual(try Data(contentsOf: app.appending(path: "exports.json")), try Data(contentsOf: res.appending(path: "exports.json")))
        // The launcher's assembly of a newer build's image (spassemble.m) reads the same rewrite map.
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
        XCTAssertEqual(try String(contentsOf: app.appending(path: "spbuild-toy"), encoding: .utf8), Self.stamp.text)
        XCTAssertEqual(lines.first, "bundling toy")
        XCTAssertTrue(lines.contains { $0.hasPrefix("bind check: ") && $0.hasSuffix(" imports resolve") }, "\(lines)")
    }

    func testAssembleStopsOnAnUnmappedLibrary() async throws {
        let base = try dir("assemble-unmapped")
        let res = base.appending(path: "xros")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try Self.rewriteMap.filter { !$0.from.contains("/Metal.framework/") }.map { "\($0.from) -> \($0.to)\n" }.joined()
            .write(to: res.appending(path: "rewrite-map.txt"), atomically: true, encoding: .utf8)
        try Self.writeManifest(for: Self.fixture, to: res.appending(path: "exports.json"))
        do {
            try await ClientAssembly.assemble(app: base.appending(path: "Slashplayed.app"), clients: [("toy", Self.fixture, Self.stamp)],
                                              platform: .xros, platformResources: res, templates: Self.repo.appending(path: "apps/client"), addons: Self.repo.appending(path: "addon"),
                                              team: "T", bundleID: "T.slashplayed", entitlements: base.appending(path: "e.plist"),
                                              helperEntitlements: base.appending(path: "h.plist")) { _ in }
            XCTFail("assembled with an unrewritten load command")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Metal.framework"), error.localizedDescription)
        }
    }

    /// The stamp ClientBuild makes from the patch service's version row is the one build.sh makes from an
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

    /// Opt-in, local only (reads the installed clients' build, fetches from Blizzard's CDN): compares the
    /// companion's client images, made from the CDN's arm64 slice as ClientBuild makes them, and the
    /// launcher's (apps/client/spassemble.m, as a device makes them) from the same slice, with those
    /// apps/client/build.sh made from the installed clients, byte for byte: their inputs differ, the images
    /// don't. Build them unsigned first, e.g. with an identity that can't sign (build.sh stops at codesign,
    /// after the images are made):
    ///   SP_PLATFORM=xros SP_NO_INSTALL=1 SP_SIGN_ID=none SP_OUT=$TMPDIR/cmp-xros apps/client/build.sh
    /// then run the tests with TEST_RUNNER_SP_COMPARE_APP=$TMPDIR/cmp-xros/Slashplayed.app
    /// TEST_RUNNER_SP_COMPARE_PLATFORM=xros (SP_INSTALL as for build.sh). The slice is of the install's
    /// build (the CDN's current one once Battle.net has updated it); the stamp from the patch service's
    /// row is compared too when that's the install's build. The CDN's files go to $TMPDIR and are deleted.
    func testMatchesBuildShOnInstalledClients() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let reference = env["SP_COMPARE_APP"].map(URL.init(fileURLWithPath:)),
              let platform = env["SP_COMPARE_PLATFORM"].flatMap(ClientAssembly.Platform.named) else {
            throw XCTSkip("set SP_COMPARE_APP and SP_COMPARE_PLATFORM to compare with build.sh's output")
        }
        let install = URL(fileURLWithPath: env["SP_INSTALL"] ?? "/Applications/World of Warcraft")
        let images = try FileManager.default.contentsOfDirectory(atPath: reference.path).filter { $0.hasPrefix("wow-") }
        XCTAssertFalse(images.isEmpty)
        let scratch = try dir("compare-cdn")
        let cdn = BlizzardCDN(cache: scratch.appending(path: "cdn"))
        for image in images {
            let flavor = try XCTUnwrap(Flavor(rawValue: String(image.dropFirst(4))))
            let row = try XCTUnwrap(try GameStore.buildInfo(install)[flavor.product])
            let region = try XCTUnwrap(row["Branch"]).lowercased()
            let slice = try await cdn.connected(product: flavor.product, region: region)
                .slice(product: flavor.product, region: region, buildConfig: try XCTUnwrap(row["Build Key"]),
                       cdnConfig: try XCTUnwrap(row["CDN Key"]), executable: flavor.clientPath).slice
            let out = try dir("compare").appending(path: image)
            try await ClientAssembly.prepareClient(slice, to: out, rewriteMap: Self.rewriteMap, platform: platform)
            let ours = try Data(contentsOf: out), theirs = try Data(contentsOf: reference.appending(path: image))
            XCTAssertTrue(ours == theirs, "\(image) from the CDN differs from build.sh's (\(ours.count) vs \(theirs.count) bytes)")
            print("compare: \(platform.name) \(image) from the CDN identical to build.sh's (\(ours.count) bytes)")
            // The third producer: the launcher's assembly on the device (apps/client/spassemble.m), of the same slice.
            let device = try DeviceAssemblyTests.launcherImage(Data(contentsOf: slice), map: DeviceAssemblyTests.mapText, platform: platform)
            XCTAssertTrue(device.image == theirs, "\(image) from spassemble.m differs from build.sh's")
            print("compare: \(platform.name) \(image) from spassemble.m identical to build.sh's")
            // Its stamp: build.sh's from the install's .build.info, ClientBuild's from the version row.
            let stamp = try String(contentsOf: reference.appending(path: ClientAssembly.Stamp.fileName(flavor.rawValue)), encoding: .utf8)
            XCTAssertEqual(try ClientAssembly.Stamp.from(product: flavor.product, row: row).text, stamp)
            let current = try await cdn.version(product: flavor.product, region: region)
            if current.buildConfig == row["Build Key"] {
                XCTAssertEqual(ClientAssembly.Stamp.from(product: flavor.product, version: current).text, stamp)
                print("compare: spbuild-\(flavor.rawValue) from the patch service identical")
            } else {
                print("compare: the install isn't Blizzard's current \(current.versionsName), so the stamp is compared with the install's row only")
            }
            try? FileManager.default.removeItem(at: out)
        }
        try? FileManager.default.removeItem(at: scratch)
        // The bundle ID and version as build.sh stamped them (the tests have no host app, so their
        // Bundle.main isn't the companion whose version the assembly would take).
        let referenceInfo = NSDictionary(contentsOf: reference.appending(path: "Info.plist"))
        let info = ClientAssembly.infoPlist(template: try String(contentsOf: Self.repo.appending(path: "apps/client/Info.plist"), encoding: .utf8),
                                            bundleID: try XCTUnwrap(referenceInfo?["CFBundleIdentifier"] as? String),
                                            platform: platform,
                                            version: try XCTUnwrap(referenceInfo?["CFBundleShortVersionString"] as? String))
        XCTAssertEqual(info, try String(contentsOf: reference.appending(path: "Info.plist"), encoding: .utf8))
        let roots = try dir("compare").appending(path: "sproots.plist")
        try await ClientAssembly.exportRootCAs(to: roots)
        XCTAssertEqual(NSArray(contentsOf: roots), NSArray(contentsOf: reference.appending(path: "sproots.plist")))
    }

    // MARK: Helpers

    /// LC_RPATH entries.
    private func rpaths(_ d: Data) throws -> [String] {
        var paths: [String] = []
        try MachO.forEachCommand(d) { cmd, off in
            guard cmd == 0x8000_001C else { return }
            let start = d.startIndex + off + Int(MachO.u32(d, off + 8))
            paths.append(String(decoding: d[start...].prefix { $0 != 0 }, as: UTF8.self))
        }
        return paths
    }

    /// The image's zero-fill sections ("sect,seg") and where their headers are.
    private func zeroFillSections(_ d: Data) throws -> [(name: String, header: Int)] {
        var sections: [(String, Int)] = []
        try MachO.forEachCommand(d) { cmd, off in
            guard cmd == MachO.lcSegment64 else { return }
            for i in 0..<Int(MachO.u32(d, off + 64)) {
                let s = off + 72 + i * 80
                guard MachO.zeroFillTypes.contains(MachO.u32(d, s + 64) & 0xFF) else { continue }
                let name = { (o: Int) in String(decoding: d[(d.startIndex + o)..<(d.startIndex + o + 16)].prefix { $0 != 0 }, as: UTF8.self) }
                sections.append(("\(name(s)),\(name(s + 16))", s))
            }
        }
        return sections
    }

    /// The file offsets of the image's zero-fill sections.
    private func zeroFillOffsets(_ d: Data) throws -> [UInt32] {
        try zeroFillSections(d).map { MachO.u32(d, $0.header + 48) }
    }
}
