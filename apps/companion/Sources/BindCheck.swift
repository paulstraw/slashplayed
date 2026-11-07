import Foundation

/// The bind check: does every import of a thinned client resolve against the shims this companion
/// bundles? exports.json (shims/exports_manifest.py, built by shims/build.sh) lists, per Mac install name
/// the rewrite map knows, every symbol the device library standing in for it provides. A game patch that
/// adds an import nothing provides would stop the client's load on the device; this catches it on the
/// Mac first, before the client is copied there, as "this game version isn't supported yet". Port of scripts/recon/check_exports.py (keep
/// the two in step; they agree on every installed flavor and both platforms). Free of the app's own
/// types (Paths, Device, Flavor), so the tests build it alone.
enum BindCheck {
    /// An import nothing provides: the library the client names ("AppKit", "libSystem") and the symbol.
    struct Unresolved: Equatable, CustomStringConvertible {
        var library: String
        var symbol: String
        var description: String { "\(library) \(symbol)" }
    }

    /// The check's result for one client: how many imports it has, and those that don't resolve.
    struct Result {
        var total: Int
        var unresolved: [Unresolved]
        var ok: Bool { unresolved.isEmpty }
    }

    /// A loaded exports.json: install name -> the symbols provided for it (read lazily per library, as
    /// the whole manifest is ~8.5 MB of names).
    final class Manifest {
        let platform: String
        /// Symbols treated as provided by nothing, as if a game patch had added them (the patch drill,
        /// see `drillImport`). Empty in normal use.
        var withheld: Set<String> = []
        private let libraries: [String: [String: Any]]
        private var symbols: [String: Set<String>] = [:]

        init(_ url: URL) throws {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let platform = json["platform"] as? String,
                  let libraries = json["libraries"] as? [String: [String: Any]] else {
                throw Failure("The bundled \(url.lastPathComponent) isn't an exports manifest.")
            }
            self.platform = platform
            self.libraries = libraries
        }

        /// The symbols provided for `installName`, or nil if the rewrite map doesn't know it.
        func symbols(for installName: String) -> Set<String>? {
            if let s = symbols[installName] { return s }
            guard let list = libraries[installName]?["symbols"] as? [String] else { return nil }
            let s = Set(list)
            symbols[installName] = s
            return s
        }
    }

