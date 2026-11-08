import AppKit
import SwiftUI

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
                DeviceChoices(pipeline: pipeline)
            }
        } footer: {
            caption((["Automatic uses whichever paired device is reachable, the last one used if several are."]
                     + DeviceChoices.reasons(pipeline)).joined(separator: " "))
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
            installError = "No game in \(url.path). Choose the folder holding _classic_era_, _anniversary_, _classic_, _retail_, or _forever_."
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
    case signing, games, install, general
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
