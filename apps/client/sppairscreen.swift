// The headset's pairing screen, in SwiftUI (sppair.m keeps the Bonjour browse, the code's listener, and
// the helper's request): where Remote Devices is, and, while the helper waits for one, the code field,
// Pair, and a way to get a new code. sppair.m sets the status line and when the field shows
// (sp_pair_ask); the code goes to its `send` block, which checks it.
import SwiftUI
import UIKit

private struct PairView: View {
    @ObservedObject var model: ScreenModel
    let send: (String) -> String?
    let renew: () -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        LauncherScreen(model: model, title: "Pair Slashplayed with this Vision Pro",
                       message: "Slashplayed pairs with this Vision Pro once, so it can prepare the game on its own.\n\nOpen Settings > General > Remote Devices and keep it open. When it shows a code, type the code here.") {
            if model.asking {
                VStack(spacing: 20) {
                    TextField("Code", text: $code, prompt: Text("Code").foregroundStyle(gold.opacity(0.6)))
                        .font(.system(size: 32).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textFieldStyle(FrameFieldStyle(height: 60))
                        .focused($focused)
                        .onSubmit(pair)
                    Button("Pair", action: pair).buttonStyle(GameButtonStyle(height: 56))
                    // A way out when no code shows: the headset dropped the pair-setup this waits on (seen
                    // after the person cleared the Remote Devices list). sppair.m ends it, which starts a new one.
                    Button("No code? Get a new one") {
                        model.status = "Getting a new code…"
                        model.asking = false
                        renew()
                    }
                    .foregroundStyle(gold)
                }
                .frame(width: 260)
            }
        }
        .onChange(of: model.asking, initial: true) { _, asking in
            if asking { code = "" }
            focused = asking
        }
    }

    private func pair() {
        if let problem = send(code) {
            model.status = problem
            return
        }
        model.status = "Pairing…"
        model.asking = false
    }
}

@_cdecl("sp_pair_screen")
public func pairScreen(_ send: @escaping @convention(block) (NSString) -> NSString?,
                       _ renew: @escaping @convention(block) () -> Void) -> UIViewController {
    let model = ScreenModel()
    return LauncherHost(model: model, view: PairView(model: model, send: { send($0 as NSString) as String? }, renew: renew))
}

// sppair.m's: the code field and its buttons show while the helper waits for a code, and only then.
@_cdecl("sp_pair_ask")
public func pairAsk(_ screen: UIViewController, _ ask: Bool) {
    (screen as? LauncherHost)?.model.asking = ask
}
