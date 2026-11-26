import XCTest

/// The region a game plays in on the device (issues #34 and #132; spcdn.h's "The region a game plays in"): the
/// device's region and languages mapped to Blizzard's (sp_region_for_country, sp_region_locale), the Tags
/// that says them (sp_region_tags, against Flavor.tags' layout), which source decides a game's
/// (sp_game_region: a pick, else the Mac's, else the device's region), and how a change reaches the kept row,
/// the stamp, .build.info, and Config.wtf without being put back.
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

    private func region(picked: String? = nil, mac: String? = nil, shipped: [String]? = nil, country: String? = "DE",
                        preferred: [String] = ["de-DE"], product: String = "wow_classic_era") -> [String: String] {
        sp_game_region(product, picked, mac, shipped, country, preferred)
    }

    private func macFile(_ branch: String, _ tags: String, product: String = "wow_classic_era") -> String {
        GameFiles.macRegion(product, row: ["Branch": branch, "Tags": tags, "Product": product])
    }

    /// A pick wins over the Mac's, and the Mac's over the device's; nothing but a pick is saved, so with neither
    /// the device's region is the answer every time. In the Mac's region its row's languages and Tags; in any
    /// other, the device's languages for it that the build ships.
    func testPickThenMacThenDevice() {
        let frTags = "OSX x86_64 EU? acct-FRA? geoip-FR? frFR speech?:OSX x86_64 EU? acct-FRA? geoip-FR? frFR text?"
        let mac = macFile("eu", frTags)
        // The Mac's: its row's languages and Tags, Battle.net's acct- and geoip- kept, whatever the device's.
        var r = region(mac: mac, country: "US", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Tags"], r["Source"], r["Default"], r["Mac"]],
                       ["eu", "frFR", "frFR", frTags, "mac", "eu", "eu"])
        // A pick in another region: the device's languages there, its own Tags; Default and Mac still say the Mac's.
        r = region(picked: "kr\n", mac: mac, country: "US", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"], r["Tags"], r["Source"], r["Default"], r["Mac"]],
                       ["kr", "koKR", "OSX x86_64 KR? koKR speech?:OSX x86_64 KR? koKR text?", "picked", "eu", "eu"])
        // A pick of the Mac's own region: the Mac's languages, as following it would give.
        r = region(picked: "eu", mac: mac, country: "US", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["eu", "frFR", "picked"])
        // A pick of Europe without the Mac: the device's German, unless the build doesn't ship it.
        r = region(picked: "eu", country: "US", preferred: ["it-IT", "de-DE"])
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Default"]], ["eu", "itIT", "itIT", "us"])
        XCTAssertNil(r["Mac"])
        r = region(picked: "eu", shipped: ["deDE", "enUS", "frFR"], country: "US", preferred: ["it-IT", "de-DE"])
        XCTAssertEqual(r["Text"], "deDE")
        // Neither: the device's region and languages, worked out now.
        r = region()
        XCTAssertEqual([r["Region"], r["Text"], r["Speech"], r["Source"], r["Default"]], ["eu", "deDE", "deDE", "device", "eu"])
        r = region(country: "KR", preferred: ["en-US"])
        XCTAssertEqual([r["Region"], r["Text"]], ["kr", "koKR"])
        // A pick that isn't a region, a Mac row for another product, or one with no Branch (header only, as the
        // companion sends for a game the Mac has no region for): passed over.
        XCTAssertEqual(region(picked: "cn")["Source"], "device")
        XCTAssertEqual(region(mac: macFile("eu", frTags, product: "wow"))["Source"], "device")
        XCTAssertEqual(region(mac: GameFiles.macRegion("wow_classic_era", row: ["Branch": ""]))["Source"], "device")
        XCTAssertEqual(region(mac: GameFiles.macRegion("wow_classic_era", row: nil))["Source"], "device")
        // A Mac row in a region Slashplayed doesn't offer (cn) is passed over too, not played in.
        XCTAssertEqual(region(mac: macFile("cn", ""))["Source"], "device")
        // A Mac row with no locales: the region's default, not the device's (Battle.net's first start's).
        r = region(mac: macFile("eu", ""), country: "US", preferred: ["de-DE"])
        XCTAssertEqual([r["Region"], r["Text"], r["Tags"]], ["eu", "enUS", sp_region_tags("eu", "enUS", "enUS")])
        // Europe's English as Slashplayed 1.4 and 1.5 wrote it in rows (issue #88): enUS.
        r = region(mac: macFile("eu", euTags))
        XCTAssertEqual([r["Text"], r["Speech"]], ["enUS", "enUS"])
        XCTAssertEqual(sp_region_source_name("picked"), "picked on device")
        XCTAssertEqual(sp_region_source_name("mac"), "following the Mac")
        XCTAssertEqual(sp_region_source_name("device"), "from the device's region")
    }

    /// Issue #132: Forever installed on an iPad set to the United States, then played from a Mac in Europe, then
    /// updated on the iPad. 1.7 saved the iPad's guess (us) at the install and went back to it after the Update.
    /// Now the Mac's region holds through the Update, a pick holds through the Mac's Plays and Updates, and
    /// following the Mac again is one choice away. Each step's region drives the kept row, .build.info, and
    /// Config.wtf as the launcher's start does.
    func testIssue132Sequence() throws {
        let product = "wowf", ipad = (country: "US", preferred: ["en-US"])
        let frTags = "OSX x86_64 EU? acct-FRA? geoip-FR? frFR speech?:OSX x86_64 EU? acct-FRA? geoip-FR? frFR text?"
        let version = ["BuildConfig": String(repeating: "b", count: 32), "CDNConfig": String(repeating: "c", count: 32),
                       "VersionsName": "1.60.1.71091"]
        let cdns = ["Path": "tpr/wow", "Hosts": "h.example", "Servers": "https://h.example/?x=1"]
        let stamp = table(stampHeader, ["wowf|us|\(version["BuildConfig"]!)|1.60.1.71091"])
        var picked: String?, mac: String?
        func now() -> [String: String] { sp_game_region(product, picked, mac, nil, ipad.country, ipad.preferred) }
        var set: NSArray?, why: NSString?

        // 1. Installed on the iPad, no Mac yet: the iPad's region, and nothing saved.
        var r = now()
        XCTAssertEqual([r["Region"], r["Source"]], ["us", "device"])
        let installed = sp_build_info_with(nil, product, r["Region"]!, r["Tags"], version, cdns)
        var config = sp_config_with_region(nil, r, &set)
        XCTAssertTrue(config.contains("SET portal \"us\""))

        // 2. Play from the Mac in Europe: it sends its row; the game follows it, and the start moves the row
        // and Config.wtf to Europe.
        mac = GameFiles.macRegion(product, row: ["Branch": "eu", "Tags": frTags, "Product": product])
        r = now()
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["eu", "frFR", "mac"])
        config = sp_config_with_region(config, r, &set)
        XCTAssertEqual(config, "SET portal \"eu\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n")
        var info = try XCTUnwrap(sp_build_info_for_image(installed, product, installed, stamp, ["Branch": r["Region"]!, "Tags": r["Tags"]!], &why))
        XCTAssertEqual(sp_table_row(info, "Product", product)?["Branch"], "eu")
        XCTAssertEqual(sp_table_row(info, "Product", product)?["Tags"], frTags)

        // 3. Updated on the iPad: nothing it writes says the region, so it's still the Mac's, and the Update's
        // kept row is in Europe.
        r = now()
        XCTAssertEqual([r["Region"], r["Source"]], ["eu", "mac"])
        let updated = sp_build_info_with(nil, product, r["Region"]!, r["Tags"], version, cdns)
        XCTAssertEqual(sp_table_row(updated, "Product", product)?["Branch"], "eu")
        XCTAssertEqual(sp_config_with_region(config, r, &set), config)  // Config.wtf stays Europe's
        XCTAssertEqual(set?.count, 0)

        // 4. Korea picked on the iPad: it wins over the Mac's, with Korean.
        picked = "kr\n"
        r = now()
        XCTAssertEqual([r["Region"], r["Text"], r["Source"], r["Default"]], ["kr", "koKR", "picked", "eu"])
        config = sp_config_with_region(config, r, &set)
        XCTAssertEqual(config, "SET portal \"kr\"\nSET textLocale \"koKR\"\nSET audioLocale \"koKR\"\n")
        info = try XCTUnwrap(sp_build_info_for_image(info, product, updated, stamp, ["Branch": r["Region"]!, "Tags": r["Tags"]!], &why))
        XCTAssertEqual(sp_table_row(info, "Product", product)?["Branch"], "kr")

        // 5. Another Play from the Mac (its row sent again, and its .build.info row, in Europe), then an Update
        // on the iPad: the pick holds, and the next start puts the row back in Korea.
        mac = GameFiles.macRegion(product, row: ["Branch": "eu", "Tags": frTags, "Product": product])
        let fromMac = GameStore.buildInfoText([BlizzardCDN.buildInfoLine(
            product: product, version: .init(region: "eu", buildConfig: version["BuildConfig"]!, cdnConfig: version["CDNConfig"]!,
                                              keyRing: "", buildID: "71091", versionsName: version["VersionsName"]!, productConfig: ""),
            cdns: .init(path: cdns["Path"]!, hosts: cdns["Hosts"]!, servers: cdns["Servers"]!), tags: frTags)])
        r = now()
        XCTAssertEqual([r["Region"], r["Source"]], ["kr", "picked"])
        info = try XCTUnwrap(sp_build_info_for_image(fromMac, product, updated, stamp, ["Branch": r["Region"]!, "Tags": r["Tags"]!], &why))
        XCTAssertEqual(sp_table_row(info, "Product", product)?["Branch"], "kr")
        XCTAssertEqual(sp_table_row(sp_build_info_with(nil, product, r["Region"]!, r["Tags"], version, cdns), "Product", product)?["Branch"], "kr")

        // 6. Follow Mac: the pick deleted, Europe and the Mac's French again.
        picked = nil
        r = now()
        XCTAssertEqual([r["Region"], r["Text"], r["Source"]], ["eu", "frFR", "mac"])
        XCTAssertEqual(sp_config_with_region(config, r, &set), "SET portal \"eu\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n")
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
    }

    /// A game copied from a Mac in Europe (issue #94): the companion's first Config.wtf says the Mac's region and
    /// languages, and one an older companion sent, "us" whatever the Mac's, is moved to the Mac's row at the next
    /// start, so the client signs in to Europe's account server. The Mac's own row decides both.
    func testMacGameConfigFollowsTheMacsRow() {
        let frTags = "OSX x86_64 EU? acct-FRA? geoip-FR? frFR speech?:OSX x86_64 EU? acct-FRA? geoip-FR? frFR text?"
        let choice = sp_game_region("wowf", nil, GameFiles.macRegion("wowf", row: ["Branch": "eu", "Tags": frTags]), nil, "US", ["en-US"])
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
