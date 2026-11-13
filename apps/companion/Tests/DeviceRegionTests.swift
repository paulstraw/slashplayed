import XCTest

/// The region a game plays in on the device (issue #34; spcdn.h's "The region a game plays in"): the
/// device's region and languages mapped to Blizzard's (sp_region_for_country, sp_region_locale), the Tags
/// that says them (sp_region_tags, against Flavor.tags' layout), which source decides a game's
/// (sp_game_region: the Mac's for a game the companion installed, the region file for one the device made),
/// and how a change reaches the kept row, the stamp, .build.info, and Config.wtf without being put back.
/// Made-up rows, no Blizzard file.
final class DeviceRegionTests: XCTestCase {
    private let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Tags!STRING:0|Version!STRING:0|Product!STRING:0"
    private let stampHeader = "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0"
    private func table(_ header: String, _ rows: [String]) -> String { ([header] + rows).map { $0 + "\n" }.joined() }
    /// A row Slashplayed 1.4 or 1.5 wrote for Europe's English, as enGB (issue #88): it reads as enUS.
    private let euTags = "OSX x86_64 EU? enGB speech?:OSX x86_64 EU? enGB text?"

    /// The owner's map: the Americas and Oceania are us; Europe, Russia, the Middle East, and Africa eu; Korea
    /// kr; Taiwan, Hong Kong, and Macao tw; anything else us. Never China, Southeast Asia, or the test region.
    func testCountryMapsToBlizzardsRegion() {
        let expected: [String?: String] = [
            "US": "us", "CA": "us", "MX": "us", "BR": "us", "AR": "us", "AU": "us", "NZ": "us",
            "GB": "eu", "DE": "eu", "FR": "eu", "ES": "eu", "IT": "eu", "PL": "eu", "SE": "eu", "UA": "eu", "RU": "eu",
            "TR": "eu", "SA": "eu", "AE": "eu", "IL": "eu", "EG": "eu", "ZA": "eu", "NG": "eu", "KE": "eu",
            "KR": "kr", "TW": "tw", "HK": "tw", "MO": "tw",
            "CN": "us", "SG": "us", "JP": "us", "TH": "us", "IN": "us", "KZ": "us", nil: "us", "": "us", "de": "eu",
        ]
        for (country, region) in expected { XCTAssertEqual(sp_region_for_country(country), region, country ?? "nil") }
        for country in Locale.Region.isoRegions.map(\.identifier) {
            XCTAssertTrue(sp_regions().contains(sp_region_for_country(country)), country)
        }
        XCTAssertEqual(sp_regions(), ["us", "eu", "kr", "tw"])
        XCTAssertEqual(sp_regions().map { sp_region_name($0) }, ["Americas", "Europe", "Korea", "Taiwan"])
    }

    /// The text language: the device's first preferred language the region has a locale for (and the build
    /// ships), else the region's default. Europe's English is enUS: the clients have no enGB, and one set to it
    /// exits on a region picker the device can't show (issue #88).
    func testLanguageFollowsTheDevice() {
        XCTAssertEqual(sp_regions().map { sp_region_locales($0).first }, ["enUS", "enUS", "koKR", "zhTW"])
        let cases: [(String, [String], String)] = [
            ("eu", ["de-DE", "en-US"], "deDE"), ("eu", ["en-GB"], "enUS"), ("us", ["en-GB"], "enUS"),
            ("us", ["es-ES"], "esMX"), ("eu", ["es-419"], "esES"), ("us", ["fr-CA", "pt-BR"], "ptBR"),
            ("us", ["fr-CA"], "enUS"), ("eu", ["ja-JP", "ru"], "ruRU"), ("kr", ["en-US"], "koKR"),
            ("tw", ["zh-Hant-TW"], "zhTW"), ("tw", ["zh-Hans-CN"], "zhTW"), ("eu", [], "enUS"), ("eu", ["nl-NL"], "enUS"),
        ]
        for (region, preferred, locale) in cases {
            XCTAssertEqual(sp_region_locale(region, preferred, nil), locale, "\(region) \(preferred)")
        }
        // What the build ships: Classic's manifests have no itIT, Retail's do.
        let classic = ["OSX", "deDE", "enUS", "esES", "esMX", "frFR", "koKR", "ptBR", "ruRU", "zhCN", "zhTW", "EU", "US"]
        XCTAssertEqual(sp_region_locale("eu", ["it-IT", "fr-FR"], classic), "frFR")
        XCTAssertEqual(sp_region_locale("eu", ["it-IT"], classic), "enUS")
        XCTAssertEqual(sp_region_locale("eu", ["it-IT"], classic + ["itIT"]), "itIT")
        XCTAssertFalse(sp_locale_shipped("itIT", classic))
        XCTAssertTrue(sp_locale_shipped("itIT", nil))
    }

