// The launcher's look, the start screen's (spstartscreen.swift), for every SwiftUI screen: its ground and
// gold, Goodmountain, and the game button, drawn in code. One copy: the start screen's games, the sign-in's
// buttons, and the waiting screens' all use GameButtonStyle.
import SwiftUI
import UIKit

let ground = Color(red: 0x10 / 255.0, green: 0x19 / 255.0, blue: 0x16 / 255.0)
let gold = Color(red: 0xAC / 255.0, green: 0x9D / 255.0, blue: 0x79 / 255.0)
// A field's face: the ground lifted a little toward the medallion's green, so it reads as a well.
let well = Color(red: 0x17 / 255.0, green: 0x24 / 255.0, blue: 0x20 / 255.0)

// Goodmountain (registered by spstart.m's sp_face, which signInScreen calls first), scaled with Dynamic Type.
func goodmountain(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    .custom("Goodmountain-Regular", size: size, relativeTo: style)
}

// Goodmountain at `size` points for the default text size, scaled like `style` for `typeSize` up to
// `maximum` (spstart.m's sp_face, which registers it; the system font when it's missing). For a cap, which
// goodmountain() can't give, and for kerning that scales with the face.
func spFace(_ size: CGFloat, _ style: UIFont.TextStyle, _ maximum: CGFloat, _ typeSize: DynamicTypeSize) -> UIFont {
    sp_face(size, style, maximum, UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
}

// An octagon: the rect, inset by `inset`, with each corner cut `cut` points along both sides. The cut is the
// inset rect's own, not shrunk by the inset (the loading screen's octagon(), sploading.m, takes it the same).
struct Octagon: InsettableShape {
    var cut: CGFloat
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset), c = cut
        return Path { p in
            p.move(to: CGPoint(x: r.minX + c, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
            p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
            p.closeSubpath()
        }
    }
    func inset(by amount: CGFloat) -> Octagon { var o = self; o.inset += amount; return o }
}

// The game buttons' frame: three octagons, gold, ground,
// and gold, cut 14, 11, and 10 at insets of 0, 5, and 6.5, so a ground line runs inside the gold; and a
// ground diamond on each side, a 9-point square turned 45°, centered 5.5 points in.
struct GameFrame: View {
    var body: some View {
        GeometryReader { geo in
            let half = 9 * 2.0.squareRoot() / 2, mid = geo.size.height / 2
            ZStack {
                Octagon(cut: 14).fill(gold)
                Octagon(cut: 11).inset(by: 5).fill(ground)
                Octagon(cut: 10).inset(by: 6.5).fill(gold)
                ForEach([5.5, geo.size.width - 5.5], id: \.self) { x in
                    Path { p in
                        p.move(to: CGPoint(x: x, y: mid - half))
                        p.addLine(to: CGPoint(x: x + half, y: mid))
                        p.addLine(to: CGPoint(x: x, y: mid + half))
                        p.addLine(to: CGPoint(x: x - half, y: mid))
                        p.closeSubpath()
                    }.fill(ground)
                }
            }
        }
    }
}

// The ornament either side of a game's name: a rule with a dot at its end and a diamond, 24 by 10.
struct Ornament: View {
    var body: some View {
        Canvas { ctx, _ in
            var rule = Path(); rule.move(to: CGPoint(x: 0, y: 5)); rule.addLine(to: CGPoint(x: 13, y: 5))
            ctx.stroke(rule, with: .color(ground), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: 0.4, y: 3.4, width: 3.2, height: 3.2)), with: .color(ground))
            var diamond = Path()
            diamond.move(to: CGPoint(x: 19, y: 1)); diamond.addLine(to: CGPoint(x: 23, y: 5))
            diamond.addLine(to: CGPoint(x: 19, y: 9)); diamond.addLine(to: CGPoint(x: 15, y: 5)); diamond.closeSubpath()
            ctx.fill(diamond, with: .color(ground))
        }
        .frame(width: 24, height: 10)
    }
}

// A game button: the frame, and the title between two ornaments, at least `height` tall; a long title or a
// large text size wraps it and it grows. The title is Goodmountain 21 (Title 3, at most 34), its kerning
// scaled with it; at the accessibility text sizes the ornaments go (the title needs the room).
struct GameButtonStyle: ButtonStyle {
    var height: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        GameButton(label: configuration.label, height: height, pressed: configuration.isPressed)
    }
}

// The style's body: a view of its own, so it reads the text size.
private struct GameButton<Label: View>: View {
    let label: Label
    let height: CGFloat
    let pressed: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let face = spFace(21, .title3, 34, typeSize), ornaments = !typeSize.isAccessibilitySize
        HStack(spacing: 9) {
            if ornaments { Ornament().accessibilityHidden(true) }
            label.font(Font(face as CTFont)).kerning(0.3 * face.pointSize / 21).foregroundStyle(ground)
                .multilineTextAlignment(.center)
            if ornaments { Ornament().scaleEffect(x: -1).accessibilityHidden(true) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(GameFrame())
        .contentShape(Octagon(cut: 14))
        // The headset's highlight where the eyes rest (and the iPad's pointer), in the button's shape (near
        // enough: its corners are cut).
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
        .hoverEffect(.highlight)
        .opacity(pressed ? 0.7 : 1)
    }
}

// A field: the well, framed in gold like the start screen's gear, its corners cut like the buttons'.
struct FrameFieldStyle: TextFieldStyle {
    var height: CGFloat
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundStyle(.white)
            .tint(gold)
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(Octagon(cut: 6).fill(well))
            .overlay(Octagon(cut: 6).strokeBorder(gold, lineWidth: 1.5))
    }
}

// ---- the launcher's waiting screens (sppair.m's, spvpn.m's, sppatch.m's): a title, what to do, a status line, and
// their own controls, centered and scrolling when they don't fit. The Objective-C sets the status line
// (sp_screen_status) and reads nothing back but what the controls send it.

final class ScreenModel: ObservableObject {
    @Published var status = ""
    @Published var asking = false  // the pairing screen's: the code field and its buttons show
}

struct LauncherScreen<Controls: View>: View {
    @ObservedObject var model: ScreenModel
    let title: String
    let message: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                // Each line takes its full height: the newer-build screen (sppatchscreen.swift) changes its
                // words while it shows, and in the scroll view a longer heading kept the old one's single line
                // and was cut ("This patch needs a Slashplayed up...").
                VStack(spacing: 24) {
                    Text(title).font(goodmountain(30, .title)).foregroundStyle(gold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message).foregroundStyle(gold.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    if !model.status.isEmpty {
                        Text(model.status).font(.headline).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    controls()
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(ground.ignoresSafeArea())
    }
}

// Their controller: full screen, pinned Dark, and the model the status calls reach.
final class LauncherHost: UIHostingController<AnyView> {
    let model: ScreenModel
    var patch: PatchModel?  // the newer-build screen's own state (sppatchscreen.swift); nil on the others

    init<V: View>(model: ScreenModel, view: V) {
        self.model = model
        _ = sp_face(1, .body, 1, UITraitCollection.current)  // registers Goodmountain for this process
        super.init(rootView: AnyView(view))
        overrideUserInterfaceStyle = .dark
        modalPresentationStyle = .fullScreen
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }
}

// sppair.m's and spvpn.m's: the status line under the screen's words ("" for none).
@_cdecl("sp_screen_status")
public func screenStatus(_ screen: UIViewController, _ text: NSString) {
    (screen as? LauncherHost)?.model.status = text as String
}
