import AppKit
import ServiceManagement

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let settingsWindow = SettingsWindowController()
    /// Flips the notch pause and returns the *new* disabled state. Owned by
    /// the app delegate so the menu item and the ⌥⌘N hotkey share one toggle.
    private let onToggleNotch: () -> Bool
    private var pauseItem: NSMenuItem?

    init(onToggleNotch: @escaping () -> Bool) {
        self.onToggleNotch = onToggleNotch
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "Côte d'OS"
            )
        }

        let menu = NSMenu()

        // ⌥⌘N is registered globally via HotKeyCenter; the key equivalent here
        // is display only, so the menu teaches the shortcut.
        let pauseItem = NSMenuItem(
            title: String(localized: "menu.pauseNotch", defaultValue: "Notch pausieren"),
            action: #selector(toggleNotch),
            keyEquivalent: "n"
        )
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseItem = pauseItem

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: String(localized: "menu.launchAtLogin", defaultValue: "Bei Anmeldung starten"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "menu.settings", defaultValue: "Einstellungen …"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: String(localized: "menu.quit", defaultValue: "Côte d'OS beenden"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    /// Reflect the pause state in the menu (checkmark) and the status icon
    /// (outline instead of filled), whichever of the two routes flipped it.
    func setNotchPaused(_ paused: Bool) {
        pauseItem?.state = paused ? .on : .off
        statusItem.button?.image = NSImage(
            systemSymbolName: paused ? "rectangle.topthird.inset" : "rectangle.topthird.inset.filled",
            accessibilityDescription: "Côte d'OS"
        )
    }

    @objc private func toggleNotch() {
        setNotchPaused(onToggleNotch())
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("CoteDOs: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
