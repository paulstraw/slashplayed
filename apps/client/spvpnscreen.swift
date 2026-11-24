// The LocalDevVPN wait's screen, in SwiftUI (spvpn.m keeps the wait, the connects, and the openURL). Two
// states, which spvpn.m switches between as its connects fail (sp_vpn_refused): LocalDevVPN off, with a button
// that asks spvpn.m to open it; or LocalDevVPN on and the device's developer services refusing through it, which
// is what cellular data does (LocalDevVPN works only on Wi-Fi), with how to get past that and no button: opening
// LocalDevVPN again doesn't help. spvpn.m sets the status line. And the wait for the internet that comes after
// the helper's attach (NetView), which spvpn.m also keeps.
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
            + "Wi-Fi, not over cellular data.\n\nJoin a Wi-Fi network, or turn on Airplane Mode for now: Slashplayed "
            + "says when to turn it off again. The game starts by itself."
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

// The wait for the internet once the helper has attached (spvpn.m's sp_net_wait): what to turn back on, a
// spinner, and Start Anyway, quieter, as the newer-build screen's second button is, since waiting is the way on.
private struct NetView: View {
    @ObservedObject var screen: ScreenModel
    let noun: String
    let startAnyway: () -> Void

    var body: some View {
        LauncherScreen(model: screen, title: "Waiting for the Internet", message: message) {
            VStack(spacing: 20) {
                ProgressView().controlSize(.large).tint(gold)
                Button("Start Anyway", action: startAnyway).foregroundStyle(gold)
            }
        }
    }

    private var message: String {
        #if os(visionOS)
        "The game signs in to Battle.net as it starts, and this \(noun) isn't online.\n\nJoin a Wi-Fi network, "
            + "and the game starts by itself."
        #else
        "The game signs in to Battle.net as it starts, and this \(noun) isn't online.\n\nIf you turned on Airplane "
            + "Mode for LocalDevVPN, turn it off now (or cellular data back on). The game starts by itself once the "
            + "\(noun) is online."
        #endif
    }
}

@_cdecl("sp_net_screen")
public func netScreen(_ noun: NSString, _ startAnyway: @escaping @convention(block) () -> Void) -> UIViewController {
    let screen = ScreenModel()
    return LauncherHost(model: screen, view: NetView(screen: screen, noun: noun as String, startAnyway: startAnyway))
}

// Which state it shows. A change clears the status line, which spoke to the other one.
@_cdecl("sp_vpn_refused")
public func vpnRefused(_ host: UIViewController, _ refused: Bool) {
    guard let host = host as? LauncherHost, let model = host.vpn, model.refused != refused else { return }
    model.refused = refused
    host.model.status = ""
}
