// The app's Settings: a sheet with Done over the start screen (spstart.m opens it from its gear), stock dark
// inset-grouped, in SwiftUI. The launcher has no SwiftUI App: UIKit runs as a coroutine the launcher pumps
// by hand (spuikit.m), so the sheet is a UIHostingController the start screen presents, behind a C entry
// point (sp_settings_sheet, spswift.h). Its logic stays in Objective-C, called through spswift.h: the
// sign-in's keychain (splogin.m), the signing identity (spsign.m), and each game's build and reset
// (launcher.m). The sheet reads them again after every change (`Settings.reload`): no state of its own but
// whether the email shows and where it's navigated to.
//
// Battle.net: whether a sign-in is saved, Show Email, Forget My Sign-In, or Sign In…. The email is the one
// value shown, only on a tap (no Face ID, Optic ID, or passcode: it's the person's own device), and only
// until the app goes to the background, the sheet closes, or a game starts (sp_settings_hide_email). Game
// Updates: the signing identity's state (dates only) and Forget Signing Identity. Both forgets act at the
// tap, after an alert whose default is Cancel. Display: the backing scale (sp_scale). Then a section per game
// (the start screen's, in its order): the build it starts with (shipped with the app, or updated on this
// device), Open in Files, and Reset Game Settings (after its alert). About: the app's version and
// Acknowledgements, the licenses of what the app ships.
import SwiftUI
import UIKit

private func say(_ s: String) { sp_launch_say("start: " + s) }

// Display > Scale's key, read by the AppKit shim (spwindow.m's sp_scale_now, which has the same literal).
private let scaleKey = "sp_scale"

// 0 (Automatic: removes the key), 1, or 2. It applies from the next game started, from here or the home
// screen: the shim reads it after $SP_SCALE (run.sh's dev override), and through it the launcher's 50%
// render-scale seed on an iPhone.
private func setScale(_ scale: Int) {
    if scale == 1 || scale == 2 { UserDefaults.standard.set(scale, forKey: scaleKey) }
    else { UserDefaults.standard.removeObject(forKey: scaleKey) }
    say("display scale: " + (scale == 1 || scale == 2 ? "\(scale)x" : "Automatic"))
}

// Touch > Click With's key, read by the AppKit shim (spevent.m's sp_chord_resolve, which has the same
// literal): whether a two- or three-finger press clicks where the rightmost finger is, not the leftmost.
private let chordRightFingerKey = "sp_chord_right_finger"

private func setChordRightFinger(_ right: Bool) {
    if right { UserDefaults.standard.set(true, forKey: chordRightFingerKey) }
    else { UserDefaults.standard.removeObject(forKey: chordRightFingerKey) }
    say("touch: click with " + (right ? "right" : "left") + " finger")
}

// "Mar 14, 2027", in the person's locale.
private func mediumDate(_ date: Date?) -> String {
    guard let date else { return "Unknown" }
    return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
}

// The license files in the app's licenses/ (apps/client/build.sh, the companion's ClientAssembly), by name,
// in this order; one this doesn't know comes last, under its file name.
struct License: Hashable {
    let path: String, name: String
    static func all() -> [License] {
        let dir = (Bundle.main.bundlePath as NSString).appendingPathComponent("licenses")
        let known = [("zsign.txt", "zsign"), ("openssl.txt", "OpenSSL"), ("idevice.txt", "idevice"),
                     ("rust-std.html", "Rust Standard Library"), ("goodmountain.txt", "Goodmountain")]
        var files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        var list: [License] = []
        for (file, name) in known where files.contains(file) {
            list.append(License(path: (dir as NSString).appendingPathComponent(file), name: name))
            files.removeAll { $0 == file }
        }
        list += files.map { License(path: (dir as NSString).appendingPathComponent($0), name: ($0 as NSString).deletingPathExtension) }
        return list
    }
}

// What the sheet's pages are: the list of licenses, or one license's text.
enum Page: Hashable { case acknowledgements, license(License) }

