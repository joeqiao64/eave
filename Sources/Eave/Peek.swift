import AppKit
import Quartz
import ImageIO
import UniformTypeIdentifiers

/// "Peek": a temporary large preview that grows out of a shelf thumbnail while the
/// user presses (Force Touch, or long-press with a mouse) and shrinks back on release.
final class Peek {
    static let shared = Peek()

    private var window: NSPanel?
    private var preview: QLPreviewView?
    private var imageView: NSImageView?
    private var originRect = NSRect.zero
    private(set) var isShowing = false

    private let maxSize = NSSize(width: 580, height: 420)

    func show(_ url: URL, from tileRect: NSRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(tileRect) }) ?? NSScreen.main!
        let size = targetSize(for: url)
        // Centred under the shelf panel, just below the tile row.
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: tileRect.minY - 30 - size.height,
                            width: size.width, height: size.height)

        let w = window ?? makeWindow()
        // Images render directly (instant, crisp); other files go through Quick Look.
        if let img = NSImage(contentsOf: url), isImage(url) {
            imageView?.image = img
            imageView?.isHidden = false
            preview?.isHidden = true
            preview?.previewItem = nil
        } else {
            imageView?.isHidden = true
            preview?.isHidden = false
            preview?.previewItem = url as NSURL
        }
        originRect = tileRect
        isShowing = true

        w.setFrame(tileRect, display: false)
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
        }
    }

    func close() {
        guard isShowing, let w = window else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(originRect, display: true)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShowing else { return }
            w.orderOut(nil)
            self.preview?.previewItem = nil
            self.imageView?.image = nil
        })
    }

    #if PERCH_DEBUG
    /// Debug: render the peek window to a PNG.
    func snapshot(to path: String) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    // MARK: -

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)   // above the notch
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.ignoresMouseEvents = true

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let ql = QLPreviewView(frame: .zero, style: .compact)!
        ql.autoresizingMask = [.width, .height]
        ql.shouldCloseWithWindow = false
        bg.addSubview(ql)

        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.autoresizingMask = [.width, .height]
        bg.addSubview(iv)
        w.contentView = bg

        window = w
        preview = ql
        imageView = iv
        return w
    }

    private func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)??.conforms(to: .image) ?? false
    }

    /// Images keep their aspect ratio; everything else gets a document-ish size.
    private func targetSize(for url: URL) -> NSSize {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let ph = props[kCGImagePropertyPixelHeight] as? CGFloat, pw > 0, ph > 0 {
            let scale = min(maxSize.width / pw, maxSize.height / ph, 1)
            // Screenshots are retina pixels; show them no larger than their point size.
            let pointScale = min(scale, 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2))
            var s = NSSize(width: pw * pointScale, height: ph * pointScale)
            if s.width < 220 && s.height < 220 {   // tiny images: don't make a postage stamp
                let k = 220 / max(s.width, s.height)
                s = NSSize(width: s.width * k, height: s.height * k)
            }
            return s
        }
        return NSSize(width: 520, height: 380)
    }
}
