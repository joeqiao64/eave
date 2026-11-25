import AppKit

/// Reads and controls Apple Music / Spotify through their official AppleScript
/// interfaces. Never launches a player that isn't already running.
final class NowPlaying: ObservableObject {
    enum Source: String {
        case spotify = "Spotify"
        case music = "Music"
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var appName: String { rawValue }
    }

    @Published private(set) var source: Source?
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var duration: Double = 0
    /// Position at `positionDate`; the UI extrapolates from it while playing.
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()

    var onPlaybackChange: (() -> Void)?

    private let queue = DispatchQueue(label: "perch.nowplaying")
    private var scripts: [String: NSAppleScript] = [:]
    private var trackKey: String?
    private var timer: Timer?

    init() {
        setFastPolling(false)
        refresh()
        // React immediately to play/pause/track changes instead of waiting for the next poll.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
    }

    func setFastPolling(_ fast: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 : 3.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if fast { refresh() }
    }

    // MARK: Controls

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    /// Jump to a position (seconds). Updates the UI immediately, then tells the player.
    func seek(to seconds: Double) {
        guard let s = source else { return }
        let target = max(0, min(duration, seconds))
        position = target
        positionDate = Date()
        let arg = String(format: "%.2f", target)
        queue.async {
            _ = self.run("tell application \"\(s.appName)\" to set player position to \(arg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
        }
    }

    private func send(_ command: String) {
        guard let s = source ?? runningSources().first else { return }
        // Optimistic UI so the button responds instantly.
        if command == "playpause" {
            isPlaying.toggle()
            position = currentPosition()
            positionDate = Date()
            onPlaybackChange?()
        }
        queue.async {
            _ = self.run("tell application \"\(s.appName)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh() }
        }
    }

    func currentPosition(at date: Date = Date()) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(positionDate))
    }

    // MARK: Polling

    private func runningSources() -> [Source] {
        [Source.spotify, .music].filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    func refresh() {
        let candidates = runningSources()
        queue.async {
            var best: (Source, [String])?
            for s in candidates {
                guard let out = self.run(self.statusScript(s)), out != "stopped" else { continue }
                let parts = out.components(separatedBy: "||")
                guard parts.count >= 6 else { continue }
                if best == nil || parts[0] == "playing" { best = (s, parts) }
                if parts[0] == "playing" { break }
            }
            DispatchQueue.main.async { self.apply(best) }
        }
    }

    private func statusScript(_ s: Source) -> String {
        let artworkExpr = s == .spotify ? "(artwork url of t)" : "\"\""
        let durationExpr = s == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        return """
        tell application "\(s.appName)"
            set ps to player state as string
            if ps is "stopped" then return "stopped"
            set t to current track
            return ps & "||" & (name of t) & "||" & (artist of t) & "||" & \(artworkExpr) & "||" & (player position as string) & "||" & (\(durationExpr) as string)
        end tell
        """
    }

    #if PERCH_DEBUG
    /// Debug/demo: pretend a track is playing (used to record the README demo).
    private var demo = false
    func setDemo(title: String, artist: String, artwork: NSImage?, duration: Double, position: Double) {
        demo = true
        source = .spotify; self.title = title; self.artist = artist; self.artwork = artwork
        self.duration = duration; self.position = position; positionDate = Date()
        isPlaying = true
        onPlaybackChange?()
    }
    #endif

    private func apply(_ result: (Source, [String])?) {
        #if PERCH_DEBUG
        if demo { return }
        #endif
        let wasPlaying = isPlaying
        guard let (s, p) = result else {
            source = nil; title = nil; artist = nil; artwork = nil
            isPlaying = false; duration = 0; position = 0; trackKey = nil
            if wasPlaying { onPlaybackChange?() }
            return
        }
        source = s
        isPlaying = p[0] == "playing"
        title = p[1]
        artist = p[2]
        duration = Self.number(p[5])
        position = Self.number(p[4])
        positionDate = Date()

        let key = "\(s.rawValue)|\(p[1])|\(p[2])"
        if key != trackKey {
            trackKey = key
            loadArtwork(source: s, url: p[3], key: key)
        }
        if wasPlaying != isPlaying { onPlaybackChange?() }
    }

    private static func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func loadArtwork(source s: Source, url: String, key: String) {
        if s == .spotify, let u = URL(string: url), !url.isEmpty {
            URLSession.shared.dataTask(with: u) { data, _, _ in
                let img = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { if self.trackKey == key { self.artwork = img } }
            }.resume()
        } else if s == .music {
            queue.async {
                let d = self.runDescriptor("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
                let img = d.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { if self.trackKey == key { self.artwork = img } }
            }
        }
    }

    // MARK: AppleScript (always called on `queue`)

    private func run(_ source: String) -> String? { runDescriptor(source)?.stringValue }

    private func runDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scripts[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            s.compileAndReturnError(&compileError)
            scripts[source] = s
            script = s
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        #if PERCH_DEBUG
        if let err { NSLog("Eave AppleScript error: %@", err) }
        #endif
        return err == nil ? result : nil
    }
}