    /// The Tags: Flavor.tags' layout (speech group, then text group), without Battle.net's acct- and geoip-
    /// tags, which no manifest lists; and read back.
    func testTagsAreFlavorTagsLayout() {
        XCTAssertEqual(sp_region_tags("eu", "enGB", "enGB"), euTags)
        let mac = "OSX x86_64 US? acct-USA? geoip-US? enUS speech?:OSX x86_64 US? acct-USA? geoip-US? enUS text?"
        XCTAssertEqual(sp_region_tags("us", "enUS", "enUS"), mac.replacingOccurrences(of: " acct-USA? geoip-US?", with: ""))
        var text: NSString?, speech: NSString?
        sp_tags_locales(sp_region_tags("eu", "deDE", "frFR"), &text, &speech)
        XCTAssertEqual(text, "deDE")
        XCTAssertEqual(speech, "frFR")
        sp_tags_locales(mac, &text, &speech)
        XCTAssertEqual(text, "enUS")
        sp_tags_locales(nil, &text, &speech)
        XCTAssertNil(text)
    }

    private func region(_ device: Bool, file: String? = nil, kept: String? = nil, stamp: String? = nil, info: String? = nil,
                        country: String? = "DE", preferred: [String] = ["de-DE"]) -> [String: String] {
        sp_game_region("wow_classic_era", device, file, kept, stamp, info, country, preferred)
    }

    /// A game the companion installed plays in the Mac's region (its .build.info row, else the image's stamp),
    /// whatever the device's region: the companion sends the row again at every sync.
    func testTheMacDecidesItsGames() {
        let info = table(header, ["eu|1|aa|cc|\(euTags)|1.15.9.1|wow_classic_era"])
        var r = region(false, file: sp_region_file("wow_classic_era", ["Region": "kr", "Text": "koKR", "Speech": "koKR"]), info: info,
                       country: "US", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Source"]], ["eu", "enUS", "enUS", "mac"])
        r = region(false, stamp: table(stampHeader, ["wow_classic_era|kr|aa|1.15.9.1"]))
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["kr", "koKR", "mac"])
        r = region(false)
        XCTAssertEqual([r["Region"], r["Text"]], ["us", "enUS"])
    }

