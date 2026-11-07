import Foundation

/// The steps that turn the games' Mac clients into the device app, as apps/client/build.sh does them (keep
/// the two in step: the client images they make are byte-identical, and so is the one the launcher's
/// apps/client/spassemble.m makes on the device from the same slice). Their input differs: the companion's
/// is the arm64 slice of each game's client from Blizzard's CDN (ClientBuild), build.sh's the Mac's install,
/// thinned to arm64. Each image then has its load commands rewritten (the rewrite map, plus the rpath to Frameworks/), its platform set
/// and its header retyped MH_BUNDLE (MachO.retype), as wow-<flavor>, with its Stamp beside it. The launcher, the JIT helper, the
/// shims and the templates come from the companion's bundled resources. Only load commands and headers change; the
/// game's code and data are untouched. Nothing here signs or knows a device: ClientBuild does that.
/// Free of the app's own types (Paths, Device, Flavor), so the tests build it alone.
enum ClientAssembly {
    static let xcrun = "/usr/bin/xcrun"

    /// A device platform's build settings, as scripts/platform.sh sets them (keep the two in step).
    struct Platform: Equatable {
        /// scripts/platform.sh's SP_PLATFORM: xros or ios.
        var name: String
        /// vtool -set-build-version's platform name (SP_VTOOL).
        var vtool: String
        /// The deployment target, also MinimumOSVersion (SP_MINOS).
        var minOS: String
        /// LC_BUILD_VERSION's platform number (PLATFORM_VISIONOS, PLATFORM_IOS), for checks.
        var machOPlatform: UInt32
        /// The Info.plist template's @PLATFORM@ (CFBundleSupportedPlatforms), @DTPLATFORM@, @FAMILY@.
        var plistPlatform: String
        var dtPlatform: String
        var family: String
        /// @PLATFORM_KEYS@: on iOS a launch screen, without which the app runs in a scaled 1024x768
        /// compatibility mode, no status bar, and landscape only on an iPhone (as scripts/platform.sh); on
        /// both the keys naming the app icon (the bundled icon/, apps/client/build-icons.sh), as actool's
        /// partial Info.plist has them.
        var platformKeys: String

        static let xros = Platform(name: "xros", vtool: "visionos", minOS: "27.0", machOPlatform: 11,
                                   plistPlatform: "XROS", dtPlatform: "xros", family: "<integer>7</integer>",
                                   platformKeys: "<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><string>AppIcon</string></dict>")
        // The test iPad (iPad14,5, M2) runs iPadOS 26.6, the test iPhone (iPhone17,1, A18 Pro) iOS 27.0.1.
        // Family 1 (iPhone) and 2 (iPad), as scripts/platform.sh: an app without 1 won't install on an iPhone.
        static let ios = Platform(name: "ios", vtool: "ios", minOS: "26.0", machOPlatform: 2,
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
                                      + "<key>CFBundleIconName</key><string>AppIcon</string></dict></dict>")

        static func named(_ name: String) -> Platform? { [xros, ios].first { $0.name == name } }
    }

    /// The on-device JIT helper (apps/client/helper): PlugIns/<helperName>.appex, executable <helperName>.
    static let helperName = "SPJitHelper"

    /// The JIT helper's bundle ID: the app's plus .helper (an extension's has to start with its app's).
    static func helperBundleID(_ bundleID: String) -> String { bundleID + ".helper" }

