// The app's Settings: a sheet with Done over the start screen (spstart.m opens it from its gear), stock dark
// inset-grouped, in SwiftUI. The launcher has no SwiftUI App: UIKit runs as a coroutine the launcher pumps
// by hand (spuikit.m), so the sheet is a UIHostingController the start screen presents, behind a C entry
// point (sp_settings_sheet, spswift.h). Its logic stays in Objective-C, called through spswift.h: the
// sign-in's keychain (splogin.m), and each game's build and reset (launcher.m). The sheet reads them again after every change (`Settings.reload`): no state of its own but
// whether the email shows and where it's navigated to.
//
// Battle.net: whether a sign-in is saved, Show Email, Forget My Sign-In, or Sign In…. Signing: until when the
// app opens (sp_profile_expiry), Forget Apple Token, when the app has the token it renews that with, and Sign
// In to Apple…, the launcher's own sign-in for one (spapple.m), when it has none or Apple stopped taking it. The email is the one
// value shown, only on a tap (no Face ID, Optic ID, or passcode: it's the person's own device), and only
// until the app goes to the background, the sheet closes, or a game starts (sp_settings_hide_email). The
// forget acts at the tap, after an alert whose default is Cancel. Display: the backing scale (sp_scale). Then a
// section per game (the start screen's, in its order): the build it starts with and where its client came
// from (spsource-<flavor>: from the Mac, or updated or installed on this device), its region (a picker for a game the device decides it for, sp_game_set_region; the Mac's, named,
// for a game the companion installed), Open in Files, and Reset Game Settings (after its alert). About: the app's version and
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

// The license files in the app's licenses/ (apps/client/build.sh, the companion's ClientAssembly), by name,
// in this order; one this doesn't know comes last, under its file name.
struct License: Hashable {
    let path: String, name: String
    static func all() -> [License] {
        let dir = (Bundle.main.bundlePath as NSString).appendingPathComponent("licenses")
        let known = [("idevice.txt", "idevice"), ("rust-std.html", "Rust Standard Library"),
                     ("spapple.txt", "isideload"), ("goodmountain.txt", "Goodmountain")]
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
    case forgetSignIn, forgetAppleToken, reset(String)
    var id: String {
        switch self {
        case .forgetSignIn: "forget-signin"
        case .forgetAppleToken: "forget-apple-token"
        case .reset(let flavor): "reset-" + flavor
        }
    }
}

// What's true now, read once per reload (the build reads files, and SwiftUI may ask for the body often).
struct Snapshot {
    // `installed`: the device has it (sp_game_has_image: its client, or game data whose client its next start
    // gets, `version` nil); `source`: where its client came from (sp_game_build).
    // `region`: its code (sp_game_region_now); `regionHere`: the device decides it, so Settings can change it.
    struct Game {
        let flavor: String, name: String, version: String?, source: String?, installed: Bool
        let region: String, regionHere: Bool
    }
    var saved = false
    var appleToken = false  // spapple.m's: the token the app renews its own profiles with
    var needsSignIn = false  // spapple.m's: the last renewal had no token it could use
    var signedUntil: Date?  // when the app stops opening, unless it's renewed (sp_profile_expiry)
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
        s.appleToken = sp_apple_token_present()
        s.needsSignIn = sp_profiles_need_signin()
        s.signedUntil = sp_profile_expiry()
        let scale = UserDefaults.standard.integer(forKey: scaleKey)
        s.scale = scale == 1 || scale == 2 ? scale : 0
        s.chordRightFinger = UserDefaults.standard.bool(forKey: chordRightFingerKey)
        s.games = flavors.map { flavor in
            var source: NSString?
            let version = sp_game_build(flavor, &source)?["Version"]
            let region = sp_game_region_now(flavor)
            return .init(flavor: flavor, name: sp_flavor_name(flavor), version: version, source: source as String?,
                         installed: sp_game_has_image(flavor), region: region["Region"] ?? "us", regionHere: region["Device"] == "1")
        }
        s.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        now = s
    }

    // ---- the actions

    func setRegion(_ flavor: String, _ region: String) {
        say(sp_game_set_region(flavor, region))
        reload()
    }

    // Read here, at the tap, and kept only while it shows. Never logged.
    func showEmail() { email = sp_login_email() }

    @objc func hideEmail() { if email != nil { email = nil } }

    func close() { host?.presentingViewController?.dismiss(animated: true) }

    func signIn() {
        host?.present(sp_login_screen { [weak self] _ in self?.reload() }, animated: true)
    }

