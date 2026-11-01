import CryptoKit
import Foundation

/// Who signs the device app, with nothing set up by hand: the user's team, the bundle ID derived from it,
/// and the development profile and identity Xcode makes for them.
///
/// Teams come from the team lists xcodebuild and Xcode keep in their preferences (read fresh: preferences(_:)),
/// by signed-in account: every signed-in account's teams, with their names and whether each is a free
/// Personal Team. Xcode 27.1 saves its own list only when a project's Team menu asks, so xcodebuild's list,
/// which a ~2 s stub build fills in (fetchTeams), is the one a new Mac has. The keychain can't stand in: an
/// Apple Development identity only exists once Xcode has made a certificate for the team (the stub build
/// below does that), it doesn't say whether the team is free, and old expired ones linger.
///
/// The profile and identity come from building the bundled stub project (apps/client/signing, as regen.sh
/// does) for the device with -allowProvisioningUpdates -allowProvisioningDeviceRegistration: Xcode
/// registers the device, makes or refreshes the explicit App ID's profile ("iOS Team Provisioning
/// Profile: <bundle id>", with the memory entitlements) and a certificate if the team has none, and signs
/// the stub with them. The stub's embedded.mobileprovision is that profile, and the leaf certificate it was
/// signed with names the identity (by SHA-1, as codesign takes it), so nothing is searched for. About 5 s
/// when nothing changes.
enum Signing {
    struct Team: Hashable, Identifiable {
        let id: String
        let name: String
        let isFree: Bool
    }

    /// UserDefaults keys: the chosen team's ID (stored at the first action, so a change in Xcode's
    /// last-used team never moves the bundle ID), and the bundle ID's prefix (the team ID unless set).
    static let teamKey = "team"
    static let bundlePrefixKey = "bundleIDPrefix"

    /// The memory entitlement a free Personal Team's profile can't have: Apple refuses a profile with
    /// extended-virtual-addressing outright, but grants increased-memory-limit, and with that alone every
    /// flavor, Retail included, reaches the world and plays (tested on the headset). Left out of the stub's
    /// profile request and the app's signature for a free team; paid teams get both.
    static let freeTeamDropped = ["com.apple.developer.kernel.extended-virtual-addressing"]

    /// What the chosen team's build leaves out (freeTeamDropped for a free team). Empty while no team is
    /// chosen or its account isn't signed in (the build then stops on that anyway).
    static var droppedEntitlements: [String] {
        guard let id = UserDefaults.standard.string(forKey: teamKey),
              let team = teams().first(where: { $0.id == id }) else { return [] }
        return dropped(for: team)
    }

    static func dropped(for team: Team) -> [String] { team.isFree ? freeTeamDropped : [] }

    /// What the JIT helper's profile leaves out of the stub's capabilities: all of them. The helper
    /// (PlugIns/SPJitHelper.appex) needs none of the app's memory entitlements.
    static let helperDropped = ["com.apple.developer.kernel.increased-memory-limit",
                                "com.apple.developer.kernel.extended-virtual-addressing"]

    /// The device app's bundle ID: <prefix>.slashplayed, the prefix being the chosen team's ID unless the
    /// user set another. Empty until a team is chosen. Changing it means a new data container on each
    /// device, so every game file is copied again.
    static var bundleID: String {
        let defaults = UserDefaults.standard
        guard let team = defaults.string(forKey: teamKey), !team.isEmpty else { return "" }
        let prefix = defaults.string(forKey: bundlePrefixKey).flatMap { $0.isEmpty ? nil : $0 } ?? team
        return "\(prefix).slashplayed"
    }

