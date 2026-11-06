import XCTest

/// The third-party notices against what's linked: idevice's notices (scripts/crate-notices.py, run by
/// scripts/build-idevice.sh; the companion's Acknowledgements/idevice.txt, the device app's
/// licenses/idevice.txt) must name every crate whose code is in that platform's archive, each with a license
/// text. The archive's own symbols say which crates those are (Rust's v0 mangling names each path's crate),
/// so this doesn't trust the cargo tree the notices came from. Needs scripts/build-idevice.sh for all three
/// platforms and scripts/build-spapple.sh for both devices' (CLAUDE.md's build order; CI does it before the
/// tests); spapple's notices are checked the same way.
final class AcknowledgementsTests: XCTestCase {
    static let idevice = ClientAssemblyTests.repo.appending(path: "work/idevice")
    /// The Rust standard library and the crates only it links (rust-std.html beside the notices covers them).
    static let standardLibrary: Set<String> = ["std", "core", "alloc", "compiler_builtins", "__rustc", "addr2line", "gimli",
                                               "object", "rustc_demangle", "miniz_oxide", "adler2", "std_detect",
                                               "panic_unwind", "panic_abort", "unwind"]

    /// A notices file's crates, by library name (what symbols use), and the crates each license text names.
    struct Notices {
        var libraries: [String: String] = [:]  // library → "name version"
        var withText: Set<String> = []
        init(_ text: String) throws {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // Exactly two spaces first, as every match starts: the regex on all ~7,700 lines takes ~0.9 s,
                // on the ~150 left ~0.03 s (the license texts' indented lines mostly start with more).
                if line.hasPrefix("  ") && !line.hasPrefix("   "), let m = line.wholeMatch(of: #/  (\S+) (\S+)(?: \(lib (\S+)\))?  .*/#) {
                    libraries[String(m.3 ?? m.1).replacing("-", with: "_")] = "\(m.1) \(m.2)"
                } else if line.hasPrefix("The license text of: ") {
                    for crate in line.dropFirst("The license text of: ".count).split(separator: ", ") { withText.insert(String(crate)) }
                }
            }
        }
    }

    /// The crates whose code is in `archive`: the first path segment of every demangled Rust symbol
    /// (generic instantiations name the crates of their parameters too).
    static func linkedCrates(_ archive: URL) async throws -> Set<String> {
        // --no-llvm-bc: the Rust standard library's prebuilt iOS objects embed LLVM bitcode newer than Apple's
        // nm reads, which fails the whole run; their machine code's symbols are what count.
        let r = try await Shell.run("/bin/sh", ["-c", #"set -o pipefail; xcrun nm --no-llvm-bc -U -j "$1" | sed -n 's/^_\(_R\)/\1/p' | xcrun llvm-cxxfilt"#,
                                                "sh", archive.path])
        // NSRegularExpression, not a Swift Regex: ~0.05 s over the ~1 MB of names, against ~0.2 s. The
        // names are ASCII, so its UTF-16 units and a Regex's characters match alike.
        let demangled = String(decoding: r.stdout, as: UTF8.self) as NSString
        let crate = try NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9_:])([a-z_][a-z0-9_]*)::"#, options: .anchorsMatchLines)
        return Set(crate.matches(in: demangled as String, range: NSRange(location: 0, length: demangled.length))
            .map { demangled.substring(with: $0.range(at: 1)) })
    }

    /// One archive's notices against its symbols: `root` is work/idevice or work/spapple, `crate` the crate
    /// whose own symbols prove the mangling still reads.
    func check(_ platform: String, root: URL = AcknowledgementsTests.idevice, archiveName: String = "libidevice_ffi.a",
               noticesName: String = "idevice.txt", crate: String = "idevice", script: String = "build-idevice.sh") async throws {
        let dir = root.appending(path: platform)
        let archive = dir.appending(path: archiveName), notices = dir.appending(path: "licenses/\(noticesName)")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            return XCTFail("no \(archive.path): run scripts/\(script) \(platform)")
        }
        let parsed = try Notices(String(contentsOf: notices, encoding: .utf8))
        XCTAssertGreaterThan(parsed.libraries.count, 100, "\(platform): the notices list too few crates to be \(crate)'s")
        for (_, listed) in parsed.libraries.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(parsed.withText.contains(listed), "\(platform): \(listed) is listed with no license text")
        }
        let linked = try await Self.linkedCrates(archive)
        XCTAssertTrue(linked.contains(crate), "\(platform): no \(crate) symbols found; has the mangling changed?")
        let missing = linked.subtracting(Self.standardLibrary).subtracting(parsed.libraries.keys)
        XCTAssertEqual(missing, [], "\(platform): crates linked into \(archiveName) that the notices don't list")
        let rustStd = try Data(contentsOf: dir.appending(path: "licenses/rust-std.html"))
        XCTAssertGreaterThan(rustStd.count, 10_000, "\(platform): rust-std.html is too small to be the standard library's notices")
    }

    func testMacNoticesListEveryLinkedCrate() async throws { try await check("macos") }
    func testIOSNoticesListEveryLinkedCrate() async throws { try await check("ios") }
    func testVisionOSNoticesListEveryLinkedCrate() async throws { try await check("xros") }

    /// spapple's notices (scripts/build-spapple.sh; the device app's licenses/spapple.txt), the same way: the
    /// launcher links it, isideload and its crates with it.
    static let spapple = ClientAssemblyTests.repo.appending(path: "work/spapple")
    func spapple(_ platform: String) async throws {
        try await check(platform, root: Self.spapple, archiveName: "libspapple.a", noticesName: "spapple.txt",
                        crate: "isideload", script: "build-spapple.sh")
    }
    func testIOSSpappleNoticesListEveryLinkedCrate() async throws { try await spapple("ios") }
    func testVisionOSSpappleNoticesListEveryLinkedCrate() async throws { try await spapple("xros") }

    /// The parser reads crate-notices.py's lines: a renamed library, a plain one, and a shared text.
    func testNoticesParsing() throws {
        let n = try Notices("""
            title

            2 crates, built with Rust 1.0.

              md-5 0.10.6 (lib md5)  MIT OR Apache-2.0  https://github.com/RustCrypto/hashes
              tokio 1.50.0           MIT  https://github.com/tokio-rs/tokio

            ====
            The license text of: md-5 0.10.6, tokio 1.50.0
            ----
            """)
        XCTAssertEqual(n.libraries, ["md5": "md-5 0.10.6", "tokio": "tokio 1.50.0"])
        XCTAssertEqual(n.withText, ["md-5 0.10.6", "tokio 1.50.0"])
    }

    /// ClientAssembly's lists (the licenses and the font it copies into the device app) are the ones
    /// bundle-resources.sh bundles. That script checks the built app against apps/companion/bundled-notices.txt
    /// (every notice, byte for byte its source); this holds ClientAssembly to the same file, with no built
    /// app needed, so a name added to one side alone fails here.
    func testClientAssemblyListsTheBundledNotices() throws {
        let list = try String(contentsOf: ClientAssemblyTests.repo.appending(path: "apps/companion/bundled-notices.txt"), encoding: .utf8)
        var byKind: [String: [String]] = [:]
        for line in list.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            guard fields.count == 3 else { XCTFail("bundled-notices.txt: not <kind> <name> <source>: \(line)"); continue }
            byKind[String(fields[0]), default: []].append(String(fields[1]))
        }
        XCTAssertEqual(byKind["license"]?.sorted(), ClientAssembly.licenseFiles.sorted(), "the device app's licenses/")
        XCTAssertEqual(byKind["font"], [ClientAssembly.fontFile], "the start screen's face")
        XCTAssertEqual(Set(byKind.keys), ["license", "font", "acknowledgement"], "bundled-notices.txt's kinds")
    }
}
