// The start screen, in SwiftUI (spstart.m keeps the wait for a tap, the logged lines, the drill, and the
// text-size override; it presents this through sp_start_screen). Its look is its own, not stock: the app
// icon's dark green-black and gold, its medallion with two faint rings around it, and framed game buttons
// (spstyle.swift's GameButtonStyle, the one game button every screen shares), all drawn in code: no bitmaps,
// the logo's paths are the icon's own vectors (splogo.h). One layout for every screen: a column on a phone
// in portrait, and the logo beside the games when the screen is wide (an iPhone in landscape, an iPad, the
// headset's window). Only the games scroll, when there are more than fit (or Dynamic Type makes them taller
// than the screen): the logo stays put. No title: the games say what it's for. Nothing destructive here:
// the forgets and resets live in Settings, behind the gear.
import SwiftUI
import UIKit

// The design's numbers for a window, its safe area, the text size, and what the last layout measured (the
// logo's size with its line, and the games' height at the column's width): where the logo, the games' slot,
// the games' scroll view, and the gear go, in the window's points. Wide (more than 1.15 times as wide as
// tall) puts the logo beside the games, and short (under 500 points) tightens it. At the accessibility text
// sizes the games take all the width they can (without their ornaments), and scroll.
//
// The slot is where the games rest; the scroll view reaches past it to the window's bottom (and its top
// too, beside the logo), and its content margins rest the games in the slot, so a drag or a bounce moves
// them past it to the window's edges rather than cutting them off at the slot's. These are the UIKit
// version's constraints, solved by hand: the logo and the slot are centered, as a group, where the margins
// allow (the slot gives way first: it's shorter rather than off center), and the column's width gives way
// only to the room beside the logo.
private struct StartLayout: Equatable {
    var header = CGRect.zero, slot = CGRect.zero, scroll = CGRect.zero, gear = CGPoint.zero

    static func wide(_ window: CGSize) -> Bool { window.width > window.height * 1.15 }
    static func emblem(_ window: CGSize) -> CGFloat { wide(window) ? (min(window.height * 0.36, 220)).rounded() : 128 }

    init() {}

    init(window: CGSize, safe: UIEdgeInsets, big: Bool, header logo: CGSize, games: CGFloat) {
        let w = window.width, h = window.height, wide = Self.wide(window), short = h < 500
        let side = max(20, safe.left, safe.right)  // the design's side margin, or the safe area's
        let spacing: CGFloat = wide ? (short ? 48 : 104) : 40
        // The gear: 8 points below the safe area's top (or the screen's), at the side margin. The games keep
        // clear of it: below it in a column, beside its column (56 points) in a row.
        let gearTop = max(safe.top, 8) + 8
        gear = CGPoint(x: w - side - 44, y: gearTop)
        let top = wide ? max(safe.top, 8) : gearTop + 44 + 12, bottom = max(safe.bottom, 8)
        let leading = side, trailing = wide ? side + 56 : side
        var column: CGFloat
        if wide {
            let room = w - 2 * side - 56 - spacing - logo.width  // the games' room beside the logo
            column = big ? room : max(260, min(400, ((w - 2 * side) / 2).rounded(), room))
            column = min(column, room)
        } else {
            column = big ? w - 2 * side : min(380, w - 2 * side)
        }
        column = max(column, 0)
        // Centered vertically, so the room is what the larger of the two margins leaves on both sides.
        let room = h - 2 * max(top, bottom)
        let slotHeight: CGFloat, size: CGSize
        if wide {
            slotHeight = max(0, min(games, room))
            size = CGSize(width: logo.width + spacing + column, height: max(logo.height, slotHeight))
        } else {
            slotHeight = max(0, min(games, room - logo.height - spacing))
            size = CGSize(width: max(logo.width, column), height: logo.height + spacing + slotHeight)
        }
        let x = max(leading, min((w - size.width) / 2, w - trailing - size.width))
        let y = max(top, min((h - size.height) / 2, h - bottom - size.height))
        if wide {
            header = CGRect(x: x, y: y + (size.height - logo.height) / 2, width: logo.width, height: logo.height)
            slot = CGRect(x: x + logo.width + spacing, y: y + (size.height - slotHeight) / 2, width: column, height: slotHeight)
        } else {
            header = CGRect(x: x + (size.width - logo.width) / 2, y: y, width: logo.width, height: logo.height)
            slot = CGRect(x: x + (size.width - column) / 2, y: y + logo.height + spacing, width: column, height: slotHeight)
        }
        // Beside the logo the games reach the window's top; in a column, only the slot's (the logo is above).
        let scrollTop = wide ? 0 : slot.minY
        scroll = CGRect(x: slot.minX, y: scrollTop, width: column, height: h - scrollTop)
    }

