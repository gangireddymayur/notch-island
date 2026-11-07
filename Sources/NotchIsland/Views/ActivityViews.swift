import AppKit
import SwiftUI

/// Picks the right card for an activity.
struct ActivityView: View {
    @ObservedObject var model: NotchViewModel
    let activity: Activity

    var body: some View {
        let n = model.notchSize
        switch activity.kind {
        case .charging:
            ChargingCardView(battery: model.battery, notchHeight: n.height)
        case .lowBattery(let p):
            BatteryAlertCard(percent: p, full: false, notchHeight: n.height)
        case .fullyCharged:
            BatteryAlertCard(percent: 100, full: true, notchHeight: n.height)
        case .notification(let note):
            NotificationCard(note: note, notchHeight: n.height) { model.dismissActivity() }
        case .bluetooth(let e):
            BluetoothCard(event: e, notchHeight: n.height)
        case .hud(let kind, let level, let muted):
            HUDView(kind: kind, level: level, muted: muted, notchWidth: n.width, height: n.height)
        case .timerDone(let label):
            TimerDoneCard(label: label, notchHeight: n.height,
                          onMore: { model.timer.start(minutes: 5, label: label); model.dismissActivity() },
                          onDone: { model.dismissActivity() })
        case .meeting(let e):
            MeetingCard(event: e, notchHeight: n.height) { model.dismissActivity() }
        case .headsetCharging(let h):
            HeadsetChargingCard(headset: h, notchHeight: n.height)
        }
    }
}

/// Shared layout for drop-down cards: a row beside the notch, then content.
struct CardScaffold<Content: View>: View {
    let notchHeight: CGFloat
    var topLeft: AnyView = AnyView(EmptyView())
    var topRight: AnyView = AnyView(EmptyView())
    @ViewBuilder let content: Content
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                topLeft.padding(.leading, 18)
                Spacer()
                topRight.padding(.trailing, 18)
            }
            .frame(height: notchHeight)
            content
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
                .padding(.bottom, 6)
                .offset(y: appeared ? 0 : 6)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.1)) { appeared = true } }
    }
}

// MARK: - Battery

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
                BigBattery(fill: fill, color: .green, showBolt: true)
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
        let steps = target - shownPercent
        guard steps > 0 else { return }
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 1.1 * Double(i) / Double(steps)) {
                withAnimation(.snappy(duration: 0.18)) { shownPercent = min(shownPercent + 1, target) }
            }
        }
    }
}

struct BatteryAlertCard: View {
    let percent: Int
    let full: Bool
    let notchHeight: CGFloat
    @State private var fill: CGFloat = 0

    var body: some View {
        let color: Color = full ? .green : (percent <= 10 ? .red : .orange)
        CardScaffold(notchHeight: notchHeight,
                     topLeft: AnyView(Image(systemName: full ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                        .symbolEffect(.pulse, options: .repeating))) {
            HStack(spacing: 16) {
                BigBattery(fill: fill, color: color, showBolt: false)
                    .frame(width: 80, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(full ? "Fully Charged" : "Low Battery")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(full ? "You can unplug your Mac" : "Plug in soon")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1).delay(0.2)) { fill = CGFloat(percent) / 100 } }
    }
}

/// Logitech headset plugged in to charge (or just finished charging).
struct HeadsetChargingCard: View {
    let headset: LogitechHeadsetService.Headset
    let notchHeight: CGFloat

    @State private var fill: CGFloat = 0
    @State private var shown = 0
    @State private var appeared = false
    @State private var bounce = 0

    private var target: Int { headset.full ? 100 : (headset.percent ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                    .padding(.leading, 18)
                Spacer()
                Image(systemName: "headphones")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.trailing, 18)
            }
            .frame(height: notchHeight)

            HStack(spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "headphones")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: bounce)
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.black, .green)
                        .offset(x: 6, y: 4)
                }
                .frame(width: 52)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(headset.full ? "Fully Charged" : "Charging")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(headset.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    BigBattery(fill: fill, color: .green, showBolt: false)
                        .frame(width: 150, height: 22)
                }
                .offset(y: appeared ? 0 : 8)
                .opacity(appeared ? 1 : 0)

                Spacer(minLength: 0)

                Text("\(shown)%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(shown)))
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 6)
        }
        .onAppear {
            shown = max(target - 20, 0)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.1)) { appeared = true }
            withAnimation(.easeOut(duration: 1.2).delay(0.2)) { fill = CGFloat(target) / 100 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { bounce += 1 }
            let steps = target - shown
            guard steps > 0 else { return }
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 1.0 * Double(i) / Double(steps)) {
                    withAnimation(.snappy(duration: 0.18)) { shown = min(shown + 1, target) }
                }
            }
        }
    }
}

// MARK: - Notification

