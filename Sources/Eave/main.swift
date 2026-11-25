import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var notch: NotchController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        notch.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt each time it opens, so the shortcut label is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared
        let shot = NSMenuItem(title: "截图", action: #selector(takeScreenshot), keyEquivalent: "")
        shot.target = self
        shot.attributedTitle = NSAttributedString(string: "截图    \(s.screenshotShortcut.display)")
        menu.addItem(shot)
        if !s.screenshotShortcutAvailable {
            menu.addItem(NSMenuItem(title: "快捷键已被其他应用占用", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Eave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func takeScreenshot() { notch.screenshotter.capture() }
}
