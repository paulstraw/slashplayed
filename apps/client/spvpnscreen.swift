// The LocalDevVPN wait's screen, in SwiftUI (spvpn.m keeps the wait, the connects, and the openURL). Two
// states, which spvpn.m switches between as its connects fail (sp_vpn_refused): LocalDevVPN off, with a button
// that asks spvpn.m to open it; or LocalDevVPN on and the device's developer services refusing through it, which
// is what cellular data does (LocalDevVPN works only on Wi-Fi), with how to get past that and no button: opening
// LocalDevVPN again doesn't help. spvpn.m sets the status line.
import SwiftUI
import UIKit

final class VPNModel: ObservableObject {
    @Published var refused = false
}

private struct VPNView: View {
    @ObservedObject var screen: ScreenModel
    @ObservedObject var model: VPNModel
    let noun: String
    let turnOn: () -> Void

    var body: some View {
        if model.refused {
            LauncherScreen(model: screen, title: "Connect to Wi-Fi", message: refusedMessage) { EmptyView() }
        } else {
            LauncherScreen(model: screen, title: "Turn on LocalDevVPN",
                           message: "Slashplayed prepares the game through LocalDevVPN, and it's off. It doesn't turn itself back on when this \(noun) restarts.\n\nOnce it's on, the game starts by itself.") {
                Button("Turn On LocalDevVPN", action: turnOn)
                    .buttonStyle(GameButtonStyle(height: 56))
                    .frame(maxWidth: 380)
            }
        }
    }

    // Airplane Mode takes cellular data away for the second or two the helper needs: the iPhone, 2026-11-14, with
    // the wait's next connect going through within a second, and the game signing in once it was off again. The
    // headset has no cellular data, so it only needs a Wi-Fi network joined.
    private var refusedMessage: String {
        #if os(visionOS)
        "LocalDevVPN is on, but this \(noun)'s developer services don't answer through it. LocalDevVPN works only on "
            + "a Wi-Fi network.\n\nJoin one, and the game starts by itself."
        #else
        "LocalDevVPN is on, but this \(noun)'s developer services don't answer through it. LocalDevVPN works only on "
            + "Wi-Fi, not over cellular data.\n\nJoin a Wi-Fi network, or turn on Airplane Mode until the game starts "
            + "loading, then turn it off again. The game starts by itself."
        #endif
    }
}

@_cdecl("sp_vpn_screen")
public func vpnScreen(_ noun: NSString, _ turnOn: @escaping @convention(block) () -> Void) -> UIViewController {
    let screen = ScreenModel(), model = VPNModel()
    let host = LauncherHost(model: screen, view: VPNView(screen: screen, model: model, noun: noun as String, turnOn: turnOn))
    host.vpn = model
    return host
}

// Which state it shows. A change clears the status line, which spoke to the other one.
@_cdecl("sp_vpn_refused")
public func vpnRefused(_ host: UIViewController, _ refused: Bool) {
    guard let host = host as? LauncherHost, let model = host.vpn, model.refused != refused else { return }
    model.refused = refused
    host.model.status = ""
}