    /// A bundle ID prefix the user typed (Settings): dot-separated letters, digits and hyphens. Empty
    /// means the team ID.
    static func isValidBundlePrefix(_ p: String) -> Bool {
        p.isEmpty || p.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*/) != nil
    }

    // MARK: Teams

    /// The teams of every account signed in to Xcode, paid first, each once, plus the team the user typed
    /// in (enteredTeam) if Xcode doesn't list it.
    static func teams() -> [Team] { xcodeAccounts().teams }

    /// Xcode's preferences, read in a fresh `defaults` process each time. This process's own
    /// CFPreferences copy of another app's domain doesn't follow a rewrite of its plist file: after a
    /// sign-in, Check Again kept reading the old list until the companion was relaunched (the rc6 run),
    /// and a scratch domain does the same (CFPreferencesAppSynchronize sees a `defaults write`, not the
    /// file replaced). cfprefsd, which a new process asks, has the file's current contents. About 20 ms.
    /// The values hold the account's Apple ID: they're only parsed, never logged.
    static func preferences(_ domain: String) -> [String: Any] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["export", domain, "-"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }

    /// What Xcode's preferences say about its accounts, the one place the account step, Play and
    /// Settings read them from.
    struct XcodeAccounts {
        /// Apple IDs signed in to Xcode (DVTDeveloperAccountManagerAppleIDLists, appleIDs(appleIDLists:)).
        let appleIDs: Int
        /// Their teams (signedInTeams), with the entered team merged in.
        let teams: [Team]
        /// Every team the lists name, signed in or not: the chosen team's name once its account is gone.
        let known: [Team]
        /// Xcode's last-used team, the first guess when the user hasn't chosen.
        let lastTeam: String?
        /// Which accounts are signed in, to tell when one is added or removed (fetchTeams). It holds the
        /// accounts' Apple IDs: compared only, never logged.
        let accountsKey: String
        var signedIn: Bool { appleIDs > 0 }

        /// `prefs`: Xcode's preferences; `xcodebuild`: xcodebuild's (xcodebuildDomain).
        init(prefs: [String: Any], xcodebuild: [String: Any] = [:], entered: Team?) {
            let lists = prefs["DVTDeveloperAccountManagerAppleIDLists"]
            let count = Signing.appleIDs(appleIDLists: lists), accounts = Signing.accounts(appleIDLists: lists)
            appleIDs = count
            let sources: [(lists: Any?, by: Set<String>)] = [
                (xcodebuild["IDEProvisioningTeamByIdentifier"], accounts.identifiers),
                (prefs["IDEProvisioningTeamByIdentifier"], accounts.identifiers),
                (prefs["IDEProvisioningTeams"], accounts.usernames),
            ]
            teams = merged(signedInTeams(sources.map { ($0.lists, count == 0 ? [] : $0.by.isEmpty ? nil : $0.by) }), entered: entered)
            known = merged(signedInTeams(sources.map { ($0.lists, nil) }), entered: entered)
            lastTeam = prefs["IDEProvisioningTeamManagerLastSelectedTeamID"] as? String
            accountsKey = (accounts.identifiers.sorted() + accounts.usernames.sorted()).joined(separator: " ")
        }
    }

    static func xcodeAccounts() -> XcodeAccounts {
        XcodeAccounts(prefs: preferences("com.apple.dt.Xcode"), xcodebuild: preferences(xcodebuildDomain), entered: enteredTeam)
    }

    /// xcodebuild's preferences domain, where it keeps its own copy of the team list (fetchTeams).
    static let xcodebuildDomain = "com.apple.dt.xcodebuild"

    /// The teams of the signed-in accounts in each list ({account: [team]}), the first list's entry winning
    /// for a team several name, paid first. `signedIn` nil takes every account. Each list keeps the
    /// accounts it ever saw: Xcode's own still names accounts signed out long ago (this Mac, 2026-10-25),
    /// and xcodebuild's is current only as of its last fetch, so only signed-in accounts count. An empty
    /// set where Xcode lists Apple IDs but not that kind of name (an older shape) takes every account.
    static func signedInTeams(_ sources: [(lists: Any?, signedIn: Set<String>?)]) -> [Team] {
        var seen: Set<String> = [], out: [Team] = []
        for (value, signedIn) in sources {
            let lists = (value as? [String: Any] ?? [:]).filter { signedIn?.contains($0.key) ?? true }
            for team in teams(byAccount: lists) where seen.insert(team.id).inserted { out.append(team) }
        }
        return out.sorted { ($0.isFree ? 1 : 0, $0.name) < ($1.isFree ? 1 : 0, $1.name) }
    }

    /// Xcode's teams, with the entered team after them unless Xcode lists it (Xcode's name and free flag
    /// win, being the account's own).
    static func merged(_ listed: [Team], entered: Team?) -> [Team] {
        guard let entered, !listed.contains(where: { $0.id == entered.id }) else { return listed }
        return listed + [entered]
    }

    /// Whether Xcode lists an Apple ID (DVTDeveloperAccountManagerAppleIDLists), which it saves at
    /// sign-in and empties at sign-out (Xcode 27.1, the rc6 run). Its own team list (above) it saves only
    /// once something in Xcode asks for the account's teams, such as a project's Team menu, so on a Mac
    /// where Xcode was never used for signing the teams come from xcodebuild's list (fetchTeams). If that
    /// lists none either, a build that names the team works from the sign-in alone: the user types the
    /// Team ID.
    ///
    /// No Apple ID listed means signed out, whatever else is cached: the stub build passes signed out
    /// when Xcode has the team's profile and identity cached (it never needs Apple then, and says nothing
    /// about the account: the rc6 run), and a typed-in team is the companion's own record. So pick fails
    /// on it first (pick(_:stored:)).
    ///
    /// A listed Apple ID isn't proof of a sign-in. Xcode 27 keeps the account's token in the
    /// data-protection keychain under Apple's own access group (59GAB85EFG.com.apple.dt.Xcode), through
    /// the KeychainService XPC service inside Xcode's DVTKeychainService framework, which checks its
    /// caller; nothing outside Xcode can read or even find that item. The listing can outlive the token: a
    /// login-keychain reset took the token and the Apple Development identity and left this list (the rc4
    /// acceptance run). The account step's stub build (checkTeam) catches that: the identity's key is gone.
    static var xcodeListsAccount: Bool { xcodeAccounts().signedIn }

    /// The Apple ID lists' shape: {"IDE.Prod": [{username: …}], "IDE.Identifiers.Prod": [{identifier: …}]}.
    /// The identifiers list counts wherever Xcode keeps one: Xcode 27.1 empties it at sign-out but leaves
    /// the signed-out Apple ID in IDE.Prod (the rc9 run: 0 and 1), and the two don't keep step either way
    /// (this Mac, 2026-10-28: 2 and 1). IDE.Prod counts only in the older shape, which has no identifiers.
    static func appleIDs(appleIDLists value: Any?) -> Int {
        let lists = value as? [String: Any] ?? [:]
        if let identifiers = lists["IDE.Identifiers.Prod"] as? [Any] { return identifiers.count }
        return (lists["IDE.Prod"] as? [Any])?.count ?? 0
    }

    static func hasAccount(appleIDLists value: Any?) -> Bool { appleIDs(appleIDLists: value) > 0 }

    /// The signed-in accounts as the team lists name them: IDEProvisioningTeamByIdentifier by identifier
    /// (IDE.Identifiers.Prod), IDEProvisioningTeams by Apple ID (IDE.Prod).
    static func accounts(appleIDLists value: Any?) -> (identifiers: Set<String>, usernames: Set<String>) {
        let lists = value as? [String: Any] ?? [:]
        func names(_ list: String, _ key: String) -> Set<String> {
            Set((lists[list] as? [[String: Any]] ?? []).compactMap { $0[key] as? String })
        }
        return (names("IDE.Identifiers.Prod", "identifier"), names("IDE.Prod", "username"))
    }

    // MARK: Fetching the teams

    /// A Team ID no account has (10 capitals and digits, so xcodebuild takes it as one): a build that
    /// names it makes xcodebuild look for the team among every signed-in account's teams, asking Apple for
    /// them and saving them in its own preferences (xcodebuildDomain), Personal Teams included. Nothing is
    /// made on any team: no account has this one, so the build stops at "No Account for Team".
    static let unknownTeam = "SPNOTEAM00"

    /// Fills in xcodebuild's team list (unknownTeam) with the stub, ~2 s, rewriting it whole each time
    /// (tested with Xcode 27.1). xcodebuild -showBuildSettings with the same settings only sometimes
    /// fetched; a build always did. A signed-out Xcode fetches nothing. The build also rewrites Xcode's
    /// own Apple ID lists from its accounts, which can lag them: on 2026-10-29, with two accounts in Xcode's
    /// Apple Accounts pane (and Xcode quit), IDE.Identifiers.Prod listed none until a build rewrote it a
    /// second in. So an empty list is only believed after this. Errors are expected and ignored: the
    /// caller reads the lists afterwards.
    static func fetchTeams(stub: URL, work: URL, onLine log: @escaping (String) -> Void) async {
        let fm = FileManager.default
        let project = work.appending(path: "project")
        try? fm.removeItem(at: work)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.copyItem(at: stub, to: project)
            _ = try await Shell.run("/usr/bin/xcrun", [
                "xcodebuild", "-project", project.appending(path: "SPProfiles.xcodeproj").path, "-scheme", "SPProfiles",
                "-destination", "generic/platform=visionOS", "-derivedDataPath", work.appending(path: "DerivedData").path,
                "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(unknownTeam)", "PRODUCT_BUNDLE_IDENTIFIER=\(unknownTeam).slashplayed",
                "build",
            ], check: false)
        } catch {
            log("teams: couldn't ask Xcode for them: \(error.localizedDescription)")
            return
        }
        let accounts = xcodeAccounts()
        log("teams: Xcode lists \(accounts.teams.count) for \(SetupStatus.count(accounts.appleIDs, "signed-in account"))")
    }

    // MARK: Entered team

    /// UserDefaults key of the team the user typed in ({id, name, free}), checked by verifyTeam.
    static let enteredTeamKey = "enteredTeam"

    static var enteredTeam: Team? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: enteredTeamKey), let id = d["id"] as? String,
                  isValidTeamID(id) else { return nil }
            return Team(id: id, name: d["name"] as? String ?? id, isFree: d["free"] as? Bool ?? false)
        }
        set {
            guard let t = newValue else { return UserDefaults.standard.removeObject(forKey: enteredTeamKey) }
            UserDefaults.standard.set(["id": t.id, "name": t.name, "free": t.isFree], forKey: enteredTeamKey)
        }
    }

    /// Where a Team ID is shown: Membership details on the developer site (a free Personal Team's isn't,
    /// so those users take the Team menu route).
    static let membershipURL = URL(string: "https://developer.apple.com/account#MembershipDetailsCard")!

    /// A Team ID: 10 capital letters and digits.
    static func isValidTeamID(_ id: String) -> Bool { id.wholeMatch(of: /[A-Z0-9]{10}/) != nil }

    /// Checks a typed Team ID the way Play will use it: builds the stub for the bundle ID the team gets,
    /// for any device of the platform (no device needed), with every entitlement; if Apple refuses one
    /// because it's a free Personal Team, again without freeTeamDropped. Returns the team with its name
    /// (from the profile) and whether it's free (refused, or a profile of 7 days rather than a year).
    static func verifyTeam(_ id: String, stub: URL, work: URL, onLine log: @escaping (String) -> Void) async throws -> Team {
        guard isValidTeamID(id) else {
            throw Problem(title: "That isn't a Team ID", message: "A Team ID is 10 capital letters and digits, like A1B2C3D4E5.")
        }
        let bundleID = bundleID(forTeam: id)
        var team = Team(id: id, name: id, isFree: false)
        let identity: Identity
        do {
            identity = try await provision(team: team, bundleID: bundleID, udid: nil, stub: stub, work: work, onLine: log)
        } catch let p as Problem where p.title.hasSuffix("is a free team and Apple refused this") {
            team = Team(id: id, name: id, isFree: true)
            identity = try await provision(team: team, bundleID: bundleID, udid: nil, stub: stub, work: work,
                                           dropped: freeTeamDropped, onLine: log)
        }
        let plist = (try? Data(contentsOf: identity.profile)).flatMap(profilePlist) ?? [:]
        let lifetime = (plist["ExpirationDate"] as? Date).flatMap { e in (plist["CreationDate"] as? Date).map { e.timeIntervalSince($0) } }
        return Team(id: id, name: plist["TeamName"] as? String ?? id,
                    isFree: team.isFree || isFreeProfile(lifetime: lifetime))
    }

    /// Onboarding's live check of the team Play will sign with: the stub build Play runs, for any device
    /// of the platform (registering none), with the team's entitlements. It fails as Play would when Xcode
    /// has no working account for the team or no Apple Development identity with its private key, which
    /// Xcode's preferences can't tell (xcodeListsAccount). About 5 s when nothing changes.
    static func checkTeam(_ team: Team, stub: URL, work: URL, onLine log: @escaping (String) -> Void) async throws {
        _ = try await provision(team: team, bundleID: bundleID(forTeam: team.id), udid: nil, stub: stub, work: work,
                                dropped: dropped(for: team), onLine: log)
    }

    /// The bundle ID a team's app gets: the prefix the user set, else the team ID (as bundleID).
    static func bundleID(forTeam id: String) -> String {
        let prefix = UserDefaults.standard.string(forKey: bundlePrefixKey).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return "\(prefix).slashplayed"
    }

    /// A free team's profile lasts 7 days, a paid team's a year.
    static func isFreeProfile(lifetime: TimeInterval?) -> Bool { lifetime.map { $0 <= 8 * 24 * 3600 } ?? false }

    /// Xcode's team list ({account: [{teamID, teamName, isFreeProvisioningTeam}]}) as Teams.
    static func teams(byAccount value: Any?) -> [Team] {
        var seen: Set<String> = [], teams: [Team] = []
        for case let list as [[String: Any]] in (value as? [String: Any] ?? [:]).values {
            for t in list {
                guard let id = t["teamID"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
                let free = (t["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? (t["teamType"] as? String == "Personal Team")
                teams.append(Team(id: id, name: t["teamName"] as? String ?? id, isFree: free))
            }
        }
        return teams.sorted { ($0.isFree ? 1 : 0, $0.name) < ($1.isFree ? 1 : 0, $1.name) }
    }

    /// Something the user has to fix before anything is signed, said for the window.
    struct Problem: LocalizedError {
        let title: String
        let message: String
        var errorDescription: String? { message }
    }

    /// The team to sign with: the chosen one (`stored`), else Xcode's last-used team if it's paid, else the
    /// only paid team, else Xcode's last-used (free) team, else the only team. Paid teams come first since
    /// their profiles last a year and carry every entitlement; a free one works, with a 7-day profile.
    /// Xcode lists an Apple ID, but no team, even after asking Apple for them (fetchTeams): offline, or
    /// the account's sign-in in Xcode has expired.
    static let teamsNotListed = Problem(title: "Xcode hasn't listed your teams yet",
                                        message: "An Apple ID is signed in to Xcode, but Xcode listed no teams for it. Check that this Mac is online and that Xcode's account doesn't ask for its password, then try again. Or type your Team ID in Settings > Signing (developer.apple.com > Account > Membership details).")

    /// The team to sign with, once Xcode lists an Apple ID: with none, Xcode is signed out, even if a team
    /// is still listed, typed in, or chosen (see xcodeListsAccount), and that's the problem, named for the
    /// chosen team when there is one.
    static func pick(_ accounts: XcodeAccounts, stored: String?) throws -> Team {
        guard accounts.signedIn else {
            guard let stored, !stored.isEmpty else { throw noAccount }
            throw noAccount(for: accounts.known.first { $0.id == stored } ?? Team(id: stored, name: stored, isFree: false))
        }
        return try pick(accounts.teams, stored: stored, xcodeLast: accounts.lastTeam, signedIn: true)
    }

    static let noAccount = Problem(title: "No Apple account in Xcode",
                                   message: "Sign in to Xcode with the Apple ID of your Apple developer account (Xcode > Settings > Apple Accounts, Sign In…), then try again.")

    static func noAccount(for team: Team) -> Problem {
        Problem(title: "No Apple account in Xcode for \(team.name)",
                message: "Sign in to Xcode with the Apple ID of team \(team.name) (Xcode > Settings > Apple Accounts, Sign In…), then try again. If the account is listed there but asks for its password, or this Mac's login keychain was reset, sign in to it again.")
    }

    /// `signedIn`: Xcode lists an Apple ID (xcodeListsAccount), so no teams means Xcode hasn't listed them
    /// yet rather than no account.
    static func pick(_ teams: [Team], stored: String?, xcodeLast: String?, signedIn: Bool = false) throws -> Team {
        if let stored, !stored.isEmpty {
            guard let team = teams.first(where: { $0.id == stored }) else {
                if signedIn && teams.isEmpty { throw teamsNotListed }
                throw Problem(title: "Team \(stored) isn't signed in",
                              message: "The device app is signed with team \(stored), but no account signed in to Xcode has it. Sign in to its Apple ID in Xcode (Settings > Apple Accounts), or pick another team in Settings > Signing (each device then gets a new, empty app).")
            }
            return team
        }
        let paid = teams.filter { !$0.isFree }, last = teams.first { $0.id == xcodeLast }
        if let team = paid.first(where: { $0 == last }) ?? (paid.count == 1 ? paid.first : nil) ??
            (paid.isEmpty ? last ?? (teams.count == 1 ? teams.first : nil) : nil) {
            return team
        }
        guard !teams.isEmpty else {
            if signedIn { throw teamsNotListed }
            throw noAccount
        }
        throw Problem(title: "Pick a team",
                      message: "Xcode is signed in to several teams. Pick the one to sign Slashplayed with in Settings > Signing.")
    }

    // MARK: Checks

    /// What makes the installed Xcode the one the command-line tools use, for a Terminal.
    static let selectXcodeCommand = "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

    /// Xcode is installed, selected, set up (its first-launch components) and its license accepted:
    /// devicectl and xcodebuild come from it. Returns the selected Xcode (Xcode.app).
    @discardableResult
    static func checkXcode() async throws -> URL {
        let r = try? await Shell.run("/usr/bin/xcode-select", ["-p"], check: false)
        let path = r.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard r?.status == 0, path.hasSuffix(".app/Contents/Developer"),
              FileManager.default.fileExists(atPath: path + "/usr/bin/xcodebuild") else {
            let found = path.isEmpty ? "No developer tools are selected" : "The selected developer tools are \(path), not Xcode"
            throw Problem(title: "Xcode isn't selected",
                          message: "\(found). Install Xcode from the App Store, open it once, then run in Terminal:\n\(selectXcodeCommand)")
        }
        // Both answer by exit status, in well under a second, without changing anything.
        if let r = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-checkFirstLaunchStatus"], check: false), r.status != 0 {
            throw Problem(title: "Xcode isn't set up yet",
                          message: "Open Xcode once so it installs its components (or run sudo xcodebuild -runFirstLaunch in Terminal), then try again.")
        }
        if let r = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-license", "check"], check: false), r.status != 0 {
            throw Problem(title: "Xcode's license isn't accepted",
                          message: "Open Xcode once and accept its license (or run sudo xcodebuild -license in Terminal), then try again.")
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Picks the team (see pick), stores it, and returns it.
    @discardableResult
    static func resolveTeam() throws -> Team {
        let team = try pick(xcodeAccounts(), stored: UserDefaults.standard.string(forKey: teamKey))
        UserDefaults.standard.set(team.id, forKey: teamKey)
        return team
    }

    /// resolveTeam, after asking Xcode for the teams (fetchTeams) when it can't pick from the list as it
    /// is: an account added to Xcode since the last fetch, a Mac where nothing fetched them yet, or
    /// preferences that list no account while Xcode has one (fetchTeams brings them up to date).
    @discardableResult
    static func resolveTeam(fetchingWith stub: URL, onLine log: @escaping (String) -> Void) async throws -> Team {
        if let team = try? resolveTeam() { return team }
        await fetchTeams(stub: stub, work: FileManager.default.temporaryDirectory.appending(path: "Slashplayed-team-list"),
                         onLine: log)
        return try resolveTeam()
    }

    // MARK: Provisioning

    /// What the device app is signed with.
    struct Identity {
        /// The development profile, for the app's embedded.mobileprovision.
        let profile: URL
        /// The signing identity's SHA-1, as codesign -s takes it.
        let hash: String
        /// Its certificate's common name, for the log.
        let name: String
    }

    /// Builds the stub project in `work` (a copy of the bundled one, since xcodebuild writes into the
    /// project and the app's own resources must stay as signed) for the device, and returns the profile and
    /// identity Xcode signed it with.
    /// `udid` nil: for any device of the platform, registering none (verifyTeam).
    static func provision(team: Team, bundleID: String, udid: String?, stub: URL, work: URL, dropped: [String] = [],
                          onLine log: @escaping (String) -> Void) async throws -> Identity {
        let fm = FileManager.default
        let project = work.appending(path: "project")
        try? fm.removeItem(at: project)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.copyItem(at: stub, to: project)
        // Xcode asks for the capabilities the stub's entitlements name, so a dropped one leaves the profile.
        if !dropped.isEmpty {
            let ents = project.appending(path: "Generated/SPProfiles.entitlements")
            try ClientAssembly.removing(dropped, from: String(contentsOf: ents, encoding: .utf8))
                .write(to: ents, atomically: true, encoding: .utf8)
            log("leaving out \(dropped.joined(separator: ", ")) of \(bundleID)'s profile")
        }
        let derived = work.appending(path: "DerivedData")
        log("provisioning \(bundleID) for team \(team.id) (\(team.name))" + (udid.map { " and device \($0)" } ?? ""))
        let r = try await Shell.run("/usr/bin/xcrun", [
            "xcodebuild", "-project", project.appending(path: "SPProfiles.xcodeproj").path, "-scheme", "SPProfiles",
            "-destination", udid.map { "id=\($0)" } ?? "generic/platform=visionOS", "-derivedDataPath", derived.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team.id)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)", "build",
        ], check: false)
        let output = r.text + "\n" + r.stderr
        let errors = output.split(separator: "\n").filter { $0.contains("error:") }.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for e in errors { log("xcodebuild: \(e)") }
        if let p = buildProblem(status: r.status, output: output, errors: errors, team: team) { throw p }

        let products = derived.appending(path: "Build/Products")
        let app = (try? fm.contentsOfDirectory(atPath: products.path))?
            .filter { $0.hasPrefix("Debug-") }.map { products.appending(path: "\($0)/SPProfiles.app") }
            .first { fm.fileExists(atPath: $0.appending(path: "embedded.mobileprovision").path) }
        guard let app else {
            throw Failure("Xcode built the signing stub but gave it no provisioning profile (\(products.path)).")
        }
        let (hash, name) = try await signer(of: app, work: work)
        let identities = try await Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).text
        if let p = keyProblem(hash: hash, name: name, identities: identities, team: team) { throw p }
        let profile = work.appending(path: "embedded.mobileprovision")
        try? fm.removeItem(at: profile)
        try fm.copyItem(at: app.appending(path: "embedded.mobileprovision"), to: profile)
        log("signing identity: \(name)")
        return Identity(profile: profile, hash: hash, name: name)
    }

    /// What the stub build's result means before its product is looked at: xcodebuild's errors said as what
    /// to do when it failed, and also when it says Xcode has no account even though it built. A build can
    /// pass from what Xcode cached (a profile and an identity) without its account; signing Play's build
    /// for a device still needs the account, so the check fails here rather than leave Play to find out.
    static func buildProblem(status: Int32, output: String, errors: [String], team: Team) -> Problem? {
        guard status != 0 || saysNoAccount(errors) else { return nil }
        return provisioningProblem(output, errors: errors, team: team)
    }

    /// xcodebuild's errors for no working account: "No Accounts: Add a new account in Accounts settings."
    /// and "No Account for Team …". Error lines only: a successful build's log names paths and settings.
    static func saysNoAccount(_ errors: [String]) -> Bool {
        errors.contains { $0.localizedCaseInsensitiveContains("No Account") }
    }

    /// Whether the identity Xcode signed the stub with (`hash`, its certificate's SHA-1) is one of the
    /// keychain's valid code-signing identities, in `security find-identity -v -p codesigning`'s list
    /// ("  1) <SHA-1> "Apple Development: …""), which holds only identities whose private key is there.
    static func keyProblem(hash: String, name: String, identities: String, team: Team) -> Problem? {
        let listed = identities.split(separator: "\n").compactMap {
            $0.firstMatch(of: /^\s*\d+\)\s+([0-9A-Fa-f]{40})\s/).map { $0.1.uppercased() }
        }
        guard !listed.contains(hash.uppercased()) else { return nil }
        return Problem(title: "No signing key for \(name)",
                       message: "Xcode signed with “\(name)”, but its private key isn't in this Mac's keychain. In Xcode > Settings > Apple Accounts, select your account, then team \(team.name), Manage Certificates…, and add an Apple Development certificate.")
    }

    /// The identity `app` is signed with: its leaf certificate's SHA-1 (as codesign -s takes it) and common
    /// name. codesign writes the chain into `work` as <prefix>0, 1, …; the leaf is 0.
    static func signer(of app: URL, work: URL) async throws -> (hash: String, name: String) {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let certs = work.appending(path: "cert")
        try await Shell.run("/usr/bin/codesign", ["-d", "--extract-certificates=\(certs.path)", app.path])
        let leaf = try Data(contentsOf: URL(fileURLWithPath: certs.path + "0"))
        let hash = Insecure.SHA1.hash(data: leaf).map { String(format: "%02X", $0) }.joined()
        let name = SecCertificateCreateWithData(nil, leaf as CFData)
            .flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? hash
        return (hash, name)
    }

    // MARK: Profile expiry

    /// How long before the app's profile runs out the companion warns and rebuilds it. A free team's
    /// profile lasts 7 days (a paid team's a year); once it's gone the device won't open the app until it's
    /// signed again.
    static let renewWithin: TimeInterval = 2 * 24 * 3600

    struct ProfileInfo: Equatable {
        let uuid: String
        let expires: Date
    }

    /// A provisioning profile's UUID and expiry. The file is a CMS envelope that holds its XML plist as
    /// is, so the plist is cut out rather than the envelope opened: the signature is codesign's and the
    /// device's business, this only says when to renew.
    static func profileInfo(_ data: Data) -> ProfileInfo? {
        guard let plist = profilePlist(data), let uuid = plist["UUID"] as? String,
              let expires = plist["ExpirationDate"] as? Date else { return nil }
        return ProfileInfo(uuid: uuid, expires: expires)
    }

    /// The plist inside a profile's CMS envelope.
    static func profilePlist(_ data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                           format: nil) as? [String: Any]
    }

    /// Deletes Xcode's cached copies of a profile about to run out, so the next stub build can't reuse it
    /// and has Xcode fetch or make a fresh one. Only that profile, by UUID; Xcode downloads it again if
    /// it's still the team's current one.
    static func forgetCachedProfile(uuid: String, log: (String) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"] {
            let file = home.appending(path: "\(dir)/\(uuid).mobileprovision")
            if (try? FileManager.default.removeItem(at: file)) != nil { log("removed Xcode's cached profile \(file.path) to renew it") }
        }
    }

    /// xcodebuild's errors, said as what to do.
    static func provisioningProblem(_ output: String, errors: [String], team: Team) -> Problem {
        let has = { (s: String) in output.localizedCaseInsensitiveContains(s) }
        let title = "Couldn't make a provisioning profile"
        if has("agreed to the Xcode") || has("license") && has("agree") {
            return Problem(title: "Xcode's license isn't accepted",
                           message: "Open Xcode once and accept its license (or run sudo xcodebuild -license in Terminal), then try again.")
        }
        if has("runFirstLaunch") {
            return Problem(title: "Xcode isn't set up yet",
                           message: "Open Xcode once so it installs its components (or run sudo xcodebuild -runFirstLaunch in Terminal), then try again.")
        }
        if has("Developer Mode") {
            return Problem(title: "Developer Mode is off",
                           message: "Turn on Developer Mode on the device (Settings > Privacy & Security > Developer Mode), restart it when asked, then try again.")
        }
        if saysNoAccount(errors) || has("No Account") || has("sign in") && has("account") {
            return noAccount(for: team)
        }
        // A free team refuses some capabilities (freeTeamDropped), and caps how many apps it may have on a
        // device and how many App IDs it may make a week.
        if has("Personal development teams") || has("free provisioning") {
            return Problem(title: "\(team.name) is a free team and Apple refused this",
                           message: "Free Personal Teams can't have every capability, and can have only a few apps on a device and a few new App IDs a week. \(errors.suffix(2).joined(separator: "\n"))\nDelete other apps you signed with this Apple ID from the device, or wait a few days, then try again; a paid Apple Developer Program team has none of these limits.")
        }
        // Apple keeps one Apple Development certificate per Mac; its private key lives in the keychain of
        // the macOS user that made it. Another user account on the same Mac (or the same Mac after a reinstall)
        // gets this, and Xcode won't make a second one without revoking the first.
        if has("Revoke certificate") || has("private key is not installed") {
            return Problem(title: "This Mac's signing certificate is in another keychain",
                           message: "Your Apple account already has an Apple Development certificate for this Mac, but its private key isn't in this macOS user's keychain: it was made in another user account on this Mac, or before macOS was reinstalled. If that account still has it: there, open Xcode > Settings > Apple Accounts, select the account, then the team, Manage Certificates…, Control-click the Apple Development certificate and choose Export; then open the exported file in this account. Otherwise revoke it in Manage Certificates and Xcode makes a new one (anything signed with the old one has to be signed again).")
        }
        // xcodebuild waits about a minute for a locked device (an unworn headset), then says "Timed out
        // waiting for all destinations … The device needs to be unlocked to continue". Play waits for the
        // unlock before provisioning (Pipeline.waitForUnlock), so this is a device locked in the meantime.
        if has("needs to be unlocked") {
            return Problem(title: "The device is locked",
                           message: "Xcode has to reach the device to sign Slashplayed for it. Put on the Vision Pro, or unlock the iPad or iPhone, then try again.")
        }
        if has("Unable to find a destination") || has("is not available") && has("destination")
            || has("Timed out waiting for all destinations") {
            return Problem(title: "Xcode can't see the device",
                           message: "Xcode couldn't reach the device to register it. Unlock it, keep it on the same network (or on USB), check it's listed in Xcode's Device Hub (Xcode > Open Developer Tool > Device Hub), then try again.")
        }
        let detail = errors.isEmpty ? "xcodebuild failed with no error message." : errors.suffix(3).joined(separator: "\n")
        return Problem(title: title, message: "\(detail)\nOpening the team in Xcode > Settings > Apple Accounts sometimes fixes this.")
    }
}
