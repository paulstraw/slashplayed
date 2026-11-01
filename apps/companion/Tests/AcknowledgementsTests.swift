import XCTest

/// The third-party notices against what's linked: idevice's notices (scripts/crate-notices.py, run by
/// scripts/build-idevice.sh; the companion's Acknowledgements/idevice.txt, the device app's
/// licenses/idevice.txt) must name every crate whose code is in that platform's archive, each with a license
/// text. The archive's own symbols say which crates those are (Rust's v0 mangling names each path's crate),
/// so this doesn't trust the cargo tree the notices came from. Needs scripts/build-idevice.sh for all three
/// platforms (CLAUDE.md's build order; CI does it before the tests).
final class AcknowledgementsTests: XCTestCase {
    static let idevice = ClientAssemblyTests.repo.appending(path: "work/idevice")
    static let fonts = ClientAssemblyTests.repo.appending(path: "work/fonts")
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
                if let m = line.wholeMatch(of: #/  (\S+) (\S+)(?: \(lib (\S+)\))?  .*/#) {
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
        let r = try await Shell.run("/bin/sh", ["-c", #"set -o pipefail; xcrun nm -U -j "$1" | sed -n 's/^_\(_R\)/\1/p' | xcrun llvm-cxxfilt"#,
                                                "sh", archive.path])
        let demangled = String(decoding: r.stdout, as: UTF8.self)
        return Set(demangled.matches(of: #/(?:^|[^A-Za-z0-9_:])([a-z_][a-z0-9_]*)::/#.anchorsMatchLineEndings()).map { String($0.1) })
    }

    func check(_ platform: String) async throws {
        let dir = Self.idevice.appending(path: platform)
        let archive = dir.appending(path: "libidevice_ffi.a"), notices = dir.appending(path: "licenses/idevice.txt")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            return XCTFail("no work/idevice/\(platform)/libidevice_ffi.a: run scripts/build-idevice.sh \(platform)")
        }
        let parsed = try Notices(String(contentsOf: notices, encoding: .utf8))
        XCTAssertGreaterThan(parsed.libraries.count, 100, "\(platform): the notices list too few crates to be idevice's")
        for (_, crate) in parsed.libraries.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(parsed.withText.contains(crate), "\(platform): \(crate) is listed with no license text")
        }
        let linked = try await Self.linkedCrates(archive)
        XCTAssertTrue(linked.contains("idevice"), "\(platform): no idevice symbols found; has the mangling changed?")
        let missing = linked.subtracting(Self.standardLibrary).subtracting(parsed.libraries.keys)
        XCTAssertEqual(missing, [], "\(platform): crates linked into libidevice_ffi.a that the notices don't list")
        let rustStd = try Data(contentsOf: dir.appending(path: "licenses/rust-std.html"))
        XCTAssertGreaterThan(rustStd.count, 10_000, "\(platform): rust-std.html is too small to be the standard library's notices")
    }

    func testMacNoticesListEveryLinkedCrate() async throws { try await check("macos") }
    func testIOSNoticesListEveryLinkedCrate() async throws { try await check("ios") }
    func testVisionOSNoticesListEveryLinkedCrate() async throws { try await check("xros") }

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

    /// The built companion (apps/companion/build.sh's, when there is one: CI builds it before the tests) ships
    /// the notices: Sparkle's from its build phase, idevice's as the companion links it, and the device app's.
    func testBuiltCompanionShipsTheNotices() throws {
        let app = ClientAssemblyTests.repo.appending(path: "build/companion/Slashplayed Companion.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("no build/companion app: run apps/companion/build.sh") }
        let res = app.appending(path: "Contents/Resources")
        let ack = res.appending(path: "Acknowledgements")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: ack.path))
        XCTAssertEqual(files, ["README.txt", "Sparkle.txt", "idevice.txt", "rust-std.html", "zsign.txt", "openssl.txt",
                               "idevice-ios.txt", "idevice-visionos.txt", "goodmountain.txt"])
        XCTAssertTrue(try String(contentsOf: ack.appending(path: "Sparkle.txt"), encoding: .utf8).contains("EXTERNAL LICENSES"))
        XCTAssertEqual(try Data(contentsOf: ack.appending(path: "idevice.txt")),
                       try Data(contentsOf: Self.idevice.appending(path: "macos/licenses/idevice.txt")))
        for p in ["ios", "xros"] {
            let bundled = Set(try FileManager.default.contentsOfDirectory(atPath: res.appending(path: "\(p)/licenses").path))
            XCTAssertEqual(bundled, Set(ClientAssembly.licenseFiles), "\(p)/licenses")
            // The start screen's face, byte for byte as scripts/fetch-font.sh checked it (its license forbids
            // any change), with that license beside it.
            XCTAssertEqual(try Data(contentsOf: res.appending(path: "\(p)/\(ClientAssembly.fontFile)")),
                           try Data(contentsOf: Self.fonts.appending(path: ClientAssembly.fontFile)), "\(p)")
            XCTAssertEqual(try Data(contentsOf: res.appending(path: "\(p)/licenses/goodmountain.txt")),
                           try Data(contentsOf: Self.fonts.appending(path: "LICENSE.md")), "\(p)")
        }
    }
}
