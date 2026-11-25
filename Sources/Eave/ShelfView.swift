import SwiftUI
import AppKit

// MARK: - Shelf page

struct ShelfPage: View {
    @ObservedObject var settings = AppSettings.shared   // re-render on language change
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var player: NowPlaying

    private var sideZone: CGFloat { (model.expandedSize(.shelf).width - model.notchSize.width) / 2 }

    var body: some View {
        let band = model.notchSize.height
        VStack(spacing: 0) {
            // Top band: the strips either side of the camera hold the page controls.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    TopIconButton(symbol: "chevron.left") { withAnimation(NotchController.openSpring) { model.page = .music } }
                    Text(L("文件架", "Shelf")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: sideZone - 14, alignment: .leading)
                Spacer(minLength: model.notchSize.width)
                HStack(spacing: 2) {
                    TopIconButton(symbol: "square.and.arrow.up") { shelf.airDrop() }
                        .help("AirDrop")
                        .disabled(shelf.items.isEmpty)
                    TopIconButton(symbol: "trash") { withAnimation(.easeInOut(duration: 0.2)) { shelf.clear() } }
                        .disabled(shelf.items.isEmpty)
                }
                .frame(width: sideZone - 14, alignment: .trailing)
            }
            .frame(height: band)

            if shelf.items.isEmpty || (model.dropTargeted && !shelf.isDraggingOut) {
                DropHint(targeted: model.dropTargeted && !shelf.isDraggingOut, hasItems: !shelf.items.isEmpty)
                    .padding(.top, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item, shelf: shelf, isNew: item.id == shelf.lastAddedID)
                                    .id(item.id)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.4, anchor: .center).combined(with: .opacity),
                                        removal: .scale(scale: 0.6).combined(with: .opacity)))
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                    .onChange(of: shelf.lastAddedID) { _, id in
                        guard let id else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

private struct DropHint: View {
    @ObservedObject var settings = AppSettings.shared
    let targeted: Bool
    let hasItems: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.white.opacity(targeted ? 0.85 : 0.25))
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(targeted ? 0.1 : 0)))
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: targeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 17, weight: .medium))
                        .symbolEffect(.bounce, value: targeted)
                    Text(targeted ? L("松手放入", "Drop to add") : L("把文件、截图或图片拖到这里", "Drag files, screenshots or images here"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(targeted ? 1 : 0.55))
            )
            .frame(height: 62)
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    var isNew = false

    var body: some View {
        let selected = shelf.selection.contains(item.id)
        VStack(spacing: 3) {
            ZStack {
                if let img = shelf.thumbnails[item.id] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: isImage ? .fill : .fit)
                        .padding(isImage ? 0 : 3)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .white.opacity(isImage ? 0.12 : 0), lineWidth: selected ? 2 : 0.5)
            )
            // Fresh arrival: soft white ring that fades out.
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(isNew ? 0.9 : 0), lineWidth: 1.5)
                    .shadow(color: .white.opacity(isNew ? 0.6 : 0), radius: 6)
            )
            .scaleEffect(isNew ? 1.04 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isNew)
            Text(displayName)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 58)
        }
        .frame(width: 60)
        .overlay(TileMouse(item: item, shelf: shelf))
        .help(item.url.path)
    }

    /// Screenshots are labelled by capture time ("20:05:17") — their full names all look alike.
    private var displayName: String {
        let name = item.url.deletingPathExtension().lastPathComponent
        if item.owned, name.hasPrefix("截图 ") || name.hasPrefix("Screenshot "),
           let r = name.range(of: #"\d{2}\.\d{2}\.\d{2}"#, options: .regularExpression) {
            return name[r].replacingOccurrences(of: ".", with: ":")
        }
        return item.url.lastPathComponent
    }

    private var isImage: Bool {
        (try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType)??.conforms(to: .image) ?? false
            || ["pdf", "mov", "mp4"].contains(item.url.pathExtension.lowercased())
    }
}

