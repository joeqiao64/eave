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
        Updater.shared.startAutomaticChecks()

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
        if let v = Updater.shared.availableVersion {
            let up = NSMenuItem(title: L("更新到 \(v)…", "Update to \(v)…"), action: #selector(openSettings), keyEquivalent: "")
            up.target = self
            up.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(up)
            menu.addItem(.separator())
        }
        let shot = NSMenuItem(title: L("截图", "Screenshot"), action: #selector(takeScreenshot), keyEquivalent: "")
        shot.target = self
        shot.attributedTitle = NSAttributedString(string: L("截图", "Screenshot") + "    \(s.screenshotShortcut.display)")
        menu.addItem(shot)
        if !s.screenshotShortcutAvailable {
            menu.addItem(NSMenuItem(title: L("快捷键已被其他应用占用", "Shortcut is used by another app"), action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 Eave", "Quit Eave"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func takeScreenshot() { notch.screenshotter.capture() }
}
