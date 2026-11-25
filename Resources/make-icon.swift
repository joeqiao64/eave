// Renders the Eave app icon (1024×1024 PNG).
// Concept: the notch is an eave; a photo, a song and a document hang beneath it like wind chimes.
// Usage: swiftc make-icon.swift -o make-icon && ./make-icon out.png
import AppKit

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func gradient(_ colors: [UInt32], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors.map { rgb($0) } as CFArray, locations: locs)!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// macOS icon grid: 824pt squircle on a 1024 canvas (CG origin bottom-left).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = rounded(tile, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x3A2F8F)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
// Dusk sky: indigo → violet → warm peach
ctx.drawLinearGradient(gradient([0x4636D8, 0x8A5CF0, 0xF39A86], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Warm glow near the bottom
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFD3B5, 0.55), rgb(0xFFD3B5, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 150), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 150), endRadius: 520, options: [])
// Soft top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 780), options: [])

// --- The eave (notch) ---
let top: CGFloat = 924, w: CGFloat = 560, h: CGFloat = 190, ear: CGFloat = 44, r: CGFloat = 80
let l = 512 - w / 2, rr = 512 + w / 2
let eave = CGMutablePath()
eave.move(to: CGPoint(x: l - ear, y: top + 2))
eave.addQuadCurve(to: CGPoint(x: l, y: top - ear), control: CGPoint(x: l, y: top))
eave.addLine(to: CGPoint(x: l, y: top - h + r))
eave.addQuadCurve(to: CGPoint(x: l + r, y: top - h), control: CGPoint(x: l, y: top - h))
eave.addLine(to: CGPoint(x: rr - r, y: top - h))
eave.addQuadCurve(to: CGPoint(x: rr, y: top - h + r), control: CGPoint(x: rr, y: top - h))
eave.addLine(to: CGPoint(x: rr, y: top - ear))
eave.addQuadCurve(to: CGPoint(x: rr + ear, y: top + 2), control: CGPoint(x: rr, y: top))
eave.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x120B3A, 0.55))
ctx.addPath(eave); ctx.setFillColor(rgb(0x08070F)); ctx.fillPath()
ctx.restoreGState()

let eaveBottom = top - h

// --- Hanging cards ---
struct Charm { let x: CGFloat; let string: CGFloat; let size: CGFloat; let tilt: CGFloat; let draw: (CGRect) -> Void }

func drawPhoto(_ r: CGRect) {
    let p = rounded(r, 30)
    ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(gradient([0xFFC6A8, 0xFF7E9D], [0, 1]), start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.setFillColor(rgb(0xFFF4D6)); ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.58, width: r.width * 0.22, height: r.width * 0.22))
    let m = CGMutablePath()
    m.move(to: CGPoint(x: r.minX, y: r.minY))
    m.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.55))
    m.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.28))
    m.addLine(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.42))
    m.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18))
    m.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    m.closeSubpath()
    ctx.addPath(m); ctx.setFillColor(rgb(0xB8457A, 0.85)); ctx.fillPath()
}

func drawMusic(_ r: CGRect) {
    ctx.addPath(rounded(r, 34)); ctx.setFillColor(rgb(0x14112B)); ctx.fillPath()
    let hs: [CGFloat] = [0.38, 0.72, 0.52, 0.86, 0.44]
    let bw = r.width * 0.09, gap = r.width * 0.055
    let total = CGFloat(hs.count) * bw + CGFloat(hs.count - 1) * gap
    let g = gradient([0xFF7AC6, 0xB78CFF, 0x6FE3FF], [0, 0.5, 1])
    for (i, k) in hs.enumerated() {
        let x = r.midX - total / 2 + CGFloat(i) * (bw + gap)
        let bh = r.height * 0.62 * k
        ctx.saveGState()
        ctx.addPath(rounded(CGRect(x: x, y: r.midY - bh / 2, width: bw, height: bh), bw / 2)); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX - total / 2, y: 0), end: CGPoint(x: r.midX + total / 2, y: 0), options: [])
        ctx.restoreGState()
    }
}

func drawDoc(_ r: CGRect) {
    let fold = r.width * 0.28
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + 26, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - 26, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 26), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + 26, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 26), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + 26))
    p.addQuadCurve(to: CGPoint(x: r.minX + 26, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(rgb(0xFFFDF8)); ctx.fillPath()
    let f = CGMutablePath()
    f.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    f.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold + 8))
    f.addQuadCurve(to: CGPoint(x: r.maxX - fold + 8, y: r.maxY - fold), control: CGPoint(x: r.maxX - fold, y: r.maxY - fold))
    f.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    f.closeSubpath()
    ctx.addPath(f); ctx.setFillColor(rgb(0xD9D3F0)); ctx.fillPath()
    ctx.setFillColor(rgb(0xC9C2E6))
    for (i, len) in [0.62, 0.7, 0.48].enumerated() {
        let y = r.maxY - fold - 22 - CGFloat(i) * r.height * 0.17
        ctx.addPath(rounded(CGRect(x: r.minX + r.width * 0.18, y: y - 9, width: r.width * CGFloat(len), height: 18), 9)); ctx.fillPath()
    }
}

let charms = [
    Charm(x: 300, string: 120, size: 196, tilt: 7, draw: drawPhoto),
    Charm(x: 512, string: 236, size: 214, tilt: 0, draw: drawMusic),
    Charm(x: 724, string: 78, size: 182, tilt: -6, draw: drawDoc),
]

for c in charms {
    let cardTop = eaveBottom - c.string
    // String
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.65)); ctx.setLineWidth(6); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: c.x, y: eaveBottom + 4)); ctx.addLine(to: CGPoint(x: c.x, y: cardTop - 6)); ctx.strokePath()
    // Card, tilted around its hanging point
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: cardTop)
    ctx.rotate(by: c.tilt * .pi / 180)
    let r = CGRect(x: -c.size / 2, y: -c.size, width: c.size, height: c.size)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: rgb(0x1A0E4A, 0.45))
    ctx.addPath(rounded(r, 32)); ctx.setFillColor(rgb(0x000000, 0.25)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); c.draw(r); ctx.restoreGState()
    // Little ring where the string attaches
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setLineWidth(5)
    ctx.strokeEllipse(in: CGRect(x: -9, y: -12, width: 18, height: 18))
    ctx.restoreGState()
}
ctx.restoreGState()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
