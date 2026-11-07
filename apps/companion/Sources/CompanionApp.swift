import AppKit
import SwiftUI

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let pipeline = Pipeline.shared
    /// Created at launch, so Sparkle's scheduled checks start with the app.
    private let updater = Updater.shared
    @State private var onboarding = Onboarding(pipeline: Pipeline.shared)
    @AppStorage(Onboarding.doneKey) private var onboarded = false
    /// Help > Setup Assistant, for this session only: quitting during it doesn't bring it back at the next
    /// launch, on a step whose check already passed (the rc6 run). `onboarded` is the first run's alone.
    /// -setup-step <n> (Onboarding.begin) opens it too.
    @State private var rerunningSetup = CommandLine.arguments.contains("-setup-step")

    var body: some Scene {
        Window("Slashplayed Companion", id: "main") {
            // Onboarding until the user gets through it once; Help > Setup Assistant brings it back.
            if onboarded && !rerunningSetup {
                ContentView(pipeline: pipeline)
            } else {
                OnboardingView(setup: onboarding) {
                    onboarded = true
                    rerunningSetup = false
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Slashplayed Companion") { About.show() }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .help) {
                Button("Setup Assistant…") { rerunningSetup = true }
                    .disabled(pipeline.isBusy || !onboarded || rerunningSetup)
                Button("Export Diagnostics…") { pipeline.exportDiagnostics() }
                    .disabled(pipeline.isBusy)
                Divider()
                Link("Slashplayed Website", destination: About.website)
                Link("Slashplayed on GitHub", destination: About.github)
                // The template chooser, not one form: bug report, new game patch, feature request.
                Link("Report an Issue…", destination: About.reportIssue)
                Button("Acknowledgements") { About.open(About.acknowledgements) }
            }
            CommandGroup(after: .newItem) {
                // Needs a game install here to copy from (Settings > Game Install).
                Button("Copy Game Files") { pipeline.copyGameFiles() }
                    .keyboardShortcut("u")
                    .disabled(pipeline.isBusy || Flavor.installed.isEmpty)
                Button("Update Client") { pipeline.updateClient() }
                    .keyboardShortcut("b")
                    .disabled(pipeline.isBusy)
                Button("Pull Device Logs") { pipeline.pullDeviceLogs() }
                    .disabled(pipeline.isBusy)
                // A new pairing for the app's JIT helper, when the device stopped accepting the old one.
                Button("Pair Again") { pipeline.pairDevice() }
                    .disabled(pipeline.isBusy)
                Divider()
                // Which device Play, Copy Game Files and Update Client work on, from the next one.
                Picker("Device", selection: Bindable(pipeline).devicePin) {
                    DeviceChoices(pipeline: pipeline)
                }
                DeviceChoices.Reasons(pipeline: pipeline)
                // Which games each device holds, whether it copies them, and whether it updates them itself:
                // Settings' Games pane, where ticking several stays open. A submenu here closed after every
                // tick (the rc9 run).
                GamesMenuItem()
            }
        }
        // The team (which signs the device app and names it), bundle ID prefix, device, games, copying,
        // updating on the device, game install, and update checks. The render scale is the device's
        // (its start screen's Settings), so it applies to a launch from the home screen too.
        Settings {
            SettingsView(pipeline: pipeline)
        }
        .windowResizability(.contentSize)
    }
}

/// File > Games…: Settings, open at its Games pane.
private struct GamesMenuItem: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsPane.key) private var pane = SettingsPane.signing

    var body: some View {
        Button("Games…") {
            pane = .games
            openSettings()
        }
    }
}

