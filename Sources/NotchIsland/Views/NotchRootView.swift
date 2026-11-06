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
        return ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.isDropDown ? 0.4 : 0), radius: 12, y: 5)

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
                .transition(a.kind.isHUD ? wingTransition : islandContentTransition)
        case .expanded:
            ExpandedView(model: model)
                .transition(islandContentTransition)
        }
    }
}
