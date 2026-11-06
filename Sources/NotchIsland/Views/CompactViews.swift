import AppKit
import SwiftUI

// Wings beside the notch: left side + (notch) + right side.

struct CompactMusicView: View {
    @ObservedObject var media: NowPlayingService
    let shown: NowPlaying?
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: shown?.artwork, bundleId: shown?.bundleId, size: height - 10, corner: 6, showBadge: false)
                .wing(.left)
                .padding(.leading, 4)
            Spacer(minLength: notchWidth)
            EqualizerView(isPlaying: shown?.isPlaying ?? false, color: AppSettings.shared.accent.color)
                .frame(width: 18, height: 14)
                .wing(.right)
                .padding(.trailing, 6)
        }
        .frame(height: height)
    }
}

struct CompactTimerView: View {
    @ObservedObject var timer: TimerService
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    RingProgress(progress: timer.progress, color: .orange, lineWidth: 2.5)
                        .frame(width: 16, height: 16)
                    Text(timer.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .wing(.left)
                .padding(.leading, 12)
                Spacer(minLength: notchWidth)
                Text(formatClock(timer.remaining(at: ctx.date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timer.isRunning ? .orange : .white.opacity(0.5))
                    .wing(.right)
                    .padding(.trailing, 12)
            }
            .frame(height: height)
        }
    }
}

struct CompactMeetingView: View {
    @ObservedObject var calendar: CalendarService
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: calendar.soonEvent?.color ?? .systemBlue)).frame(width: 7, height: 7)
                    Image(systemName: "calendar").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .wing(.left)
                .padding(.leading, 12)
                Spacer(minLength: notchWidth)
                Text(calendar.soonEvent.map { relativeStart($0.start, now: ctx.date) } ?? "")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: calendar.soonEvent?.color ?? .systemBlue))
                    .wing(.right)
                    .padding(.trailing, 12)
            }
            .frame(height: height)
        }
    }
}

func relativeStart(_ start: Date, now: Date = Date()) -> String {
    let mins = Int((start.timeIntervalSince(now) / 60).rounded(.up))
    if mins <= 0 { return "now" }
    if mins < 60 { return "in \(mins)m" }
    return "in \(mins / 60)h \(mins % 60)m"
}

func formatClock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Wing content grows out from behind the camera: it starts tucked toward
/// the notch, small and blurred, and springs outward as the island widens.
struct WingReveal: ViewModifier {
    enum Side { case left, right }
    let side: Side
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(x: shown ? 0 : (side == .left ? 44 : -44))
            .scaleEffect(shown ? 1 : 0.4, anchor: side == .left ? .trailing : .leading)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.05)) { shown = true }
            }
    }
}

extension View {
    func wing(_ side: WingReveal.Side) -> some View { modifier(WingReveal(side: side)) }
}
