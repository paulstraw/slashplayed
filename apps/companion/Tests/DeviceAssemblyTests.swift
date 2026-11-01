import CryptoKit
import XCTest

/// The launcher's assembly (apps/client/spassemble.m, which makes the client image on the device from a
/// newer build's slice) against the companion's (ClientAssembly.prepareClient, which runs install_name_tool
/// and vtool): the same bytes. On the client-shaped loadertest fixture (Loadertest.client) signed as a shipped
/// client is (codesign, not only the linker) and unsigned. No Blizzard file is read, except by the opt-in
/// comparisons at the end.
final class DeviceAssemblyTests: XCTestCase {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-device-assembly-tests-\(getpid())")
    /// The fixture as ld leaves it: arm64 code signed only by the linker, which the tools re-sign.
    static var linkerSigned: URL { scratch.appending(path: "linker-signed") }
    /// Thin fixtures: signed ad hoc with codesign (the tools leave such a signature alone, stale, as they
    /// leave a client's Developer ID one), and with no signature at all. Each with a file offset planted on
    /// its zero-fill section, as the clients' linker left one, so the retype has something to change.
    static var signed: URL { scratch.appending(path: "signed") }
    static var unsigned: URL { scratch.appending(path: "unsigned") }

    /// shims/generated/rewrite-map.txt, as the app carries it.
    static let mapText = try! String(contentsOf: ClientAssemblyTests.repo.appending(path: "shims/generated/rewrite-map.txt"), encoding: .utf8)

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // The fixture ClientAssemblyTests and BindCheckTests read. ld takes its UUID and its signature's
        // identifier from its file name, and neither matters here: both assemblies get the same slice, and
        // the linker-signed one is refused for being ld's whatever it's called.
        let universal = try! Loadertest.client
        try! ClientAssemblyTests.run(["lipo", "-thin", "arm64", universal.path, "-output", linkerSigned.path])
        try! ClientAssemblyTests.run(["lipo", "-thin", "arm64", universal.path, "-output", signed.path])
        try! codesign(["-f", "-s", "-", signed.path])
        try! ClientAssemblyTests.run(["lipo", "-thin", "arm64", universal.path, "-output", unsigned.path])
        try! codesign(["--remove-signature", unsigned.path])
        for f in [signed, unsigned] { try! plantZeroFillOffset(f) }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    static func codesign(_ args: [String]) throws {
        try TestShell.check("/usr/bin/codesign", args, mergingStderr: true)
    }

    /// Gives the thread-local zero-fill section a file offset.
    static func plantZeroFillOffset(_ image: URL) throws {
        var d = try Data(contentsOf: image)
        var header: Int?
        try MachO.forEachCommand(d) { cmd, off in
            guard cmd == MachO.lcSegment64 else { return }
            for i in 0..<Int(MachO.u32(d, off + 64)) where MachO.u32(d, off + 72 + i * 80 + 64) & 0xFF == 0x12 {
                header = off + 72 + i * 80
            }
        }
        MachO.setU32(&d, try XCTUnwrap(header) + 48, 0x1234)
        try d.write(to: image)
    }

    /// LC_BUILD_VERSION's xxxx.yy.zz encoding of a version such as 26.0.
    static func encoded(_ version: String) -> UInt32 {
        let parts = version.split(separator: ".").compactMap { UInt32($0) } + [0, 0]
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }

    /// spassemble.m's image of `slice` for `platform`, and the retype's lines.
    static func launcherImage(_ slice: Data, map: String, platform: ClientAssembly.Platform) throws -> (image: Data, changes: [String]) {
        var changes: NSArray?, problem: NSString?
        let image = try XCTUnwrap(sp_assemble(slice, map, platform.machOPlatform, encoded(platform.minOS), &changes, &problem),
                                  problem as String? ?? "")
        return (image, changes as? [String] ?? [])
    }

