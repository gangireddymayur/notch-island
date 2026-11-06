import AppKit
import SwiftUI

// Wings beside the notch: left side + (notch) + right side.

struct CompactMusicView: View {
    @ObservedObject var media: NowPlayingService
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let shown = (media.current?.isPlaying == true ? media.current : nil) ?? media.players.first { $0.isPlaying }
        HStack(spacing: 0) {
            ArtworkView(image: shown?.artwork, bundleId: shown?.bundleId, size: height - 10, corner: 6, showBadge: false)
                .padding(.leading, 6)
            Spacer(minLength: notchWidth)
            EqualizerView(isPlaying: shown?.isPlaying ?? false, color: .accentColor)
                .frame(width: 18, height: 14)
                .padding(.trailing, 10)
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
                .padding(.leading, 12)
                Spacer(minLength: notchWidth)
                Text(formatClock(timer.remaining(at: ctx.date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timer.isRunning ? .orange : .white.opacity(0.5))
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
                .padding(.leading, 12)
                Spacer(minLength: notchWidth)
                Text(calendar.soonEvent.map { relativeStart($0.start, now: ctx.date) } ?? "")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: calendar.soonEvent?.color ?? .systemBlue))
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
