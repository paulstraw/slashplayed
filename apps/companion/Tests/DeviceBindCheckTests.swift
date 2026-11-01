import XCTest

/// The launcher's bind check (apps/client/spbind.m, which reads a client's imports from its Mach-O, as the
/// device has no dyld_info) against the companion's (BindCheck, which runs dyld_info): the same imports
/// and the same verdict. On loadertest fixtures (Loadertest.link) linked both ways the linker writes
/// fixups: bind opcodes (the clients') and chained fixups (today's default). No Blizzard file is read,
/// except by the opt-in comparison at the end.
final class DeviceBindCheckTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-device-bind-tests-\(getpid())")
    /// The same source linked with bind opcodes (macOS 11, -no_fixup_chains) and with chained fixups.
    static var opcodes: URL { scratch.appending(path: "opcodes") }
    static var chained: URL { scratch.appending(path: "chained") }
    /// The opcodes fixture plus one import the manifest won't have, and a weak import.
    static var patched: URL { scratch.appending(path: "patched") }
    /// Manifests that provide exactly the imports of the opcodes and chained fixtures (whose deployment
    /// targets differ, and so do their imports).
    static var manifest: URL { scratch.appending(path: "exports.json") }
    static var chainedManifest: URL { scratch.appending(path: "exports-chained.json") }

    /// A weak import (of a symbol that exists, so it links): left out by both checks.
    static let weak = """
        extern void NSBeep(void) __attribute__((weak_import));
        void sp_weak_use(void) { if (NSBeep) NSBeep(); }
        """

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try! buildThin(opcodes, extra: weak, minOS: "11.0", linkFlags: ["-Wl,-no_fixup_chains"])
        try! buildThin(chained, extra: weak, minOS: "13.0", linkFlags: ["-Wl,-fixup_chains"])
        try! buildThin(patched, extra: weak + """

            #include <stdbool.h>
            extern bool NSApplicationLoad(void);
            bool sp_patch_import(void) { return NSApplicationLoad(); }
            """, minOS: "11.0", linkFlags: ["-Wl,-no_fixup_chains"])
        try! ClientAssemblyTests.writeManifest(for: universal(opcodes), to: manifest)
        try! ClientAssemblyTests.writeManifest(for: universal(chained), to: chainedManifest)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// The universal file a thin fixture came from (writeManifest takes one).
    static func universal(_ thin: URL) -> URL { thin.appendingPathExtension("universal") }

    /// A thin arm64 loadertest fixture for `minOS`, linked with `linkFlags` (as a universal file, then thinned,
    /// as a client is), from the main.m object the other fixtures for `minOS` link.
    static func buildThin(_ output: URL, extra: String, minOS: String, linkFlags: [String]) throws {
        try Loadertest.link(universal(output), extra: """
            #include <stddef.h>
            const void *const sp_refs[] = {0};
            const char *const sp_ref_names[] = {0};
            const size_t sp_ref_count = 0;
            \(extra)
            """, minOS: minOS, linkFlags: linkFlags)
        try ClientAssemblyTests.run(["lipo", "-thin", "arm64", universal(output).path, "-output", output.path])
    }

    /// dyld_info's imports as BindCheck reads them: "<short library> <symbol>", in its order.
    private func dyldInfoImports(_ image: URL) throws -> [String] {
        try ClientAssemblyTests.run(["dyld_info", "-imports", image.path]).split(separator: "\n").compactMap { line in
            line.firstMatch(of: #/^\s+(?:0x[0-9A-Fa-f]+\s+)?(\S+)\s+\(from (\S+)\)/#).map { "\($0.2) \($0.1)" }
        }
    }

    /// spbind.m's imports, named as BindCheck names them.
    private func launcherImports(_ image: URL) throws -> [String] {
        var problem: NSString?
        let pairs = try XCTUnwrap(sp_bind_imports(Data(contentsOf: image), &problem), problem as String? ?? "")
        return pairs.map { pair in
            let base = pair[0].split(separator: "/").last.map(String.init) ?? pair[0]
            return "\(base.prefix { $0 != "." }) \(pair[1])"
        }
    }

    private func loadCommands(_ image: URL) throws -> String { try ClientAssemblyTests.run(["otool", "-l", image.path]) }

    func testFixturesHaveBothKindsOfFixups() throws {
        XCTAssertTrue(try loadCommands(Self.opcodes).contains("LC_DYLD_INFO_ONLY"))
        XCTAssertFalse(try loadCommands(Self.opcodes).contains("LC_DYLD_CHAINED_FIXUPS"))
        XCTAssertTrue(try loadCommands(Self.chained).contains("LC_DYLD_CHAINED_FIXUPS"))
    }

    func testImportsAreDyldInfos() throws {
        for image in [Self.opcodes, Self.chained, Self.patched] {
            let ours = try launcherImports(image), theirs = try dyldInfoImports(image)
            XCTAssertGreaterThan(ours.count, 50, image.lastPathComponent)
            XCTAssertEqual(ours.count, Set(ours).count, "\(image.lastPathComponent): an import listed twice")
            XCTAssertEqual(Set(ours), Set(theirs), image.lastPathComponent)
            XCTAssertEqual(ours.count, theirs.count, image.lastPathComponent)
            // The weak import isn't among them.
            XCTAssertFalse(ours.contains("AppKit _NSBeep"), image.lastPathComponent)
        }
    }

    func testUnresolvedAreBindChecks() async throws {
        for (image, manifest, expected) in [(Self.opcodes, Self.manifest, [String]()), (Self.chained, Self.chainedManifest, []),
                                            (Self.patched, Self.manifest, ["AppKit _NSApplicationLoad"])] {
            var total = 0, problem: NSString?
            let ours = try XCTUnwrap(sp_bind_unresolved(Data(contentsOf: image), Data(contentsOf: manifest), nil, &total, &problem),
                                     problem as String? ?? "")
            let theirs = try await BindCheck.check(image, against: BindCheck.Manifest(manifest))
            XCTAssertEqual(ours, expected, image.lastPathComponent)
            XCTAssertEqual(ours, theirs.unresolved.map(\.description), image.lastPathComponent)
            XCTAssertEqual(total, theirs.total, image.lastPathComponent)
        }
    }

    /// The device's patch drill (sppatch.m's SP_PATCH_DRILL) withholds symbols as the companion's does
    /// (BindCheck.Manifest.withheld): one the image imports under its library, one it doesn't as the drill's.
    func testWithheldSymbolsAreBindChecks() async throws {
        for withheld in [["_NSApp"], ["_spNotImported"], ["_NSApp", "_spNotImported"]] {
            var total = 0, problem: NSString?
            let ours = try XCTUnwrap(sp_bind_unresolved(Data(contentsOf: Self.opcodes), Data(contentsOf: Self.manifest),
                                                        Set(withheld), &total, &problem), problem as String? ?? "")
            let manifest = try BindCheck.Manifest(Self.manifest)
            manifest.withheld = Set(withheld)
            let theirs = try await BindCheck.check(Self.opcodes, against: manifest)
            XCTAssertEqual(ours.count, withheld.count, "\(withheld)")
            XCTAssertEqual(ours, theirs.unresolved.map(\.description), "\(withheld)")
        }
    }

    /// The device's "This patch needs a Slashplayed update." screen (sppatch.m) says the news once: it read
    /// "Classic Era 1.15.9.70003 is out. is out, and …" when the body was built from the heading.
    func testPatchScreenNeedsUpdateBody() {
        XCTAssertEqual(sp_patch_news("Classic Era", "1.15.9.70003") + ".", "Classic Era 1.15.9.70003 is out.")
        XCTAssertEqual(sp_patch_needs_update_body(sp_patch_news("Classic Era", "1.15.9.70003")),
                       "Classic Era 1.15.9.70003 is out, and this version of Slashplayed can't run it yet. In Slashplayed "
                       + "Companion on your Mac, check for updates; once there's one for it, press Play there.")
        XCTAssertEqual(sp_patch_news("Retail", nil), "A new build of Retail is out")
        XCTAssertEqual(sp_patch_news("Retail", ""), "A new build of Retail is out")
        XCTAssertTrue(sp_patch_needs_update_body(sp_patch_news("Retail", nil))
                          .hasPrefix("A new build of Retail is out, and this version"))
    }

    func testRefusesWhatIsntAThinImage() throws {
        var problem: NSString?
        XCTAssertNil(sp_bind_imports(Data("not a Mach-O file at all, just text".utf8), &problem))
        XCTAssertNotNil(problem)
        // A load command whose size runs past the file.
        var image = try Data(contentsOf: Self.opcodes).prefix(4096)
        image.replaceSubrange(36..<40, with: Data([0xFF, 0xFF, 0, 0]))
        problem = nil
        XCTAssertNil(sp_bind_imports(image, &problem))
        XCTAssertNotNil(problem)
        var total = 0
        problem = nil
        XCTAssertNil(sp_bind_unresolved(try Data(contentsOf: Self.opcodes), Data("[]".utf8), nil, &total, &problem))
        XCTAssertNotNil(problem)
    }

    /// Opt-in, local only (reads the overnight run's Mac clients, never copied into the repo): on every
    /// builds/<product>/<version>/exe there, the launcher's check and BindCheck give the same total and the
    /// same unresolved imports against the built build/<platform>/exports.json (shims/build.sh <platform>),
    /// for both platforms. Some of the older builds don't bind, so both verdicts are covered. Run the tests
    /// with TEST_RUNNER_SP_COMPARE_BUILDS=1 (TEST_RUNNER_SP_BUILDS for another folder than
    /// /Volumes/T7-A/sp-untethered/builds).
    func testMatchesBindCheckOnTheOvernightBuilds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SP_COMPARE_BUILDS"] == "1" else { throw XCTSkip("set SP_COMPARE_BUILDS=1 to compare on the overnight builds") }
        let root = URL(fileURLWithPath: env["SP_BUILDS"] ?? "/Volumes/T7-A/sp-untethered/builds")
        let fm = FileManager.default
        let exes = try fm.contentsOfDirectory(atPath: root.path).sorted().flatMap { product in
            try fm.contentsOfDirectory(atPath: root.appending(path: product).path).sorted().map { root.appending(path: "\(product)/\($0)/exe") }
        }.filter { fm.fileExists(atPath: $0.path) }
        XCTAssertFalse(exes.isEmpty)
        var failing = 0
        for platform in ["xros", "ios"] {
            let manifestURL = ClientAssemblyTests.repo.appending(path: "build/\(platform)/exports.json")
            let manifest = try BindCheck.Manifest(manifestURL), exports = try Data(contentsOf: manifestURL)
            for exe in exes {
                let name = exe.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: " ")
                let thin = Self.scratch.appending(path: "build-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: thin) }
                try ClientAssemblyTests.run(["lipo", "-thin", "arm64", exe.path, "-output", thin.path])
                var total = 0, problem: NSString?
                let start = Date()
                let ours = try XCTUnwrap(sp_bind_unresolved(Data(contentsOf: thin, options: .alwaysMapped), exports, nil, &total, &problem),
                                         "\(name): \(problem ?? "")")
                let seconds = Date().timeIntervalSince(start)
                let theirs = try await BindCheck.check(thin, against: manifest)
                print("device bind check: \(platform) \(name) \(total - ours.count)/\(total)"
                      + String(format: " (%.2f s)", seconds) + (ours.isEmpty ? "" : ", doesn't bind"))
                XCTAssertEqual(total, theirs.total, "\(platform) \(name)")
                XCTAssertEqual(Set(ours), Set(theirs.unresolved.map(\.description)), "\(platform) \(name)")
                if !ours.isEmpty { failing += 1 }
            }
        }
        print("device bind check: \(exes.count) builds, \(failing / 2) don't bind")
    }
}
