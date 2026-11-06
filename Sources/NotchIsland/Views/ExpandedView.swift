import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Row beside the hardware notch: page tabs left, battery right.
            HStack {
                PageTabs(model: model).padding(.leading, 14)
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

            Group {
                switch model.page {
                case .media: MediaPage(media: model.media)
                case .calendar: CalendarPage(calendar: model.calendar)
                case .shelf: ShelfPage(shelf: model.shelf, targeted: dropTargeted)
                case .timer: TimerPage(timer: model.timer)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(model.page)
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard model.settings.shelfEnabled else { return false }
            model.page = .shelf
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.shelf.add([url]) }
                }
            }
            return true
        }
    }
}

struct PageTabs: View {
    @ObservedObject var model: NotchViewModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.pages) { page in
                let selected = page == model.page
                Button {
                    model.page = page
                } label: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.45))
                        .frame(width: 30, height: 22)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "page", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(page.title)
            }
        }
        .animation(islandSpring, value: model.page)
    }
}

// MARK: - Calendar

struct CalendarPage: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        if !calendar.hasAccess {
            PagePlaceholder(symbol: "calendar.badge.exclamationmark", text: "Calendar access needed",
                            detail: "Allow Notch Island in Privacy & Security → Calendars",
                            action: ("Open Settings", { openPrivacyPane("Privacy_Calendars") }))
        } else if calendar.events.isEmpty {
            PagePlaceholder(symbol: "calendar", text: "Nothing coming up", detail: "Your next 36 hours are free")
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(spacing: 6) {
                    ForEach(calendar.events.prefix(3)) { e in
                        EventRow(event: e, now: ctx.date)
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        let live = event.start <= now && event.end > now
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(timeText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(live ? "now" : relativeStart(event.start, now: now))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(live ? .green : .white.opacity(0.6))
            if let url = event.joinURL {
                PillButton(title: "Join", prominent: live) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var timeText: String {
        let day = Calendar.current.isDateInToday(event.start) ? "" :
            (Calendar.current.isDateInTomorrow(event.start) ? "Tomorrow " : event.start.formatted(.dateTime.weekday()) + " ")
        let t = "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        return day + t + (event.location.map { " · \($0)" } ?? "")
    }
}

// MARK: - Shelf

struct ShelfPage: View {
    @ObservedObject var shelf: ShelfStore
    let targeted: Bool

    var body: some View {
        HStack(spacing: 12) {
            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.white.opacity(targeted ? 0.8 : 0.3))
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22))
                            Text("Drop files here").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.5))
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items, id: \.self) { url in ShelfTile(url: url, shelf: shelf) }
                    }
                    .padding(.vertical, 4)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(targeted ? 0.12 : 0)))
                VStack(spacing: 8) {
                    PillButton(title: "AirDrop", prominent: true) { shelf.airDrop(shelf.items) }
                    PillButton(title: "Clear") { shelf.clear() }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

struct ShelfTile: View {
    let url: URL
    @ObservedObject var shelf: ShelfStore
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 72)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { shelf.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shelf.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(url) }
            Button("Show in Finder") { shelf.reveal(url) }
            Button("AirDrop") { shelf.airDrop([url]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(url) }
        }
        .help(url.path)
    }
}

// MARK: - Timer

struct TimerPage: View {
    @ObservedObject var timer: TimerService
    private let presets: [(String, Double)] = [("Focus", 25), ("Short break", 5), ("Long break", 15), ("Deep work", 50)]

    var body: some View {
        if timer.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 18) {
                    ZStack {
                        RingProgress(progress: 1 - timer.remaining(at: ctx.date) / max(timer.total, 1),
                                     color: .orange, lineWidth: 6)
                        Image(systemName: timer.isRunning ? "timer" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(.orange)
                    }
                    .frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        Text(formatClock(timer.remaining(at: ctx.date)))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: Int(timer.remaining(at: ctx.date)))
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        PillButton(title: timer.isRunning ? "Pause" : "Resume", prominent: true) { timer.togglePause() }
                        HStack(spacing: 6) {
                            PillButton(title: "+1") { timer.add(minutes: 1) }
                            PillButton(title: "Stop") { timer.reset() }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start a timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { name, mins in
                        Button { timer.start(minutes: mins, label: name) } label: {
                            VStack(spacing: 2) {
                                Text("\(Int(mins))").font(.system(size: 22, weight: .semibold, design: .rounded))
                                Text(name).font(.system(size: 10, weight: .medium)).opacity(0.6)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 62)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}
