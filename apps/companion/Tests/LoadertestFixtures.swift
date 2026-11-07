import XCTest

/// The loadertest fixtures (research/loadertest, the toy with the client's import shape: an AppKit program
/// linking the same frameworks), universal like the Mac clients and never committed as a binary. Built
/// once per test process into a directory of its own, deleted when the test bundle finishes, and shared by
/// every suite that takes the same one: ClientAssemblyTests and BindCheckTests both
/// read `client`, and only ever read it.
///
/// main.m is compiled once per deployment target and each fixture only linked from it: compiling it for
/// both architectures is ~0.96 s of a ~1.2 s build. The images come out byte for byte as one-step clang
/// builds made them.
enum Loadertest {
    static let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-loadertest-\(getpid())")

    /// Like a client, with nothing extra.
    static var client: URL { get throws { try fixture(named: "sploader-macos") } }

    /// Every framework the rewrite map knows (its "<Mac install name> -> <device install name>" lines),
    /// linked into every fixture.
    static var frameworks: [String] {
        get throws {
            try String(contentsOf: ClientAssemblyTests.repo.appending(path: "shims/generated/rewrite-map.txt"), encoding: .utf8)
                .split(separator: "\n").compactMap { line in
                    line.split(separator: " -> ").first?.firstMatch(of: #/Frameworks/(\w+)\.framework/#).map { String($0.1) }
                }
        }
    }

    /// The client-shaped fixture `name`, built on first use: loadertest's main.m with an empty import table
    /// in place of the generated refs.c (which needs a client), a thread-local zero-fill section like the
    /// client's __thread_bss, `extra` C source added, every framework linked, and room left for longer
    /// install names. A name is one fixture: asking for it again with other source is a test bug. (The name
    /// is the file's, which ld's ad hoc signature takes as its identifier.)
    static func fixture(named name: String, extra extraSource: String = "") throws -> URL {
        let source = """
            #include <stddef.h>
            const void *const sp_refs[] = {0};
            const char *const sp_ref_names[] = {0};
            const size_t sp_ref_count = 0;
            __thread char sp_tls_zerofill[4096];
            char *sp_tls_use(void) { return sp_tls_zerofill; }
            \(extraSource)
            """
        if let (url, made) = built[name] {
            precondition(made == source, "loadertest fixture \(name) asked for with different source")
            return url
        }
        let url = try directory.get().appending(path: name)
        try link(url, extra: source, minOS: "11.0", linkFlags: ["-headerpad_max_install_names"])
        built[name] = (url, source)
        return url
    }

    /// Links a universal fixture at `output` from main.m (compiled for `minOS`) and `extra` C source, with
    /// `linkFlags` and every framework. The arguments are a one-step build's with main.m's object in its
    /// place, in the same order, so the image is the same.
    static func link(_ output: URL, extra: String, minOS: String, linkFlags: [String]) throws {
        let extraFile = output.deletingLastPathComponent().appending(path: "\(output.lastPathComponent)-extra.c")
        try extra.write(to: extraFile, atomically: true, encoding: .utf8)
        try TestShell.check(ClientAssembly.xcrun, ["clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=\(minOS)"]
                                + compileFlags + linkFlags + [try mainObject(minOS: minOS).path, extraFile.path,
                                                              "-lc++abi", "-lbsm", "-lc++", "-o", output.path]
                                + frameworks.flatMap { ["-framework", $0] },
                            mergingStderr: true)
    }

    private static let compileFlags = ["-fobjc-arc", "-O1", "-w"]

    /// main.m compiled for both architectures: a universal object, which ld takes apart per architecture.
    private static func mainObject(minOS: String) throws -> URL {
        if let url = objects[minOS] { return url }
        let url = try directory.get().appending(path: "main-\(minOS).o")
        try TestShell.check(ClientAssembly.xcrun, ["clang", "-c", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=\(minOS)"]
                                + compileFlags + [ClientAssemblyTests.repo.appending(path: "research/loadertest/main.m").path,
                                                  "-o", url.path],
                            mergingStderr: true)
        objects[minOS] = url
        return url
    }

    /// What's built so far, by name and by deployment target. No lock: the tests run one at a time, and
    /// fixtures are asked for from class setUps.
    private static var built: [String: (URL, String)] = [:]
    private static var objects: [String: URL] = [:]

    /// The fixtures' directory, made on first use along with the observer that deletes it when the bundle
    /// finishes (no suite's tearDown can: a later suite may still need what's in it).
    private static let directory = Result<URL, Error> {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        XCTestObservationCenter.shared.addTestObserver(Cleanup())
        return scratch
    }

    private final class Cleanup: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) { try? FileManager.default.removeItem(at: Loadertest.scratch) }
    }
}