    // The content margins that rest the games in the slot.
    var rest: (top: CGFloat, bottom: CGFloat) { (slot.minY - scroll.minY, scroll.maxY - slot.maxY) }
}

// An SVG color ("#ac9d79", splogo.h's).
private func svgColor(_ hex: String) -> Color {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

// The logo: the icon's medallion and S (splogo.h; the S parsed by spstart.m's sp_logo_s), filling its square.
// The design frames the icon's 1024-unit art at 112…912, so the medallion's ring nearly touches the edges.
private struct Emblem: View {
    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / 800
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -112, y: -112)
            let logoGold = svgColor(SP_LOGO_GOLD)
            ctx.fill(Path(CGRect(x: SP_LOGO_SQUARE_ORIGIN, y: SP_LOGO_SQUARE_ORIGIN,
                                 width: SP_LOGO_SQUARE_SIDE, height: SP_LOGO_SQUARE_SIDE)), with: .color(logoGold))
            let r = SP_LOGO_DISC_RADIUS
            let disc = Path(ellipseIn: CGRect(x: SP_LOGO_DISC_CENTER - r, y: SP_LOGO_DISC_CENTER - r, width: 2 * r, height: 2 * r))
            ctx.fill(disc, with: .color(svgColor(SP_LOGO_DISC_FILL)))
            ctx.stroke(disc, with: .color(logoGold), lineWidth: SP_LOGO_RING_WIDTH)  // centered on the radius, as SVG's
            ctx.fill(Path(sp_logo_s().cgPath), with: .color(logoGold))
        }
        .accessibilityHidden(true)
    }
}

// The logo with the two faint rings around it (1.7 and 2.6 times its size, the outer at 60%) and the
// SLASHPLAYED line. The rings pass behind the line and past the window's edges, as in the design, and take
// no room in the layout.
private struct Header: View {
    let emblem: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let small = spFace(14, .footnote, 24, typeSize)
        VStack(spacing: 20) {  // the design's 14 below the logo, and the line's own leading
            Emblem()
                .frame(width: emblem, height: emblem)
                .background {
                    // CSS's 1 px border on a box of 1.7 (2.6) times the logo: inside the box.
                    ZStack {
                        Circle().strokeBorder(gold.opacity(0.22), lineWidth: 1)
                            .frame(width: (emblem * 2.6).rounded(), height: (emblem * 2.6).rounded())
                            .opacity(0.6)
                        Circle().strokeBorder(gold.opacity(0.22), lineWidth: 1)
                            .frame(width: (emblem * 1.7).rounded(), height: (emblem * 1.7).rounded())
                    }
                    .allowsHitTesting(false)
                }
            Text("SLASHPLAYED")
                .font(Font(small as CTFont))
                .kerning(3.5 * small.pointSize / 14)
                .foregroundStyle(gold)
                .fixedSize()
                // The screen's heading, spelled out (as written, it'd be read letter by letter).
                .accessibilityLabel("Slashplayed")
                .accessibilityAddTraits(.isHeader)
        }
        .fixedSize()
    }
}

// The window's safe area (UIKit's: the host lays SwiftUI out over the whole window, StartHost), and the
// games and what a tap or the gear does with them.
private final class StartModel: ObservableObject {
    @Published var safe = UIEdgeInsets.zero
    let flavors: [String]
    let pick: (String) -> Void
    weak var host: UIViewController?

    init(flavors: [String], pick: @escaping (String) -> Void) {
        self.flavors = flavors
        self.pick = pick
    }

    // The Settings sheet (spsettings.swift), opening in `drill`'s state when one is given ($SP_START_DRILL).
    func openSettings(_ drill: String?) {
        guard let host, host.presentedViewController == nil else { return }
        host.present(sp_settings_sheet(flavors, drill), animated: drill == nil)
    }
}

