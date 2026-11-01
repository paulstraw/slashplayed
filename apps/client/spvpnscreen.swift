// The LocalDevVPN wait's screen, in SwiftUI (spvpn.m keeps the wait, the connects, and the openURL):
// what's off, and a button that asks spvpn.m to open LocalDevVPN. spvpn.m sets the status line.
import SwiftUI
import UIKit

private struct VPNView: View {
    @ObservedObject var model: ScreenModel
    let noun: String
    let turnOn: () -> Void

    var body: some View {
        LauncherScreen(model: model, title: "Turn on LocalDevVPN",
                       message: "Slashplayed prepares the game through LocalDevVPN, and it's off. It doesn't turn itself back on when this \(noun) restarts.\n\nOnce it's on, the game starts by itself.") {
            Button("Turn On LocalDevVPN", action: turnOn)
                .buttonStyle(GameButtonStyle(height: 56))
                .frame(maxWidth: 380)
        }
    }
}

@_cdecl("sp_vpn_screen")
public func vpnScreen(_ noun: NSString, _ turnOn: @escaping @convention(block) () -> Void) -> UIViewController {
    let model = ScreenModel()
    return LauncherHost(model: model, view: VPNView(model: model, noun: noun as String, turnOn: turnOn))
}
