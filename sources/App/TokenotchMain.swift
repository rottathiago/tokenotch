import AppKit
import Combine
import TokenotchCore
import SwiftUI

@main
@MainActor
enum TokenotchMain {
    static func main() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: TokenotchModel?
    private var settings: NSWindowController?
    private var fleet: NotchFleet?
    private var status: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var applicationLock: ApplicationLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            applicationLock = try ApplicationLock(url: home.appendingPathComponent(".tokenotch-launch.lock"))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Tokenotch could not start"
            alert.informativeText = "Another copy of Tokenotch may already be running, or startup resources are unavailable. Quit other copies and check local permissions before retrying. Saved data has not been removed."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        startApplication()
    }

    private func startApplication() {
        let defaults = UserDefaults.standard
        let model = TokenotchModel(defaults: defaults)
        self.model = model
        let fleet = NotchFleet(model: model, openSettings: { [weak self] in self?.showSettings() })
        self.fleet = fleet
        model.expandNotch = { [weak fleet] in fleet?.reveal(allowSettings: false) }
        model.openNotificationDetails = { [weak self] in self?.showSettings() }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.status = status
        let statusImage = TokenotchBrand.menuBarImage ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        statusImage?.accessibilityDescription = "Tokenotch: Copilot status"
        status.button?.image = statusImage
        status.button?.toolTip = "Tokenotch — visibility into your AI coding usage and patterns"
        model.$sessions.combineLatest(model.$clock, model.$accountSnapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateMenu() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak model] _ in model?.resumeAfterWake() }
            .store(in: &cancellables)
        updateMenu()
        model.start()
        fleet.start()
        if !model.onboardingComplete {
            model.resumeOnboarding()
            showSettings()
        }
    }

    private func updateMenu() {
        guard let model else { return }
        let menu = NSMenu()
        let header = NSMenuItem(title: "Tokenotch · GitHub Copilot", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let count = model.sessions.filter { $0.isWorking(now: model.clock) }.count
        menu.addItem(withTitle: "\(count) observed working", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: model.usageMessage, action: nil, keyEquivalent: "")
        add("Show Copilot summary", action: #selector(reveal), to: menu)
        menu.addItem(.separator())
        add("Snooze for 30 minutes", action: #selector(snooze), to: menu)
        add("Resume notifications", action: #selector(resume), to: menu)
        add("Settings…", action: #selector(showSettings), to: menu, key: ",")
        add("Check for Updates…", action: #selector(checkForUpdates), to: menu)
        add("Quit Tokenotch", action: #selector(quit), to: menu, key: "q")
        status?.menu = menu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func reveal() {
        if model?.options.showNotch == true { fleet?.reveal(keyboard: true) } else { showSettings() }
    }
    @objc private func snooze() { model?.snooze(minutes: 30) }
    @objc private func resume() { model?.options.notifications.snoozedUntil = nil }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() {
        model?.settingsTab = .about
        showSettings()
        model?.updates.check()
    }

    @objc private func showSettings() {
        guard let model else { return }
        if settings == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            controller.sceneBridgingOptions = [.title, .toolbars]
            let window = NSWindow(contentViewController: controller)
            window.title = "Tokenotch"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 880, height: 720))
            window.contentMinSize = NSSize(width: 780, height: 560)
            window.setFrameAutosaveName("TokenotchSettings")
            settings = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        model.refreshPermission()
        model.refreshLoginItemStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        fleet?.stop()
        model?.stop()
    }
}
