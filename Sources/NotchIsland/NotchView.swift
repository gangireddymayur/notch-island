import AppKit
import SwiftUI

let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

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
        return ZStack(alignment: .top) {
            NotchShape(topRadius: NotchViewModel.earRadius, bottomRadius: model.bottomRadius)
                .fill(Color.black)
                .shadow(color: .black.opacity(model.mode == .expanded ? 0.45 : 0), radius: 16, y: 6)

            content
                .padding(.horizontal, NotchViewModel.earRadius)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
        .frame(width: size.width, height: size.height)
        .animation(islandSpring, value: model.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .closed:
            Color.clear
        case .music:
            CompactMusicView(media: model.media, notchWidth: model.notchSize.width, height: model.notchSize.height)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        case .charging:
            ChargingCardView(battery: model.battery, notchHeight: model.notchSize.height)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        case .expanded:
            ExpandedView(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }
}

// MARK: - Compact states (wings beside the notch)

struct CompactMusicView: View {
    @ObservedObject var media: NowPlayingService
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let shown = (media.current?.isPlaying == true ? media.current : nil) ?? media.players.first { $0.isPlaying }
        HStack(spacing: 0) {
            ArtworkView(image: shown?.artwork, bundleId: shown?.bundleId, size: height - 10, corner: 6, showBadge: false)
                .padding(.leading, 6)
                .id(shown?.id)
                .transition(.opacity)
            Spacer(minLength: notchWidth)
            EqualizerView(isPlaying: shown?.isPlaying ?? false, color: .accentColor)
                .frame(width: 18, height: 14)
                .padding(.trailing, 10)
        }
        .frame(height: height)
    }
}

/// Shown for a few seconds after plugging in: the island drops open and a
/// battery fills up while the percentage counts up.
struct ChargingCardView: View {
    @ObservedObject var battery: BatteryService
    let notchHeight: CGFloat

    @State private var fill: CGFloat = 0
    @State private var shownPercent = 0
    @State private var appeared = false

    private var state: BatteryState { battery.state }
    private var full: Bool { state.percent >= 100 }

    var body: some View {
        VStack(spacing: 0) {
            // Row beside the hardware notch.
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                    .padding(.leading, 18)
                Spacer()
                BatteryGlyph(percent: state.percent, charging: true)
                    .padding(.trailing, 18)
            }
            .frame(height: notchHeight)

            HStack(spacing: 16) {
                BigBattery(fill: fill)
                    .frame(width: 86, height: 40)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(full ? "Fully Charged" : "Charging")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .offset(y: appeared ? 0 : 8)
                .opacity(appeared ? 1 : 0)

                Spacer(minLength: 0)

                Text("\(shownPercent)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .contentTransition(.numericText(value: Double(shownPercent)))
                    .monospacedDigit()
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 6)
        }
        .onAppear(perform: animateIn)
    }

    private var subtitle: String {
        // Right after plugging in, macOS briefly reports "not charging" and has no
        // time estimate yet, so only show the time once macOS actually knows it.
        if !full, state.isCharging, let m = state.minutesToFull {
            return m >= 60 ? "Full in \(m / 60) h \(m % 60) min" : "Full in \(m) min"
        }
        return "Power adapter connected"
    }

    private func animateIn() {
        let target = state.percent
        shownPercent = max(target - 20, 0)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.12)) { appeared = true }
        withAnimation(.easeOut(duration: 1.3).delay(0.2)) { fill = CGFloat(target) / 100 }
        // Count the number up in small steps so the digits roll.
        let steps = target - shownPercent
        guard steps > 0 else { return }
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 1.1 * Double(i) / Double(steps)) {
                withAnimation(.snappy(duration: 0.18)) { shownPercent = min(shownPercent + 1, target) }
            }
        }
    }
}

/// Large battery outline whose green fill grows, with a light sweep across it.
struct BigBattery: View {
    let fill: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            GeometryReader { geo in
                let inner = geo.size.width - 8
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.85, blue: 0.4),
                                                      Color(red: 0.45, green: 1.0, blue: 0.55)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(inner * fill, 6))
                        .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)))
                        .padding(4)
                        .shadow(color: .green.opacity(0.6), radius: 8)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(maxWidth: .infinity)
                        .symbolEffect(.bounce, options: .repeat(2).speed(0.8), value: fill > 0)
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

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        let media = model.media
        VStack(spacing: 0) {
            // Top row lives beside the hardware notch.
            HStack {
                Group {
                    if media.players.count > 1 {
                        PlayerTabs(media: media)
                    } else {
                        Text(appName(media.current?.bundleId) ?? "Notch Island")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.leading, 18)
                Spacer(minLength: model.notchSize.width)
                HStack(spacing: 5) {
                    Text("\(model.battery.state.percent)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.battery.state.onAC ? .green : .white.opacity(0.8))
                    BatteryGlyph(percent: model.battery.state.percent, charging: model.battery.state.onAC)
                }
                .padding(.trailing, 18)
            }
            .frame(height: model.notchSize.height)

            if let current = media.current {
                PlayerView(media: media, info: current)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .id(current.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                            removal: .opacity.combined(with: .offset(x: -24))))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .animation(islandSpring, value: media.current?.id)
    }
}

/// App icons beside the notch; tap one to show that player.
struct PlayerTabs: View {
    @ObservedObject var media: NowPlayingService
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(media.players) { p in
                let selected = p.id == media.current?.id
                Button { media.select(p.id) } label: {
                    HStack(spacing: 4) {
                        if let icon = appIcon(p.bundleId) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        if p.isPlaying {
                            EqualizerView(isPlaying: true, color: .white.opacity(0.8))
                                .frame(width: 12, height: 10)
                                .scaleEffect(0.75)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background {
                        if selected {
                            Capsule().fill(.white.opacity(0.16))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .opacity(selected ? 1 : 0.55)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(appName(p.bundleId) ?? p.bundleId)
            }
        }
        .animation(islandSpring, value: media.current?.id)
    }
}

struct PlayerView: View {
    @ObservedObject var media: NowPlayingService
    let info: NowPlaying

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { openSource(info.bundleId) } label: {
                ArtworkView(image: info.artwork, bundleId: info.bundleId, size: 76, corner: 14, showBadge: true)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " – "))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                ProgressRow(info: info)
                    .padding(.top, 4)

                HStack(spacing: 26) {
                    ControlButton(symbol: "backward.fill", size: 16) { media.send(.previous) }
                    ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.send(.toggle) }
                    ControlButton(symbol: "forward.fill", size: 16) { media.send(.next) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ProgressRow: View {
    let info: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = info.currentElapsed(at: ctx.date)
            let fraction = info.duration > 0 ? elapsed / info.duration : 0
            HStack(spacing: 8) {
                Text(format(elapsed))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
                Text(info.duration > 0 ? format(info.duration) : "--:--")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .animation(.linear(duration: 0.5), value: fraction)
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
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
