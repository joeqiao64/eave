import AppKit
import SwiftUI
import Quartz
import Combine
import Carbon.HIToolbox

/// Visual state of the notch.
enum NotchMode: Equatable {
    case idle      // exactly covers the hardware notch (invisible)
    case compact   // music playing / shelf has files: small wings either side
    case expanded  // hovered: full panel
}

enum NotchPage: Equatable {
    case music
    case shelf
}

/// Shared, observable layout + mode. Geometry lives here so the controller
/// (hit-testing) and the SwiftUI view (drawing) always agree.
final class NotchModel: ObservableObject {
    @Published var mode: NotchMode = .idle
    @Published var page: NotchPage = .music
    @Published var dropTargeted = false
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Width added on each side of the notch in compact mode.
    var compactWing: CGFloat { notchSize.height - 2 }
    /// Music page hugs the notch; the shelf page is a little larger so thumbnails are readable.
    func expandedSize(_ p: NotchPage) -> CGSize {
        switch p {
        case .music: return CGSize(width: notchSize.width + 130, height: notchSize.height + 66)
        case .shelf: return CGSize(width: notchSize.width + 190, height: notchSize.height + 80)
        }
    }
    /// Concave "ear" radius where the shape meets the top edge of the screen.
    func earRadius(_ m: NotchMode) -> CGFloat { m == .expanded ? 10 : 6 }
    func bottomRadius(_ m: NotchMode) -> CGFloat { m == .expanded ? 22 : 10 }

    /// Size of the black body (excluding ears).
    func bodySize(_ m: NotchMode) -> CGSize {
        switch m {
        case .idle: return notchSize
        case .compact: return CGSize(width: notchSize.width + compactWing * 2, height: notchSize.height)
        case .expanded: return expandedSize(page)
        }
    }

    /// Largest frame the shape can ever occupy; the window is fixed at this size.
    var canvasSize: CGSize {
        let a = expandedSize(.music), b = expandedSize(.shelf)
        return CGSize(width: max(a.width, b.width) + earRadius(.expanded) * 2 + 40,
                      height: max(a.height, b.height) + 30)
    }
}

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel, QLPreviewPanelDataSource {
    /// Files Space / Quick Look should show.
    var quickLookURLs: () -> [URL] = { [] }
    private var previewURLs: [URL] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Space toggles Quick Look for the selected shelf items.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 49 { toggleQuickLook(); return }
        super.sendEvent(event)
    }

    func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible {
            ql.orderOut(nil)
            return
        }
        previewURLs = quickLookURLs()
        guard !previewURLs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        ql.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
}

