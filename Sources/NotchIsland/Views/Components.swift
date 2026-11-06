import AppKit
import SwiftUI

/// Large battery outline whose green fill grows, with a light sweep across it.
struct BigBattery: View {
    let fill: CGFloat
    var color: Color = .green
    var showBolt = true

    var body: some View {
        HStack(spacing: 3) {
            GeometryReader { geo in
                let inner = geo.size.width - 8
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(inner * fill, 6))
                        .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)))
                        .padding(4)
                        .shadow(color: color.opacity(0.6), radius: 8)
                    if showBolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(maxWidth: .infinity)
                        .symbolEffect(.bounce, options: .repeat(2).speed(0.8), value: fill > 0)
                    }
                }
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.35))
                .frame(width: 4, height: 14)
        }
    }
}

/// A soft white highlight that sweeps left to right forever.
struct Shimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.5)
                .offset(x: phase * geo.size.width)
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false).delay(0.6)) {
                        phase = 1.2
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Small pieces

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 18, height: size + 14)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let bundleId: String?
    let size: CGFloat
    let corner: CGFloat
    let showBadge: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if let icon = appIcon(bundleId) {
                    Image(nsImage: icon).resizable().padding(size * 0.12)
                } else {
                    Image(systemName: "music.note").font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            if showBadge, image != nil, let icon = appIcon(bundleId) {
                Image(nsImage: icon).resizable()
                    .frame(width: size * 0.36, height: size * 0.36)
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
    }
}

struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: isPlaying ? 4 + 10 * CGFloat((phase + 1) / 2) : 3)
                }
            }
            .animation(.easeInOut(duration: 1 / 12), value: t)
        }
    }
}

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        let color: Color = charging ? .green : (percent <= 20 ? .red : .white)
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).stroke(.white.opacity(0.5), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, 19 * CGFloat(min(percent, 100)) / 100))
                    .padding(1.5)
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.5)).frame(width: 1.5, height: 4)
        }
    }
}

// MARK: - App helpers

@MainActor private var iconCache: [String: NSImage] = [:]

@MainActor func appIcon(_ bundleId: String?) -> NSImage? {
    guard let bundleId else { return nil }
    if let cached = iconCache[bundleId] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    iconCache[bundleId] = icon
    return icon
}

@MainActor func appName(_ bundleId: String?) -> String? {
    guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

@MainActor func openSource(_ bundleId: String?) {
    guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

struct RingProgress: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}

struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color).frame(width: max(0, geo.size.width * min(1, max(0, value))))
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white.opacity(hover ? 1 : 0.9)
                                                     : Color.white.opacity(hover ? 0.22 : 0.14)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PagePlaceholder: View {
    let symbol: String
    let text: String
    var detail: String? = nil
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            if let action { PillButton(title: action.title, action: action.run).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
