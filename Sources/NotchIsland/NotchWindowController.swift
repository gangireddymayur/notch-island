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
        // Without this, mouse-moved events stop arriving once the pointer is
        // over the island, and the hover could be missed.
        acceptsMouseMovedEvents = true
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
    private var hoverPoll: Timer?
    private var lastPointer = NSPoint.zero

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
        // Watch for files being dragged toward the notch (opens the shelf).
        let down: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in down(e); return e }) {
            monitors.append(l)
        }
        // Backup: a cheap 10×/s pointer check so a fast flick to the top
        // edge is never missed, even if an event gets lost.
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = self.screen else { return }
                let p = NSEvent.mouseLocation
                guard p != self.lastPointer else { return }
                self.lastPointer = p
                // Only matters near the top of the screen or while the island is open.
                if p.y > screen.frame.maxY - 260 || self.model.isHovering { self.mouseMoved() }
            }
        }
        hoverPoll?.tolerance = 0.05
        // Desktop swipes hide and re-show this window; replay the wings.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, (n.object as? NSWindow) === p else { return }
                if p.occlusionState.contains(.visible) { self.model.windowShown() } else { self.model.windowHidden() }
            }
        }
        model.$mode.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateMouseCapture()
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

    /// The island's current outline in screen coordinates.
    private func shapeRect() -> NSRect {
        guard let screen else { return .zero }
        let size = model.shapeSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Where the pointer opens the island: the notch strip (plus any wings).
    private func hoverTriggerRect() -> NSRect {
        guard let screen else { return .zero }
        if model.mode == .expanded { return shapeRect().insetBy(dx: -4, dy: -4) }
        // Exactly the visible black shape (wings included) — no invisible
        // margin, so passing near the island doesn't open it.
        let visibleWidth = model.isDropDown ? model.notchSize.width : max(model.notchSize.width, model.shapeSize.width)
        let width = visibleWidth + (model.mode == .closed ? 6 : 0)
        let height = model.notchSize.height + 2
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// The panel only takes clicks inside the island; everywhere else they
    /// pass straight through to the apps underneath.
    private func updateMouseCapture() {
        let inside = shapeRect().insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        let capture = model.mode != .closed && (inside || model.isDraggingFile)
        if panel?.ignoresMouseEvents == capture { panel?.ignoresMouseEvents = !capture }
    }

    // MARK: Swipe between players

    private var swipeAccum: CGFloat = 0
    private var swipeLocked = false

    private func handleScroll(_ e: NSEvent) {
        guard model.settings.swipeToSwitch, model.mode == .expanded, model.page == .media,
              e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began { swipeAccum = 0; swipeLocked = false }
        guard !swipeLocked, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        swipeAccum += e.scrollingDeltaX
        if abs(swipeAccum) > 50 {
            swipeLocked = true   // one switch per gesture
            model.media.selectNext(offset: swipeAccum < 0 ? 1 : -1)
            model.haptic()
        }
    }

    // MARK: Hover

    private var openWork: DispatchWorkItem?

    private func open() {
        openWork?.cancel(); openWork = nil
        guard !model.isHovering else { return }
        model.isHovering = true
        model.haptic()
    }

    private func mouseMoved() {
        updateMouseCapture()
        guard !model.isDraggingFile else { return }
        if hoverTriggerRect().contains(NSEvent.mouseLocation) {
            collapseWork?.cancel()
            collapseWork = nil
            // With "click to open" the pointer alone never opens the island.
            guard !model.isHovering, !model.settings.expandOnClick, openWork == nil else { return }
            let delay = model.settings.hoverDelay.seconds
            if delay == 0 { open(); return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.openWork = nil
                if self.hoverTriggerRect().contains(NSEvent.mouseLocation) { self.open() }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            openWork?.cancel(); openWork = nil
            if model.isHovering, collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.model.isHovering = false
                    self?.collapseWork = nil
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }
    }

    // MARK: File drag → shelf

    private var dragPoll: Timer?
    private var dragChangeCount = 0

    private func mouseDown() {
        if model.settings.expandOnClick, !model.isHovering, hoverTriggerRect().contains(NSEvent.mouseLocation) {
            open()
        }
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        dragPoll?.invalidate()
        dragPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
    }

    private func pollDrag() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown {
            dragPoll?.invalidate(); dragPoll = nil
            if model.isDraggingFile {
                // Give the drop a moment to land before closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.model.isDraggingFile = false
                    self?.updateMouseCapture()
                }
            }
            return
        }
        guard model.settings.shelfEnabled, let screen else { return }
        let pb = NSPasteboard(name: .drag)
        // Files, plus "promised" files like the floating screenshot preview.
        let fileLike: [NSPasteboard.PasteboardType] = [
            .fileURL, .png, .tiff,
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("public.jpeg"),
        ]
        guard pb.changeCount != dragChangeCount,
              let types = pb.types, types.contains(where: fileLike.contains) else { return }

        let p = NSEvent.mouseLocation
        let near = NSRect(x: screen.frame.midX - 200, y: screen.frame.maxY - model.notchSize.height - 40,
                          width: 400, height: model.notchSize.height + 40)
        if !model.isDraggingFile, near.contains(p) {
            model.isDraggingFile = true
            model.haptic()
            panel?.ignoresMouseEvents = false
        } else if model.isDraggingFile, !shapeRect().insetBy(dx: -60, dy: -60).contains(p) {
            model.isDraggingFile = false
        }
    }
}
