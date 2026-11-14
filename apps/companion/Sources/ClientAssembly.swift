import Foundation

/// The steps that make the device app, as apps/client/build.sh does them (keep the two in step): the
/// launcher, the JIT helper, the shims, and the templates, from the companion's bundled resources. The app
/// holds no game client: each game's is its unchanged arm64 slice, which the launcher loads with spguest
/// from the app's data container (Library/spgames/wow-<flavor>, apps/client/spguest.c), and which the Mac
/// copies there (ClientBuild.copyClient) or the device fetches itself. So the app is the same for every
/// device on a platform and every set of games. Nothing here signs or knows a device: ClientBuild does that.
/// Free of the app's own types (Paths, Device, Flavor), so the tests build it alone.
enum ClientAssembly {
    static let xcrun = "/usr/bin/xcrun"

    /// A device platform's build settings, as scripts/platform.sh sets them (keep the two in step).
    struct Platform: Equatable {
        /// scripts/platform.sh's SP_PLATFORM: xros or ios.
        var name: String
        /// The deployment target, also MinimumOSVersion (SP_MINOS).
        var minOS: String
        /// The Info.plist template's @PLATFORM@ (CFBundleSupportedPlatforms), @DTPLATFORM@, @FAMILY@.
        var plistPlatform: String
        var dtPlatform: String
        var family: String
        /// @PLATFORM_KEYS@: on iOS a launch screen, without which the app runs in a scaled 1024x768
        /// compatibility mode, no status bar, and landscape only on an iPhone (as scripts/platform.sh); on
        /// both the keys naming the app icon (the bundled icon/, apps/client/build-icons.sh), as actool's
        /// partial Info.plist has them.
        var platformKeys: String

        static let xros = Platform(name: "xros", minOS: "27.0",
                                   plistPlatform: "XROS", dtPlatform: "xros", family: "<integer>7</integer>",
                                   platformKeys: "<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><string>AppIcon</string></dict>")
        // The test iPad (iPad14,5, M2) runs iPadOS 26.6, the test iPhone (iPhone17,1, A18 Pro) iOS 27.0.1.
        // Family 1 (iPhone) and 2 (iPad), as scripts/platform.sh: an app without 1 won't install on an iPhone.
        static let ios = Platform(name: "ios", minOS: "26.0",
                                  plistPlatform: "iPhoneOS", dtPlatform: "iphoneos",
                                  family: "<integer>1</integer><integer>2</integer>",
                                  platformKeys: "<key>UILaunchScreen</key><dict/><key>UIStatusBarHidden</key><true/>"
                                      + "<key>UISupportedInterfaceOrientations~iphone</key><array>"
                                      + "<string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>"
                                      + "<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>"
                                      + "<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>"
                                      + "<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
                                      + "<key>CFBundleIcons~ipad</key><dict><key>CFBundlePrimaryIcon</key><dict>"
                                      + "<key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string></array>"
                                      + "<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
                                      // A game, with Game Mode and the controller profile that lets Settings
                                      // remap a controller for the app, as scripts/platform.sh says.
                                      + "<key>LSApplicationCategoryType</key><string>public.app-category.games</string>"
                                      + "<key>LSSupportsGameMode</key><true/>"
                                      + "<key>GCSupportsControllerUserInteraction</key><true/>"
                                      + "<key>GCSupportedGameControllers</key><array><dict>"
                                      + "<key>ProfileName</key><string>ExtendedGamepad</string></dict></array>")

        static func named(_ name: String) -> Platform? { [xros, ios].first { $0.name == name } }
    }

    /// The on-device JIT helper (apps/client/helper): PlugIns/<helperName>.appex, executable <helperName>.
    static let helperName = "SPJitHelper"

    /// The JIT helper's bundle ID: the app's plus .helper (an extension's has to start with its app's).
    static func helperBundleID(_ bundleID: String) -> String { bundleID + ".helper" }

    /// The build a game's client is, in a file beside it: Library/spgames/spbuild-<flavor> next to
    /// wow-<flavor>, written last by whatever put the client there (the Mac's copyClient, the device's own
    /// update or install, apps/client/seed-client.sh), so the launcher always knows which build the client
    /// it's about to load is. .build.info's columns that name a build, for the client's product, as a
    /// one-row table of the same shape (the launcher reads both with one parser).
    struct Stamp: Equatable {
        var product: String, branch: String, buildKey: String, version: String

