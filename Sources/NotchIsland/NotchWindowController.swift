import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a control work without activating the app.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController {
    private let model: NotchViewModel
    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?

    /// Window is a fixed canvas; the island animates inside it.
    private let canvas = CGSize(width: 760, height: 260)

    init(model: NotchViewModel) {
        self.model = model
    }

    func start() {
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
        // Two-finger horizontal swipe on the open island switches players.
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handleScroll(e) }
            return e
        }) {
            monitors.append(s)
        }
        model.$mode.sink { [weak self] mode in
            self?.panel?.ignoresMouseEvents = (mode != .expanded)
        }.store(in: &bag)
    }

    /// Prefer the built-in display (the one with a notch).
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        model.notchSize = Self.notchSize(on: screen)

        let frame = NSRect(x: screen.frame.midX - canvas.width / 2,
                           y: screen.frame.maxY - canvas.height,
                           width: canvas.width, height: canvas.height)
        if panel == nil {
            let p = NotchPanel(frame: frame)
            let host = ClickThroughHostingView(rootView: NotchRootView(model: model))
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            p.contentView = host
            p.orderFrontRegardless()
            panel = p
        } else {
            panel?.setFrame(frame, display: true)
        }
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: top)
        }
        // No notch (external display): a small pill under the menu bar height.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 190, height: max(menuBar, 24))
    }

    /// The area (in screen coordinates) that should react to the pointer.
    private func hotRect(for mode: IslandMode) -> NSRect {
        guard let screen else { return .zero }
        let size = mode == .expanded ? model.shapeSize : CGSize(width: max(model.shapeSize.width, model.notchSize.width) + 16,
                                                                 height: model.notchSize.height + 6)
        return NSRect(x: screen.frame.midX - size.width / 2,
                      y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private var swipeAccum: CGFloat = 0
    private var swipeLocked = false

    private func handleScroll(_ e: NSEvent) {
        guard model.mode == .expanded, e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began { swipeAccum = 0; swipeLocked = false }
        guard !swipeLocked, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        swipeAccum += e.scrollingDeltaX
        if abs(swipeAccum) > 50 {
            swipeLocked = true   // one switch per gesture
            model.media.selectNext(offset: swipeAccum < 0 ? 1 : -1)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let inside = hotRect(for: model.mode).insetBy(dx: -4, dy: -4).contains(p)
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.isHovering {
                model.isHovering = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else if model.isHovering, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.model.isHovering = false
                self?.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
}
