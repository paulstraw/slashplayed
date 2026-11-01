// The Battle.net sign-in screen, in SwiftUI. Only the screen: what's typed goes straight to splogin.m's
// `entered` block, which checks it, keeps it in the keychain, and writes login.txt; nothing here logs,
// stores, or passes on either value (CLAUDE.md's credential rules). Swift strings can't be zeroed, which
// UIKit's text fields never allowed either; the fields are emptied once splogin.m takes them.
//
// Two ways in (splogin.m): full screen at a launch with no saved sign-in, and Settings' Sign In…, with
// Cancel (the X), not swiped away half-typed. Pinned Dark, as every launcher screen is, in the start
// screen's look (spstyle.swift): its ground, gold, and Goodmountain, the fields framed in gold, and Sign In
// drawn as a game button.
//
// On an iPhone in landscape the keyboard leaves about a third of the screen. So with a compact height the
// words go on the left and the fields and Sign In on the right, at the top, where the keyboard leaves
// them visible; the whole screen still scrolls, and a drag down puts the keyboard away.
import SwiftUI
import UIKit

final class SignIn: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var status = ""
    let noun: String
    // splogin.m's: nil when it took them, else what to say (nothing typed, a line break, the keychain).
    let entered: (String, String) -> String?
    let cancel: (() -> Void)?

    init(noun: String, entered: @escaping (String, String) -> String?, cancel: (() -> Void)?) {
        self.noun = noun
        self.entered = entered
        self.cancel = cancel
    }

    func send() {
        // Shown while it's checked and saved; splogin.m dismisses the screen once it's done.
        status = "Signing in…"
        if let problem = entered(email, password) {
            status = problem
            return
        }
        email = ""
        password = ""
    }
}

struct SignInView: View {
    @ObservedObject var model: SignIn
    @Environment(\.verticalSizeClass) private var vertical
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        // The scroll view ends above the keyboard (SwiftUI's own avoidance), so the visible height is
        // what's left; the content is at least that tall, centered in it while it fits, else from the top.
        GeometryReader { geo in
            ScrollView {
                Group {
                    if vertical == .compact {
                        HStack(alignment: .top, spacing: 32) {
                            words.frame(maxWidth: .infinity)
                            form
                        }
                    } else {
                        VStack(spacing: 20) { words; form }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, compact ? 12 : 24)
                // Room for Cancel: beside the words when they're on the left, above them otherwise.
                .padding(vertical == .compact ? .leading : .top, model.cancel == nil ? 0 : 56)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(ground.ignoresSafeArea())
#if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .onAppear { focus = .email }
        // Cancel floats in the corner, not in a navigation bar: a bar's height is what the iPhone in landscape
        // can't spare above the keyboard.
        .overlay(alignment: .topLeading) {
            if let cancel = model.cancel {
                // The gear's twin (spstartscreen.swift): a gold-framed square, a fixed 44 points.
                Button(action: cancel) {
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

    private var words: some View {
        VStack(spacing: 20) {
            Text("Sign in").font(goodmountain(30, .title)).foregroundStyle(gold)
            Text("Slashplayed signs into the game with your Battle.net email and password. They stay in this \(model.noun)'s keychain. If your account has an authenticator, the game client will ask for a code.")
                .foregroundStyle(gold.opacity(0.85))
        }
        .multilineTextAlignment(.center)
    }

    // With a compact height (an iPhone in landscape) the keyboard leaves about 175 points: the form fits
    // above it only a little tighter.
    private var compact: Bool { vertical == .compact }

    private var form: some View {
        VStack(spacing: compact ? 12 : 20) {
            if !model.status.isEmpty {
                Text(model.status).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
            }
            // Content types let Passwords fill them in.
            TextField("Email", text: $model.email, prompt: Text("Email").foregroundStyle(gold.opacity(0.6)))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
            SecureField("Password", text: $model.password, prompt: Text("Password").foregroundStyle(gold.opacity(0.6)))
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(send)
            Button("Sign In", action: send).buttonStyle(GameButtonStyle(height: compact ? 48 : 56))
        }
        .textFieldStyle(FrameFieldStyle(height: compact ? 40 : 44))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(width: 320)
    }

    private func send() {
        focus = nil
        model.send()
    }
}

// splogin.m's: the screen, for it to present (full screen at a launch) or return (Settings' Sign In…, with
// `cancel`). `entered` is called on the main thread with what was typed.
@_cdecl("sp_signin_screen")
public func signInScreen(_ noun: NSString, _ entered: @escaping @convention(block) (NSString, NSString) -> NSString?,
                         _ cancel: (@convention(block) () -> Void)?) -> UIViewController {
    _ = sp_face(1, .body, 1, UITraitCollection.current)  // registers Goodmountain for this process
    let model = SignIn(noun: noun as String, entered: { entered($0 as NSString, $1 as NSString) as String? },
                       cancel: cancel)
    let host = UIHostingController(rootView: SignInView(model: model))
    host.overrideUserInterfaceStyle = .dark
    // Not swiped away half-typed: Cancel says it.
    host.isModalInPresentation = cancel != nil
    return host
}