/// Lets buttons respond to the very first click without activating the app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchController {
    let model = NotchModel()
    let player = NowPlaying()
    let shelf = ShelfStore()

    private var panel: NotchPanel!
    private var screen: NSScreen!
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var bag = Set<AnyCancellable>()
    /// Drag-pasteboard change count when the button went down; a different value
    /// while dragging means a real drag session (with content) is in progress.
    private var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    /// Debug: keep expanded regardless of pointer position.
    private var pinned = false
    /// Debug: frame recorder for the README demo.
    private var recTimer: Timer?
    /// True while the screenshot crosshair is up.
    private var isCapturing = false
    /// Keep the panel open until this time (e.g. to show a fresh screenshot).
    private var holdOpenUntil = Date.distantPast

    let screenshotter = Screenshotter()
    private var screenshotHotKey: HotKey?
    let settings = AppSettings.shared

    // Animation curves: a touch of overshoot when opening, crisp when closing.
    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let closeSpring = Animation.spring(response: 0.34, dampingFraction: 0.95)

    func start() {
        panel = NotchPanel()
        panel.quickLookURLs = { [weak self] in self?.shelf.selectedOrAllURLs ?? [] }
        let root = NotchView(model: model, player: player, shelf: shelf)
        panel.contentView = FirstClickHostingView(rootView: root)
        layoutWindow()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layoutWindow() }

        // Event-driven hover tracking.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
        // Safety net: drags from other apps don't always deliver events to us.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.mouseChanged() }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t

        player.onPlaybackChange = { [weak self] in self?.syncRestingMode() }
        shelf.$items.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncRestingMode() }
        }.store(in: &bag)
        model.$dropTargeted.dropFirst().sink { [weak self] targeted in
            guard targeted, let self, !self.shelf.isDraggingOut else { return }
            withAnimation(Self.openSpring) { self.model.page = .shelf }
            self.expand()
        }.store(in: &bag)

        // Region screenshot: ⇧⌘A → shelf + clipboard, notch pops open to show it.
        screenshotter.onStart = { [weak self] in
            guard let self else { return }
            // Get out of the way: no expanded panel in the shot, no hover-expanding while selecting.
            self.isCapturing = true
            self.holdOpenUntil = .distantPast
            if self.model.mode == .expanded { self.collapse() }
        }
        screenshotter.onFinish = { [weak self] url in
            guard let self else { return }
            self.isCapturing = false
            guard let url else { return }
            self.shelf.append(url, owned: true)
            if self.settings.popOpenAfterScreenshot { self.showShelfBriefly() }
        }
        // Hotkey follows the setting; paused while the recorder is listening.
        settings.$screenshotShortcut.combineLatest(settings.$isRecordingShortcut)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shortcut, recording in self?.registerScreenshotHotKey(shortcut, paused: recording) }
            .store(in: &bag)
        // Compact-mode preferences take effect immediately.
        settings.$showCompactMusic.combineLatest(settings.$showShelfReminder)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncRestingMode() } }
            .store(in: &bag)

        #if PERCH_DEBUG
        installDebugHooks()
        #endif
    }

    private func registerScreenshotHotKey(_ s: Shortcut, paused: Bool) {
        screenshotHotKey = nil   // unregister the old one first
        guard !paused else { return }
        screenshotHotKey = HotKey(keyCode: Int(s.keyCode), modifiers: Int(s.modifiers)) { [weak self] in
            self?.screenshotter.capture()
        }
        settings.screenshotShortcutAvailable = screenshotHotKey != nil
    }

    /// Pop the shelf open for a moment (after a screenshot lands on it).
    func showShelfBriefly() {
        holdOpenUntil = Date().addingTimeInterval(2.2)
        withAnimation(Self.openSpring) { model.page = .shelf }
        expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in self?.mouseChanged() }
    }

    // MARK: Geometry

    private func layoutWindow() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main!
        let f = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: f.width - l.width - r.width, height: top)
        } else {
            // No hardware notch: draw a pill at the top centre instead.
            model.notchSize = CGSize(width: 180, height: NSStatusBar.system.thickness)
        }
        let c = model.canvasSize
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height),
                       display: true)
    }

    /// Screen-space rect of the black body for a given mode.
    private func bodyRect(_ m: NotchMode) -> NSRect {
        let s = model.bodySize(m)
        let f = screen.frame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func contains(_ r: NSRect, _ p: NSPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY + 1
    }

    // MARK: Hover / drag logic

    private func handle(_ e: NSEvent) {
        if e.type == .leftMouseDown { dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
        mouseChanged()
    }

    /// True while the user is dragging files or images (from any app).
    private func isContentDrag() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, !shelf.isDraggingOut else { return false }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragCountAtMouseDown else { return false }
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
            || types.contains { $0.rawValue.contains("promise") || $0.rawValue == "public.jpeg" }
    }

    private func mouseChanged() {
        if isCapturing { panel.ignoresMouseEvents = true; return }
        let p = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0

        switch model.mode {
        case .idle, .compact:
            if buttonDown {
                // Dragging something toward the notch: open as a drop zone (generous target).
                if isContentDrag(), contains(bodyRect(model.mode).insetBy(dx: -40, dy: -24), p) {
                    withAnimation(Self.openSpring) { model.page = .shelf }
                    expand()
                    panel.ignoresMouseEvents = false
                    return
                }
            } else if contains(bodyRect(model.mode).insetBy(dx: -6, dy: 0), p) {
                expand()
            }
            panel.ignoresMouseEvents = true
        case .expanded:
            let inside = contains(bodyRect(.expanded).insetBy(dx: -12, dy: -12), p)
            // Only intercept clicks over the visible shape; everything else passes through.
            panel.ignoresMouseEvents = !inside
            if inside || buttonDown || pinned || model.dropTargeted || Date() < holdOpenUntil { cancelCollapse() } else { scheduleCollapse() }
        }
    }

    func expand() {
        cancelCollapse()
        guard model.mode != .expanded else { return }
        player.setFastPolling(true)
        withAnimation(Self.openSpring) { model.mode = .expanded }
    }

    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private var restingMode: NotchMode {
        let music = player.isPlaying && settings.showCompactMusic
        let files = !shelf.items.isEmpty && settings.showShelfReminder
        return (music || files) ? .compact : .idle
    }

    func collapse() {
        collapseWork = nil
        panel.ignoresMouseEvents = true
        player.setFastPolling(false)
        withAnimation(Self.closeSpring) {
            model.mode = restingMode
            // An empty shelf always reopens on the music page.
            if shelf.items.isEmpty { model.page = .music }
        }
    }

    private func syncRestingMode() {
        guard model.mode != .expanded else { return }
        let target = restingMode
        guard target != model.mode else { return }
        withAnimation(Self.closeSpring) { model.mode = target }
    }

    #if PERCH_DEBUG
    // MARK: Debug hooks (driven by the perch-ctl helper)

    private func installDebugHooks() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.local.perch.expand"), object: nil, queue: .main) { [weak self] _ in self?.pinned = true; self?.expand() }
        dnc.addObserver(forName: .init("com.local.perch.collapse"), object: nil, queue: .main) { [weak self] _ in self?.pinned = false; self?.collapse() }
        dnc.addObserver(forName: .init("com.local.perch.screenshot"), object: nil, queue: .main) { [weak self] _ in self?.screenshotter.capture() }
        // Simulates a finished screenshot (same naming + pipeline) from an existing image.
        dnc.addObserver(forName: .init("com.local.perch.fakeshot"), object: nil, queue: .main) { [weak self] n in
            guard let src = n.userInfo?["path"] as? String else { return }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = ShelfStore.uniqueURL(base: L("截图 ", "Screenshot ") + f.string(from: Date()), ext: "png")
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: url)
            self?.screenshotter.onFinish?(url)
        }
        dnc.addObserver(forName: .init("com.local.perch.peek"), object: nil, queue: .main) { n in
            guard let src = n.userInfo?["path"] as? String, let scr = NSScreen.main else { return }
            let r = NSRect(x: scr.frame.midX - 26, y: scr.frame.maxY - 100, width: 52, height: 52)
            Peek.shared.show(URL(fileURLWithPath: src), from: r)
        }
        dnc.addObserver(forName: .init("com.local.perch.peeksnap"), object: nil, queue: .main) { n in
            if let p = n.userInfo?["path"] as? String { Peek.shared.snapshot(to: p) }
            Peek.shared.close()
        }
        dnc.addObserver(forName: .init("com.local.perch.settings"), object: nil, queue: .main) { n in
            SettingsWindowController.shared.show()
            if let p = n.userInfo?["path"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { SettingsWindowController.shared.snapshot(to: p) }
            }
        }
        dnc.addObserver(forName: .init("com.local.perch.checkupdate"), object: nil, queue: .main) { _ in Updater.shared.check() }
        dnc.addObserver(forName: .init("com.local.perch.installupdate"), object: nil, queue: .main) { _ in Updater.shared.installUpdate() }
        dnc.addObserver(forName: .init("com.local.perch.verifysig"), object: nil, queue: .main) { n in
            guard let path = n.userInfo?["path"] as? String else { return }
            let ok = Updater.isSignedLikeMe(URL(fileURLWithPath: path))
            try? (ok ? "ACCEPTED" : "REJECTED").write(toFile: path + ".result", atomically: true, encoding: .utf8)
        }
        dnc.addObserver(forName: .init("com.local.perch.music"), object: nil, queue: .main) { [weak self] _ in
            withAnimation(Self.openSpring) { self?.model.page = .music }
        }
        // Demo track with a generated artwork (no real album art in the README).
        dnc.addObserver(forName: .init("com.local.perch.demotrack"), object: nil, queue: .main) { [weak self] n in
            let art = (n.userInfo?["path"] as? String).flatMap { NSImage(contentsOfFile: $0) }
            self?.player.setDemo(title: "Golden Hour Drive", artist: "Eave Demo", artwork: art, duration: 214, position: 63)
        }
        // Frame recorder: renders the panel 30×/s into numbered PNGs.
        dnc.addObserver(forName: .init("com.local.perch.recstart"), object: nil, queue: .main) { [weak self] n in
            guard let self, let dir = n.userInfo?["path"] as? String else { return }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var i = 0
            self.recTimer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.snapshot(to: String(format: "%@/f%05d.png", dir, i)); i += 1
            }
            RunLoop.main.add(t, forMode: .common)
            self.recTimer = t
        }
        dnc.addObserver(forName: .init("com.local.perch.recstop"), object: nil, queue: .main) { [weak self] _ in
            self?.recTimer?.invalidate(); self?.recTimer = nil
        }
        dnc.addObserver(forName: .init("com.local.perch.shelf"), object: nil, queue: .main) { [weak self] _ in self?.model.page = .shelf }
        dnc.addObserver(forName: .init("com.local.perch.add"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.userInfo?["path"] as? String else { return }
            self?.shelf.add([NSItemProvider(contentsOf: URL(fileURLWithPath: path))!])
        }
        dnc.addObserver(forName: .init("com.local.perch.snapshot"), object: nil, queue: .main) { [weak self] n in
            if let path = n.userInfo?["path"] as? String { self?.snapshot(to: path) }
        }
    }

    /// Debug: render the panel's content to a PNG (works without Screen Recording permission).
    private func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
