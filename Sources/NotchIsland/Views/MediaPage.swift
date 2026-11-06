import AppKit
import SwiftUI

/// The Media page: current player, or a placeholder.
struct MediaPage: View {
    @ObservedObject var media: NowPlayingService

    var body: some View {
        Group {
            if let current = media.current {
                PlayerView(media: media, info: current)
                    .id(current.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                            removal: .opacity.combined(with: .offset(x: -24))))
            } else {
                PagePlaceholder(symbol: "music.note", text: "Nothing playing")
            }
        }
        .animation(islandSpring, value: media.current?.id)
    }
}

/// App icons for switching players (Spotify, Chrome, …); tap one to show it.
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
                    .frame(height: 22)
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
                HStack(alignment: .top, spacing: 8) {
                    Text(info.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if media.players.count > 1 { PlayerTabs(media: media) }
                }
                Text([info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " – "))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                ProgressRow(info: info, canSeek: media.canSeek(info)) { media.seek(to: $0) }
                    .padding(.top, 4)

                HStack(spacing: 10) {
                    ControlButton(symbol: "backward.end.fill", size: 14) { media.send(.previous) }
                        .help("Previous")
                    ControlButton(symbol: "gobackward.10", size: 15) { media.send(.skipBack) }
                        .help("Back 10 seconds")
                    ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.send(.toggle) }
                    ControlButton(symbol: "goforward.10", size: 15) { media.send(.skipForward) }
                        .help("Forward 10 seconds")
                    ControlButton(symbol: "forward.end.fill", size: 14) { media.send(.next) }
                        .help("Next")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ProgressRow: View {
    let info: NowPlaying
    var canSeek = false
    var onSeek: (Double) -> Void = { _ in }

    @State private var hovering = false
    @State private var scrub: Double?   // 0…1 while dragging

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = info.currentElapsed(at: ctx.date)
            let live = info.duration > 0 ? elapsed / info.duration : 0
            let fraction = min(1, max(0, scrub ?? live))
            let active = canSeek && (hovering || scrub != nil)
            HStack(spacing: 8) {
                Text(format(scrub.map { $0 * info.duration } ?? elapsed))
                    .foregroundStyle(scrub != nil ? .white : .white.opacity(0.5))
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                            .frame(height: active ? 7 : 4)
                        Capsule().fill(.white.opacity(0.9))
                            .frame(width: max(0, w * fraction), height: active ? 7 : 4)
                        if active {
                            Circle().fill(.white)
                                .frame(width: 13, height: 13)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .offset(x: min(max(0, w * fraction - 6.5), w - 13))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard canSeek, w > 0 else { return }
                            scrub = min(1, max(0, g.location.x / w))
                        }
                        .onEnded { g in
                            guard canSeek, w > 0 else { return }
                            let f = min(1, max(0, g.location.x / w))
                            onSeek(f * info.duration)
                            // Keep the knob where you dropped it until the player catches up.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scrub = nil }
                        })
                }
                .frame(height: 14)
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
                Text(info.duration > 0 ? format(info.duration) : "--:--")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .animation(scrub == nil ? .linear(duration: 0.5) : nil, value: fraction)
            .animation(.easeOut(duration: 0.15), value: active)
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

