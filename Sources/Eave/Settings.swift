import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// A global keyboard shortcut in Carbon terms (what RegisterEventHotKey wants).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey | shiftKey | optionKey | controlKey
    var display: String

    static let screenshotDefault = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘A")

    /// Builds a shortcut from a key press; nil unless it has ⌘, ⌃ or ⌥ (plain keys would hijack typing).
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) || f.contains(.control) || f.contains(.option) else { return nil }
        var mods: UInt32 = 0
        var symbols = ""
        if f.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
        keyCode = UInt32(event.keyCode)
        modifiers = mods
        display = symbols + Shortcut.keyName(event)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static func keyName(_ e: NSEvent) -> String {
        let special: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        ]
        if let s = special[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

enum AppLanguage: String, CaseIterable {
    case system, zhHans, en
}

/// Picks the Chinese or English string for the current language setting.
func L(_ zh: String, _ en: String) -> String { AppSettings.shared.isEnglish ? en : zh }

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var screenshotShortcut: Shortcut {
        didSet { if let data = try? JSONEncoder().encode(screenshotShortcut) { d.set(data, forKey: "screenshotShortcut") } }
    }
    @Published var copyScreenshotToClipboard: Bool { didSet { d.set(copyScreenshotToClipboard, forKey: "copyScreenshotToClipboard") } }
    @Published var popOpenAfterScreenshot: Bool { didSet { d.set(popOpenAfterScreenshot, forKey: "popOpenAfterScreenshot") } }
    @Published var showCompactMusic: Bool { didSet { d.set(showCompactMusic, forKey: "showCompactMusic") } }
    @Published var showShelfReminder: Bool { didSet { d.set(showShelfReminder, forKey: "showShelfReminder") } }
    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: "language") } }
    @Published var autoCheckUpdates: Bool {
        didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates"); Updater.shared.startAutomaticChecks() }
    }

    /// "System" follows the first preferred macOS language: Chinese → 中文, anything else → English.
    var isEnglish: Bool {
        switch language {
        case .en: return true
        case .zhHans: return false
        case .system: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    /// Set while the shortcut recorder is listening, so the live hotkey doesn't swallow the keys.
    @Published var isRecordingShortcut = false
    /// False when another app already owns the chosen screenshot shortcut.
    @Published var screenshotShortcutAvailable = true
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        if let data = d.data(forKey: "screenshotShortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            screenshotShortcut = s
        } else {
            screenshotShortcut = .screenshotDefault
        }
        copyScreenshotToClipboard = bool("copyScreenshotToClipboard", true)
        popOpenAfterScreenshot = bool("popOpenAfterScreenshot", true)
        showCompactMusic = bool("showCompactMusic", true)
        showShelfReminder = bool("showShelfReminder", true)
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        autoCheckUpdates = bool("autoCheckUpdates", true)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Eave: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }
}

// MARK: - Shortcut recorder control

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.settings = settings
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.settings = settings
        b.refresh()
    }
}

final class RecorderButton: NSButton {
    weak var settings: AppSettings?
    private var recording = false { didSet { settings?.isRecordingShortcut = recording; refresh() } }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        title = recording ? L("请按下新快捷键…", "Press new shortcut…") : (settings?.screenshotShortcut.display ?? "")
    }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        // Local monitor so we see the combination before menus/key equivalents do.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.recording else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            if let s = Shortcut(event: e) {
                self.settings?.screenshotShortcut = s
                self.stop()
            } else {
                NSSound.beep()   // needs ⌘, ⌃ or ⌥
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, recording { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Update section

private struct UpdateSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section(L("更新", "Updates")) {
            LabeledContent(L("当前版本", "Current version"), value: updater.currentVersion)
            HStack(spacing: 10) {
                status
                Spacer()
                action
            }
            Toggle(L("自动检查更新", "Check for updates automatically"), isOn: $settings.autoCheckUpdates)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            Text(L("还没有检查过", "Not checked yet")).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("正在检查…", "Checking…")) }
        case .upToDate:
            Label(L("已是最新版本", "You're up to date"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let v):
            VStack(alignment: .leading, spacing: 2) {
                Label(L("发现新版本 \(v)", "Version \(v) is available"), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Link(L("查看更新内容", "What's new"), destination: Updater.releasesPage).font(.caption)
            }
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 120)
                Text(L("正在下载…", "Downloading…")).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("正在安装，马上重启…", "Installing, relaunching…")) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.state {
        case .available:
            Button(L("立即更新", "Update Now")) { updater.installUpdate() }.buttonStyle(.borderedProminent)
        case .checking, .downloading, .installing:
            EmptyView()
        default:
            Button(L("检查更新", "Check for Updates")) { updater.check() }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section(L("截图", "Screenshot")) {
                LabeledContent(L("截图快捷键", "Screenshot shortcut")) {
                    HStack(spacing: 8) {
                        ShortcutRecorder(settings: settings)
                            .frame(width: 150)
                        if settings.screenshotShortcut != .screenshotDefault {
                            Button(L("恢复默认", "Reset")) { settings.screenshotShortcut = .screenshotDefault }
                        }
                    }
                }
                if !settings.screenshotShortcutAvailable {
                    Label(L("这个组合已被其他应用占用，请换一个", "Another app already uses this shortcut. Pick another one."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Toggle(L("截图后自动复制到剪贴板", "Copy screenshots to the clipboard"), isOn: $settings.copyScreenshotToClipboard)
                Toggle(L("截图后在刘海里弹出预览", "Show new screenshots in the notch"), isOn: $settings.popOpenAfterScreenshot)
            }
            Section(L("刘海", "Notch")) {
                Toggle(L("播放音乐时在刘海两侧显示封面和音波", "Show artwork and waveform while music plays"), isOn: $settings.showCompactMusic)
                Toggle(L("文件架有内容时在刘海两侧提醒", "Show a reminder when the shelf has files"), isOn: $settings.showShelfReminder)
            }
            Section(L("通用", "General")) {
                Picker(L("语言", "Language"), selection: $settings.language) {
                    Text(L("跟随系统", "System")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.zhHans)
                    Text("English").tag(AppLanguage.en)
                }
                Toggle(L("开机自动启动", "Launch at login"), isOn: Binding(get: { settings.launchAtLogin },
                                                  set: { settings.setLaunchAtLogin($0) }))
            }
            UpdateSection(settings: settings)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        AppSettings.shared.refreshLaunchAtLogin()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: .shared))
            let w = NSWindow(contentViewController: host)
            w.title = L("Eave 设置", "Eave Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.title = L("Eave 设置", "Eave Settings")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if PERCH_DEBUG
    func snapshot(to path: String) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
