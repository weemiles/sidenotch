import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: UsageStore?
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        let controller = NotchController(store: store)
        self.store = store
        self.controller = controller

        controller.show()
        store.start()
        installStatusItem()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in controller.reposition() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "SideNotch"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: L.refreshNow, action: #selector(refresh), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: L.moveToCursorScreen, action: #selector(moveScreen), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L.openSettings, action: #selector(openConfig), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: L.reloadSettings, action: #selector(reloadConfig), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: L.launchAtLogin,
                                 action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: L.quit, action: #selector(quit), keyEquivalent: "q")
            .target = self

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func refresh() { store?.refreshNow() }

    @objc private func moveScreen() { controller?.moveToScreenUnderCursor() }

    @objc private func openConfig() {
        let url = Config.url
        if !FileManager.default.fileExists(atPath: url.path) { Config().save() }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfig() {
        store?.reloadConfig()
        controller?.reposition()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // Reflect the real login-item state each time the menu opens; the user can
    // also change it in System Settings, so a cached flag would drift.
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
