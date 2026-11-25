import AppKit
import Security

/// Checks GitHub Releases for a newer Eave, downloads it, verifies that it is signed by the
/// same identity as the running app, swaps it in place and relaunches.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "joeqiao64/eave"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    private var latestVersion: String?
    private var downloadURL: URL?
    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var availableVersion: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    // MARK: Scheduling

    /// Called at launch: check shortly after start, then once a day, if the user allows it.
    func startAutomaticChecks() {
        timer?.invalidate()
        guard AppSettings.shared.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(userInitiated: false) }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(userInitiated: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Check

    func check(userInitiated: Bool = true) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var req = URLRequest(url: Self.api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Eave-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.handleCheck(data: data, response: response, error: error, userInitiated: userInitiated) }
        }.resume()
    }

    private func handleCheck(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        lastChecked = Date()
        guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            // Background checks fail quietly (offline, rate-limited…); manual checks say so.
            state = userInitiated ? .failed(L("无法连接到 GitHub，请稍后再试", "Couldn't reach GitHub. Try again later.")) : .idle
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String) == "Eave.zip" }?["browser_download_url"] as? String

        if Self.isNewer(version, than: currentVersion), let zip, let url = URL(string: zip) {
            latestVersion = version
            downloadURL = url
            state = .available(version: version)
        } else {
            state = .upToDate
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    func installUpdate() {
        guard let url = downloadURL, availableVersion != nil else { return }
        state = .downloading(progress: 0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, error in
            guard let self else { return }
            guard let tmp, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.state = .failed(L("下载失败，请检查网络后重试", "Download failed. Check your connection and try again.")) }
                return
            }
            // Move out of the temp location before this handler returns.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("eave-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Eave.zip")
            do { try FileManager.default.moveItem(at: tmp, to: zip) } catch {
                DispatchQueue.main.async { self.state = .failed(L("下载失败，请重试", "Download failed. Please try again.")) }
                return
            }
            DispatchQueue.main.async { self.state = .installing }
            self.prepare(zip: zip, in: work)
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(progress: p.fractionCompleted) }
            }
        }
        task.resume()
    }

    /// Unzip → verify signature → hand over to a helper that swaps the bundle once we quit.
    private func prepare(zip: URL, in work: URL) {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        do { try unzip.run(); unzip.waitUntilExit() } catch {}
        let newApp = work.appendingPathComponent("Eave.app")

        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: newApp.path) else {
            return fail(L("更新包已损坏，请稍后再试", "The update package is damaged. Try again later."))
        }
        guard Self.isSignedLikeMe(newApp) else {
            return fail(L("新版本的签名与当前应用不一致，已取消更新", "The update isn't signed like this app, so it wasn't installed."))
        }
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            return fail(L("没有权限写入应用所在的文件夹", "No permission to write to the app's folder."))
        }

        // Wait for us to quit, swap bundles (restoring the old one if anything fails), relaunch.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        OLD="$DEST.old-$$"
        if mv "$DEST" "$OLD" && mv "$NEW" "$DEST"; then rm -rf "$OLD"; else [ -d "$OLD" ] && mv "$OLD" "$DEST"; fi
        rm -rf "$WORK"
        open "$DEST"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.environment = ["DEST": dest.path, "NEW": newApp.path, "WORK": work.path,
                              "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        do { try helper.run() } catch {
            return fail(L("无法完成更新，请重试", "Couldn't finish the update. Please try again."))
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    /// True if `app` satisfies the running app's own designated requirement — i.e. it was
    /// signed with the same certificate and has the same bundle identifier.
    static func isSignedLikeMe(_ app: URL) -> Bool {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var req: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req) == errSecSuccess
    }
}
