import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browser: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let browser = BrowserWindowController()
        self.browser = browser
        browser.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ChatGPT Stable")
        appMenu.addItem(withTitle: "About ChatGPT Stable", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Health Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: "d").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ChatGPT Stable", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let navigationItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "Navigation")
        addMenuItem(navigationMenu, title: "Back", action: #selector(goBack(_:)), key: "[")
        addMenuItem(navigationMenu, title: "Forward", action: #selector(goForward(_:)), key: "]")
        navigationMenu.addItem(.separator())
        addMenuItem(navigationMenu, title: "Reload", action: #selector(reload(_:)), key: "r")
        let hard = addMenuItem(navigationMenu, title: "Hard Reload", action: #selector(hardReload(_:)), key: "r")
        hard.keyEquivalentModifierMask = [.command, .shift]
        addMenuItem(navigationMenu, title: "Recover Now", action: #selector(recoverNow(_:)), key: "k")
        addMenuItem(navigationMenu, title: "Optimize Conversation Now", action: #selector(optimizeNow(_:)), key: "")
        addMenuItem(navigationMenu, title: "ChatGPT Home", action: #selector(goHome(_:)), key: "0")
        navigationMenu.addItem(.separator())
        addMenuItem(navigationMenu, title: "Open Current Page in Browser", action: #selector(openInBrowser(_:)), key: "o")
        navigationItem.submenu = navigationMenu
        mainMenu.addItem(navigationItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector, key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func reload(_ sender: Any?) { browser?.reload(sender) }
    @objc private func hardReload(_ sender: Any?) { browser?.hardReload(sender) }
    @objc private func recoverNow(_ sender: Any?) { browser?.recoverNow() }
    @objc private func optimizeNow(_ sender: Any?) { browser?.optimizeNow() }
    @objc private func showDiagnostics(_ sender: Any?) { browser?.presentDiagnostics() }
    @objc private func goBack(_ sender: Any?) { browser?.goBack(sender) }
    @objc private func goForward(_ sender: Any?) { browser?.goForward(sender) }
    @objc private func goHome(_ sender: Any?) { browser?.goHome(sender) }
    @objc private func openInBrowser(_ sender: Any?) { browser?.openCurrentPageInBrowser(sender) }
}