/// The About panel and the Help menu's links. The standard panel shows the icon, name, version (build)
/// and NSHumanReadableCopyright from Info.plist; the credits add the disclaimer and the links.
/// Acknowledgements is the bundled folder of third-party licenses (Sparkle, idevice and its Rust crates,
/// and the device app's; bundle-resources.sh), opened in Finder.
enum About {
    static let website = URL(string: "https://slashplayed.strawdynamics.com")!
    static let github = URL(string: "https://github.com/paulstraw/slashplayed")!
    static let reportIssue = URL(string: "https://github.com/paulstraw/slashplayed/issues/new/choose")!
    static var acknowledgements: URL { Bundle.main.resourceURL!.appending(path: "Acknowledgements", directoryHint: .isDirectory) }
    /// The one way the panel's links and the Help menu's Acknowledgements open (AboutLinks says why).
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    /// The panel's text view holds its delegate weakly.
    @MainActor private static let links = AboutLinks(open: About.open)
    private static let blurb = "Runs the Mac World of Warcraft clients on iPad, iPhone, and Apple Vision Pro.\n"

    @MainActor static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]
        let credits = NSMutableAttributedString(
            string: blurb
                + "Unofficial. Not affiliated with Blizzard Entertainment.\n\n", attributes: plain)
        for (i, (title, url)) in [("Website", website), ("GitHub", github), ("Report an Issue", reportIssue),
                                  ("Acknowledgements", acknowledgements)].enumerated() {
            if i > 0 { credits.append(NSAttributedString(string: " · ", attributes: plain)) }
            credits.append(NSAttributedString(string: title, attributes: [.font: small, .link: url, .paragraphStyle: center]))
        }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        // The panel is built by now; its credits view is the one showing the blurb.
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            for text in AboutLinks.textViews(in: content, showing: blurb.trimmingCharacters(in: .newlines)) { text.delegate = links }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // -play: Play the game the menu by Play picks (signed in on the device, no Battle.net). With
        // -skip-intro, without the intro movie or Retail's Screen Narrator question (ClientLauncher.env).
        if CommandLine.arguments.contains("-play") { Pipeline.shared.play() }
        // -sync: copy game files at startup (for testing without a Battle.net login).
        if CommandLine.arguments.contains("-sync") { Pipeline.shared.copyGameFiles() }
        // -update: copy each game's newer client, and rebuild and install the app if it needs it.
        if CommandLine.arguments.contains("-update") { Pipeline.shared.updateClient() }
        // -pair: Pair Again (the iPad's or iPhone's RemotePairing record made over USB and sent; the headset's cleared).
        if CommandLine.arguments.contains("-pair") { Pipeline.shared.pairDevice() }
        // -push-identity: send the device its signing identity (or ask it to forget it), as Play would.
        if CommandLine.arguments.contains("-push-identity") { Pipeline.shared.pushIdentity() }
        // -certificate-request: make the Slashplayed certificate's key and request (a paid team's, B).
        if CommandLine.arguments.contains("-certificate-request") { try? Pipeline.shared.makeCertificateRequest() }
        // -pull-logs: fetch the device's logs into ~/Library/Logs/Slashplayed/triage/.
        if CommandLine.arguments.contains("-pull-logs") { Pipeline.shared.pullDeviceLogs() }
        // -export-diagnostics: write the diagnostics zip into ~/Library/Logs/Slashplayed/diagnostics/.
        if CommandLine.arguments.contains("-export-diagnostics") { Pipeline.shared.exportDiagnostics() }
        // -check-for-updates: what the menu item does (Sparkle shows the result).
        if CommandLine.arguments.contains("-check-for-updates") { Updater.shared.checkForUpdates() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    let pipeline: Pipeline
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                // The device is named beside it (DevicePicker).
                Text(pipeline.flavor.map { "Playing \($0.name)" } ?? "World of Warcraft")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                DevicePicker(pipeline: pipeline)
            }
            // By the device's status, whenever a copy would be held back, not only during one (the rc9 run).
            // Left-aligned with the window's content: under the device menu, right-aligned, it read as the
            // menu's caption (the rc10 run).
            if pipeline.slowCable {
                Label(USBLink.slowCableLine, systemImage: "cable.connector")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The \(pipeline.device.noun) is connected at USB 2 speed (480 Mbit/s), and the cable in its box is USB 2. If this cable is USB 3, try another port: some Macs have a USB 2 port.")
            }
            Headline(step: pipeline.current, busy: pipeline.isBusy, noun: pipeline.device.noun,
                     appMissing: pipeline.deviceAppMissing)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pipeline.steps) { StepRow(step: $0) }
            }
            if showLog { LogView(lines: pipeline.log) }
            HStack {
                Toggle("Log", isOn: $showLog).toggleStyle(.button)
                Spacer()
                if pipeline.isRunning {
                    Button("Stop Client", role: .destructive) { pipeline.cancel() }
                    // Another game (or the same one again): Play stops this one first (Pipeline.afterStopping).
                    PlayMenu(pipeline: pipeline)
                    Button("Play") { pipeline.play() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(pipeline.playGame == nil)
                        .help("Stop the client running on the \(pipeline.device.noun) and start \(pipeline.playGame?.name ?? "the game")")
                } else if pipeline.isBusy {
                    Button("Cancel") { pipeline.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    if let issue = pipeline.unsupportedIssue {
                        Link("Report It…", destination: issue)
                            .help("Open the “New game patch broke it” issue form on GitHub, filled in with this game version and the missing imports")
                    }
                    // A saved zip gets its own row below: beside Play and the game menu, it didn't fit.
                    if pipeline.diagnosticsZip == nil, pipeline.current?.state == .failed {
                        Button("Export Diagnostics…") { pipeline.exportDiagnostics() }
                            .help("Zip the logs from this Mac and the \(pipeline.device.noun), for a bug report")
                    }
                    if let logs = pipeline.pulledLogs {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logs]) }
                            .help("The logs pulled from the \(pipeline.device.noun), and summary.txt")
                    }
                    if pipeline.canRetryLaunch {
                        Button("Retry Launch") { pipeline.retryLaunch() }
                            .help("Start the client again, with what's already on the \(pipeline.device.noun)")
                    }
                    PlayMenu(pipeline: pipeline)
                    Button("Play") { pipeline.play() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(pipeline.playGame == nil)
                }
            }
            if pipeline.isExporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(pipeline.exportStatus ?? "Exporting diagnostics…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                if let note = pipeline.diagnosticsNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let zip = pipeline.diagnosticsZip {
                    HStack {
                        Text("Diagnostics saved, with login values, device IDs, and personal details blanked out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Show Diagnostics") { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
                            .controlSize(.small)
                            .fixedSize()
                            .help("The zip to attach to a bug report")
                    }
                }
            }
            if let expires = pipeline.profileExpires, expires.timeIntervalSinceNow <= Signing.renewWithin {
                ProfileWarning(expires: expires, noun: pipeline.device.noun, busy: pipeline.isBusy) { pipeline.updateClient() }
            }
            Divider()
            GamesFooter(pipeline: pipeline)
        }
        .padding(20)
        .frame(width: 480)
        // Its ideal height, so the window (sized to the content) grows with a long detail.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu by Play: which of the device's games Play starts (any of them, installed on this Mac or not),