        static func fileName(_ flavor: String) -> String { "spbuild-\(flavor)" }

        /// From .build.info's row for the product (GameStore.buildInfo's rows).
        static func from(product: String, row: [String: String]?) throws -> Stamp {
            guard let row, let key = row["Build Key"], !key.isEmpty, let version = row["Version"], !version.isEmpty else {
                throw Failure("The game install's .build.info has no build for \(product).")
            }
            return Stamp(product: product, branch: row["Branch"] ?? "", buildKey: key, version: version)
        }

        /// From Blizzard's version row for the product (BlizzardCDN), the build the Mac copies now. The
        /// same as `from(product:row:)` gives for an install of that build.
        static func from(product: String, version: BlizzardCDN.Version) -> Stamp {
            Stamp(product: product, branch: version.region, buildKey: version.buildConfig, version: version.versionsName)
        }

        /// Whether the client is `version`'s build, by its Build Key alone: the launcher's region_sync writes
        /// the region chosen in the device's Settings into the stamp's Branch, so an up-to-date client's
        /// stamp can differ from `from(product:version:)`'s in its Branch.
        func isBuild(_ version: BlizzardCDN.Version) -> Bool { buildKey == version.buildConfig }

        var text: String {
            "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\n\(product)|\(branch)|\(buildKey)|\(version)\n"
        }
    }