struct NotificationCard: View {
    let note: IslandNotification
    let notchHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        CardScaffold(notchHeight: notchHeight,
                     topLeft: AnyView(Text(note.appName ?? "Notification")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1)),
                     topRight: AnyView(Text("now").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)))) {
            Button {
                if let url = note.appURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                onClose()
            } label: {
                HStack(spacing: 14) {
                    Group {
                        if let url = note.appURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                        } else {
                            Image(systemName: "bell.badge.fill").resizable().scaledToFit().padding(8)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if !note.body.isEmpty {
                            Text(note.body)
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Bluetooth

struct BluetoothCard: View {
    let event: BluetoothEvent
    let notchHeight: CGFloat
    @State private var bounce = false

    var body: some View {
        CardScaffold(notchHeight: notchHeight,
                     topLeft: AnyView(Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.blue))) {
            HStack(spacing: 16) {
                Image(systemName: event.symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: bounce)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(event.note ?? (event.connected ? (event.charging ? "Connected \u{00B7} Charging" : "Connected")
                                                         : "Turned off"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(event.note != nil ? .orange : (event.connected ? .green : .white.opacity(0.5)))
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let v = event.left { BatteryChip(label: "L", value: v) }
                    if let v = event.right { BatteryChip(label: "R", value: v) }
                    if let v = event.caseLevel { BatteryChip(label: "Case", value: v) }
                    if event.left == nil, event.right == nil, let v = event.single { BatteryChip(label: nil, value: v) }
                }
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { bounce.toggle() } }
    }
}

struct BatteryChip: View {
    let label: String?
    let value: Int
    var body: some View {
        VStack(spacing: 3) {
            RingProgress(progress: Double(value) / 100, color: value <= 20 ? .red : .green, lineWidth: 3)
                .frame(width: 28, height: 28)
                .overlay(Text("\(value)").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white))
            if let label {
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Volume / brightness HUD (wings)

struct HUDView: View {
    let kind: HUDKind
    let level: Float
    let muted: Bool
    let notchWidth: CGFloat
    let height: CGFloat   // hardware notch height

    @State private var bump = 0
    @State private var appeared = false

    private var value: Double { muted ? 0 : Double(min(1, max(0, level))) }
    private var percent: Int { Int((value * 100).rounded()) }

    private var gradient: LinearGradient {
        switch kind {
        case .brightness:
            return LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.25), Color(red: 1.0, green: 0.55, blue: 0.15)],
                                  startPoint: .leading, endPoint: .trailing)
        case .volume:
            return LinearGradient(colors: [.white.opacity(0.85), .white], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var glow: Color { kind == .brightness ? .orange : .white }

    private var symbol: String {
        switch kind {
        case .brightness: return value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || value == 0 { return "speaker.slash.fill" }
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: height)   // row beside the hardware notch
            HStack(spacing: 14) {
                Image(systemName: symbol, variableValue: kind == .volume ? value : 1)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(muted ? AnyShapeStyle(Color.white.opacity(0.45)) : AnyShapeStyle(gradient))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bump)
                    .frame(width: 30)

                // Level bar with 16 steps (one per key press).
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(gradient)
                            .frame(width: max(value > 0 ? 10 : 0, w * value))
                            .shadow(color: glow.opacity(muted ? 0 : 0.55), radius: 6)
                            .opacity(muted ? 0.35 : 1)
                        HStack(spacing: 0) {
                            ForEach(1..<16, id: \.self) { _ in
                                Spacer(minLength: 0)
                                Rectangle().fill(.black.opacity(0.28)).frame(width: 1.5)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                .scaleEffect(x: appeared ? 1 : 0.6, y: 1, anchor: .leading)

                Text(muted ? "Muted" : "\(percent)%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(muted ? 0.5 : 0.95))
                    .contentTransition(.numericText(value: value))
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
            .opacity(appeared ? 1 : 0)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: value)
        .animation(.easeOut(duration: 0.2), value: muted)
        .onChange(of: level) { _, _ in bump += 1 }
        .onChange(of: muted) { _, _ in bump += 1 }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.06)) { appeared = true }
        }
    }
}

// MARK: - Timer & meeting

struct TimerDoneCard: View {
    let label: String
    let notchHeight: CGFloat
    let onMore: () -> Void
    let onDone: () -> Void
    @State private var ring = false

    var body: some View {
        CardScaffold(notchHeight: notchHeight,
                     topLeft: AnyView(Image(systemName: "timer").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange))) {
            HStack(spacing: 16) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                    .symbolEffect(.bounce, options: .repeat(3), value: ring)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Time's up").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                PillButton(title: "+5 min", action: onMore)
                PillButton(title: "Done", prominent: true, action: onDone)
            }
        }
        .onAppear { ring.toggle() }
    }
}

struct MeetingCard: View {
    let event: CalendarEvent
    let notchHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        CardScaffold(notchHeight: notchHeight,
                     topLeft: AnyView(Image(systemName: "calendar").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(nsColor: event.color)))) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 4, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("Starts \(relativeStart(event.start)) · \(event.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                if let url = event.joinURL {
                    PillButton(title: "Join", prominent: true) { NSWorkspace.shared.open(url); onClose() }
                }
            }
        }
    }
}