/// and Play with My Mac's Battle.net, which signs in with the Mac's Battle.net instead of the device's own
/// sign-in. That one needs Battle.net to launch the game here, so it's offered only when one of the
/// device's games is installed on this Mac.
struct PlayMenu: View {
    let pipeline: Pipeline

    var body: some View {
        Menu(pipeline.playGame?.name ?? "No Game") {
            Picker("Game", selection: Binding(get: { pipeline.playGame }, set: { $0.map(pipeline.setPlayGame) })) {
                // pipeline.games, not Device.flavors: SwiftUI doesn't watch UserDefaults.
                ForEach(pipeline.games) { Text($0.name).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if pipeline.games.contains(where: Flavor.installed.contains) {
                Divider()
                Button("Play with My Mac's Battle.net") { pipeline.playWithBattleNet() }
                    .help("Press Play in Battle.net next: Slashplayed moves its launch credentials to the \(pipeline.device.noun), for when the \(pipeline.device.noun)'s own sign-in doesn't work")
            }
        }
        .controlSize(.large)
        .fixedSize()
        .help("The game Play starts on the \(pipeline.device.noun)")
    }
}

/// The device app's profile runs out soon (or has): a free team's lasts 7 days, and the device won't open
/// the app after that until it's signed again. Play renews it too (ClientBuild.isComplete); this says so
/// before a session is due, and offers the rebuild on its own.
struct ProfileWarning: View {
    let expires: Date
    let noun: String
    let busy: Bool
    let rebuild: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            Text(expires < Date()
                 ? "The app's profile on the \(noun) ran out \(expires.formatted(.relative(presentation: .named))). The \(noun) won't open Slashplayed until it's rebuilt."
                 : "The app's profile on the \(noun) runs out \(expires.formatted(.relative(presentation: .named))) (a free team's lasts 7 days). Rebuild now, or press Play, which renews it.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Rebuild Now", action: rebuild)
                .disabled(busy)
                .help("Sign the app again with a fresh profile and install it on the \(noun)")
        }
        .font(.caption)
    }
}

