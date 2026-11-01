import AppKit
import SwiftUI

/// Onboarding's window content: the steps down the side, the current one's check, what it found, and
/// how to fix it.
struct OnboardingView: View {
    let setup: Onboarding
    /// Called at Ready's "Start Playing".
    let onFinish: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set Up Slashplayed").font(.headline).padding(.bottom, 6)
                ForEach(Onboarding.StepID.allCases) { step in
                    SetupStepRow(title: step.title, status: setup.current == step ? .checking : setup.status[step],
                                 isCurrent: setup.current == step, isBeyond: setup.current.map { step.rawValue > $0.rawValue } ?? false)
                }
                SetupStepRow(title: "Ready", status: setup.current == nil ? .ok("") : nil,
                             isCurrent: setup.current == nil, isBeyond: setup.current != nil)
                Spacer()
            }
            .padding(20)
            .frame(width: 250, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                // Scrolls, so a step with several devices (or the certificate) never pushes the buttons off.
                ScrollView {
                    Group {
                        if let step = setup.current {
                            StepPage(setup: setup, step: step)
                        } else {
                            ReadyPage(setup: setup)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    if setup.current != .xcode {
                        Button("Back") { setup.back() }
                            .disabled(setup.pipeline.isBusy)
                    }
                    Spacer()
                    if let step = setup.current {
                        Button("Check Again") { Task { await setup.check(step) } }
                            .disabled(setup.pipeline.isBusy)
                        Button("Continue") { setup.next() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!setup.status(step).isOK || setup.pipeline.isBusy)
                    } else {
                        Button("Done") {
                            setup.finish()
                            onFinish()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .frame(width: 520, alignment: .topLeading)
        }
        .frame(height: 560)
        .onAppear { setup.begin() }
        .onDisappear { setup.stop() }
    }
}

/// A step in the side list: its check's outcome, or where it is in the order.
private struct SetupStepRow: View {
    let title: String
    let status: Onboarding.Status?
    let isCurrent: Bool
    let isBeyond: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .ok?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .problem?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .checking? where isCurrent: Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                default: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isBeyond ? .secondary : .primary)
        }
    }
}

/// One step: the one thing to do (its lead), the check's outcome, its controls, and the details after.
private struct StepPage: View {
    let setup: Onboarding
    let step: Onboarding.StepID

