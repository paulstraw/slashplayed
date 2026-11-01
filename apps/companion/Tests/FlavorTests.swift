import XCTest

/// apps/client/flavors.plist, the one list of the flavors' names, products, clients, arguments, and addon numbers,
/// against Flavor's cases: a case with no entry would stop the app the first time its name is shown.
final class FlavorTests: XCTestCase {
    func testEveryFlavorHasAnEntry() {
        for flavor in Flavor.allCases {
            XCTAssertFalse(flavor.name.isEmpty, flavor.rawValue)
            XCTAssertEqual(flavor.launcherArguments.first, "-launcherlogin", flavor.rawValue)
            XCTAssertGreaterThan(flavor.toc, 0, flavor.rawValue)
            XCTAssertTrue(flavor.product.hasPrefix("wow"), flavor.rawValue)
        }
        XCTAssertEqual(Flavor.retail.name, "Retail")
        XCTAssertEqual(Flavor.allCases.map(\.product), ["wow_classic_era", "wow_anniversary", "wow_classic", "wow"])
        XCTAssertEqual(Flavor.classicEra.clientPath, "World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic")
        XCTAssertEqual(Flavor.anniversary.clientPath, Flavor.classicEra.clientPath)
        XCTAssertEqual(Flavor.classic.clientPath, Flavor.classicEra.clientPath)
        XCTAssertEqual(Flavor.retail.clientPath, "World of Warcraft.app/Contents/MacOS/World of Warcraft")
        XCTAssertEqual(Flavor.classicEra.launcherArguments, ["-launcherlogin", "-uid", "wow_classic_era", "-initialgamemode=cera"])
    }

    /// MoP Classic is Battle.net's _classic_ folder and wow_classic product, beside Classic
    /// Era's _classic_era_ and wow_classic_era: the one name must never stand for the other.
    func testMoPClassic() {
        XCTAssertEqual(Flavor.classic.name, "MoP Classic")
        XCTAssertEqual(Flavor.classic.folder, "_classic_")
        XCTAssertEqual(Flavor.classicEra.folder, "_classic_era_")
        XCTAssertEqual(Flavor.classic.product, "wow_classic")
        XCTAssertEqual(Flavor.classic.launcherArguments, ["-launcherlogin", "-uid", "wow_classic"])
        XCTAssertEqual(Flavor.classic.toc, 50504)
        XCTAssertEqual(Flavor.allCases, [.classicEra, .anniversary, .classic, .retail])
    }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL

    /// Each addon's one TOC goes into every flavor's folder as it is, so its Interface line lists each
    /// flavor's number, in flavors.plist's order: a flavor left out flags the addon as out of date there.
    func testAddonsListEveryFlavorsInterface() throws {
        for name in ["SPHover", "SPMovie"] {
            let toc = try String(contentsOf: Self.repo.appending(path: "addon/\(name)/\(name).toc"), encoding: .utf8)
            let lines = toc.split(separator: "\n").filter { $0.hasPrefix("## Interface:") }
            XCTAssertEqual(lines.count, 1, name)
            let numbers = try XCTUnwrap(lines.first).dropFirst("## Interface:".count)
                .split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            XCTAssertEqual(numbers, Flavor.allCases.map(\.toc), name)
        }
        XCTAssertEqual(Flavor.retail.toc, 120105)
    }

    /// The toc from a build's version, as flavors.plist's comment gives the rule: 12.1.5.70575 is 120105.
    static func toc(version: String) -> Int? {
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 10000 + parts[1] * 100 + parts[2]
    }

    func testTocRule() {
        XCTAssertEqual(Self.toc(version: "1.15.9.70003"), 11509)
        XCTAssertEqual(Self.toc(version: "5.5.4.70579"), 50504)
        XCTAssertEqual(Self.toc(version: "12.1.5.70575"), 120105)
        XCTAssertNil(Self.toc(version: "12.1"))
    }

    /// Opt-in (asks Blizzard's patch service, keeps nothing): each flavor's toc is its current US build's,
    /// so a patch that changed a version shows here before the addon is flagged in game. Run the tests
    /// with TEST_RUNNER_SP_COMPARE_CDN=1.
    func testTocsMatchTheCurrentBuilds() async throws {
        guard ProcessInfo.processInfo.environment["SP_COMPARE_CDN"] == "1" else {
            throw XCTSkip("set SP_COMPARE_CDN=1 to compare with the patch service")
        }
        let cdn = BlizzardCDN(cache: FileManager.default.temporaryDirectory.appending(path: "sp-toc-\(UUID().uuidString)"))
        for flavor in Flavor.allCases {
            let version = try await cdn.version(product: flavor.product, region: "us").versionsName
            print("toc compare: \(flavor.rawValue) \(version), toc \(flavor.toc)")
            XCTAssertEqual(Self.toc(version: version), flavor.toc, "\(flavor.rawValue) is \(version)")
        }
    }
}