// The confirmations, each with Cancel as its default.
enum Confirmation: Identifiable {
    case forgetSignIn, forgetIdentity, reset(String)
    var id: String {
        switch self {
        case .forgetSignIn: "forget-signin"
        case .forgetIdentity: "forget-identity"
        case .reset(let flavor): "reset-" + flavor
        }
    }
}

// What's true now, read once per reload (the build reads files, and SwiftUI may ask for the body often).
struct Snapshot {
    // `installed`: it has an image to start (sp_game_has_image); `shipped`: the app has one (an app built
    // without images has none, and the device installs each game itself).
    struct Game { let flavor: String, name: String, version: String?, updated: Bool, installed: Bool, shipped: Bool }
    var saved = false
    var identity: SPIdentityReading?
    var scale = 0
    var chordRightFinger = false
    var games: [Game] = []
    var version = "Unknown"
}

final class Settings: ObservableObject {
    let flavors: [String]
    @Published var now = Snapshot()
    @Published var email: String?  // while shown; nil hides it
    @Published var path: [Page] = []
    @Published var confirmation: Confirmation?
    weak var host: UIViewController?
    var scrollTo: ((String) -> Void)?  // set by the list once it's up
    var drill: String?

    // The sheet that's up, for sp_settings_hide_email.
    static weak var shown: Settings?

    init(flavors: [String], drill: String?) {
        self.flavors = flavors
        self.drill = drill
        reload()
        // The email hides when the app leaves the foreground (the app switcher's snapshot included).
        for name in [UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(hideEmail), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func reload() {
        var s = Snapshot()
        s.saved = sp_login_saved()
        if !s.saved { email = nil }
        s.identity = sp_identity_reading()
        let scale = UserDefaults.standard.integer(forKey: scaleKey)
        s.scale = scale == 1 || scale == 2 ? scale : 0
        s.chordRightFinger = UserDefaults.standard.bool(forKey: chordRightFingerKey)
        s.games = flavors.map { flavor in
            var updated: ObjCBool = false
            let version = sp_game_build(flavor, &updated)?["Version"]
            let shipped = FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "wow-" + flavor).path)
            return .init(flavor: flavor, name: sp_flavor_name(flavor), version: version, updated: updated.boolValue,
                         installed: sp_game_has_image(flavor), shipped: shipped)
        }
        s.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        now = s
    }

    // ---- the actions

    // Read here, at the tap, and kept only while it shows. Never logged.
    func showEmail() { email = sp_login_email() }

    @objc func hideEmail() { if email != nil { email = nil } }

    func close() { host?.presentingViewController?.dismiss(animated: true) }

    func signIn() {
        host?.present(sp_login_screen { [weak self] _ in self?.reload() }, animated: true)
    }

    func confirm(_ c: Confirmation) {
        switch c {
        case .forgetSignIn:
            _ = sp_login_forget()
            email = nil
        case .forgetIdentity:
            say(sp_identity_forget())
        case .reset(let flavor):
            say(sp_game_reset(flavor))
        }
        reload()
    }