    static let iPhoneMouseHelp = URL(string: "https://github.com/paulstraw/slashplayed/blob/main/docs/troubleshooting.md#no-cursor-with-a-mouse-on-an-iphone")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(step.title).font(.title2.weight(.semibold))
            Text(lead).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            StatusBox(status: setup.status(step))
            controls
            if let details {
                Text(details).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What to do on this step, in a line.
    private var lead: String {
        let ok = setup.status(step).isOK
        switch step {
        case .xcode: return "Install Xcode from the Mac App Store, and open it once."
        case .account: return "Sign in to Xcode with your Apple Account."
        case .device: return "Pair each device you'll play on with this Mac."
        case .helper:
            return ok ? "Nothing to do now: leave LocalDevVPN off. Slashplayed asks for it when the game starts."
                : "Install LocalDevVPN, free on the App Store, on each device."
        case .games: return "Choose the games for each device."
        case .install: return "Nothing to do here, unless World of Warcraft is on this Mac in another folder."
        case .firstInstall: return "Install Slashplayed on each device you'll play on."
        case .updates: return "Optional: let a device update a game itself when Blizzard patches it."
        }
    }

    /// Why, and what else to know: after the lead, the check, and the controls.
    private var details: String? {
        switch step {
        case .xcode:
            "Slashplayed uses Xcode's tools to sign, install, and start the app on your devices. You won't need Xcode itself after setup."
        case .account:
            "Any Apple Account works. A free one's Personal Team signs for 7 days at a time, and Play signs again after that. A paid Apple Developer Program team signs for a year."
        case .device:
            "Slashplayed runs on an iPad with an M2 chip or later, an iPhone 15 Pro or later, and Apple Vision Pro."
        case .helper:
            "Each time the game starts, Slashplayed prepares its code on the device, with no Mac needed. It reaches the device's developer services through LocalDevVPN. If a device stops accepting Slashplayed's pairing later, File > Pair Again makes a new one."
        case .games:
            "Each game streams its data from Blizzard as you play, so its first start takes a few minutes."
                + (Flavor.installed.isEmpty ? "" : " A game installed on this Mac can be copied instead (Settings > Games), at about 30 MB a second.")
        case .install:
            "You sign in to Battle.net on the device. A game Battle.net installed here adds two things: copying its files to a device instead of streaming, and Play with My Mac's Battle.net, a fallback sign-in in the menu by Play."
        case .firstInstall:
            "Install builds the app (about a minute the first time), signs it with your team, installs it, and pairs an iPad or iPhone over USB. Keep the iPad or iPhone unlocked and on its cable, or wear the headset, until it's done."
        case .updates:
            "Without it, the device asks you to press Play on this Mac after a patch. You can change this later in Settings."
        }
    }

    @ViewBuilder private var controls: some View {
        switch step {
        case .xcode:
            if !setup.status(step).isOK {
                if !setup.xcodeInstalled {
                    Link("Get Xcode on the Mac App Store", destination: URL(string: "macappstore://apps.apple.com/app/id497799835")!)
                }
                CommandBox(command: Signing.selectXcodeCommand,
                           note: "Then run this in Terminal, so Slashplayed uses that Xcode (it asks for your Mac password):")
            }
        case .account:
            let teams = setup.teams
            if teams.count > 1 {
                Picker("Team", selection: Binding(get: { setup.pipeline.teamID }, set: { setup.pickTeam($0) })) {
                    if !teams.contains(where: { $0.id == setup.pipeline.teamID }) { Text("Choose…").tag(setup.pipeline.teamID) }
                    ForEach(teams) { Text("\($0.name) (\($0.isFree ? "free, 7-day signing" : $0.id))").tag($0.id) }
                }
                .frame(maxWidth: 360)
                Text("Pick it now: changing the team later makes a new, empty app on each device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if setup.status(step).isOK {
                // Setup Assistant again: a team Xcode doesn't list can still be chosen here.
                if setup.signedIn {
                    DisclosureGroup("Use a team that isn't listed") { TeamIDEntry(setup: setup) }
                        .frame(maxWidth: 480, alignment: .leading)
                }
            } else {
                if setup.needsTeamID {
                    TeamIDEntry(setup: setup)
                } else {
                    Text("In Xcode, choose Xcode > Settings > Apple Accounts, click Sign In…, and sign in.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                OpenXcodeButton(xcode: setup.xcode)
            }
        case .device:
            if !setup.devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(setup.devices) { d in DeviceLine(info: d) }
                }
            }
            PairingHelp()
            // What an iPhone needs that nothing on the Mac can check: iOS gives an app no pointer without
            // AssistiveTouch, and the game shows no on-screen keyboard.
            if setup.devices.contains(where: { $0.device.kind == .iPhone && $0.supported }) {
                HStack(spacing: 4) {
                    Text("iPhone: turn on AssistiveTouch to use a mouse (Settings > Accessibility > Touch), and use a hardware keyboard to type.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("More…", destination: Self.iPhoneMouseHelp)
                }
                .font(.caption)
            }
            if !setup.status(step).isOK { OpenXcodeButton(xcode: setup.xcode) }
        case .helper:
            Link("LocalDevVPN on the App Store", destination: Device.localDevVPNStore)
        case .games:
            GamesChooser(setup: setup)
        case .install:
            HStack {
                Button("Choose Folder…") { chooseInstall() }
                if Flavor.installRoot != Flavor.defaultInstallRoot {
                    Button("Use \(Flavor.defaultInstallRoot.path)") {
                        Onboarding.setInstall(nil)
                        setup.pipeline.installChanged()
                        Task { await setup.check(.install) }
                    }
                }
            }
            if !Flavor.installed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Flavor.allCases) { f in
                        let installed = Flavor.installed.contains(f)
                        Label(installed ? f.name : "\(f.name): not installed", systemImage: installed ? "checkmark" : "minus")
                            .foregroundStyle(installed ? .primary : .secondary)
                    }
                }
            }
        case .firstInstall:
            InstallList(setup: setup)
        case .updates:
            UpdatesChooser(setup: setup)
        }
    }

    private func chooseInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Flavor.installRoot.deletingLastPathComponent()
        panel.message = "Choose the World of Warcraft folder Battle.net installed into."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { _ = setup.pickInstall(url) }
    }
}

/// The step's outcome: a green line, or what's wrong and how to fix it.
private struct StatusBox: View {
    let status: Onboarding.Status

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .ok(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .problem(let title, let fix):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold)
                    Text(fix).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A Terminal command to copy.
private struct CommandBox: View {
    let command: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            .padding(8)
            .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The account step's Team ID: when Xcode is signed in but lists no team (Onboarding.needsTeamID), or for
/// a team it doesn't list. Checked with a real stub build before it's used.
private struct TeamIDEntry: View {
    let setup: Onboarding
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Team ID", text: $draft, prompt: Text("A1B2C3D4E5"))
                    .frame(maxWidth: 160)
                    .disabled(setup.verifyingTeam)
                    .onSubmit(use)
                Button("Use This Team", action: use)
                    .disabled(setup.verifyingTeam || !Signing.isValidTeamID(cleaned))
                if setup.verifyingTeam {
                    ProgressView().controlSize(.small)
                    Text("Checking with Xcode…").foregroundStyle(.secondary)
                }
            }
            Link("Find your Team ID (Membership details)", destination: Signing.membershipURL)
            Text("A free Personal Team's ID isn't shown there. It's in the Team menu once Xcode lists your teams; if it isn't, open any project in Xcode and choose the team in Signing & Capabilities > Team.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = setup.teamIDError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cleaned: String { draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    private func use() {
        guard Signing.isValidTeamID(cleaned) else { return }
        Task { await setup.useTeamID(cleaned) }
    }
}

private struct OpenXcodeButton: View {
    let xcode: URL?