    /// A game the device decides: its region file, else (made before it) the kept row, else the stamp, else the
    /// game data's row, else the device's region and languages.
    func testTheDeviceDecidesItsOwn() {
        let file = sp_region_file("wow_classic_era", ["Region": "tw", "Text": "zhTW", "Speech": "zhTW", "Shipped": "enUS zhTW"])
        let kept = table(header, ["kr|1|aa|cc|OSX x86_64 KR? koKR speech?:OSX x86_64 KR? koKR text?|1.15.9.1|wow_classic_era"])
        let stamp = table(stampHeader, ["wow_classic_era|us|aa|1.15.9.1"])
        let info = table(header, ["eu|1|aa|cc|\(euTags)|1.15.9.1|wow_classic_era"])
        var r = region(true, file: file, kept: kept, stamp: stamp, info: info)
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Source"], r["Shipped"]], ["tw", "zhTW", "zhTW", "chosen", "enUS zhTW"])
        // A region file 1.4 or 1.5 wrote for Europe's English: enUS, so the game no longer exits at its start.
        r = region(true, file: sp_region_file("wow_classic_era", ["Region": "eu", "Text": "enGB", "Speech": "enGB"]))
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Source"]], ["eu", "enUS", "enUS", "chosen"])
        r = region(true, kept: kept, stamp: stamp, info: info)
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["kr", "koKR", "kept row"])
        // The stamp's Branch, with the game data's languages when its row is in that region, else the device's.
        r = region(true, stamp: stamp, info: info, preferred: ["es-ES"])
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["us", "esMX", "stamp"])
        r = region(true, stamp: table(stampHeader, ["wow_classic_era|eu|aa|1.15.9.1"]), info: info, preferred: ["de-DE"])
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["eu", "enUS", "stamp"])
        r = region(true, info: info)
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["eu", "enUS", "build.info"])
        // Nothing yet (an empty container: the host tool's): the device's, German in Germany. No more "us".
        r = region(true)
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Source"]], ["eu", "deDE", "deDE", "device"])
        r = region(true, country: "KR", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"]], ["kr", "koKR"])
        // A region file for another product, or one in a region it doesn't offer, is passed over.
        r = region(true, file: sp_region_file("wow", ["Region": "kr", "Text": "koKR", "Speech": "koKR"]))
        XCTAssertEqual(r["Source"], "device")
        r = region(true, file: sp_region_file("wow_classic_era", ["Region": "cn", "Text": "zhCN", "Speech": "zhCN"]))
        XCTAssertEqual(r["Source"], "device")
    }

    /// A device-decided row's Tags win over the old row's, so a change isn't put back; the Mac's game keeps its
    /// own row's Tags, as before.
    func testBuildInfoRowsFollowTheRegion() throws {
        let version = ["BuildConfig": String(repeating: "b", count: 32), "CDNConfig": String(repeating: "c", count: 32),
                       "VersionsName": "1.15.9.2"]
        let cdns = ["Path": "tpr/wow", "Hosts": "h.example", "Servers": "https://h.example/?x=1"]
        let usTags = sp_region_tags("us", "enUS", "enUS")
        let old = sp_build_info_with(nil, "wow_classic_era", "us", usTags, version, cdns)
        XCTAssertEqual(sp_table_row(old, "Product", "wow_classic_era")?["Tags"], usTags)
        let moved = sp_build_info_with(old, "wow_classic_era", "eu", euTags, version, cdns)
        XCTAssertEqual(sp_table_row(moved, "Product", "wow_classic_era")?["Tags"], euTags)
        XCTAssertEqual(sp_table_row(moved, "Product", "wow_classic_era")?["Branch"], "eu")
        XCTAssertEqual(sp_table_row(sp_build_info_with(old, "wow_classic_era", "eu", nil, version, cdns), "Product", "wow_classic_era")?["Tags"],
                       usTags)

        // The start-time rewrite: the image's build in .build.info, but in the old region (Settings moved it).
        let stamp = table(stampHeader, ["wow_classic_era|us|\(version["BuildConfig"]!)|1.15.9.2"])
        var why: NSString?
        XCTAssertNil(sp_build_info_for_image(old, "wow_classic_era", old, stamp, nil, &why))
        let eu = ["Branch": "eu", "Tags": euTags]
        let rewritten = try XCTUnwrap(sp_build_info_for_image(old, "wow_classic_era", old, stamp, eu, &why))
        XCTAssertNil(why)
        XCTAssertEqual(sp_table_row(rewritten, "Product", "wow_classic_era")?["Branch"], "eu")
        XCTAssertEqual(sp_table_row(rewritten, "Product", "wow_classic_era")?["Tags"], euTags)
        XCTAssertEqual(sp_table_row(rewritten, "Product", "wow_classic_era")?["Build Key"], version["BuildConfig"])
        // In its region now: left alone.
        XCTAssertNil(sp_build_info_for_image(rewritten, "wow_classic_era", old, stamp, eu, &why))
        XCTAssertNil(why)
        // Emptied (the test's 0-byte copy): written in the region, from a kept row still in the old one.
        XCTAssertEqual(sp_build_info_for_image("", "wow_classic_era", old, stamp, eu, &why), rewritten)
    }

    /// The kept row's and the stamp's region set in place, their own layout kept; nil when there's nothing to change.
    func testTableWithSetsColumns() throws {
        let stamp = table(stampHeader, ["wow_classic_era|us|aa|1.15.9.1", "wow|us|bb|12.0.1"])
        let moved = try XCTUnwrap(sp_table_with(stamp, "wow_classic_era", ["Branch": "eu"]))
        XCTAssertEqual(moved, table(stampHeader, ["wow_classic_era|eu|aa|1.15.9.1", "wow|us|bb|12.0.1"]))
        XCTAssertNil(sp_table_with(moved, "wow_classic_era", ["Branch": "eu"]))
        XCTAssertNil(sp_table_with(stamp, "wow_anniversary", ["Branch": "eu"]))
        XCTAssertNil(sp_table_with(nil, "wow", ["Branch": "eu"]))
        XCTAssertNil(sp_table_with(stamp, "wow", ["Tags": "x"]))  // no such column
    }

    /// Config.wtf: missing or empty ones always set; a value set kept (a language picked in the game, or the
    /// Mac's), except that a device-decided game Settings moved to another region gets all three replaced.
    func testConfigFollowsTheRegion() {
        let eu = ["Region": "eu", "Text": "deDE", "Speech": "deDE"]
        var set: NSArray?
        var text = sp_config_with_region(nil, eu, &set)
        XCTAssertEqual(text, "SET portal \"eu\"\nSET textLocale \"deDE\"\nSET audioLocale \"deDE\"\n")
        XCTAssertEqual(set as? [String], ["portal", "textLocale", "audioLocale"])
        // Again: nothing to do.
        XCTAssertEqual(sp_config_with_region(text, eu, &set), text)
        XCTAssertEqual(set?.count, 0)
        // The game saved them empty after a region picker it couldn't show: filled, the rest kept.
        let blank = "SET gxApi \"metal\"\nSET portal \"\"\nSET textLocale \"\"\nSET audioLocale \"enUS\"\n"
        text = sp_config_with_region(blank, eu, &set)
        XCTAssertEqual(text, "SET gxApi \"metal\"\nSET portal \"eu\"\nSET textLocale \"deDE\"\nSET audioLocale \"enUS\"\n")
        XCTAssertEqual(set as? [String], ["portal", "textLocale"])
        // A language picked in the game's options, same region: kept.
        let picked = "SET portal \"eu\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n"
        XCTAssertEqual(sp_config_with_region(picked, eu, &set), picked)
        // Settings moved the game to Europe: all three follow.
        let us = "SET portal \"us\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET gxApi \"metal\"\n"
        XCTAssertEqual(sp_config_with_region(us, eu, &set),
                       "SET portal \"eu\"\nSET textLocale \"deDE\"\nSET audioLocale \"deDE\"\nSET gxApi \"metal\"\n")
        XCTAssertEqual(set as? [String], ["portal", "textLocale", "audioLocale"])
        // Nothing said the region (a Mac game with no Branch in its row or stamp): what's set stays.
        XCTAssertEqual(sp_config_with_region(us, ["Region": "us", "Text": "enUS", "Speech": "enUS", "Source": "default"], &set), us)
        XCTAssertEqual(set?.count, 0)
    }

    /// A game copied from a Mac in Europe (issue #94): the companion's first Config.wtf says the Mac's region and
    /// languages, and one an older companion sent, "us" whatever the Mac's, is moved to the Mac's row at the next
    /// start, so the client signs in to Europe's account server. The Mac's own row decides both.
    func testMacGameConfigFollowsTheMacsRow() {
        let frTags = "OSX x86_64 EU? acct-FRA? geoip-FR? frFR speech?:OSX x86_64 EU? acct-FRA? geoip-FR? frFR text?"
        let info = table(header, ["eu|1|aa|cc|\(frTags)|1.60.1.70938|wowf"])
        let choice = sp_game_region("wowf", false, nil, nil, nil, info, "US", ["en-US"])
        let config = "SET portal \"eu\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n"
        XCTAssertEqual(GameFiles.firstConfig(region: "eu", tags: frTags), config)
        var set: NSArray?
        XCTAssertEqual(sp_config_with_region(config, choice, &set), config)  // the launcher agrees with it
        XCTAssertEqual(set?.count, 0)
        let old = "SET gxApi \"metal\"\nSET portal \"us\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\n"
        XCTAssertEqual(sp_config_with_region(old, choice, &set), "SET gxApi \"metal\"\n" + config)
        XCTAssertEqual(set as? [String], ["portal", "textLocale", "audioLocale"])
        // Speech and text apart; Europe's English as enUS (issue #88); no locale in the Tags: the region's own.
        let mixed = "OSX x86_64 EU? deDE speech?:OSX x86_64 EU? enGB text?"
        XCTAssertEqual(GameFiles.firstConfig(region: "eu", tags: mixed),
                       "SET portal \"eu\"\nSET textLocale \"enUS\"\nSET audioLocale \"deDE\"\n")
        XCTAssertEqual(GameFiles.firstConfig(region: "kr", tags: "OSX x86_64 KR?"),
                       "SET portal \"kr\"\nSET textLocale \"koKR\"\nSET audioLocale \"koKR\"\n")
    }
}
