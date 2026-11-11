// The launcher's own Apple sign-in screen, in SwiftUI. Only the screen: spapple.m runs the sign-in (spapple's
// "login" op), keeps the token it makes, and tells this screen each step (sp_apple_screen_show). What's typed
// goes straight to its blocks; nothing here logs, stores, or passes on the Apple ID, the password, or a code
// (CLAUDE.md, "The Apple ID is a credential"). Swift strings can't be zeroed, as on the Battle.net sign-in
// (spsignin.swift); the password and code fields are emptied as soon as they're sent.
//
// Opt-in, and it says what it is: a second sign-in to the person's Apple ID through a third-party anisette
// server, for a device whose companion gives it no token (the Mac's, every Vision Pro) or whose token Apple
// stopped taking. Opened from the start screen's note and Settings' Signing, full screen, with Cancel (the X).
// The steps: the form (Apple ID, password, and the anisette server, which can be changed), a spinner while
// Apple answers, the 2FA code (or a choice of how to get one), and done. In the sign-in screen's look and
// layout: words left and the fields right on an iPhone in landscape, where the keyboard leaves a third.
import SwiftUI
import UIKit

final class AppleSignIn: ObservableObject {
    enum Step { case form, working, code, done }
    struct Number: Hashable { let id: Int, number: String }

    @Published var step = Step.form
    @Published var email = ""
    @Published var password = ""
    @Published var server: String
    @Published var editingServer = false
    @Published var code = ""
    @Published var status = ""
    // The code step's: by text (else on the person's Apple devices), the last way failed (choose another),
    // and Apple's trusted numbers, masked by Apple.
    @Published var sms = false
    @Published var unknown = false
    @Published var numbers: [Number] = []
    @Published var selected: Int?  // the number a text went to

    let noun: String
    // spapple.m's: nil when it took them (the steps follow through show), else what to say.
    let begin: (String, String, String) -> String?
    let answer: (String, Int, String) -> Void
    let cancel: () -> Void
    let finish: () -> Void

    init(noun: String, server: String, begin: @escaping (String, String, String) -> String?,
         answer: @escaping (String, Int, String) -> Void, cancel: @escaping () -> Void, finish: @escaping () -> Void) {
        self.noun = noun
        self.server = server
        self.begin = begin
        self.answer = answer
        self.cancel = cancel
        self.finish = finish
    }

    var host: String { URLComponents(string: server)?.host ?? server }

    func signIn() {
        if let problem = begin(email, password, server) {
            status = problem
            return
        }
        password = ""
        status = "Signing in…"
        step = .working
    }

    // An answer to Apple's ask: "code" (what's typed), "sms" (to `number`), "devices", or "resend".
    func send(_ kind: String, number: Int = 0, saying: String) {
        let typed = kind == "code" ? code : ""
        code = ""
        status = saying
        step = .working
        answer(kind, number, typed)
    }

    // spapple.m's step: "form" (with what went wrong), "code" (sms, unknown, retry, numbers), or "done".
    func show(_ s: [String: Any]) {
        switch s["step"] as? String {
        case "code":
            sms = s["sms"] as? Bool ?? false
            unknown = s["unknown"] as? Bool ?? false
            numbers = (s["numbers"] as? [[String: Any]] ?? []).compactMap { n in
                guard let id = n["id"] as? Int, let number = n["number"] as? String else { return nil }
                return Number(id: id, number: number)
            }
            selected = s["selected"] as? Int
            status = s["retry"] as? Bool == true ? "That code didn’t work. Type it again, or get a new one." : ""
            step = .code
        case "done":
            status = ""
            step = .done
        default:
            status = s["status"] as? String ?? ""
            step = .form
        }
    }
}