    var body: some View {
        let app = xcode ?? URL(fileURLWithPath: "/Applications/Xcode.app")
        if FileManager.default.fileExists(atPath: app.path) {
            Button("Open Xcode") { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
        }
    }
}

private struct DeviceLine: View {
    let info: Onboarding.DeviceInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: info.device.symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.device.name)
                Group {
                    if !info.supported {
                        Text(info.device.kind == .iPhone ? "Not supported: Slashplayed needs an iPhone 15 Pro or later."
                             : "Not supported: Slashplayed needs an iPad with an M2 chip or later.").foregroundStyle(.orange)
                    } else if info.developerMode == false {
                        Text("Developer Mode is off: Settings > Privacy & Security > Developer Mode.").foregroundStyle(.orange)
                    } else {
                        Text(info.reachable ? "Paired and connected" : info.device.kind == .headset
                             ? "Paired (asleep or away now; that's fine until you play)"
                             : "Paired (not connected now; plug it in with USB when you play)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }
}

/// How to pair each kind of device: on the device step whatever is paired already, so a second device
/// can be added after the first (the rc6 run lost the headset's steps once an iPad paired).
private struct PairingHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPad or iPhone: connect it with USB and unlock it. Click Allow when this Mac asks to let the accessory connect, then tap Trust on the device.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Vision Pro: on the headset, open Settings > General > Remote Devices. Then in Xcode, choose Xcode > Open Developer Tool > Device Hub, select the headset, and pair it.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The install step: each usable device, what it holds (SetupStatus.installState), and its Install or Update button;
/// while one runs, what the pipeline is doing (its current step), and what failed.
private struct InstallList: View {
    let setup: Onboarding

    var body: some View {
        let pipeline = setup.pipeline
        VStack(alignment: .leading, spacing: 10) {
            ForEach(setup.usable) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.device.symbol).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.device.name)
                        Text(state(d)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if setup.installing == d.id {
                        ProgressView().controlSize(.small)
                    } else if setup.installed[d.id] == .upToDate {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(button(d)) { setup.install(on: d.device) }
                            .disabled(pipeline.isBusy || setup.installed[d.id] == nil)
                    }
                }
            }
            PipelineProgress(pipeline: pipeline, active: setup.installing != nil)
        }
    }

    private func state(_ d: Onboarding.DeviceInfo) -> String {
        if setup.installing == d.id { return "Installing…" }
        guard let need = setup.installed[d.id] else { return "Checking…" }
        return SetupStatus.installState(need, wake: wake(d)).text
    }

    private func button(_ d: Onboarding.DeviceInfo) -> String {
        setup.installed[d.id].flatMap { SetupStatus.installState($0, wake: nil).button } ?? "Install"
    }

    /// What an unreachable device needs before Install can reach it.
    private func wake(_ d: Onboarding.DeviceInfo) -> String? {
        d.reachable ? nil : d.device.kind == .headset ? "Put on the headset first." : "Connect it with USB first."
    }
}

/// What the pipeline is doing for an install or an identity push started from setup, or what stopped it.
private struct PipelineProgress: View {
    let pipeline: Pipeline
    let active: Bool