    private func companionImage(_ slice: URL, platform: ClientAssembly.Platform) async throws -> (image: Data, changes: [String]) {
        let out = Self.scratch.appending(path: "companion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let changes = try await ClientAssembly.prepareClient(slice, to: out, rewriteMap: ClientAssemblyTests.rewriteMap, platform: platform)
        return (try Data(contentsOf: out), changes)
    }

    func testMatchesPrepareClient() async throws {
        for slice in [Self.signed, Self.unsigned] {
            for platform in [ClientAssembly.Platform.xros, .ios] {
                let name = "\(slice.lastPathComponent) \(platform.name)"
                let theirs = try await companionImage(slice, platform: platform)
                let ours = try Self.launcherImage(Data(contentsOf: slice), map: Self.mapText, platform: platform)
                XCTAssertEqual(ours.image.count, theirs.image.count, name)
                XCTAssertTrue(ours.image == theirs.image, "\(name): spassemble.m's image differs from prepareClient's")
                XCTAssertEqual(ours.changes, theirs.changes, name)
                XCTAssertEqual(ours.changes, ["__thread_bss,__DATA: zero-fill offset 0x1234 -> 0"], name)
            }
        }
    }

    /// The signature a shipped client has stays where it was, its bytes untouched (signing replaces it).
    func testKeepsTheSignatureBytes() throws {
        let slice = try Data(contentsOf: Self.signed)
        let image = try Self.launcherImage(slice, map: Self.mapText, platform: .ios).image
        var signature: (off: Int, size: Int)?
        try MachO.forEachCommand(image) { cmd, off in
            if cmd == 0x1D { signature = (Int(MachO.u32(image, off + 8)), Int(MachO.u32(image, off + 12))) }
        }
        let s = try XCTUnwrap(signature)
        XCTAssertEqual(image[s.off..<(s.off + s.size)], slice[s.off..<(s.off + s.size)])
    }

    /// Where the tools refuse, so does the device: load commands that no longer fit before the first section.
    func testRefusesWhatDoesntFit() async throws {
        let long = try ClientAssemblyTests.rewriteMap.map { "\($0.from) -> @rpath/\(String(repeating: "x", count: 1500)).dylib\n" }.joined()
        var changes: NSArray?, problem: NSString?
        XCTAssertNil(sp_assemble(try Data(contentsOf: Self.signed), long, 2, Self.encoded("26.0"), &changes, &problem))
        XCTAssertTrue((problem as String? ?? "").contains("don't fit"), problem as String? ?? "")
        let out = Self.scratch.appending(path: "too-long")
        let map = try ClientAssembly.rewriteMap(long)
        do {
            try await ClientAssembly.prepareClient(Self.signed, to: out, rewriteMap: map, platform: .ios)
            XCTFail("install_name_tool took load commands that don't fit")
        } catch {}
    }

    func testRefusesWhatIsntAShippedExecutable() throws {
        var changes: NSArray?, problem: NSString?
        // ld's own signature: the tools re-sign it (renaming its identifier after their output file).
        XCTAssertNil(sp_assemble(try Data(contentsOf: Self.linkerSigned), Self.mapText, 2, Self.encoded("26.0"), &changes, &problem))
        XCTAssertTrue((problem as String? ?? "").contains("linker"), problem as String? ?? "")
        problem = nil
        XCTAssertNil(sp_assemble(Data("not a Mach-O file at all, just text".utf8), Self.mapText, 2, 0, &changes, &problem))
        XCTAssertNotNil(problem)
        // An image already assembled (a bundle now, and it has the rpath).
        let image = try Self.launcherImage(Data(contentsOf: Self.signed), map: Self.mapText, platform: .ios).image
        problem = nil
        XCTAssertNil(sp_assemble(image, Self.mapText, 2, Self.encoded("26.0"), &changes, &problem))
        XCTAssertNotNil(problem)
        problem = nil
        XCTAssertNil(sp_assemble(try Data(contentsOf: Self.signed), "no arrow here\n", 2, 0, &changes, &problem))
        XCTAssertTrue((problem as String? ?? "").contains("rewrite map"), problem as String? ?? "")
    }

    /// Opt-in, fetches from Blizzard's CDN (nothing kept: its cache is in $TMPDIR and deleted): the current
    /// build's arm64 slice of every game, assembled for both platforms by the launcher's spassemble.m and
    /// by ClientAssembly.prepareClient, byte for byte, with no game install needed. Prints each image's
    /// SHA-256, to compare with the launcher's `assemble:` line for the same build on a device
    /// ($SP_ASSEMBLE_TEST). Run the tests with TEST_RUNNER_SP_COMPARE_ASSEMBLY=1 (TEST_RUNNER_SP_COMPARE_REGION
    /// for another region than us).
    func testMatchesPrepareClientOnTheCDNSlices() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SP_COMPARE_ASSEMBLY"] == "1" else { throw XCTSkip("set SP_COMPARE_ASSEMBLY=1 to compare on the CDN's slices") }
        let region = env["SP_COMPARE_REGION"] ?? "us"
        let cdn = BlizzardCDN(cache: Self.scratch.appending(path: "cdn"))
        defer { try? FileManager.default.removeItem(at: Self.scratch.appending(path: "cdn")) }
        let map = Self.mapText
        for flavor in Flavor.allCases {
            let client = try await cdn.client(product: flavor.product, region: region, executable: flavor.clientPath)
            let slice = try Data(contentsOf: client.slice, options: .alwaysMapped)
            for platform in [ClientAssembly.Platform.xros, .ios] {
                let name = "\(flavor.rawValue) \(client.version.versionsName) \(platform.name)"
                let theirs = try await companionImage(client.slice, platform: platform)
                let start = Date()
                let ours = try Self.launcherImage(slice, map: map, platform: platform)
                let seconds = Date().timeIntervalSince(start)
                XCTAssertTrue(ours.image == theirs.image, "\(name): spassemble.m's image differs from prepareClient's")
                XCTAssertEqual(ours.changes, theirs.changes, name)
                let sha = SHA256.hash(data: ours.image).map { String(format: "%02x", $0) }.joined()
                print("assembly compare: \(name) identical, \(ours.image.count) bytes, \(String(format: "%.3f", seconds)) s, sha256 \(sha)"
                      + (ours.changes.isEmpty ? "" : "; retype: \(ours.changes.joined(separator: "; "))"))
            }
        }
    }
}
