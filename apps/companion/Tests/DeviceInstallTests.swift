import XCTest

/// The launcher's games and their clients (apps/client/spcdn.m): which games the start screen offers and
/// which it installs (sp_games), which Library/spgames files it retires rather than load (sp_slice_retire),
/// and the game folder's .flavor.info the launcher writes at every start (sp_flavor_info, against the
/// companion's GameFiles.flavorInfo). The install itself is the update's chain (spcdn.m, spbind.m), which
/// their own tests cover, and its region is DeviceRegionTests'. Made-up rows and fixtures of our own, no
/// Blizzard file.
final class DeviceInstallTests: XCTestCase {
    private let order = Flavor.allCases.map(\.rawValue)

    private func games(_ made: [String]) -> (games: [String], installable: Set<String>) {
        var installable: NSSet?
        let games = sp_games(order, made, &installable)
        return (games, (installable as? Set<String>) ?? [])
    }

    /// Every game is offered, in flavors.plist's order, and the ones the device has nothing of are installed.
    func testEveryGameIsOfferedAndTheMissingOnesInstalled() {
        let none = games([])
        XCTAssertEqual(none.games, order)
        XCTAssertEqual(none.installable, Set(order))
        let some = games(["retail", "classic_era"])
        XCTAssertEqual(some.games, order)
        XCTAssertEqual(some.installable, Set(order).subtracting(["retail", "classic_era"]))
    }