    // Sign In to Apple…: spapple.m's sign-in, full screen over the sheet.
    func appleSignIn() {
        host?.present(sp_apple_signin { [weak self] _ in self?.reload() }, animated: true)
    }

    func confirm(_ c: Confirmation) {
        switch c {
        case .forgetSignIn:
            _ = sp_login_forget()
            email = nil
        case .forgetAppleToken:
            say(sp_apple_token_forget())
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

    // The drill's states: `settings` (the sheet as it opens), `signing`, `display`, `games`, and `about`
    // (scrolled to that section, or the first game's), `sign-in` (Sign In…'s screen), `sign-in-launch`
    // (the sign-in screen as a launch with no saved sign-in shows it, full screen; it saves nothing),
    // `vpn`, `pair`, and `pair-code` (the LocalDevVPN wait's and the pairing screen's, the last asking for the
    // code; they do nothing), `acknowledgements` (its
    // page), `license-<file>` (one license's text, e.g. license-rust-std), and `alert-forget-signin`,
    // `apple-sign-in` (Sign In to Apple…'s screen: a real sign-in, as a tap's is), `apple-sign-in-code`,
    // `apple-sign-in-texts`, and `apple-sign-in-done` (its 2FA step, by device and by text with made-up
    // numbers, and its end; they sign nothing in), `alert-forget-apple-token`, and `alert-reset` (the
    // confirmations, the last for the first game, shown
    // whatever's saved, so they can be screenshotted without a credential; Cancel is what a drill expects to
    // be tapped, if anything). `reset-<flavor>` is Reset's Reset tapped: it resets that game's settings with
    // no alert, so a test can check what it deletes and the next start's seeding. `scale-<0|1|2>` picks that
    // Display > Scale (0 is Automatic), so a test can set it without taps; it's saved, as a tap's is.
    // `files-<flavor>` is that game's Open in Files tapped. `region-<flavor>-<us|eu|kr|tw>` picks that game's
    // Region, saved as a pick is (one the Mac decides logs that it can't). Once, when the sheet has appeared.
    private func presentDrill(_ screen: UIViewController) {
        screen.modalPresentationStyle = .fullScreen
        host?.present(screen, animated: false)
    }

    // The Apple sign-in's screen in one of its steps, with blocks that do nothing.
    private func appleDrill(_ step: [String: Any]) {
        let screen = appleScreen(sp_device_noun() as NSString, "https://mac-ani.jkcoxson.com", { _, _, _ in "A drill: nothing was sent." },
                                 { _, _, _ in }, {}, {})
        appleScreenShow(screen, step as NSDictionary)
        presentDrill(screen)
    }

    func runDrill() {
        guard let state = drill else { return }
        drill = nil
        let states: [String: () -> Void] = [
            "settings": {},
            "signing": { self.scrollTo?("signing") },
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
            "apple-sign-in": { self.appleSignIn() },
            "apple-sign-in-code": { self.appleDrill(["step": "code", "numbers": [["id": 1, "number": "(•••) •••-••12"]]]) },
            "apple-sign-in-texts": {
                self.appleDrill(["step": "code", "sms": true, "selected": 1, "retry": true,
                                 "numbers": [["id": 1, "number": "(•••) •••-••12"], ["id": 2, "number": "+44 ••••• ••••34"]]])
            },
            "apple-sign-in-done": { self.appleDrill(["step": "done"]) },
            "acknowledgements": { self.push([.acknowledgements]) },
            "alert-forget-signin": { self.confirmation = .forgetSignIn },
            "alert-forget-apple-token": { self.confirmation = .forgetAppleToken },
            "alert-reset": { if let f = self.flavors.first { self.confirmation = .reset(f) } },
        ]
        var open = states[state]
        let suffix = { (prefix: String) -> String? in state.hasPrefix(prefix) ? String(state.dropFirst(prefix.count)) : nil }
        if open == nil, let f = suffix("reset-"), flavors.contains(f) {
            open = { say(sp_game_reset(f)); self.reload(); self.scrollTo?("game-" + f) }
        }
        if open == nil, let f = suffix("files-"), flavors.contains(f) { open = { self.openInFiles(f) } }
        if open == nil, let rest = suffix("region-"), let dash = rest.lastIndex(of: "-"), flavors.contains(String(rest[..<dash])) {
            let f = String(rest[..<dash]), r = String(rest[rest.index(after: dash)...])
            open = { self.setRegion(f, r); self.scrollTo?("game-" + f) }
        }
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
                    signing
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
        case .forgetAppleToken: "Forget the Apple Token?"
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
        case .forgetAppleToken: "Slashplayed stops renewing its own signing. To renew it again, sign in to Apple here, or run Slashplayed Companion on a computer."
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

    // Signing: until when the app opens, and the Apple token it renews that with (spapple.m), which
    // slashplayed-companion pushes or the launcher's own sign-in makes: Sign In to Apple… when there's none
    // (or Apple stopped taking it), opt-in, its screen saying what it is. The token's forget acts at the tap,
    // after an alert whose default is Cancel.
    private var signing: some View {
        Section {
            if let until = settings.now.signedUntil {
                LabeledContent("Signed Until", value: until.formatted(date: .abbreviated, time: .omitted))
                    .id("signing")
            }
            if !settings.now.appleToken || settings.now.needsSignIn {
                Button("Sign In to Apple…") { settings.appleSignIn() }
            }
            if settings.now.appleToken {
                Button("Forget Apple Token", role: .destructive) { settings.confirmation = .forgetAppleToken }
            }
        } header: {
            Text("Signing")
        } footer: {
            Text(settings.now.appleToken && !settings.now.needsSignIn
                 ? "Slashplayed renews its signing itself in the last 3 days, when a game starts, with an Apple token kept on this device. It isn’t your Apple ID password."
                 : settings.now.appleToken
                 ? "Apple no longer takes this device’s Apple token. Sign in to Apple again, or run Slashplayed Companion before then, to keep Slashplayed opening."
                 : "Run Slashplayed Companion again before then to keep Slashplayed opening. Or sign in to Apple here, optionally, so Slashplayed renews its signing itself: a second sign-in to your Apple ID, through a third-party server.")
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
    // Finger chords (spevent.m): two fingers right-click, three middle-click, at one finger's spot; two held
    // still open the edit menu (Copy, Paste, and Keyboard) as they lift.
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
            Text("Press with two fingers together to right-click, or three to middle-click. The click is where the left or right finger is. Hold two fingers still for a moment, then lift them, for Copy, Paste, and Keyboard. With Accessibility Zoom on, three-finger presses lag.")
        }
    }
    #endif

    private func game(_ g: Snapshot.Game) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                if g.installed, let version = g.version {
                    Text("Build " + version)
                    Text(sourceText(g)).font(.subheadline).foregroundStyle(.secondary)
                } else if g.installed {
                    Text("Not Ready")
                    Text("Its next start gets it ready.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Not Installed")
                    Text("Install \(g.name) on the start screen to play it.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .id("game-" + g.flavor)
            if g.regionHere {
                LabeledContent("Region") {
                    Picker("Region", selection: Binding(get: { g.region }, set: { settings.setRegion(g.flavor, $0) })) {
                        ForEach(sp_regions(), id: \.self) { Text(sp_region_name($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()  // LabeledContent's is the label
                }
            } else {
                LabeledContent("Region", value: sp_region_name(g.region))
            }
            Button("Open in Files") { settings.openInFiles(g.flavor) }
            Button("Reset Game Settings", role: .destructive) { settings.confirmation = .reset(g.flavor) }
        } header: {
            Text(g.name)
        } footer: {
            // About the region only: the build row above says where the client came from.
            Text(g.regionHere
                 ? "Region is where your realms are. The game’s language follows this \(sp_device_noun())’s. A change applies the next time the game starts."
                 : "\(g.name)’s region is set in Battle.net on your Mac. To change it, change it there, then press Play in Slashplayed Companion.")
        }
    }

    // Where the game's client came from. One with no word (none of today's writers leaves it out) reads as
    // the device's own: installed for a game whose region the device decides (it installed it), else updated.
    private func sourceText(_ g: Snapshot.Game) -> String {
        switch g.source {
        case "mac": "From your Mac"
        case "updated": "Updated on this device"
        case "installed": "Installed on this device"
        default: g.regionHere ? "Installed on this device" : "Updated on this device"
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
    var closed: (() -> Void)?

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
            closed?()
        }
    }
}

@_cdecl("sp_settings_sheet")
public func settingsSheet(_ flavors: NSArray, _ drill: NSString?, _ closed: @escaping @convention(block) () -> Void) -> UIViewController {
    let settings = Settings(flavors: flavors.compactMap { $0 as? String }, drill: drill as String?)
    let host = SettingsHost(settings: settings)
    host.closed = closed
    settings.host = host
    Settings.shown = settings
    // Pinned Dark, as every launcher screen, so its stock controls suit the start screen.
    host.overrideUserInterfaceStyle = .dark
    return host
}

@_cdecl("sp_settings_hide_email")
public func settingsHideEmail() { Settings.shown?.hideEmail() }