    // The game's folder, Documents/_<flavor>_/, in the Files app (Info.plist's LSSupportsOpeningDocumentsInPlace
    // shows Documents/ there): its shareddocuments:// URL is the folder's path. Before the game's first start
    // there's no folder yet, so Files opens at the app's Documents/.
    func openInFiles(_ flavor: String) {
        let documents = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        var folder = (documents as NSString).appendingPathComponent("_\(flavor)_")
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &directory) || !directory.boolValue { folder = documents }
        var url = URLComponents()
        url.scheme = "shareddocuments"
        url.path = folder
        guard let target = url.url else { return }
        UIApplication.shared.open(target) { opened in
            say("open in files \(flavor): \((folder as NSString).lastPathComponent) \(opened ? "opened" : "refused")")
        }
    }

    // Pages the drill opens open without animating.
    private func push(_ pages: [Page]) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { path = pages }
    }

    // The drill's states: `settings` (the sheet as it opens), `game-updates`, `display`, `games`, and `about`
    // (scrolled to that section, or the first game's), `sign-in` (Sign In…'s screen), `sign-in-launch`
    // (the sign-in screen as a launch with no saved sign-in shows it, full screen; it saves nothing),
    // `vpn`, `pair`, and `pair-code` (the LocalDevVPN wait's and the pairing screen's, the last asking for the
    // code; they do nothing), `acknowledgements` (its
    // page), `license-<file>` (one license's text, e.g. license-rust-std), and `alert-forget-signin`,
    // `alert-forget-identity`, and `alert-reset` (the confirmations, the last for the first game, shown
    // whatever's saved, so they can be screenshotted without a credential; Cancel is what a drill expects to
    // be tapped, if anything). `reset-<flavor>` is Reset's Reset tapped: it resets that game's settings with
    // no alert, so a test can check what it deletes and the next start's seeding. `scale-<0|1|2>` picks that
    // Display > Scale (0 is Automatic), so a test can set it without taps; it's saved, as a tap's is.
    // `files-<flavor>` is that game's Open in Files tapped. Once, when the sheet has appeared.
    private func presentDrill(_ screen: UIViewController) {
        screen.modalPresentationStyle = .fullScreen
        host?.present(screen, animated: false)
    }

    func runDrill() {
        guard let state = drill else { return }
        drill = nil
        let states: [String: () -> Void] = [
            "settings": {},
            "game-updates": { self.scrollTo?("game-updates") },
            "display": { self.scrollTo?("display") },
            "games": { if let f = self.flavors.first { self.scrollTo?("game-" + f) } },
            "about": { self.scrollTo?("about") },
            "sign-in": { self.signIn() },
            "sign-in-launch": { self.presentDrill(signInScreen(sp_device_noun() as NSString, { _, _ in "A drill: nothing was saved." }, nil)) },
            "vpn": { self.presentDrill(vpnScreen(sp_device_noun() as NSString, {})) },
            "pair": { self.presentDrill(pairScreen({ _ in "A drill: nothing was sent." }, {})) },
            "pair-code": {
                let screen = pairScreen({ _ in "A drill: nothing was sent." }, {})
                screenStatus(screen, "Type the code Remote Devices shows.")
                pairAsk(screen, true)
                self.presentDrill(screen)
            },
            "acknowledgements": { self.push([.acknowledgements]) },
            "alert-forget-signin": { self.confirmation = .forgetSignIn },
            "alert-forget-identity": { self.confirmation = .forgetIdentity },
            "alert-reset": { if let f = self.flavors.first { self.confirmation = .reset(f) } },
        ]
        var open = states[state]
        let suffix = { (prefix: String) -> String? in state.hasPrefix(prefix) ? String(state.dropFirst(prefix.count)) : nil }
        if open == nil, let f = suffix("reset-"), flavors.contains(f) {
            open = { say(sp_game_reset(f)); self.reload(); self.scrollTo?("game-" + f) }
        }
        if open == nil, let f = suffix("files-"), flavors.contains(f) { open = { self.openInFiles(f) } }
        if open == nil, let i = ["scale-0", "scale-1", "scale-2"].firstIndex(of: state) {
            open = { setScale(i); self.reload(); self.scrollTo?("display") }
        }
        if open == nil, let name = suffix("license-") {
            open = {
                if let l = License.all().first(where: { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension == name }) {
                    self.push([.acknowledgements, .license(l)])
                } else {
                    say("drill: no license " + state)
                    self.push([.acknowledgements])
                }
            }
        }
        if let open { open() }
        else { say("drill: no state \(state) (\(states.keys.sorted())); the sheet as it opens") }
    }
}

// ---- the views

