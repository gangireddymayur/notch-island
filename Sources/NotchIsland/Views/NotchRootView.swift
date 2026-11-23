import AppKit
import SwiftUI

let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

/// Content fades in after the shape has started growing, and fades out
/// almost instantly when closing — so nothing "ghosts" while the black
/// shape shrinks back into the notch.
private let islandContentTransition = AnyTransition.asymmetric(
    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        .animation(.easeOut(duration: 0.22).delay(0.08)),
    removal: .opacity.animation(.easeIn(duration: 0.07))
)

/// Wings animate their own content out of the notch (see WingReveal), so
/// they only need a quick fade + tuck when leaving.
private let wingTransition = AnyTransition.asymmetric(
    insertion: .identity,
    removal: .opacity.combined(with: .scale(scale: 0.7)).animation(.easeIn(duration: 0.12))
)

/// Black island, or Liquid Glass: the desktop blurred through the island with
/// a soft light edge. The top stays black so it still merges with the camera.
struct IslandBackground: View {
    let shape: NotchShape
    let glass: Bool
    let notchHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let top = geo.size.height > 0 ? min(0.9, notchHeight / geo.size.height) : 0.3
            ZStack {
                if glass {
                    BehindWindowBlur()
                        .clipShape(shape)
                    // Tint + black notch band fading into the glass.
                    shape.fill(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: top * 0.85),
                        .init(color: .black.opacity(0.42), location: min(1, top + 0.32)),
                        .init(color: .black.opacity(0.30), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    // Liquid highlight: a soft sheen across the upper glass.
                    shape.fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                        .mask(LinearGradient(stops: [.init(color: .clear, location: top),
                                                     .init(color: .white, location: min(1, top + 0.05))],
                                             startPoint: .top, endPoint: .bottom))
                    // Light edge, brightest along the lower curve like glass.
                    shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.18), .white.opacity(0.38)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                } else {
                    shape.fill(Color.black)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: glass)
    }
}

/// Blurs whatever is behind the window (your wallpaper and apps).
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active               // the island never becomes key; stay frosted
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var island: some View {
        let size = model.shapeSize
        let shape = NotchShape(topRadius: NotchViewModel.earRadius, bottomRadius: model.bottomRadius)
        // Liquid Glass only for the opened island and cards; the small wings
        // live in the menu bar and stay black.
        let glass = model.settings.islandStyle == .glass && model.isDropDown
        return ZStack(alignment: .top) {
            IslandBackground(shape: shape, glass: glass, notchHeight: model.notchSize.height)
                .shadow(color: .black.opacity(model.isDropDown ? (glass ? 0.3 : 0.4) : 0), radius: glass ? 18 : 12, y: 5)

            content
                .padding(.horizontal, NotchViewModel.earRadius)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)   // content can never draw outside the island
        }
        .frame(width: size.width, height: size.height)
        .animation(islandSpring, value: model.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let n = model.notchSize
        switch model.mode {
        case .closed:
            Color.clear
        case .compact(.music):
            CompactMusicView(media: model.media, shown: model.musicForWings.first, notchWidth: n.width, height: n.height)
                .transition(wingTransition)
        case .compact(.timer):
            CompactTimerView(timer: model.timer, notchWidth: n.width, height: n.height)
                .transition(wingTransition)
        case .compact(.meeting):
            CompactMeetingView(calendar: model.calendar, notchWidth: n.width, height: n.height)
                .transition(wingTransition)
        case .activity(let a):
            ActivityView(model: model, activity: a)
                .id(a.kind.isHUD ? "hud" : a.id.uuidString)
                .transition(islandContentTransition)
        case .expanded:
            ExpandedView(model: model)
                .transition(islandContentTransition)
        }
    }
}
