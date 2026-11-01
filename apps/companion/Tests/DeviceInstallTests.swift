import XCTest

/// The launcher's install of a game on the device, for an app built with no client images (build.sh's
/// SP_NO_IMAGES=1): which games the start screen offers and which it installs (sp_games), the region an
/// install asks the patch service for (sp_install_region), and the game folder's .flavor.info it writes
/// (sp_flavor_info, against the companion's GameFiles.flavorInfo). The install itself is the update's chain
/// (spcdn.m, spbind.m, spassemble.m, spsign.m), which their own tests cover. Made-up rows, no Blizzard file.
final class DeviceInstallTests: XCTestCase {
    private let order = Flavor.allCases.map(\.rawValue)

    private func games(_ bundled: [String], _ made: [String]) -> (games: [String], installable: Set<String>) {
        var installable: NSSet?
        let games = sp_games(order, bundled, made, &installable)
        return (games, (installable as? Set<String>) ?? [])
    }

    /// An app with images offers what it bundles, in flavors.plist's order, and installs nothing, even with
    /// an update the device made of a game it no longer bundles: as before images could be left out.
    func testAnAppWithImagesOffersItsOwn() {
        let r = games(["retail", "classic_era"], ["anniversary", "retail"])
        XCTAssertEqual(r.games, ["classic_era", "retail"])
        XCTAssertEqual(r.installable, [])
        // One flavors.plist doesn't list goes last, as the launcher always sorted them.
        XCTAssertEqual(games(["zz_test", "retail"], []).games, ["retail", "zz_test"])
    }

    /// An app without images offers every game, and installs the ones the device hasn't made.
    func testAnAppWithoutImagesOffersEveryGame() {
        let none = games([], [])
        XCTAssertEqual(none.games, order)
        XCTAssertEqual(none.installable, Set(order))
        let some = games([], ["retail"])
        XCTAssertEqual(some.games, order)
        XCTAssertEqual(some.installable, Set(order).subtracting(["retail"]))
    }

    /// The region: the product's .build.info row's Branch (lowercased, as the patch check takes it), else
    /// "us", the companion's first Config.wtf's.
    func testInstallRegion() {
        let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0"
        let info = [header, "EU|1|aaaa|1.15.9.70003|wow_classic_era", "kr|1|bbbb|11.2.7.1|wow"].map { $0 + "\n" }.joined()
        XCTAssertEqual(sp_install_region(info, "wow_classic_era"), "eu")
        XCTAssertEqual(sp_install_region(info, "wow"), "kr")
        XCTAssertEqual(sp_install_region(info, "wow_anniversary"), "us")
        XCTAssertEqual(sp_install_region(nil, "wow"), "us")
        XCTAssertEqual(sp_install_region([header, "|1|cccc|1.0|wow"].map { $0 + "\n" }.joined(), "wow"), "us")
    }

    /// The .flavor.info the device writes for a game it installed is the one the companion sends.
    func testFlavorInfoIsTheCompanions() {
        for flavor in Flavor.allCases {
            XCTAssertEqual(sp_flavor_info(flavor.product), GameFiles.flavorInfo(flavor), flavor.rawValue)
        }
    }
}