private struct DoneButton: ToolbarContent {
    let settings: Settings
    var body: some ToolbarContent {
        // .confirm: the system's Done, a checkmark, as UIKit's UIBarButtonSystemItemDone draws it.
        ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { settings.close() } }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        NavigationStack(path: $settings.path) {
            ScrollViewReader { proxy in
                List {
                    battleNet
                    gameUpdates
                    display
                    #if !os(visionOS)
                    touch
                    #endif
                    ForEach(settings.now.games, id: \.flavor) { game($0) }
                    about
                }
                .listStyle(.insetGrouped)
                .onAppear { settings.scrollTo = { id in proxy.scrollTo(id, anchor: .top) } }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton(settings: settings) }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .acknowledgements: AcknowledgementsView(settings: settings)
                case .license(let l): LicenseView(license: l).navigationTitle(l.name).toolbar { DoneButton(settings: settings) }
                }
            }
        }
        .alert(title, isPresented: Binding(get: { settings.confirmation != nil }, set: { if !$0 { settings.confirmation = nil } }),
               presenting: settings.confirmation) { c in
            // The default (Return, and drawn as the preferred action), as UIKit's preferredAction made it.
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(button(c), role: .destructive) { settings.confirm(c) }
        } message: { c in
            Text(message(c))
        }
    }

    private var title: String {
        switch settings.confirmation {
        case .forgetSignIn: "Forget Your Battle.net Sign-In?"
        case .forgetIdentity: "Forget Signing Identity?"
        case .reset(let flavor): "Reset \(sp_flavor_name(flavor)) Settings?"
        case nil: ""
        }
    }

    private func button(_ c: Confirmation) -> String {
        if case .reset = c { return "Reset" }
        return "Forget"
    }

    private func message(_ c: Confirmation) -> String {
        switch c {
        case .forgetSignIn: "You’re asked to sign in the next time a game starts."
        case .forgetIdentity:
            "Your Mac’s companion turns Update Games on This Device off for this device. Turning it back on there puts the identity back."
        case .reset: "Graphics, sound, and other game settings go back to their defaults. Keybindings, macros, and addon settings are kept."
        }
    }

    @ViewBuilder private var battleNet: some View {
        if !settings.now.saved {
            Section("Battle.net") {
                Text("Not saved: you’re asked when a game starts.")
                Button("Sign In…") { settings.signIn() }
            }
        } else {
            Section {
                Text("A Battle.net sign-in is saved.")
                if let email = settings.email {
                    LabeledContent("Email", value: email)
                    Button("Hide Email") { settings.hideEmail() }
                } else {
                    Button("Show Email") { settings.showEmail() }
                }
                Button("Forget My Sign-In", role: .destructive) { settings.confirmation = .forgetSignIn }
            } header: {
                Text("Battle.net")
            } footer: {
                Text("To switch accounts, forget the saved sign-in, then sign in again.")
            }
        }
    }

    @ViewBuilder private var gameUpdates: some View {
        let r = settings.now.identity
        let state = r?.state ?? .none
        Section {
            switch state {
            case .none, .forgotten:
                LabeledContent("Signing Identity", value: "None").id("game-updates")
            case .present:
                LabeledContent("Signing Identity", value: "Valid until " + mediumDate(r?.notAfter)).id("game-updates")
                LabeledContent("Signs Game Updates", value: r?.listed == true ? "Yes" : "No")
            case .expired:
                LabeledContent("Signing Identity") { Text("Expired " + mediumDate(r?.notAfter)).foregroundStyle(.red) }.id("game-updates")
            case .unreadable:
                LabeledContent("Signing Identity") { Text("Can’t Be Opened").foregroundStyle(.red) }.id("game-updates")
            @unknown default:
                LabeledContent("Signing Identity", value: "Unknown").id("game-updates")
            }
            if state != .none && state != .forgotten {
                Button("Forget Signing Identity", role: .destructive) { settings.confirmation = .forgetIdentity }
            }
        } header: {
            Text("Game Updates")
        } footer: {
            switch state {
            case .none, .forgotten: Text("Turn on Update Games on This Device in the companion on your Mac to put one here.")
            case .present:
                Text(r?.listed == true ? "Games update on this device without your Mac."
                                       : "The app’s profiles don’t list this identity, so it can’t sign game updates.")
            case .unreadable: Text("A signing identity is in the keychain, but it can’t be opened.")
            default: EmptyView()
            }
        }
    }

    private var display: some View {
        Section {
            LabeledContent("Scale") {
                Picker("Scale", selection: Binding(get: { settings.now.scale }, set: { setScale($0); settings.reload() })) {
                    Text("Automatic").tag(0)
                    Text("1x").tag(1)
                    Text("2x").tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .id("display")
        } header: {
            Text("Display")
        } footer: {
            Text("This device only. Automatic is 1x on Vision Pro and iPad, and 2x on iPhone. On an iPhone at 1x, set the game’s render scale to 100% in its graphics settings.")
        }
    }

    #if !os(visionOS)
    // Finger chords (spevent.m): two fingers right-click, three middle-click, at one finger's spot.
    private var touch: some View {
        Section {
            LabeledContent("Click With") {
                Picker("Click With", selection: Binding(get: { settings.now.chordRightFinger },
                                                        set: { setChordRightFinger($0); settings.reload() })) {
                    Text("Left Finger").tag(false)
                    Text("Right Finger").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .id("touch")
        } header: {
            Text("Touch")
        } footer: {
            Text("Press with two fingers together to right-click, or three to middle-click. The click is where the left or right finger is. With Accessibility Zoom on, three-finger presses lag.")
        }
    }
    #endif

    private func game(_ g: Snapshot.Game) -> some View {
        Section(g.name) {
            VStack(alignment: .leading, spacing: 2) {
                if g.installed {
                    Text(g.version.map { "Build " + $0 } ?? "Build Unknown")
                    Text(!g.updated ? "Shipped with the app" : g.shipped ? "Updated on this device" : "Installed on this device")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Not Installed")
                    Text("Install \(g.name) on the start screen to play it.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .id("game-" + g.flavor)
            Button("Open in Files") { settings.openInFiles(g.flavor) }
            Button("Reset Game Settings", role: .destructive) { settings.confirmation = .reset(g.flavor) }
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: settings.now.version).id("about")
            NavigationLink("Acknowledgements", value: Page.acknowledgements)
        }
    }
}

// The licenses of what the app ships, each opening its text.
struct AcknowledgementsView: View {
    let settings: Settings
    private let licenses = License.all()

    var body: some View {
        List {
            Section {
                ForEach(licenses, id: \.self) { NavigationLink($0.name, value: Page.license($0)) }
            } footer: {
                Text("Slashplayed includes these open-source components and the Goodmountain typeface.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton(settings: settings) }
    }
}

// One license's text, scrolling. A UITextView, not a Text: the Rust standard library's notices are 1.5 MB,
// more than SwiftUI's Text lays out quickly, and the text view finds the links in them.
struct LicenseView: UIViewRepresentable {
    let license: License

    func makeUIView(context: Context) -> UITextView {
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.textColor = .label
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        text.dataDetectorTypes = .link
        let raw = try? String(contentsOfFile: license.path, encoding: .utf8)
        text.text = raw.map { (license.path as NSString).pathExtension == "html" ? sp_html_text($0) : $0 } ?? "This license can’t be read."
        return text
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

// The sheet's controller: it runs the drill once it's up, and hides the email when the sheet closes (Done,
// a swipe) or the start screen goes (a game starts).
final class SettingsHost: UIHostingController<SettingsView> {
    let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        super.init(rootView: SettingsView(settings: settings))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // After this pass, so the list has rows to scroll to.
        DispatchQueue.main.async { [settings] in settings.runDrill() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController?.isBeingDismissed == true || presentingViewController == nil {
            settings.hideEmail()
        }
    }
}

@_cdecl("sp_settings_sheet")
public func settingsSheet(_ flavors: NSArray, _ drill: NSString?) -> UIViewController {
    let settings = Settings(flavors: flavors.compactMap { $0 as? String }, drill: drill as String?)
    let host = SettingsHost(settings: settings)
    settings.host = host
    Settings.shown = settings
    // Pinned Dark, as every launcher screen, so its stock controls suit the start screen.
    host.overrideUserInterfaceStyle = .dark
    return host
}

@_cdecl("sp_settings_hide_email")
public func settingsHideEmail() { Settings.shown?.hideEmail() }
