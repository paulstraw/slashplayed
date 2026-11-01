import Foundation

/// The WoW flavors. Their names, products, clients, launch arguments, and addon numbers are
/// apps/client/flavors.plist's (a resource of the app and its tests), which scripts/flavor.sh and the
/// device's launcher read too; a new flavor needs a case here as well.
enum Flavor: String, CaseIterable, Identifiable {
    case classicEra = "classic_era"
    case anniversary
    /// MoP Classic: Battle.net's _classic_ folder and wow_classic product (Classic Era is
    /// classic_era).
    case classic
    case retail

    /// Where Battle.net installs the games unless told otherwise.
    static let defaultInstallRoot = URL(fileURLWithPath: "/Applications/World of Warcraft", isDirectory: true)
    /// UserDefaults key of the install the user picked (onboarding, Settings > Game Install); unset means
    /// the default.
    static let installRootKey = "gameInstall"

    /// The game install every flavor lives in (one folder: the shared Data/ and .build.info, and a folder
    /// per flavor).
    /// Made with isDirectory, as without it URL(fileURLWithPath:) lstat()s the path to find out: on the
    /// main thread, at launch, which held the whole app while the install's drive didn't answer.
    static var installRoot: URL {
        UserDefaults.standard.string(forKey: installRootKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultInstallRoot
    }

    var id: String { rawValue }

    /// flavors.plist's entry for each flavor. A missing or malformed one is a build mistake, so it stops here.
    private struct Entry: Decodable {
        let id: String, product: String, client: String, name: String, arguments: [String], toc: Int
    }

    private static let entries: [String: Entry] = {
        let url = Bundle(for: BundleToken.self).url(forResource: "flavors", withExtension: "plist")!
        let list = try! PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }()

    private var entry: Entry { Self.entries[rawValue]! }

    var name: String { entry.name }

    /// The flavor's folder in the install, and on the device in Documents/.
    var folder: String { "_\(rawValue)_" }

    /// Its product: .build.info's Product column (GameStore takes these) and the patch service's.
    var product: String { entry.product }

    /// The region the game is played in: the patch service's and CDN's region for it (BlizzardCDN), its
    /// image's stamp, and its .build.info row's Branch. The Mac install's Branch for the product when it
    /// has one, else us, the portal of the first Config.wtf the companion writes (GameFiles).
    var region: String { (Self.installRow(product)?["Branch"]).flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "us" }

    /// Its .build.info row's Tags: the platform, region, and locale the client fetches content for. The
    /// Mac install's when it has the product, else what Battle.net writes for a US English Mac install.
    var tags: String {
        (Self.installRow(product)?["Tags"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? "OSX x86_64 US? acct-USA? geoip-US? enUS speech?:OSX x86_64 US? acct-USA? geoip-US? enUS text?"
    }

    /// From the install's snapshot (GameInstall), never the install itself: Play's build check asks this
    /// for every game, and a stalled drive must not hold it.
    private static func installRow(_ product: String) -> [String: String]? {
        GameInstall.known?.rows[product]
    }

    /// The arguments Battle.net launches the client with, less the launch credentials it adds: Play passes
    /// these. -launcherlogin is the one that matters, since without it the client doesn't sign in from the
    /// device's login.txt (docs/research.md).
    var launcherArguments: [String] { entry.arguments }

    /// The Mac client's executable, which Battle.net launches.
    var clientExecutable: URL { clientExecutable(in: Self.installRoot) }

    func clientExecutable(in root: URL) -> URL { root.appending(path: "\(folder)/\(clientPath)") }

    /// The client's executable in the flavor's folder: also its name in the build's install manifest on
    /// Blizzard's CDN (BlizzardCDN), with backslashes.
    var clientPath: String { entry.client }

    /// The flavors installed on the Mac, as its snapshot last found them (GameInstall; empty before the
    /// first read of the install chosen now). The window, Settings, and onboarding read this on the main
    /// thread, which a drive that doesn't answer would otherwise hold.
    static var installed: [Flavor] { GameInstall.known?.flavors ?? [] }

    /// The flavors installed in `root`, read now (GameInstall.Snapshot.read, and a folder the user picks).
    static func installed(in root: URL) -> [Flavor] {
        allCases.filter { FileManager.default.fileExists(atPath: $0.clientExecutable(in: root).path) }
    }

    /// The game install a folder the user picked stands for: the folder itself if it holds a game, or the
    /// install around it if they picked a flavor's folder (_retail_) or a client app in it. Nil if neither.
    static func installRoot(picked folder: URL) -> URL? {
        var url = folder.standardizedFileURL
        for _ in 0..<3 {
            if !installed(in: url).isEmpty { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// The SPHover addon's `## Interface` number.
    var toc: Int { entry.toc }
}

extension Flavor {
    /// About 150 GB: what Retail can take on a device (README), streamed or copied.
    static let retailSpace: Int64 = 150_000_000_000

    /// What to say about Retail on an iPad or iPhone (onboarding's games, Settings' Games), by the free space
    /// the companion shows for it (Device.freeSpaceNow): only a device short of room is warned about space,
    /// so a 1 TB iPhone with 810 GB free isn't told it's more than most have (the rc6 run). Retail has
    /// played on an M2 iPad (hot, with a memory warning; README) and an iPhone 16 Pro (2026-10-29).
    static func retailNote(noun: String, free: FreeSpace?) -> String {
        let note = noun == "iPad" ? "Retail runs hot on an iPad, near its memory limit." : "Retail has been played on an iPhone 16 Pro."
        guard let free else { return "Retail can take about 150 GB; the \(noun)'s free space isn't known yet. \(note)" }
        guard free.bytes < retailSpace else { return note }
        return "Retail can take about 150 GB, and the \(noun) has \(free.text). \(note)"
    }
}

/// Finds the bundle Flavor.swift is built into: the app's, or the tests' (which have no host app).
private final class BundleToken {}

/// Where the app keeps things: what bundle-resources.sh put in it, its logs and its working files.
enum Paths {
    /// A bundled resource (Contents/Resources/<path>).
    static func resource(_ path: String) -> URL { Bundle.main.resourceURL!.appending(path: path) }

    /// The device platform's bundled shims, exports.json, rewrite-map.txt, launcher, and JIT helper.
    static func platformResources(_ device: Device) -> URL { resource(device.platform) }

    /// A bundled addon's folder (addon/<name> in the repo: SPMovie, SPHover).
    static func addon(_ name: String) -> URL { resource(name) }

    /// ~/Library/Logs/Slashplayed.
    static var logs: URL {
        directory(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Slashplayed"))
    }

    /// ~/Library/Application Support/Slashplayed: thinned clients and the assembled device apps.
    static var support: URL {
        directory(URL.applicationSupportDirectory.appending(path: "Slashplayed"))
    }

    /// BlizzardCDN's downloads: the configs, manifest chunks, and arm64 slices of each game's current build.
    static var cdn: URL { directory(support.appending(path: "cdn")) }

    /// The device's build dir (one per platform).
    static func clientDir(_ device: Device) -> URL { directory(support.appending(path: "client-\(device.platform)")) }

    /// The device app built there (and installed).
    static func clientApp(_ device: Device) -> URL { clientDir(device).appending(path: "Slashplayed.app") }

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