private struct TopIconButton: View {
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.3))
    }
}

// MARK: - Mouse handling for tiles (AppKit, so drags can be forced to "copy")

private struct TileMouse: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfStore

    func makeNSView(context: Context) -> TileMouseView { TileMouseView() }
    func updateNSView(_ v: TileMouseView, context: Context) {
        v.item = item
        v.shelf = shelf
    }
}

final class TileMouseView: NSView, NSDraggingSource {
    var item: ShelfItem!
    weak var shelf: ShelfStore?
    private var downEvent: NSEvent?
    private var longPress: DispatchWorkItem?
    private var peeking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downEvent = e
        window?.makeKey()   // so Space can open Quick Look
        if e.clickCount == 2 {
            longPress?.cancel()
            NSWorkspace.shared.open(item.url)
            downEvent = nil
            return
        }
        // Mouse users: holding still for a moment also peeks.
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.downEvent != nil, !self.peeking else { return }
            self.startPeek()
        }
        longPress = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// Trackpad: peek once the press is about halfway to a full Force Click —
    /// noticeably lighter than the system's deep-press threshold.
    override func pressureChange(with e: NSEvent) {
        guard !peeking, downEvent != nil else { return }
        if e.stage >= 2 || (e.stage == 1 && e.pressure >= 0.5) { startPeek() }
    }

    private func startPeek() {
        longPress?.cancel()
        peeking = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // Grow out of the thumbnail (top 52pt of the tile).
        let thumb = NSRect(x: (bounds.width - 52) / 2, y: bounds.height - 52, width: 52, height: 52)
        guard let win = window else { return }
        let screenRect = win.convertToScreen(convert(thumb, to: nil))
        Peek.shared.show(item.url, from: screenRect)
    }

    override func mouseUp(with e: NSEvent) {
        longPress?.cancel()
        defer { downEvent = nil }
        if peeking {                 // release ends the peek; it is not a click
            peeking = false
            Peek.shared.close()
            return
        }
        guard downEvent != nil, let shelf else { return }
        if e.modifierFlags.contains(.command) {
            if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
        } else {
            shelf.selection = shelf.selection == [item.id] ? [] : [item.id]
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard !peeking, let d = downEvent, let shelf else { return }
        let dx = e.locationInWindow.x - d.locationInWindow.x, dy = e.locationInWindow.y - d.locationInWindow.y
        guard hypot(dx, dy) > 3 else { return }
        longPress?.cancel()
        downEvent = nil

        let carried = shelf.dragItems(startingAt: item.id)
        let origin = convert(d.locationInWindow, from: nil)
        let draggingItems = carried.enumerated().map { i, it -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: it.url as NSURL)
            let img = shelf.thumbnails[it.id] ?? NSWorkspace.shared.icon(forFile: it.url.path)
            let off = CGFloat(min(i, 4)) * 5
            di.setDraggingFrame(NSRect(x: origin.x - 26 + off, y: origin.y - 26 - off, width: 52, height: 52), contents: img)
            return di
        }
        shelf.isDraggingOut = true
        let session = beginDraggingSession(with: draggingItems, event: e, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        shelf?.isDraggingOut = false
    }

    /// Always copy: the original file is never moved out of its folder.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: L("打开", "Open"), action: #selector(openItem), keyEquivalent: "").target = self
        m.addItem(withTitle: L("在 Finder 中显示", "Show in Finder"), action: #selector(reveal), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: L("从文件架移除", "Remove from Shelf"), action: #selector(removeItem), keyEquivalent: "").target = self
        return m
    }

    @objc private func openItem() { NSWorkspace.shared.open(item.url) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    @objc private func removeItem() {
        guard let shelf else { return }
        let ids = shelf.selection.contains(item.id) ? shelf.selection : [item.id]
        withAnimation(.easeInOut(duration: 0.2)) { shelf.remove(ids) }
    }
}