    /// shims/generated/rewrite-map.txt: "<Mac install name> -> <device install name>" per line.
    static func rewriteMap(_ text: String) throws -> [(from: String, to: String)] {
        try text.split(separator: "\n").filter { !$0.isEmpty }.map { line in
            let parts = line.components(separatedBy: " -> ")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw Failure("The bundled rewrite map has a line that isn't \"<from> -> <to>\": \(line)")
            }
            return (parts[0], parts[1])
        }
    }

    /// The build a client image was made from, in a file beside it: spbuild-<flavor> next to wow-<flavor>,
    /// in the app now and in Library/ with an image an on-device update puts there, so the launcher always
    /// knows which build the image it's about to load is. .build.info's columns that name a build, for
    /// the image's product, as a one-row table of the same shape (the launcher reads both with one parser).
    /// apps/client/build.sh writes the same bytes.
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

        /// From Blizzard's version row for the product (BlizzardCDN), the build the image is made from
        /// now. The same as `from(product:row:)` gives for an install of that build.
        static func from(product: String, version: BlizzardCDN.Version) -> Stamp {
            Stamp(product: product, branch: version.region, buildKey: version.buildConfig, version: version.versionsName)
        }

        var text: String {
            "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0\n\(product)|\(branch)|\(buildKey)|\(version)\n"
        }
    }

    /// Makes `client` (the Mac's universal or arm64 executable) into a device client image at `output`:
    /// thinned, load commands rewritten plus the Frameworks/ rpath, platform set, retyped. `checkThinned`
    /// sees the thinned image before anything is rewritten (the bind check: its imports still name the Mac
    /// libraries). Returns what the retype changed, for the log.
    @discardableResult
    static func prepareClient(_ client: URL, to output: URL, rewriteMap: [(from: String, to: String)],
                              platform: Platform, checkThinned: ((URL) async throws -> Void)? = nil) async throws -> [String] {
        try? FileManager.default.removeItem(at: output)
        if try MachO.isFat(Data(contentsOf: client, options: .alwaysMapped)) {
            try await Shell.run(xcrun, ["lipo", "-thin", "arm64", client.path, "-output", output.path])
        } else {
            try FileManager.default.copyItem(at: client, to: output)
        }
        try await checkThinned?(output)
        // Every map entry, whether or not this client links it (as build.sh), so the result is the same.
        let changes = rewriteMap.flatMap { ["-change", $0.from, $0.to] }
        try await Shell.run(xcrun, ["install_name_tool"] + changes
                            + ["-add_rpath", "@executable_path/Frameworks", output.path])
        try await Shell.run(xcrun, ["vtool", "-set-build-version", platform.vtool, platform.minOS, platform.minOS,
                                    "-replace", "-output", output.path, output.path])
        var image = try Data(contentsOf: output)
        let changed = try MachO.retype(&image)
        try image.write(to: output)
        return changed
    }

    /// Load commands the device can't satisfy: anything not in @rpath (the shims), a top-level system
    /// framework binary or /usr/lib. Empty when the image is fully rewritten (build.sh's otool check).
    static func unrewrittenLoadCommands(_ image: URL) throws -> [String] {
        try MachO.loadedDylibs(Data(contentsOf: image, options: .alwaysMapped)).filter { name in
            !(name.hasPrefix("@rpath/") || name.hasPrefix("/usr/lib/")
              || name.wholeMatch(of: #/\/System\/Library\/Frameworks\/[A-Za-z]*\.framework\/[A-Za-z]*/#) != nil)
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
    /// (scripts/build-idevice.sh); and the start screen's face, Goodmountain, ships with its license
    /// (scripts/fetch-font.sh).
    static let licenseFiles = ["idevice.txt", "rust-std.html", "goodmountain.txt"]

    /// The start screen's face (apps/client/spstart.m), in the app's root, unmodified: its license forbids
    /// changing or renaming the file (scripts/fetch-font.sh, bundle-resources.sh).
    static let fontFile = "Goodmountain-Regular.otf"

    /// The addons the device app carries, at addons/<name>/ (as addon/ has them), which its launcher puts
    /// in each game's folder before the client loads (apps/client/spcdn.m's sp_addons_place: SPMovie on every
    /// device, SPHover on the headset), as build.sh's app has them. Both on both platforms: the launcher
    /// decides. bundle-resources.sh bundles them in Resources/addons/.
    static let addonFiles = ["SPMovie/SPMovie.toc", "SPMovie/SPMovie.lua", "SPHover/SPHover.toc", "SPHover/SPHover.lua"]

    /// Assembles an unsigned Slashplayed.app at `app` from the given clients (flavor raw value → the Mac
    /// client, universal or its arm64 slice, and the build it is, for its Stamp) and the companion's resources: `platformResources` (<platform>/: the shims, the
    /// launcher, the JIT helper's executable, rewrite-map.txt, exports.json, licenses/, the start screen's
    /// font) and `templates` (client/:
    /// Info.plist, entitlements.plist, flavors.plist, and helper/'s two, as apps/client has them), and `addons`
    /// (addonFiles: Resources/addons/, or the repo's addon/). Writes the filled
    /// entitlements to `entitlements` and the helper's to `helperEntitlements`, for signing. Throws BindCheck.Unsupported for a
    /// client with an import the shims don't provide (a game patch this version doesn't know), and fails
    /// on an unrewritten load command.
    static func assemble(app: URL, clients: [(flavor: String, executable: URL, stamp: Stamp)], platform: Platform,
                         platformResources: URL, templates: URL, addons: URL, team: String, bundleID: String,
                         entitlements entitlementsFile: URL, helperEntitlements: URL, droppedEntitlements: [String] = [],
                         onLine: (String) -> Void) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        let frameworks = app.appending(path: "Frameworks")
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let map = try rewriteMap(String(contentsOf: platformResources.appending(path: "rewrite-map.txt"), encoding: .utf8))
        let exports = try BindCheck.Manifest(platformResources.appending(path: "exports.json"))
        if let drill = BindCheck.drillImport {
            onLine("patch drill: withholding \(drill) from the bundled shims")
            exports.withheld = [drill]
        }
        for (flavor, executable, stamp) in clients {
            guard fm.fileExists(atPath: executable.path) else {
                throw Failure("The \(flavor) client isn't at \(executable.path) any more.")
            }
            onLine("bundling \(flavor)")
            let image = app.appending(path: "wow-\(flavor)")
            // prepareClient's hook is optional, so escaping; it's only called before prepareClient returns.
            let changed = try await withoutActuallyEscaping(onLine) { onLine in
                try await prepareClient(executable, to: image, rewriteMap: map, platform: platform) { thinned in
                    try await BindCheck.require(thinned, flavor: flavor, against: exports, platform: platform.name, onLine: onLine)
                }
            }
            for line in changed {
                onLine(line)
            }
            let left = try unrewrittenLoadCommands(image)
            guard left.isEmpty else {
                throw Failure("wow-\(flavor) still loads libraries the device doesn't have (the rewrite map misses them): \(left.joined(separator: ", "))")
            }
            try stamp.text.write(to: app.appending(path: Stamp.fileName(flavor)), atomically: true, encoding: .utf8)
        }
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
        // The shims' exports, as the bind check above reads them: the launcher checks a newer build against
        // them on the device (apps/client/sppatch.m, spbind.m), as build.sh's app has them.
        try fm.copyItem(at: platformResources.appending(path: "exports.json"), to: app.appending(path: "exports.json"))
        // The rewrite map, as prepareClient uses it: the launcher assembles a newer build's image on the device
        // with it (apps/client/spassemble.m), as build.sh's app has it.
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

/// The few Mach-O header reads and edits the build needs (64-bit little-endian, arm64).
enum MachO {
    static let magic64: UInt32 = 0xFEED_FACF
    static let execute: UInt32 = 2, bundle: UInt32 = 8
    static let lcSegment64: UInt32 = 0x19, lcBuildVersion: UInt32 = 0x32
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
    static let dylibLoads: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    /// S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL.
    static let zeroFillTypes: Set<UInt32> = [0x1, 0xC, 0x12]

    /// A universal (fat) file: its magic is big-endian FAT_MAGIC or FAT_MAGIC_64.
    static func isFat(_ d: Data) -> Bool {
        guard d.count >= 4 else { return false }
        let m = d.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return m == 0xCAFE_BABE || m == 0xCAFE_BABF
    }

    static func u32(_ d: Data, _ off: Int) -> UInt32 {
        let i = d.startIndex + off
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    static func setU32(_ d: inout Data, _ off: Int, _ v: UInt32) {
        let i = d.startIndex + off
        for k in 0..<4 { d[i + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(k))) }
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

    /// apps/client/retype.py: makes a thinned executable dlopen-able for the launcher. Retypes the header
    /// MH_EXECUTE -> MH_BUNDLE (dyld refuses to dlopen an executable) and zeroes the file offset of
    /// zero-fill sections (dyld rejects a non-main image whose zero-fill section has one, e.g. the
    /// client's __DATA,__thread_bss). Only the header and section headers change. Returns a line per
    /// section changed.
    static func retype(_ d: inout Data) throws -> [String] {
        guard d.count >= 32, u32(d, 0) == magic64, u32(d, 12) == execute else {
            throw Failure("Not a thin 64-bit executable, so it can't be retyped.")
        }
        setU32(&d, 12, bundle)
        var changed: [String] = []
        var sections: [Int] = []
        try forEachCommand(d) { cmd, off in
            guard cmd == lcSegment64 else { return }
            for i in 0..<Int(u32(d, off + 64)) { sections.append(off + 72 + i * 80) }
        }
        for s in sections {
            let offset = u32(d, s + 48), flags = u32(d, s + 64)
            if zeroFillTypes.contains(flags & 0xFF) && offset != 0 {
                changed.append("\(name(d, s)),\(name(d, s + 16)): zero-fill offset 0x\(String(offset, radix: 16)) -> 0")
                setU32(&d, s + 48, 0)
            }
        }
        return changed
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

    /// LC_BUILD_VERSION's platform and minimum OS (xxxx.yy.zz nibbles), if it has one.
    static func buildVersion(_ d: Data) throws -> (platform: UInt32, minOS: UInt32)? {
        var found: (UInt32, UInt32)?
        try forEachCommand(d) { cmd, off in
            if cmd == lcBuildVersion { found = (u32(d, off + 8), u32(d, off + 12)) }
        }
        return found
    }

    /// A section or segment name: 16 bytes, NUL-padded.
    private static func name(_ d: Data, _ off: Int) -> String {
        String(decoding: d[(d.startIndex + off)..<(d.startIndex + off + 16)].prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func cString(_ d: Data, _ off: Int) -> String {
        String(decoding: d[(d.startIndex + off)...].prefix { $0 != 0 }, as: UTF8.self)
    }
}
