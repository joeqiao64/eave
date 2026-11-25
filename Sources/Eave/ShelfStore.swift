import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    /// true when Perch created the file itself (screenshot thumbnail, web image)
    /// and should delete it when the item is removed. Referenced files are never touched.
    let owned: Bool
}

/// The file shelf. Stores references to files (not copies); dragging out always copies.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published var selection: Set<UUID> = []
    /// True while the user is dragging items *out of* the shelf. Drops during that
    /// time are ignored, so dragging an item back onto the notch just cancels.
    @Published var isDraggingOut = false
    /// Most recently added item; the UI scrolls to it and highlights it briefly.
    @Published private(set) var lastAddedID: UUID?

    private let defaultsKey = "shelfItems"
    private var pruneTimer: Timer?

    /// Where Perch keeps files it had to create (images without an original file).
    static let storageDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        load()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.prune() }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    // MARK: Adding

    /// Accepts dropped files, plus images that have no file yet (screenshot thumbnail, browser image).
    func add(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { self.append(url, owned: false) }
                }
            } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                let suggested = p.suggestedName
                p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
                    guard let tmp else { return }
                    let ext = tmp.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : tmp.pathExtension
                    let dest = Self.uniqueURL(base: suggested ?? Self.defaultImageName(), ext: ext)
                    // The temp file is deleted when this handler returns, so copy synchronously.
                    guard (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil else { return }
                    DispatchQueue.main.async { self.append(dest, owned: true) }
                }
            }
        }
    }

    func append(_ url: URL, owned: Bool) {
        let std = url.standardizedFileURL
        guard !items.contains(where: { $0.url.standardizedFileURL == std }) else { return }
        let item = ShelfItem(id: UUID(), url: std, owned: owned)
        // Newest first, like a stack of screenshots: the latest one is always in view.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            items.insert(item, at: 0)
        }
        lastAddedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.lastAddedID == item.id { self?.lastAddedID = nil }
        }
        save()
        makeThumbnail(for: item)
    }

    // MARK: Removing

    func remove(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) && item.owned {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll { ids.contains($0.id) }
        ids.forEach { thumbnails[$0] = nil }
        selection.subtract(ids)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    /// Drop references whose file was deleted or moved away.
    private func prune() {
        let gone = items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.id)
        if !gone.isEmpty { remove(Set(gone)) }
    }

    // MARK: Helpers for the UI

    /// Items a drag starting on `id` should carry: the whole selection if `id` is part of it.
    func dragItems(startingAt id: UUID) -> [ShelfItem] {
        selection.contains(id) ? items.filter { selection.contains($0.id) } : items.filter { $0.id == id }
    }

    var selectedOrAllURLs: [URL] {
        let sel = items.filter { selection.contains($0.id) }
        return (sel.isEmpty ? items : sel).map(\.url)
    }

    func airDrop() {
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: selectedOrAllURLs)
    }

    // MARK: Thumbnails

    private func makeThumbnail(for item: ShelfItem) {
        // File icon right away, real Quick Look thumbnail when it is ready.
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.url.path)
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 120, height: 120),
                                               scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                if self.items.contains(where: { $0.id == item.id }) { self.thumbnails[item.id] = img }
            }
        }
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        items.forEach(makeThumbnail)
    }

    private static func defaultImageName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "图片 " + f.string(from: Date())
    }

    static func uniqueURL(base: String, ext: String) -> URL {
        // Strip a real extension ("photo.png") but not a time component ("20.04.37").
        let ns = base as NSString
        let hasExt = !ns.pathExtension.isEmpty && ns.pathExtension.allSatisfy(\.isLetter)
        let clean = (hasExt ? ns.deletingPathExtension : base).replacingOccurrences(of: "/", with: "-")
        var url = storageDir.appendingPathComponent(clean).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = storageDir.appendingPathComponent("\(clean) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
