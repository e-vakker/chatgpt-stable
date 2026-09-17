import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browser: BrowserWindowController?
    private weak var standardInterfaceItem: NSMenuItem?
    private weak var leanInterfaceItem: NSMenuItem?
    private weak var terminalInterfaceItem: NSMenuItem?

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
        appMenu.addItem(withTitle: "Health Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: "").target = self
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
        addMenuItem(navigationMenu, title: "Recover Now", action: #selector(recoverNow(_:)), key: "")
        addMenuItem(navigationMenu, title: "Optimize Conversation Now", action: #selector(optimizeNow(_:)), key: "")
        let interfaceItem = NSMenuItem(title: "Interface", action: nil, keyEquivalent: "")
        let interfaceMenu = NSMenu(title: "Interface")
        let standard = addMenuItem(interfaceMenu, title: InterfaceMode.standard.displayName, action: #selector(useStandardInterface(_:)), key: "")
        let lean = addMenuItem(interfaceMenu, title: InterfaceMode.lean.displayName, action: #selector(useLeanInterface(_:)), key: "")
        let terminal = addMenuItem(interfaceMenu, title: InterfaceMode.terminal.displayName, action: #selector(useTerminalInterface(_:)), key: "")
        standardInterfaceItem = standard
        leanInterfaceItem = lean
        terminalInterfaceItem = terminal
        terminal.state = .on
        interfaceItem.submenu = interfaceMenu
        navigationMenu.addItem(interfaceItem)
        navigationMenu.addItem(.separator())
        addMenuItem(navigationMenu, title: "ChatGPT Home", action: #selector(goHome(_:)), key: "")
        navigationMenu.addItem(.separator())
        addMenuItem(navigationMenu, title: "Open Current Page in Browser", action: #selector(openInBrowser(_:)), key: "")
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
    private func selectInterface(_ mode: InterfaceMode) {
        browser?.setInterfaceMode(mode)
        standardInterfaceItem?.state = mode == .standard ? .on : .off
        leanInterfaceItem?.state = mode == .lean ? .on : .off
        terminalInterfaceItem?.state = mode == .terminal ? .on : .off
    }

    @objc private func useStandardInterface(_ sender: Any?) { selectInterface(.standard) }
    @objc private func useLeanInterface(_ sender: Any?) { selectInterface(.lean) }
    @objc private func useTerminalInterface(_ sender: Any?) { selectInterface(.terminal) }
    @objc private func showDiagnostics(_ sender: Any?) { browser?.presentDiagnostics() }
    @objc private func goBack(_ sender: Any?) { browser?.goBack(sender) }
    @objc private func goForward(_ sender: Any?) { browser?.goForward(sender) }
    @objc private func goHome(_ sender: Any?) { browser?.goHome(sender) }
    @objc private func openInBrowser(_ sender: Any?) { browser?.openCurrentPageInBrowser(sender) }
}
