import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,): what onboarding set up, to change later, in panes. A new team or bundle ID prefix means a
/// new app on each device, so it asks first. Locked while an action runs.
struct SettingsView: View {
    let pipeline: Pipeline
    /// Sparkle's own defaults key for its scheduled checks (Sparkle reads it; unset, Info.plist's YES).
    @AppStorage("SUEnableAutomaticChecks") private var autoUpdate = true
    @AppStorage(Signing.bundlePrefixKey) private var bundlePrefix = ""
    @AppStorage(Flavor.installRootKey) private var installPath = ""
    @State private var prefixDraft = ""
    @State private var pendingTeam: String?
    @State private var pendingPrefix: String?
    @State private var installError: String?
    @State private var teamIDDraft = ""
    @State private var checkingTeamID = false
    @State private var teamIDError: String?
    @AppStorage(SettingsPane.key) private var pane = SettingsPane.signing

    var body: some View {
        // Panes, not one long scrolling form: with a few devices paired it ran past a laptop's screen (the
        // rc6 run). Each locks its sections while an action runs (Pane).
        TabView(selection: $pane) {
            Pane(pipeline: pipeline) { signing }
                .tabItem { Label("Signing", systemImage: "signature") }
                .tag(SettingsPane.signing)
            Pane(pipeline: pipeline) { games }
                .tabItem { Label("Games", systemImage: "gamecontroller") }
                .tag(SettingsPane.games)
            Pane(pipeline: pipeline) { DeviceUpdatesPane(pipeline: pipeline) }
                .tabItem { Label("Updates on Devices", systemImage: "arrow.down.app") }
                .tag(SettingsPane.updates)
            Pane(pipeline: pipeline) { gameInstall }
                .tabItem { Label("Game Install", systemImage: "externaldrive") }
                .tag(SettingsPane.install)
            Pane(pipeline: pipeline) { general }
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)
        }
        .onAppear {
            prefixDraft = bundlePrefix
            Task {
                await pipeline.refreshDevices()
                await pipeline.refreshAllFreeSpace()
                // Xcode's teams as Apple has them now: an account added in Xcode since shows in the menu.
                if !pipeline.isBusy { await pipeline.refreshTeams() }
            }
        }
        .alert("Change the team?", isPresented: Binding(get: { pendingTeam != nil }, set: { if !$0 { pendingTeam = nil } })) {
            Button("Change Team", role: .destructive) {
                if let pendingTeam { pipeline.teamID = pendingTeam }
                pendingTeam = nil
            }
            // .cancel takes Escape, not Return, and beside a .destructive button nothing is the default.
            Button("Cancel", role: .cancel) { pendingTeam = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(changeWarning)
        }
        .alert("Change the bundle ID prefix?", isPresented: Binding(get: { pendingPrefix != nil }, set: { if !$0 { pendingPrefix = nil } })) {
            Button("Change Prefix", role: .destructive) {
                if let pendingPrefix { bundlePrefix = pendingPrefix }
                pendingPrefix = nil
            }
            Button("Cancel", role: .cancel) {
                prefixDraft = bundlePrefix
                pendingPrefix = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(changeWarning)
        }
    }

    @ViewBuilder private var signing: some View {
        Section {
            Picker("Team", selection: Binding(get: { pipeline.teamID }, set: { if $0 != pipeline.teamID { pendingTeam = $0 } })) {
                if !pipeline.teams.contains(where: { $0.id == pipeline.teamID }) {
                    Text(pipeline.teamID.isEmpty ? "Automatic" : "\(pipeline.teamID) (not signed in)").tag(pipeline.teamID)
                }
                ForEach(pipeline.teams) { team in
                    Text(team.isFree ? "\(team.name) (free, 7-day signing)" : "\(team.name) (\(team.id))").tag(team.id)
                }
            }
            if pipeline.fetchingTeams {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Asking Xcode for your teams…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            caption("The app on your devices is \(Signing.bundleID.isEmpty ? "<team>.slashplayed" : Signing.bundleID). A new team or prefix puts a new, empty app on each device.")
        }
        Section {
            // A team Xcode doesn't list (it couldn't reach Apple, say): checked with a stub build first.
            LabeledContent("Team ID") {
                HStack {
                    TextField("", text: $teamIDDraft, prompt: Text("A1B2C3D4E5"))
                        .onSubmit(proposeTeamID)
                        .disabled(checkingTeamID)
                    Button("Use…", action: proposeTeamID)
                        .disabled(checkingTeamID || !Signing.isValidTeamID(cleanedTeamID))
                    if checkingTeamID { ProgressView().controlSize(.small) }
                }
            }
            LabeledContent("Bundle ID prefix") {
                HStack {
                    TextField("", text: $prefixDraft, prompt: Text(pipeline.teamID.isEmpty ? "the team ID" : pipeline.teamID))
                        .onSubmit(proposePrefix)
                    Button("Change…", action: proposePrefix)
                        .disabled(prefixDraft == bundlePrefix || !Signing.isValidBundlePrefix(prefixDraft))
                }
            }
        } footer: {
            if let teamIDError {
                Text(teamIDError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                caption("Team ID: for a team not in the menu, from Membership details on developer.apple.com.")
            }
        }
    }

    @ViewBuilder private var games: some View {
        if pipeline.devices.isEmpty {
            Section { Text("No device is paired.").foregroundStyle(.secondary) }
        } else {
            ForEach(pipeline.devices) { DeviceGamesSection(pipeline: pipeline, device: $0) }
            // Its own section, as switches: beside the games' checkboxes it read as one more game. Shown with
            // no game here too, disabled, with the reason first: hidden, it looked missing (the rc6 run).
            let none = Flavor.installed.isEmpty
            Section {
                if none {
                    Text("No game is installed on this Mac, so every game streams on the device. To copy instead, install one with Battle.net (Game Install).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pipeline.devices) { device in
                    let _ = pipeline.gamesRevision
                    Toggle(device.name, isOn: Binding(
                        get: { device.copiesGameFiles && !none },
                        set: { pipeline.setCopiesGameFiles($0, for: device) }))
                        .toggleStyle(.switch)
                        .disabled(none)
                }
            } header: {
                Text("Copy Game Files from This Mac")
            } footer: {
                caption("Off: the game streams its data from Blizzard. On: Play copies this Mac's files first (Classic Era about 25 GB, Retail about 150 GB).")
            }
        }
    }

    @ViewBuilder private var gameInstall: some View {
        Section {
            LabeledContent("World of Warcraft") {
                HStack {
                    Text(Flavor.installRoot.path).truncationMode(.middle).lineLimit(1)
                        .help(Flavor.installRoot.path)
                    Button("Choose…", action: chooseInstall)
                    if !installPath.isEmpty {
                        Button("Use Default") { setInstall(nil) }
                    }
                }
            }
            if let installError {
                Text(installError).font(.caption).foregroundStyle(.orange)
            }
        } footer: {
            caption("Optional. A game installed here can be copied to a device, and Play with My Mac's Battle.net signs in through it.")
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker("Play on", selection: Bindable(pipeline).devicePin) {
                Text("Automatic").tag("")
                ForEach(pipeline.devices) { Text($0.name).tag($0.udid) }
            }
        } footer: {
            caption("Automatic uses whichever paired device is reachable, the last one used if several are.")
        }
        Section {
            Toggle("Check for updates automatically", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { Updater.shared.setAutomaticChecks(autoUpdate) }
        } footer: {
            caption("An update is never installed without asking. Slashplayed Companion > Check for Updates… works either way.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var changeWarning: String {
        "Your devices get a new, empty Slashplayed app, which fetches its game data from Blizzard again as you play (with copying on, every game file is copied again). The old app stays until you delete it from each device."
    }

    private var cleanedTeamID: String { teamIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    /// Checks the typed Team ID with Xcode (Pipeline.verifyTeamID, ~10-30 s), then asks before switching.
    private func proposeTeamID() {
        let id = cleanedTeamID
        guard Signing.isValidTeamID(id), !checkingTeamID else { return }
        checkingTeamID = true
        teamIDError = nil
        Task {
            defer { checkingTeamID = false }
            do {
                let team = try await pipeline.verifyTeamID(id)
                teamIDDraft = ""
                if team.id != pipeline.teamID { pendingTeam = team.id }
            } catch let p as Signing.Problem {
                teamIDError = "\(p.title). \(p.message)"
            } catch {
                teamIDError = error.localizedDescription
            }
        }
    }

    private func proposePrefix() {
        let p = prefixDraft.trimmingCharacters(in: .whitespaces)
        guard p != bundlePrefix, Signing.isValidBundlePrefix(p) else { return }
        pendingPrefix = p
    }

    private func chooseInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Flavor.installRoot.deletingLastPathComponent()
        panel.message = "Choose the World of Warcraft folder Battle.net installed into."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let root = Flavor.installRoot(picked: url) else {
            installError = "No game in \(url.path). Choose the folder holding _classic_era_, _anniversary_, _classic_, or _retail_."
            return
        }
        setInstall(root)
    }

    private func setInstall(_ root: URL?) {
        installError = nil
        Onboarding.setInstall(root)
        installPath = UserDefaults.standard.string(forKey: Flavor.installRootKey) ?? ""
        pipeline.installChanged()
    }
}

/// Settings' panes, the one shown kept across openings: File > Games… opens Games.
enum SettingsPane: String {
    case signing, games, updates, install, general
    static let key = "settingsPane"
}

/// Settings' Games for one device: its games, its free space (or why it isn't known), and Retail's note.
private struct DeviceGamesSection: View {
    let pipeline: Pipeline
    let device: Device

    var body: some View {
        let _ = pipeline.gamesRevision
        let chosen = device.flavors
        Section {
            // One row of checkboxes, at the left: a row per game drew the first device's card around its
            // first game alone (macOS 26), and right-aligned beside notes they moved per device (the rc6 run).
            VStack(alignment: .leading, spacing: 6) {
                // Every game, installed here or not: each one's client comes from Blizzard.
                ForEach(Flavor.allCases) { flavor in
                    Toggle(flavor.name, isOn: Binding(get: { chosen.contains(flavor) },
                                                      set: { pipeline.setGame(flavor, on: $0, for: device) }))
                        .toggleStyle(.checkbox)
                        .disabled(chosen == [flavor])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text(device.name)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(freeSpaceNote).font(.caption).foregroundStyle(.secondary)
                // Under the games, the width of the pane.
                if device.kind != .headset, chosen.contains(.retail) {
                    Text(Flavor.retailNote(noun: device.noun, free: pipeline.freeSpaces[device.udid]))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Its free space, or why that isn't known.
    private var freeSpaceNote: String {
        if let free = pipeline.freeSpaces[device.udid] {
            return "\(free.text) on the \(device.noun)."
        }
        return device.kind == .headset
            ? "The headset's free space shows once Slashplayed has started on it."
            : "The \(device.noun)'s free space shows when it's connected with USB, or once Slashplayed has started on it."
    }
}

/// One Settings pane: a grouped form 520 wide that scrolls once it's taller than a laptop screen fits,
/// locked while an action runs. The sections are, not the form: disabled, its scroll view takes no
/// scrolling either, and a copy can run for an hour. A Group passes the modifier to each section.
private struct Pane<Content: View>: View {
    let pipeline: Pipeline
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Group { content }
                .disabled(pipeline.isBusy)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 260, idealHeight: 460, maxHeight: .infinity)
    }
}

/// Settings' Updates on Devices: each device's Update Games on This Device, and for a paid team the
/// Slashplayed certificate the devices sign with. Where the key comes from depends on the team
/// (DeviceIdentity): a free team's is the identity the app is signed with; a paid team's is the
/// certificate, set up in the section below.
private struct DeviceUpdatesPane: View {
    let pipeline: Pipeline

    var body: some View {
        if pipeline.devices.isEmpty {
            Section { Text("No device is paired.").foregroundStyle(.secondary) }
        } else if let source = DeviceIdentity.source {
            let ready = source == .a || { if case .ready = pipeline.certificate { true } else { false } }()
            Section {
                // The reason first, when the switches can't be turned on: last, they looked broken (the rc6 run).
                if !ready {
                    Text("Set up the Slashplayed certificate below first.")
                        .font(.callout.weight(.medium))
                }
                ForEach(pipeline.devices) { device in
                    let _ = pipeline.gamesRevision
                    Toggle(device.name, isOn: Binding(
                        get: { device.updatesGames },
                        set: { on in
                            if !on || UpdateGamesConsent.confirm(device, source: source) { pipeline.setUpdatesGames(on, for: device) }
                        }))
                        .toggleStyle(.switch)
                        // Off can always be chosen, so a device can still be asked to forget.
                        .disabled(!ready && !device.updatesGames)
                }
            } header: {
                Text("Update Games on Devices")
            } footer: {
                Text(UpdateGamesConsent.summary(source))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if source == .b {
                CertificateSection(pipeline: pipeline)
            }
        } else {
            Section { Text("Choose a team in Signing first.").foregroundStyle(.secondary) }
        }
    }
}

/// What Update Games on This Device puts on a device, said before it's turned on (Settings, the Games
/// menu): a signing key for the team, in that device's keychain only, used only to sign game clients, and
/// how to take it back. Which key depends on the team (DeviceIdentity.Source). DeviceIdentity does the
/// sending.
enum UpdateGamesConsent {
    static func summary(_ source: DeviceIdentity.Source) -> String {
        "A device with this on makes and signs a patched game itself, with a copy of "
            + (source == .a ? "the key this Mac signs Slashplayed with" : "the Slashplayed certificate's key, made for this alone")
            + ". Turning it off deletes the key from the device."
    }

    /// Asks before turning it on. True to go ahead. Short: the three paragraphs it had were all true, and
    /// a wall of text (the rc6 run). What it sends, where it's kept, and how to take it back.
    @MainActor static func confirm(_ device: Device, source: DeviceIdentity.Source) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let the \(device.noun) update games itself?"
        let what = source == .a
            ? "a copy of the key this Mac signs Slashplayed with (macOS asks you to allow the export)"
            : "a copy of the Slashplayed certificate's key"
        alert.informativeText = """
            At the next Play, Slashplayed sends the \(device.noun) \(what). It stays in Slashplayed's keychain on the \(device.noun) alone, used only to sign game updates.

            To take it back, turn this off, or tap Forget Signing Identity in Settings on Slashplayed's start screen on the \(device.noun).
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Settings' Slashplayed Certificate (a paid team's key for devices that update games themselves, B): makes
/// the request, walks the person through developer.apple.com, takes the .cer they download (Choose, or
/// dropped here), and stops using it. SlashplayedCertificate does the keychain work.
struct CertificateSection: View {
    let pipeline: Pipeline
    @State private var problem: String?
    @State private var dropTargeted = false
    @State private var confirmingStop = false

    var body: some View {
        Section("Slashplayed Certificate") {
            switch pipeline.certificate {
            case .none:
                Text("Devices that update games themselves need a certificate of Slashplayed's own. Making it takes a minute on developer.apple.com, and you can revoke it without touching anything else.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Make Certificate Request…") { run { try reveal(pipeline.makeCertificateRequest()) } }
            case .requested:
                Text("""
                    1. Slashplayed saved a certificate request to Downloads: \(SlashplayedCertificate.requestFile.lastPathComponent). Its key stays on this Mac, in Slashplayed's own keychain.
                    2. On developer.apple.com, signed in with your team, open Certificates, IDs & Profiles > Certificates and click +.
                    3. Choose Apple Development, Continue, and upload the request. Greyed out ("Maximum number of certificates generated")? Revoke one you no longer use in the Certificates list, then click + again.
                    4. Download the certificate, then choose it here or drop it on this section.
                    """)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                // Two rows, each button at its full width: four in one row cut "Open developer.apple.com" short
                // (the rc6 run).
                HStack {
                    Button("Open developer.apple.com") { NSWorkspace.shared.open(SlashplayedCertificate.portalURL) }
                        .fixedSize()
                    Button("Show Request") { run { try reveal(pipeline.makeCertificateRequest()) } }
                        .fixedSize()
                    Spacer()
                }
                HStack {
                    Button("Choose Certificate…", action: choose)
                        .fixedSize()
                    Spacer()
                    Button("Start Over") { pipeline.stopUsingCertificate() }
                        .fixedSize()
                }
            case .ready(let cert):
                LabeledContent("Certificate", value: cert.name)
                LabeledContent("Valid until", value: cert.expires.formatted(date: .abbreviated, time: .omitted))
                let revoked = pipeline.certificateStanding == .revoked
                if revoked || cert.expires <= Date() {
                    Text("This certificate \(revoked ? "was revoked on developer.apple.com" : "has expired"), so devices can't sign game updates with it. Stop using it, then make a new one.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Stop Using the Slashplayed Certificate…", action: stop)
            case .otherCopy(let cert):
                // The fix first: rc9's only hint was "turn it on to be asked again", which couldn't help.
                Text(SlashplayedCertificate.otherCopyFix)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let cert {
                    LabeledContent("Certificate", value: cert.name)
                    Button("Stop Using the Slashplayed Certificate…", action: stop)
                } else {
                    Button("Start Over") { pipeline.stopUsingCertificate() }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(pipeline.isBusy)
        .task(id: pipeline.certificate) { await pipeline.checkCertificateStanding() }
        // As the team-change alert has it: Stop Using red, Cancel the default (Return). An NSAlert made
        // the first button, Stop Using, the default (6.2 on rc12); roles alone left no default (rc13).
        .alert("Stop using the Slashplayed certificate?", isPresented: $confirmingStop) {
            Button("Stop Using", role: .destructive) { pipeline.stopUsingCertificate() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Its key and certificate are deleted from this Mac, and Update Games on This Device turns off for every device it was sent to: each deletes its copy at its next Play or Update Client. Then revoke it on developer.apple.com (Certificates, IDs & Profiles > Certificates): until it expires, it stays valid there and counts toward your team's limit of Apple Development certificates.")
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard case .requested = pipeline.certificate, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in run { try pipeline.addCertificate(url) } }
            }
            return true
        }
    }

    private func run(_ body: () throws -> Void) {
        problem = nil
        do { try body() } catch { problem = error.localizedDescription }
    }

    private func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.x509Certificate]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        panel.message = "Choose the certificate you downloaded from developer.apple.com."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try pipeline.addCertificate(url) }
    }

    private func stop() {
        confirmingStop = true
    }
}