    /// The device app's version: the companion's own (MARKETING_VERSION, as scripts/platform.sh's SP_VERSION
    /// reads it from project.yml), its X.Y.Z only, since a bundle version can't carry an -rc1 suffix.
    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return String(short.prefix { $0.isNumber || $0 == "." })
    }

    /// The device app's Info.plist from its template (scripts/platform.sh's sp_plist).
    static func infoPlist(template: String, bundleID: String, platform: Platform, version: String = appVersion) -> String {
        // sp_plist's sed replaces the first @BUNDLE_ID@ per line only; the template has one.
        template.replacingOccurrences(of: "@BUNDLE_ID@", with: bundleID)
            .replacingOccurrences(of: "@VERSION@", with: version)
            .replacingOccurrences(of: "@PLATFORM@", with: platform.plistPlatform)
            .replacingOccurrences(of: "@DTPLATFORM@", with: platform.dtPlatform)
            .replacingOccurrences(of: "@MINOS@", with: platform.minOS)
            .replacingOccurrences(of: "@FAMILY@", with: platform.family)
            .replacingOccurrences(of: "@PLATFORM_KEYS@", with: platform.platformKeys)
    }

    /// The device app's entitlements from their template.
    static func entitlements(template: String, team: String, bundleID: String) -> String {
        template.replacingOccurrences(of: "@TEAM@", with: team).replacingOccurrences(of: "@BUNDLE_ID@", with: bundleID)
    }

    /// An entitlements plist without `keys` (the free-team test's dropped memory entitlements), as XML.
    /// Unchanged text when there's nothing to drop, so normal builds sign with the template as written.
    static func removing(_ keys: [String], from plist: String) throws -> String {
        guard !keys.isEmpty else { return plist }
        guard var dict = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any] else {
            throw Failure("An entitlements plist isn't a dictionary.")
        }
        for k in keys { dict.removeValue(forKey: k) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    /// The Mac's root CAs (DER) for the client's own TLS trust store (shims/security/spssl.m), as a binary
    /// plist array. Read from the system roots keychain with `security`, as build.sh does:
    /// SecTrustCopyAnchorCertificates gives a slightly different set (one root differs on macOS 26).
    static func exportRootCAs(to output: URL) async throws {
        let r = try await Shell.run("/usr/bin/security", ["find-certificate", "-a", "-p",
                                                          "/System/Library/Keychains/SystemRootCertificates.keychain"])
        let ders = try pemCertificates(r.text)
        guard !ders.isEmpty else { throw Failure("security found no root certificates in the system roots keychain.") }
        try PropertyListSerialization.data(fromPropertyList: ders, format: .binary, options: 0).write(to: output)
    }

    /// The DER bytes of every certificate in PEM text.
    static func pemCertificates(_ pem: String) throws -> [Data] {
        try pem.matches(of: #/-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----/#.dotMatchesNewlines()).map {
            guard let der = Data(base64Encoded: String($0.1), options: .ignoreUnknownCharacters) else {
                throw Failure("security printed a root certificate that isn't valid base64.")
            }
            return der
        }
    }

    /// The device app's licenses/, as bundle-resources.sh bundles them and apps/client/build.sh copies them:
    /// the JIT helper links idevice (MIT) with its Rust crates and the Rust standard library
    /// (scripts/build-idevice.sh); the launcher spapple, with isideload (MIT) and its Rust crates
    /// (scripts/build-spapple.sh); and the start screen's face, Goodmountain, ships with its license
    /// (scripts/fetch-font.sh).
    static let licenseFiles = ["idevice.txt", "rust-std.html", "spapple.txt", "goodmountain.txt"]

    /// The start screen's face (apps/client/spstart.m), in the app's root, unmodified: its license forbids
    /// changing or renaming the file (scripts/fetch-font.sh, bundle-resources.sh).
    static let fontFile = "Goodmountain-Regular.otf"

    /// The addons the device app carries, at addons/<name>/ (as addon/ has them), which its launcher puts
    /// in each game's folder before the client loads (apps/client/spcdn.m's sp_addons_place: SPMovie on every
    /// device, SPHover on the headset, SPKeyboard on the iPad and iPhone), as build.sh's app has them. All on
    /// both platforms: the launcher decides. bundle-resources.sh bundles them in Resources/addons/.
    static let addonFiles = ["SPMovie/SPMovie.toc", "SPMovie/SPMovie.lua", "SPHover/SPHover.toc", "SPHover/SPHover.lua",
                             "SPKeyboard/SPKeyboard.toc", "SPKeyboard/SPKeyboard.lua"]

    /// Assembles an unsigned Slashplayed.app at `app` from the companion's resources: `platformResources`
    /// (<platform>/: the shims, the launcher, the JIT helper's executable, rewrite-map.txt, exports.json,
    /// licenses/, the start screen's font), `templates` (client/: Info.plist, entitlements.plist,
    /// flavors.plist, and helper/'s two, as apps/client has them), and `addons` (addonFiles:
    /// Resources/addons/, or the repo's addon/). Writes the filled entitlements to `entitlements` and the
    /// helper's to `helperEntitlements`, for signing.
    static func assemble(app: URL, platform: Platform, platformResources: URL, templates: URL, addons: URL,
                         team: String, bundleID: String, entitlements entitlementsFile: URL, helperEntitlements: URL,
                         droppedEntitlements: [String] = []) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        let frameworks = app.appending(path: "Frameworks")
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try fm.copyItem(at: platformResources.appending(path: "slashplayed"), to: app.appending(path: "slashplayed"))
        // The JIT helper (apps/client/helper, the launcher's spjit.m starts it), an app extension: in
        // PlugIns/ with its own Info.plist, and later its own profile and signature (ClientBuild).
        let helper = app.appending(path: "PlugIns/\(helperName).appex")
        try fm.createDirectory(at: helper, withIntermediateDirectories: true)
        try fm.copyItem(at: platformResources.appending(path: helperName), to: helper.appending(path: helperName))
        let helperInfo = try String(contentsOf: templates.appending(path: "helper/Info.plist"), encoding: .utf8)
        try infoPlist(template: helperInfo, bundleID: helperBundleID(bundleID), platform: platform)
            .write(to: helper.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        let helperEnts = try String(contentsOf: templates.appending(path: "helper/entitlements.plist"), encoding: .utf8)
        try entitlements(template: helperEnts, team: team, bundleID: helperBundleID(bundleID))
            .write(to: helperEntitlements, atomically: true, encoding: .utf8)
        let dylibs = try fm.contentsOfDirectory(atPath: platformResources.path).filter { $0.hasSuffix(".dylib") }.sorted()
        guard !dylibs.isEmpty else { throw Failure("The companion has no bundled shims for \(platform.name).") }
        for d in dylibs { try fm.copyItem(at: platformResources.appending(path: d), to: frameworks.appending(path: d)) }
        // The shims' exports, as the Mac's bind check of each client it copies reads them (ClientBuild): the
        // launcher checks a newer build against them on the device (apps/client/sppatch.m, spbind.m), as
        // build.sh's app has them.
        try fm.copyItem(at: platformResources.appending(path: "exports.json"), to: app.appending(path: "exports.json"))
        // The rewrite map: the launcher opens the client's libraries through it (apps/client/spguestlaunch.m),
        // as build.sh's app has it.
        try fm.copyItem(at: platformResources.appending(path: "rewrite-map.txt"), to: app.appending(path: "rewrite-map.txt"))
        // The licenses of what the app's code links and the font it ships (licenseFiles), as build.sh's app has them.
        let licenses = platformResources.appending(path: "licenses")
        guard licenseFiles.allSatisfy({ fm.fileExists(atPath: licenses.appending(path: $0).path) }) else {
            throw Failure("The companion has no bundled licenses for \(platform.name)'s launcher and JIT helper.")
        }
        try fm.copyItem(at: licenses, to: app.appending(path: "licenses"))
        // The start screen's face (fontFile), as build.sh's app has it.
        guard fm.fileExists(atPath: platformResources.appending(path: fontFile).path) else {
            throw Failure("The companion has no bundled start screen font for \(platform.name).")
        }
        try fm.copyItem(at: platformResources.appending(path: fontFile), to: app.appending(path: fontFile))
        // The compiled icon (Assets.car, plus loose PNGs on iOS) goes in the app's root, as build.sh's
        // build-icons.sh writes it.
        let icon = platformResources.appending(path: "icon")
        let iconFiles = (try? fm.contentsOfDirectory(atPath: icon.path)) ?? []
        guard iconFiles.contains("Assets.car") else { throw Failure("The companion has no bundled app icon for \(platform.name).") }
        for f in iconFiles.sorted() { try fm.copyItem(at: icon.appending(path: f), to: app.appending(path: f)) }
        let info = try String(contentsOf: templates.appending(path: "Info.plist"), encoding: .utf8)
        try infoPlist(template: info, bundleID: bundleID, platform: platform)
            .write(to: app.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        // The flavors' names (the start screen, apps/client/spstart.m) and Battle.net's arguments (launcher.m).
        try fm.copyItem(at: templates.appending(path: "flavors.plist"), to: app.appending(path: "flavors.plist"))
        // The addons (addonFiles), as build.sh's app has them.
        for file in addonFiles {
            guard fm.fileExists(atPath: addons.appending(path: file).path) else {
                throw Failure("The companion has no bundled addon \(file).")
            }
            let dest = app.appending(path: "addons/\(file)")
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: addons.appending(path: file), to: dest)
        }
        // The client looks up its icon, wow.icns, for its data setup dialog's IconURL, and throws on a nil
        // path. The dialog is never drawn (shims/appkit/spnotice.m), so the file only has to exist.
        try Data().write(to: app.appending(path: "wow.icns"))
        try await exportRootCAs(to: app.appending(path: "sproots.plist"))
        let ents = try String(contentsOf: templates.appending(path: "entitlements.plist"), encoding: .utf8)
        try removing(droppedEntitlements, from: entitlements(template: ents, team: team, bundleID: bundleID))
            .write(to: entitlementsFile, atomically: true, encoding: .utf8)
    }
}