struct AppleSignInView: View {
    @ObservedObject var model: AppleSignIn
    @Environment(\.verticalSizeClass) private var vertical
    @FocusState private var focus: Field?
    private enum Field { case email, password, server, code }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    if compact {
                        HStack(alignment: .top, spacing: 32) {
                            words.frame(maxWidth: .infinity)
                            controls
                        }
                    } else {
                        VStack(spacing: 20) { words; controls }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, compact ? 12 : 24)
                .padding(compact ? .leading : .top, 56)  // room for Cancel
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(ground.ignoresSafeArea())
#if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        // No field takes the focus at first: on an iPhone in landscape the keyboard would cover the words that
        // say what this sign-in is, which should be read before anything's typed.
        .onChange(of: model.step) { _, step in focus = step == .code ? .code : step == .form ? .password : nil }
        .overlay(alignment: .topLeading) {
            if model.step != .done {
                // The sign-in screen's Cancel: a gold-framed square, a fixed 44 points.
                Button(action: model.cancel) {
                    Image(systemName: "xmark").font(.system(size: 18)).foregroundStyle(gold)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(gold, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .padding(16)
            }
        }
    }

    private var compact: Bool { vertical == .compact }

    private var words: some View {
        VStack(spacing: 16) {
            Text(model.step == .done ? "Signed in" : "Sign in to Apple").font(goodmountain(30, .title)).foregroundStyle(gold)
            Group {
                switch model.step {
                case .form, .working:
                    Text("Optional. With an Apple token, Slashplayed renews its own signing on this \(model.noun), with no computer.")
                    Text("This is a second sign-in to your Apple ID, made the way sideloading tools sign in: through a third-party anisette server, which Apple doesn’t officially support. A secondary Apple ID is safest. Use the Apple ID Slashplayed was set up with, or another on its team.")
                    Text("Your password is used once for this sign-in and isn’t kept. Only the Apple token it makes is kept, in this \(model.noun)’s keychain, until you forget it in Settings.")
                case .code:
                    Text(codeWords)
                case .done:
                    Text("Slashplayed renews its own signing from now on, when a game starts in the last 3 days before it runs out. To stop it, forget the Apple token in Settings.")
                }
            }
            .foregroundStyle(gold.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }

    private var codeWords: String {
        if model.unknown { return "Choose how Apple sends your code." }
        if model.sms {
            let to = model.numbers.first { $0.id == model.selected }?.number
            return to.map { "Type the code Apple texted to \($0)." } ?? "Type the code Apple texted to you."
        }
        return "Type the code shown on your Apple devices."
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: compact ? 12 : 20) {
            if !model.status.isEmpty {
                Text(model.status).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.step {
            case .form: form
            case .working: ProgressView().controlSize(.large).tint(gold)
            case .code: codeStep
            case .done: Button("Done", action: model.finish).buttonStyle(GameButtonStyle(height: compact ? 48 : 56))
            }
        }
        .frame(width: 320)
    }

    private var form: some View {
        VStack(spacing: compact ? 12 : 20) {
            // Content types let Passwords fill them in.
            TextField("Apple ID", text: $model.email, prompt: Text("Apple ID").foregroundStyle(gold.opacity(0.6)))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
            SecureField("Password", text: $model.password, prompt: Text("Password").foregroundStyle(gold.opacity(0.6)))
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(signIn)
            Button("Sign In", action: signIn).buttonStyle(GameButtonStyle(height: compact ? 48 : 56))
            VStack(spacing: 8) {
                if model.editingServer {
                    TextField("Anisette server", text: $model.server,
                              prompt: Text("https://…").foregroundStyle(gold.opacity(0.6)))
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($focus, equals: .server)
                } else {
                    Text("Anisette server: \(model.host)").foregroundStyle(gold.opacity(0.85))
                    Button("Use Another Server") {
                        model.editingServer = true
                        focus = .server
                    }
                    .foregroundStyle(gold)
                }
                Text("It never gets your Apple ID, password, or token.").foregroundStyle(gold.opacity(0.65))
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
        }
        .textFieldStyle(FrameFieldStyle(height: compact ? 40 : 44))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var codeStep: some View {
        VStack(spacing: compact ? 12 : 20) {
            if !model.unknown {
                TextField("Code", text: $model.code, prompt: Text("Code").foregroundStyle(gold.opacity(0.6)))
                    .font(.system(size: 28).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(FrameFieldStyle(height: compact ? 48 : 56))
                    .focused($focus, equals: .code)
                    .onSubmit(submit)
                Button("Continue", action: submit).buttonStyle(GameButtonStyle(height: compact ? 48 : 56))
                Button("Send a New Code") { model.send("resend", saying: "Asking Apple for a new code…") }.foregroundStyle(gold)
            }
            // The other ways: a text to one of Apple's trusted numbers, or the Apple devices.
            ForEach(model.numbers.filter { !model.sms || $0.id != model.selected }, id: \.self) { n in
                Button("Text \(n.number)") { model.send("sms", number: n.id, saying: "Asking Apple to text \(n.number)…") }
                    .foregroundStyle(gold)
            }
            if model.unknown || model.sms {
                Button("Show on My Apple Devices") { model.send("devices", saying: "Asking Apple to show a code on your devices…") }
                    .foregroundStyle(gold)
            }
        }
    }

    private func signIn() {
        focus = nil
        model.signIn()
    }

    private func submit() {
        guard !model.code.trimmingCharacters(in: .whitespaces).isEmpty else {
            model.status = "Type the code."
            return
        }
        focus = nil
        model.send("code", saying: "Checking the code…")
    }
}

// spapple.m's: the screen, full screen and pinned Dark, not swiped away half-typed (Cancel says it).
@_cdecl("sp_apple_screen")
public func appleScreen(_ noun: NSString, _ server: NSString,
                        _ begin: @escaping @convention(block) (NSString, NSString, NSString) -> NSString?,
                        _ answer: @escaping @convention(block) (NSString, Int, NSString) -> Void,
                        _ cancel: @escaping @convention(block) () -> Void,
                        _ finish: @escaping @convention(block) () -> Void) -> UIViewController {
    _ = sp_face(1, .body, 1, UITraitCollection.current)  // registers Goodmountain for this process
    let model = AppleSignIn(noun: noun as String, server: server as String,
                            begin: { begin($0 as NSString, $1 as NSString, $2 as NSString) as String? },
                            answer: { answer($0 as NSString, $1, $2 as NSString) }, cancel: cancel, finish: finish)
    return AppleSignInHost(model: model)
}

final class AppleSignInHost: UIHostingController<AppleSignInView> {
    let model: AppleSignIn

    init(model: AppleSignIn) {
        self.model = model
        super.init(rootView: AppleSignInView(model: model))
        overrideUserInterfaceStyle = .dark
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }
}

// spapple.m's: the sign-in's next step (AppleSignIn.show's keys).
@_cdecl("sp_apple_screen_show")
public func appleScreenShow(_ screen: UIViewController, _ step: NSDictionary) {
    (screen as? AppleSignInHost)?.model.show(step as? [String: Any] ?? [:])
}
