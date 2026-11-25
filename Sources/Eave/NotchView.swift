import SwiftUI
import AppKit

// MARK: - Shape

/// Notch silhouette: concave "ears" where it meets the top screen edge,
/// rounded bottom corners. Both radii animate, so the morph stays smooth.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4)
        let left = r.minX + e, right = r.maxX - e
        let b = max(0, min(bottom, r.height - e, (right - left) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: r.minY + e), control: CGPoint(x: left, y: r.minY))
        p.addLine(to: CGPoint(x: left, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: left + b, y: r.maxY), control: CGPoint(x: left, y: r.maxY))
        p.addLine(to: CGPoint(x: right - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: right, y: r.maxY - b), control: CGPoint(x: right, y: r.maxY))
        p.addLine(to: CGPoint(x: right, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: right, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Transitions

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.92 : 1, anchor: .top)
    }
}

private extension AnyTransition {
    /// Content appears slightly after the shape starts opening, and leaves quickly.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.26).delay(0.07)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeIn(duration: 0.10))
        )
    }
}

// MARK: - Root

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var player: NowPlaying
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        let mode = model.mode
        let size = model.bodySize(mode)
        let ear = model.earRadius(mode)
        let bottom = model.bottomRadius(mode)

        ZStack(alignment: .top) {
            NotchShape(ear: ear, bottom: bottom)
                .fill(Color.black)
                .frame(width: size.width + ear * 2, height: size.height)
                .shadow(color: .black.opacity(mode == .expanded ? 0.4 : 0), radius: 14, y: 6)

            ZStack(alignment: .top) {
                if mode == .compact {
                    CompactView(model: model, player: player, shelf: shelf)
                        .transition(.notchContent)
                }
                if mode == .expanded && model.page == .music {
                    let s = model.expandedSize(.music)
                    ExpandedPlayer(model: model, player: player, shelf: shelf)
                        .frame(width: s.width, height: s.height)
                        .transition(.notchContent)
                }
                if mode == .expanded && model.page == .shelf {
                    let s = model.expandedSize(.shelf)
                    ShelfPage(model: model, shelf: shelf, player: player)
                        .frame(width: s.width, height: s.height)
                        .transition(.notchContent)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(ear: 0, bottom: bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $model.dropTargeted) { providers in
            guard !shelf.isDraggingOut else { return false }   // item dragged back in: just cancel
            shelf.add(providers)
            return true
        }
    }
}

// MARK: - Compact (music playing, not hovered)

private struct CompactView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var player: NowPlaying
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var settings = AppSettings.shared

    /// Music wins when both are on; otherwise show the shelf reminder.
    private var showMusic: Bool { player.isPlaying && settings.showCompactMusic }

    var body: some View {
        let wing = model.compactWing
        let h = model.notchSize.height
        HStack(spacing: 0) {
            Group {
                if showMusic {
                    Artwork(image: player.artwork, size: h - 14, corner: 5)
                } else {
                    // Shelf reminder: first item's thumbnail.
                    Artwork(image: shelf.items.first.flatMap { shelf.thumbnails[$0.id] }, size: h - 14, corner: 5)
                }
            }
            .frame(width: wing, height: h)
            Spacer(minLength: model.notchSize.width)
            Group {
                if showMusic {
                    Waveform(playing: true, tint: player.artwork?.vibrantColor ?? .white)
                        .frame(width: 14, height: 10)
                } else {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: wing, height: h)
        }
        .frame(width: model.bodySize(.compact).width, height: h)
    }
}

// MARK: - Expanded player

private struct ExpandedPlayer: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var player: NowPlaying
    @ObservedObject var shelf: ShelfStore

    /// Width of the free strip on each side of the camera housing.
    private var sideZone: CGFloat { (model.expandedSize(.music).width - model.notchSize.width) / 2 }

    var body: some View {
        let band = model.notchSize.height
        ZStack(alignment: .topLeading) {
            // Top-right strip beside the camera: waveform + shelf button.
            HStack(spacing: 4) {
                if player.source != nil {
                    Waveform(playing: player.isPlaying, tint: player.artwork?.vibrantColor ?? .white)
                        .frame(width: 14, height: 12)
                }
                ShelfButton(count: shelf.items.count) {
                    withAnimation(NotchController.openSpring) { model.page = .shelf }
                }
            }
            .fixedSize()
            .frame(height: band)
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    // Artwork rises into the top-left strip beside the camera.
                    Artwork(image: player.artwork, size: 50, corner: 11)
                        .padding(.top, 9)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: band + 2)   // keep text fully below the camera housing
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(player.source == nil ? "没有正在播放" : (player.title ?? ""))
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(player.source == nil ? "在 Music 或 Spotify 播放后显示" : (player.artist ?? ""))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if player.source != nil {
                                HStack(spacing: 0) {
                                    ControlButton(symbol: "backward.fill", size: 12) { player.previous() }
                                    ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 17) { player.playPause() }
                                    ControlButton(symbol: "forward.fill", size: 12) { player.next() }
                                }
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: player.title)
                    }
                }
                Spacer(minLength: 0)
                if player.source != nil {
                    ProgressRow(player: player)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct ShelfButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: count > 0 ? "tray.full.fill" : "tray")
                    .font(.system(size: 11, weight: .semibold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(count > 0 ? 0.9 : 0.45))
            .padding(.horizontal, 2)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

/// Fraction under the pointer while scrubbing; nil when not interacting.
/// (A class instead of @State: @State needs a macro plugin that ships only with full Xcode.)
private final class ScrubState: ObservableObject {
    @Published var fraction: Double?
}

private struct ProgressRow: View {
    @ObservedObject var player: NowPlaying
    @StateObject private var scrubState = ScrubState()
    private var scrub: Double? {
        get { scrubState.fraction }
        nonmutating set { scrubState.fraction = newValue }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let live = player.duration > 0 ? min(1, player.currentPosition(at: ctx.date) / player.duration) : 0
            let frac = scrub ?? live
            let pos = frac * player.duration
            let active = scrub != nil
            HStack(spacing: 8) {
                Text(Self.format(pos)).frame(width: 30, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(active ? 0.28 : 0.18))
                        Capsule().fill(.white.opacity(active ? 1 : 0.9))
                            .frame(width: max(3, g.size.width * frac))
                            .animation(active ? nil : .linear(duration: 0.25), value: frac)
                    }
                    .frame(height: active ? 6 : 3)
                    .frame(maxHeight: .infinity)           // centre the bar in a taller hit area
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard player.duration > 0 else { return }
                                scrub = min(1, max(0, v.location.x / g.size.width))
                            }
                            .onEnded { v in
                                guard player.duration > 0 else { return }
                                let f = min(1, max(0, v.location.x / g.size.width))
                                player.seek(to: f * player.duration)
                                scrub = nil
                            }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
                }
                .frame(height: 14)
                Text("-" + Self.format(max(0, player.duration - pos))).frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(active ? 0.8 : 0.5))
        }
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pieces

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(.white.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: image)
    }
}

/// Four bars that bounce while playing and settle when paused.
private struct Waveform: View {
    let playing: Bool
    let tint: Color

    private let speeds: [Double] = [7.1, 9.3, 6.2, 8.4]
    private let phases: [Double] = [0, 1.7, 3.1, 4.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                HStack(alignment: .center, spacing: g.size.width * 0.12) {
                    ForEach(0..<4, id: \.self) { i in
                        let level = playing
                            ? 0.3 + 0.7 * abs(sin(t * speeds[i] * 0.5 + phases[i]) * cos(t * speeds[(i + 1) % 4] * 0.23))
                            : 0.18
                        Capsule()
                            .fill(tint)
                            .frame(height: max(2, g.size.height * level))
                            .animation(.easeOut(duration: 0.12), value: level)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Artwork tint

extension NSImage {
    /// Average colour of the image, nudged brighter/saturated so it reads on black.
    var vibrantColor: Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: min(1, s * 1.3 + 0.1), brightness: max(0.75, b), alpha: 1))
    }
}