    /// Checks the thinned client at `client` (the CDN's arm64 slice, unchanged) against `manifest`. dyld_info names each
    /// import's library by its short name ("(from AppKit)"); that's looked up under the install name the
    /// client's load commands give it, as check_exports.py does.
    /// For an image with chained fixups, dyld_info puts the import's index first ("0x0000  _NSApp  (from
    /// AppKit)"); the clients have bind opcodes today, but today's linker writes chained fixups. A weak
    /// import ("_NSBeep [weak-import] (from AppKit)") isn't counted: missing, it binds to NULL rather than
    /// stopping the load (the launcher's spbind.m leaves it out too).
    static func check(_ client: URL, against manifest: Manifest) async throws -> Result {
        var installName: [String: String] = [:]
        for name in try MachO.loadedDylibs(Data(contentsOf: client, options: .alwaysMapped)) {
            let base = name.split(separator: "/").last.map(String.init) ?? name
            installName[String(base.prefix { $0 != "." })] = name
        }
        let r = try await Shell.run(ClientAssembly.xcrun, ["dyld_info", "-imports", client.path])
        var total = 0, unresolved: [Unresolved] = []
        for line in r.text.split(separator: "\n") {
            guard let m = line.firstMatch(of: #/^\s+(?:0x[0-9A-Fa-f]+\s+)?(\S+)\s+\(from (\S+)\)/#) else { continue }
            let symbol = String(m.1), library = String(m.2)
            total += 1
            let provided = installName[library].flatMap { manifest.symbols(for: $0) }
            if provided?.contains(symbol) != true || manifest.withheld.contains(symbol) {
                unresolved.append(Unresolved(library: library, symbol: symbol))
            }
        }
        guard total > 0 else { throw Failure("dyld_info listed no imports for \(client.lastPathComponent).") }
        // A withheld symbol the client doesn't import still fails the check, so a drill with a mistyped
        // symbol shows up as a drill rather than passing as if nothing were set.
        for symbol in manifest.withheld.sorted() where !unresolved.contains(where: { $0.symbol == symbol }) {
            unresolved.append(Unresolved(library: "patch drill", symbol: symbol))
        }
        return Result(total: total, unresolved: unresolved)
    }

    /// Checks `flavor`'s thinned client and throws Unsupported if an import doesn't resolve, logging the
    /// count and each unresolved import: the check of each client the Mac copies to a device
    /// (ClientBuild.copyClient), the patch drill's included.
    static func require(_ client: URL, flavor: String, against manifest: Manifest, platform: String,
                        onLine: (String) -> Void) async throws {
        let result = try await check(client, against: manifest)
        onLine("bind check: \(result.total - result.unresolved.count)/\(result.total) imports resolve")
        guard result.ok else {
            for u in result.unresolved { onLine("UNRESOLVED \(u)") }
            throw Unsupported(flavor: flavor, platform: platform, total: result.total, unresolved: result.unresolved)
        }
    }

    /// The patch drill: rehearses a game patch with an import the shims don't provide, without touching
    /// any game file. `defaults write com.strawdynamics.slashplayed.companion SPPatchDrillImport _NSApp`
    /// (or the launch argument `-SPPatchDrillImport _NSApp`) withholds that symbol from the manifest, so
    /// Play and Update Client stop with the "isn't supported yet" message and issue link in the copy of the
    /// game's client (Pipeline.copyGameClients), which checks an up-to-date client too while drilling and
    /// writes nothing to the device. Honoured only in Debug builds and pre-release versions (`drill`).
    static var drillImport: String? { drill("SPPatchDrillImport") }

    /// The device's patch drill: rehearses the device's newer-build screen (apps/client/sppatch.m) without a
    /// newer build on Blizzard's CDN. `defaults write com.strawdynamics.slashplayed.companion SPDevicePatchDrill
    /// binds` has Play launch the game with SP_PATCH_DRILL=binds (ClientLauncher): the device treats the
    /// current build as newer than its image, fetches its slice, and finds it binds, so it offers "Update on
    /// your Mac" (or Update, with Update Games on This Device on). A symbol instead (`_NSApp`) is withheld from
    /// the device's check too, so it says "This patch needs a Slashplayed update". Only Play passes it, so a
    /// start from the device alone never drills. Honoured only in Debug builds and pre-release versions
    /// (`drill`); apps/client/run.sh passes SP_PATCH_DRILL for a dev build.
    static var deviceDrill: String? { drill("SPDevicePatchDrill") }

    /// A drill's setting, if this companion honours drills: Debug builds and pre-release versions
    /// (0.1.0-rc5, 0.1.0-test). A release ignores the setting, so a stray default can never break a user's
    /// build or launch.
    static func drill(_ key: String, in defaults: UserDefaults = .standard, version: String = appVersion,
                      debug: Bool = isDebug) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty, debug || version.contains("-") else { return nil }
        return value
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The copy of a game's client stops on this: a client this version of Slashplayed can't run yet.
    /// Carries what the "New game patch broke it" issue form asks for.
    struct Unsupported: LocalizedError {
        /// The flavor's raw value (classic_era).
        var flavor: String
        var platform: String
        var total: Int
        var unresolved: [Unresolved]

        var errorDescription: String? {
            "wow-\(flavor) has \(unresolved.count) of \(total) imports the bundled \(platform) shims don't provide: "
                + unresolved.prefix(10).map(\.description).joined(separator: ", ") + (unresolved.count > 10 ? ", …" : "")
        }
    }

    static let issueForm = URL(string: "https://github.com/paulstraw/slashplayed/issues/new")!

    /// What the companion shows for an unsupported client: "<Flavor> <build> isn't supported by this
    /// version of Slashplayed yet…", then the missing imports.
    static func message(flavorName: String, build: String, unsupported: Unsupported) -> String {
        let list = unsupported.unresolved.prefix(10).map { "  \($0)" }.joined(separator: "\n")
        let more = unsupported.unresolved.count > 10 ? "\n  … and \(unsupported.unresolved.count - 10) more" : ""
        return "\(flavorName) \(build) isn't supported by this version of Slashplayed yet. Check for updates; if there isn't one, report it.\n"
            + "It imports \(unsupported.unresolved.count) function\(unsupported.unresolved.count == 1 ? "" : "s") the shims don't provide:\n\(list)\(more)"
    }

    /// The "New game patch broke it" issue form (.github/ISSUE_TEMPLATE/game_patch.yml), pre-filled
    /// through its field IDs: flavor, game-build, platform, companion-version, imports. Keep the IDs in
    /// step with the template. The import list is cut to keep the URL within GitHub's length limit.
    static func issueURL(flavorName: String, build: String, companionVersion: String, unsupported: Unsupported) -> URL {
        var imports = "", cut = 0
        for u in unsupported.unresolved {
            guard imports.utf8.count < 4000 else { cut += 1; continue }
            imports += "\(u)\n"
        }
        if cut > 0 { imports += "… and \(cut) more (see the companion's build log)\n" }
        var c = URLComponents(url: issueForm, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "template", value: "game_patch.yml"),
            URLQueryItem(name: "title", value: "\(flavorName) \(build) isn't supported"),
            URLQueryItem(name: "flavor", value: flavorName),
            URLQueryItem(name: "game-build", value: build),
            URLQueryItem(name: "platform", value: unsupported.platform),
            URLQueryItem(name: "companion-version", value: companionVersion),
            URLQueryItem(name: "imports", value: imports),
        ]
        // URLComponents leaves "+" alone, which GitHub would read as a space (libc++ symbols have none,
        // but a build or a version might).
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}