/// The device's games and the space they need: Settings > Games.
struct GamesFooter: View {
    let pipeline: Pipeline

    var body: some View {
        let device = pipeline.device
        // Copying needs a game install here (Pipeline.play); without one, every game streams.
        let copying = pipeline.copiesGameFiles && !Flavor.installed.isEmpty
        let missing = copying ? pipeline.games.filter { !Flavor.installed.contains($0) } : []
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(pipeline.games.map(\.name).joined(separator: " + ") + ": " +
                     (!copying ? "streamed from Blizzard on the \(device.noun)"
                        : pipeline.gamesSize.map(bytes) ?? "working out the size…"))
                    .help(copying ? "Copied from this Mac (Settings > Games)"
                          : "The game fetches its data itself as it plays; Settings > Games can copy it from this Mac instead")
                Spacer()
                if let free = pipeline.freeSpace {
                    Text("\(free.text) on the \(device.noun)")
                        .help(free.atLeast ? "Settings on the \(device.noun) shows more: space it can clear. Slashplayed's first start there tells the Mac how much."
                              : "As the \(device.noun)'s Settings counts it: now, for an iPad or iPhone the Mac can reach; else when Slashplayed last started")
                }
            }
            // Games the device updated itself past Blizzard's build as this Mac last asked (Pipeline.checkDeviceUpdates).
            ForEach(pipeline.updatedOnDevice.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { flavor, version in
                Text("\(flavor.name) \(version), updated on the \(device.noun)")
                    .help("The \(device.noun) updated itself to this version. Play keeps it there until this Mac has a newer one.")
            }
            // Nothing sets it since the device needs no signing identity; it goes with the rest of it.
            if let notice = pipeline.identityNotice {
                Text(notice)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pipeline.pendingFree > 0 {
                Text("\(bytes(pipeline.pendingFree)) is freed when the client next starts.")
            }
            if !missing.isEmpty {
                let names = missing.map(\.name).joined(separator: " and ")
                Text("\(names) isn't on this Mac, so it streams on the \(device.noun) instead of being copied.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// The current step, big: what's happening or what the user has to do.
struct Headline: View {
    let step: Pipeline.Step?
    let busy: Bool
    /// The device's ("headset", "iPad"), for the idle text.
    let noun: String
    /// Slashplayed isn't on the device (Pipeline.deviceAppMissing): the idle text says to press Play.
    var appMissing = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch step?.state {
                case .active?: ProgressView().controlSize(.regular)
                case .waitingOnUser?: Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange)
                case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .done?: Image(systemName: busy ? "checkmark.circle.fill" : "gamecontroller.fill").foregroundStyle(.green)
                default: Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 30))
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(step?.title ?? SetupStatus.idleHeading(noun: noun, appMissing: appMissing).title)
                    .font(.title2.weight(.semibold))
                Text(step?.detail ?? (step == nil ? SetupStatus.idleHeading(noun: noun, appMissing: appMissing).detail : ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let progress = step?.progress {
                    ProgressView(value: progress).padding(.top, 4)
                }
            }
        }
        .frame(minHeight: 64, alignment: .top)
    }
}

struct StepRow: View {
    let step: Pipeline.Step

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            Text(step.title)
                .foregroundStyle(step.state == .pending ? .secondary : .primary)
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active: ProgressView().controlSize(.mini)
        case .waitingOnUser: Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// The device the window works on, and whether it's reachable; a menu to pick another (as File > Device
/// and Settings > Games' Play on do), so a second device is found from the window (the rc6 run). Just the
/// badge while an action runs (the device is picked when one starts) or with one device paired.
struct DevicePicker: View {
    let pipeline: Pipeline

    var body: some View {
        let device = pipeline.device, available = pipeline.deviceAvailable
        let unsupported = pipeline.unsupportedReason(device)
        HStack(spacing: 5) {
            // Beside the menu, not in its label: a menu's label shows only its text and images.
            Circle().fill(unsupported != nil ? .red : available == true ? .green : available == false ? .orange : .gray)
                .frame(width: 8, height: 8)
            // Connected or not, a device that can't run the client says so first: Play stops on it at once.
            let status = unsupported != nil ? "\(device.name) not supported"
                : available == true ? "\(device.name) connected"
                : available == false ? (device.kind == .headset ? "Headset asleep or away" : "\(device.noun) not connected")
                : "Checking \(device.noun)…"
            if pipeline.devices.count < 2 || pipeline.isBusy {
                Text(status)
                    .foregroundStyle(.secondary)
                    .help(unsupported ?? "")
            } else {
                Menu(status) {
                    Picker("Device", selection: Bindable(pipeline).devicePin) {
                        DeviceChoices(pipeline: pipeline)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    DeviceChoices.Reasons(pipeline: pipeline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // It's the window's first control, so it took the focus ring at every launch.
                .focusable(false)
                .help("The device Play works on. Automatic picks whichever is reachable, the last one used if several are.")
            }
        }
        .font(.callout)
    }
}

/// What the device menus (File > Device, the window's, Settings' Play on) offer: Automatic and every paired
/// device. One whose model can't run the client (Pipeline.unsupportedReason) is listed, so it isn't taken
/// for unpaired, but can't be picked.
struct DeviceChoices: View {
    let pipeline: Pipeline

    var body: some View {
        Text("Automatic").tag("")
        ForEach(pipeline.devices) { device in
            let unsupported = pipeline.unsupportedReason(device) != nil
            Text(unsupported ? "\(device.name) (not supported)" : device.name)
                .tag(device.udid)
                .disabled(unsupported)
        }
    }

    /// Why: onboarding's wording, once for each kind of device listed that can't (a menu item has no
    /// subtitle, so it's a disabled line under the choices).
    static func reasons(_ pipeline: Pipeline) -> [String] {
        var seen: [String] = []
        for reason in pipeline.devices.compactMap(pipeline.unsupportedReason) where !seen.contains(reason) { seen.append(reason) }
        return seen
    }

    /// Those reasons, as menu lines after a divider; nothing when every device can run the client.
    struct Reasons: View {
        let pipeline: Pipeline

        var body: some View {
            let reasons = DeviceChoices.reasons(pipeline)
            if !reasons.isEmpty {
                Divider()
                ForEach(reasons, id: \.self) { Text($0) }
            }
        }
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(6)
            }
            .frame(height: 200)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}