    var body: some View {
        if let step = pipeline.current, active || step.state == .failed {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if step.state == .failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if step.state == .waitingOnUser {
                        Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange)
                    }
                    Text(step.title).fontWeight(.semibold)
                    Spacer()
                    if pipeline.isBusy { Button("Cancel") { pipeline.cancel() } }
                }
                if let detail = step.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let progress = step.progress { ProgressView(value: progress) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The last step: the Slashplayed certificate a paid team needs first, then each device's Update Games
/// on This Device, sent to it at once (Onboarding.setUpdatesGames).
private struct UpdatesChooser: View {
    let setup: Onboarding
    /// The form's content height, as its scroll view measures it: the form is as tall as what it holds,
    /// so only the step page scrolls (a guessed fixed height made the form scroll inside it once the
    /// certificate section outgrew the guess: rc19's E.2). nil until the first measure.
    @State private var formHeight: CGFloat?

    var body: some View {
        let pipeline = setup.pipeline
        if let source = DeviceIdentity.source {
            let ready = source == .a || { if case .ready = pipeline.certificate { true } else { false } }()
            VStack(alignment: .leading, spacing: 10) {
                if !ready {
                    Text("First, make the Slashplayed certificate: a paid team's devices sign updates with a certificate of their own.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One grouped form, so the switches line up as they do in Settings. Its height is its
                // content's, so it has nothing to scroll, and with no bounce it hands the wheel to the step
                // page around it, the one scroller (.scrollDisabled kept the wheel and scrolled nothing).
                let _ = pipeline.gamesRevision
                Form {
                    if source == .b { CertificateSection(pipeline: pipeline) }
                    Section("Update games on") {
                        ForEach(setup.usable) { d in
                            Toggle(d.device.name, isOn: Binding(
                                get: { d.device.updatesGames },
                                set: { on in
                                    if !on || UpdateGamesConsent.confirm(d.device, source: source) { setup.setUpdatesGames(on, for: d.device) }
                                }))
                                .toggleStyle(.switch)
                                .disabled(pipeline.isBusy || (!ready && !d.device.updatesGames))
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom
                } action: { _, height in
                    if height > 0 { formHeight = height.rounded(.up) }
                }
                // Before the first measure, a rough height; it settles to the content's on the next layout.
                .frame(height: formHeight ?? CGFloat(source == .a ? 70 : ready ? 200 : 280) + CGFloat(setup.usable.count) * 46)
                .padding(.horizontal, -20)
                PipelineProgress(pipeline: pipeline, active: setup.installing != nil)
            }
        } else {
            Text("Choose a team on the Apple Account step first.").foregroundStyle(.secondary)
        }
    }
}

/// The games step: each usable device's games, every game whether or not it's installed here, what a
/// copy from this Mac would take for a device that copies, and what to watch for.
private struct GamesChooser: View {
    let setup: Onboarding

    var body: some View {
        // No scroll view of its own: the step page scrolls.
        VStack(alignment: .leading, spacing: 14) {
            ForEach(setup.usable) { d in
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.device.name).fontWeight(.semibold)
                    // Sizes only where they mean something: what Play copies to a device that copies.
                    let copies = d.device.copiesGameFiles && !Flavor.installed.isEmpty
                    ForEach(Flavor.allCases) { f in
                        Toggle(isOn: Binding(get: { setup.games(d).contains(f) },
                                             set: { setup.setGame(f, on: $0, for: d.device) })) {
                            Text(f.name) + Text(!copies ? "" : !Flavor.installed.contains(f) ? "  streamed"
                                                : setup.size([f]).map { "  \(Onboarding.bytes($0))" } ?? "  …")
                                .foregroundStyle(.secondary)
                        }
                        .disabled(setup.games(d) == [f])
                    }
                    Text(summary(d, copies: copies))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(setup.warnings(for: d), id: \.self) { w in
                        Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where a device's game data comes from, and its free space once known.
    private func summary(_ d: Onboarding.DeviceInfo, copies: Bool) -> String {
        let chosen = setup.games(d).filter(Flavor.installed.contains)
        let source = !copies ? "Fetched from Blizzard on the \(d.device.noun) as you play"
            : chosen.isEmpty ? "None of these is installed on this Mac, so they're fetched from Blizzard on the \(d.device.noun)"
            : "Copied from this Mac: " + (setup.size(chosen).map(Onboarding.bytes) ?? "working it out…")
        return source + (setup.freeSpace[d.id].map { " · \($0.text) on the \(d.device.noun)" } ?? "")
    }
}

/// Ready: Slashplayed is on a device (the install step), so it's played from there; the Mac's Play is for
/// what the device can't do alone.
private struct ReadyPage: View {
    let setup: Onboarding

    var body: some View {
        let kinds = Set(setup.usable.map(\.device.kind))
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready").font(.title2.weight(.semibold))
            Text("Open Slashplayed on your device to play.").font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: 8) {
                if setup.teamIsFree {
                    Text("• The first time, the device says “Untrusted Developer”: open Settings > General > VPN & Device Management there, tap your Apple Account, and tap Trust.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kinds.contains(.headset) {
                    Text("• Vision Pro, the first time: Slashplayed shows a code. Open Settings > General > Remote Devices on the headset and type it into Slashplayed. Leave the other entries there alone: one is this Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("• Sign in to Battle.net there. Slashplayed keeps the sign-in in the device's keychain.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("• Turn on LocalDevVPN when Slashplayed asks. It opens it for you.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("• A game's first start takes a few minutes while it fetches its data.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Press Play on this Mac after a patch, to add games, or to set up another device\(setup.teamIsFree ? ", and every 7 days on a free team" : ""). Settings (⌘,) has the team and the games; Help > Setup Assistant runs these checks again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