/// The few Mach-O header reads the bind check needs (64-bit little-endian, arm64).
enum MachO {
    static let magic64: UInt32 = 0xFEED_FACF
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
    static let dylibLoads: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]

    static func u32(_ d: Data, _ off: Int) -> UInt32 {
        let i = d.startIndex + off
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    /// Calls `body` with each load command's type and offset.
    static func forEachCommand(_ d: Data, _ body: (UInt32, Int) throws -> Void) throws {
        guard d.count >= 32, u32(d, 0) == magic64 else { throw Failure("Not a thin 64-bit Mach-O.") }
        var off = 32
        for _ in 0..<u32(d, 16) {
            guard off + 8 <= d.count else { throw Failure("A Mach-O load command runs past the end of the file.") }
            try body(u32(d, off), off)
            off += Int(u32(d, off + 4))
        }
    }

    /// The install names the image loads, in load-command order.
    static func loadedDylibs(_ d: Data) throws -> [String] {
        var names: [String] = []
        try forEachCommand(d) { cmd, off in
            guard dylibLoads.contains(cmd) else { return }
            names.append(cString(d, off + Int(u32(d, off + 8))))
        }
        return names
    }

    private static func cString(_ d: Data, _ off: Int) -> String {
        String(decoding: d[(d.startIndex + off)...].prefix { $0 != 0 }, as: UTF8.self)
    }
}