private struct StartView: View {
    @ObservedObject var model: StartModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var logo = CGSize.zero  // the header's size, as last laid out
    @State private var games: CGFloat = 0  // the games' height at the column's width, as last laid out
    @State private var position = ScrollPosition(edge: .top)
    @State private var dragging = false
    @State private var flash = 0  // the games' scroll indicators, once
    @State private var flashed = false

    var body: some View {
        GeometryReader { geo in
            let window = geo.size
            let layout = StartLayout(window: window, safe: model.safe, big: typeSize.isAccessibilitySize, header: logo, games: games)
            ZStack(alignment: .topLeading) {
                Header(emblem: StartLayout.emblem(window))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { logo = $0 }
                    .offset(x: layout.header.minX, y: layout.header.minY)
                gameList(layout)
                gear.offset(x: layout.gear.x, y: layout.gear.y)
            }
            .frame(width: window.width, height: window.height, alignment: .topLeading)
            // The rest, from what's measured after the layout (the header's and the games' sizes), not
            // before: kept, with the scroll position, while a drag is under way; else the games go back to
            // resting at the top of their slot, as they would at the first layout.
            .onChange(of: layout) { _, _ in
                if !dragging { position.scrollTo(edge: .top) }
                // Show that the games scroll, once they've been laid out shorter than they are.
                if !flashed, layout.slot.height > 0, games > layout.slot.height + 1 {
                    flashed = true
                    flash += 1
                }
            }
        }
        .background(ground)
    }

    private func gameList(_ layout: StartLayout) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(model.flavors, id: \.self) { flavor in
                    Button(sp_flavor_name(flavor)) { model.pick(flavor) }
                        .buttonStyle(GameButtonStyle(height: 66))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { games = $0 }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.always)  // it gives under a drag even when every game fits, as lists do
        .contentMargins(.top, layout.rest.top, for: .scrollContent)
        .contentMargins(.bottom, layout.rest.bottom, for: .scrollContent)
        .contentMargins(.top, layout.rest.top, for: .scrollIndicators)
        .contentMargins(.bottom, layout.rest.bottom, for: .scrollIndicators)
        .scrollIndicatorsFlash(trigger: flash)
        .onScrollPhaseChange { _, phase in dragging = phase == .interacting }
        .frame(width: layout.scroll.width, height: layout.scroll.height)
        .offset(x: layout.scroll.minX, y: layout.scroll.minY)
    }

    // The gear: a gold-framed square, a fixed 44 points, so the symbol doesn't grow with the text size; a
    // long press shows it large instead (the Large Content Viewer).
    private var gear: some View {
        Button { model.openSettings(nil) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .regular))
                .imageScale(.large)  // UIButtonConfiguration's, which the gear was drawn with
                .foregroundStyle(gold)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(gold, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 4))
        .hoverEffect()
        .accessibilityLabel("Settings")
        .accessibilityShowsLargeContentViewer { Label("Settings", systemImage: "gearshape") }
    }
}

// Its controller: full screen, pinned Dark (as every launcher screen, so the sheet's stock controls and the
// status bar suit the dark ground; a full-screen screen takes its traits from the window, not from the root,
// so each pins itself), and laid out over the whole window: StartLayout keeps the safe area's margins itself,
// from UIKit's insets, as the design's numbers say.
private final class StartHost: UIHostingController<StartView> {
    let model: StartModel

    init(model: StartModel) {
        self.model = model
        _ = sp_face(1, .body, 1, UITraitCollection.current)  // registers Goodmountain for this process
        super.init(rootView: StartView(model: model))
        safeAreaRegions = []
        overrideUserInterfaceStyle = .dark
        modalPresentationStyle = .fullScreen
        model.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if model.safe != view.safeAreaInsets { model.safe = view.safeAreaInsets }
    }
}

// spstart.m's: the screen for `flavors` (flavors.plist's order); `pick` gets the one tapped (each tap: it
// keeps the first).
@_cdecl("sp_start_screen")
public func startScreen(_ flavors: NSArray, _ pick: @escaping @convention(block) (NSString) -> Void) -> UIViewController {
    StartHost(model: StartModel(flavors: flavors.compactMap { $0 as? String }, pick: { pick($0 as NSString) }))
}

// spstart.m's, for $SP_START_DRILL: the Settings sheet over the screen, in `drill`'s state.
@_cdecl("sp_start_settings")
public func startSettings(_ screen: UIViewController, _ drill: NSString) {
    (screen as? StartHost)?.model.openSettings(drill as String)
}