    /// A Library/spgames client spguest can't load is retired with its stamp, row, and spsource, before the
    /// launcher would load it: the image an older Slashplayed assembled there (an MH_BUNDLE, as a 1.4 device
    /// holds), a copy cut short, and an executable spguest's load refuses though its header looks right (one
    /// with chained fixups, as a client built for a newer macOS would have: the check is spguest's own parse,
    /// so it can't pass what the load refuses). The game data beside it stays. The game's own executable
    /// (linked as the clients are, with dyld-info opcodes) stays, files and all, and so does nothing at all.
    func testAClientThatIsntAnExecutableIsRetiredNotLoaded() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "sp-slice-retire-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let games = scratch.appending(path: "Library/spgames"), data = scratch.appending(path: "Documents/.build.info")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "game data".write(to: data, atomically: true, encoding: .utf8)
        try "int main(void) { return 0; }\nint sp_retire_answer(void) { return 42; }\n"
            .write(to: scratch.appending(path: "fixture.c"), atomically: true, encoding: .utf8)
        let exe = scratch.appending(path: "exe"), bundle = scratch.appending(path: "bundle"), chained = scratch.appending(path: "chained")
        let source = scratch.appending(path: "fixture.c").path, opcodes = ["-mmacosx-version-min=11.0", "-Wl,-no_fixup_chains"]
        try ClientAssemblyTests.run(["clang", "-arch", "arm64"] + opcodes + [source, "-o", exe.path])
        try ClientAssemblyTests.run(["clang", "-arch", "arm64"] + opcodes + ["-bundle", source, "-o", bundle.path])
        try ClientAssemblyTests.run(["clang", "-arch", "arm64", "-mmacosx-version-min=13.0", "-Wl,-fixup_chains", source, "-o", chained.path])
        let stamp = "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\nwow_classic_era|us|00112233445566778899aabbccddeeff|1.2.3.45678\n"
        func place(_ client: Data) throws {
            try client.write(to: games.appending(path: "wow-classic_era"))
            try stamp.write(to: games.appending(path: "spbuild-classic_era"), atomically: true, encoding: .utf8)
            try "row".write(to: games.appending(path: "spbuildinfo-classic_era"), atomically: true, encoding: .utf8)
            try "updated\n".write(to: games.appending(path: "spsource-classic_era"), atomically: true, encoding: .utf8)
        }
        func left() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: games.path)) }
        let all: Set<String> = ["wow-classic_era", "spbuild-classic_era", "spbuildinfo-classic_era", "spsource-classic_era"]

        // The executable spguest loads: nothing to say, nothing retired.
        try place(try Data(contentsOf: exe))
        XCTAssertNil(sp_slice_problem(games.appending(path: "wow-classic_era").path))
        XCTAssertNil(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertEqual(try left(), all)
        // What a 1.4 device's signing left when it stopped part way goes, beside a client that stays.
        for name in ["wow-classic_era.signing", "wow-classic_era.signed"] { try Data("x".utf8).write(to: games.appending(path: name)) }
        let leftovers = try XCTUnwrap(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertTrue(leftovers.contains("wow-classic_era.signing (0.0 MB), wow-classic_era.signed"), leftovers)
        XCTAssertEqual(try left(), all)

        // An older Slashplayed's image: retired, with all three beside it.
        try place(try Data(contentsOf: bundle))
        let line = try XCTUnwrap(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertTrue(line.contains("wow_classic_era 1.2.3.45678") && line.contains("an image an older Slashplayed made"), line)
        XCTAssertEqual(try left(), [])
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "game data")

        // A copy cut short: its header's fine, its segments run past the file's end.
        let whole = try Data(contentsOf: exe)
        try place(whole.prefix(whole.count / 2))
        XCTAssertTrue(sp_slice_problem(games.appending(path: "wow-classic_era").path)?.contains("cut short") == true)
        XCTAssertNotNil(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertEqual(try left(), [])

        // Chained fixups, which spguest doesn't apply: its header is an arm64 MH_EXECUTE with an entry point,
        // whole, which is all the launcher's own check once looked at.
        try place(try Data(contentsOf: chained))
        XCTAssertTrue(sp_slice_problem(games.appending(path: "wow-classic_era").path)?.contains("chained fixups") == true)
        XCTAssertNotNil(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertEqual(try left(), [])

        // Not a Mach-O at all, and no client: the first retired, the second nothing to do.
        try place(Data("not a client".utf8))
        XCTAssertNotNil(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
        XCTAssertNil(sp_slice_retire(games.path, "classic_era", "wow_classic_era"))
    }

    /// The addons the launcher puts in a game's folder (sp_addons_place): SPMovie everywhere, SPHover only on
    /// the headset, as the companion copied them; a file written only when it's missing or its bytes differ.
    func testAddonsArePlaced() throws {
        let repo = ClientAssemblyTests.repo, addons = repo.appending(path: "addon")
        let game = FileManager.default.temporaryDirectory.appending(path: "sp-addons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: game) }
        func place(hover: Bool) -> (ok: Bool, line: String) {
            var line: NSString?
            let ok = sp_addons_place(addons.path, game.path, hover, &line)
            return (ok, (line as String?) ?? "")
        }
        let movie = game.appending(path: "Interface/AddOns/SPMovie/SPMovie.lua")
        var r = place(hover: false)
        XCTAssertTrue(r.ok, r.line)
        XCTAssertEqual(r.line, "addons: 0 up to date, wrote SPMovie/SPMovie.toc SPMovie/SPMovie.lua")
        XCTAssertEqual(try Data(contentsOf: movie), try Data(contentsOf: addons.appending(path: "SPMovie/SPMovie.lua")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appending(path: "Interface/AddOns/SPHover").path))
        // The same bytes: nothing written (the date stays).
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: movie.path)
        XCTAssertEqual(place(hover: false).line, "addons: 2 up to date")
        XCTAssertEqual(try movie.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date(timeIntervalSince1970: 1))
        // Another copy (an older addon) is replaced; on the headset SPHover comes too.
        try Data("-- old".utf8).write(to: movie)
        r = place(hover: true)
        XCTAssertEqual(r.line, "addons: 1 up to date, wrote SPMovie/SPMovie.lua SPHover/SPHover.toc SPHover/SPHover.lua")
        XCTAssertEqual(try Data(contentsOf: movie), try Data(contentsOf: addons.appending(path: "SPMovie/SPMovie.lua")))
        // An app without them says so.
        var line: NSString?
        XCTAssertFalse(sp_addons_place(game.appending(path: "none").path, game.path, false, &line))
        XCTAssertTrue((line as String?)?.contains("FAILED SPMovie/SPMovie.toc (not in the app)") == true, "\(String(describing: line))")
    }

    /// The .flavor.info the launcher writes for a game is the one the companion sends.
    func testFlavorInfoIsTheCompanions() {
        for flavor in Flavor.allCases {
            XCTAssertEqual(sp_flavor_info(flavor.product), GameFiles.flavorInfo(flavor), flavor.rawValue)
        }
    }
}
