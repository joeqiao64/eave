import AppKit

/// Menu-bar glyph: a screen outline with the notch hanging from its top edge.
/// Template image, so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let s = r.width / 18   // design on an 18pt grid (y grows downward)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Screen outline
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.6 * s, y: 3.2 * s, width: 14.8 * s, height: 11.6 * s),
                                      xRadius: 2.6 * s, yRadius: 2.6 * s)
            screen.lineWidth = 1.5 * s
            screen.stroke()

            // Notch hanging from the top edge, rounded at the bottom
            let notch = NSBezierPath()
            let l = 6.0 * s, rr = 12.0 * s, top = 3.2 * s, bottom = 7.0 * s, rad = 1.6 * s
            notch.move(to: NSPoint(x: l, y: top))
            notch.line(to: NSPoint(x: l, y: bottom - rad))
            notch.curve(to: NSPoint(x: l + rad, y: bottom), controlPoint1: NSPoint(x: l, y: bottom), controlPoint2: NSPoint(x: l, y: bottom))
            notch.line(to: NSPoint(x: rr - rad, y: bottom))
            notch.curve(to: NSPoint(x: rr, y: bottom - rad), controlPoint1: NSPoint(x: rr, y: bottom), controlPoint2: NSPoint(x: rr, y: bottom))
            notch.line(to: NSPoint(x: rr, y: top))
            notch.close()
            notch.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Eave"
        return img
    }
}
