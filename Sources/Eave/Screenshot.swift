import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Returns nil if another app already owns this combination.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.actions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_4348) /* 'PRCH' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.actions[id] = nil
    }
}

/// Region screenshot using the system's own `screencapture` tool.
/// The result goes onto the shelf and the clipboard.
final class Screenshotter {
    private var running = false
    var onStart: (() -> Void)?
    var onFinish: ((URL?) -> Void)?

    func capture() {
        guard !running else { return }
        running = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        // Unique even for several shots within the same second (otherwise the new one overwrites the old).
        let url = ShelfStore.uniqueURL(base: "截图 \(f.string(from: Date()))", ext: "png")
        onStart?()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive (drag a region; Space toggles window mode; Esc cancels), -o no window shadow
        p.arguments = ["-i", "-o", url.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.running = false
                guard FileManager.default.fileExists(atPath: url.path) else {   // Esc: cancelled
                    self?.onFinish?(nil)
                    return
                }
                if AppSettings.shared.copyScreenshotToClipboard, let img = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }
                self?.onFinish?(url)
            }
        }
        do { try p.run() } catch {
            running = false
            onFinish?(nil)
            NSLog("Eave: screencapture failed: \(error)")
        }
    }
}
