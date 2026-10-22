import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = FocusTracker()
    private lazy var windowManager = WindowManager(tracker: tracker)
    private lazy var switcher = SwitcherController(windows: windowManager)
    private let keyboard = KeyboardTap()
    private let onboarding = OnboardingWindowController()
    private var statusItem: NSStatusItem?
    private var accessibilityPoll: Timer?
    private var engineRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        // One hung app must not freeze the switcher, so cap every accessibility call (the default is 6 s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        keyboard.isSwitcherActive = { [unowned self] in switcher.isActive }
        keyboard.onAction = { [unowned self] action in switcher.handle(action) }
        setUpStatusItem()

        if Permissions.accessibilityGranted {
            startEngine()
        } else {
            onboarding.show()
            waitForAccessibility()
        }
    }

    /// Reopening the app from Finder or Spotlight brings up the permissions window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboarding.show()
        return false
    }

    private func startEngine() {
        guard !engineRunning else { return }
        tracker.start()
        engineRunning = keyboard.start()
        if !engineRunning { NSLog("Flick: couldn't install the keyboard tap even though Accessibility is granted") }
        updateStatusIcon()
        // The first accessibility round trip to each app is slow (~250 ms in total, vs ~5 ms warm). Pay it now
        // rather than on the first ⌥⇥.
        runOnMain(after: 0.5) { [weak self] in _ = self?.windowManager.snapshot() }
    }

    private func waitForAccessibility() {
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard Permissions.accessibilityGranted else { return }
                timer.invalidate()
                self?.startEngine()
            }
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol = engineRunning ? "rectangle.on.rectangle" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flick")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: engineRunning ? "Hold ⌥ and press ⇥ to switch" : "Waiting for Accessibility access", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if !Permissions.accessibilityGranted || !Permissions.screenRecordingGranted {
            menu.addItem(item("Permissions…", symbol: "exclamationmark.triangle", #selector(showPermissions)))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Show"))
        menu.addItem(item("Windows on Other Spaces", symbol: "rectangle.3.group", #selector(toggleOtherSpaces), isOn: Settings.showOtherSpaces))
        menu.addItem(item("Minimized Windows", symbol: "dock.arrow.down.rectangle", #selector(toggleMinimized), isOn: Settings.showMinimized))
        menu.addItem(item("Hidden Apps", symbol: "eye.slash", #selector(toggleHiddenApps), isOn: Settings.showHiddenApps))
        menu.addItem(item("Apps Without Windows", symbol: "app.dashed", #selector(toggleWindowlessApps), isOn: Settings.showWindowlessApps))

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", symbol: "power", #selector(toggleLaunchAtLogin), isOn: SMAppService.mainApp.status == .enabled))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Flick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    /// macOS 26 menus pair most items with a symbol; earlier versions simply show it too.
    private func item(_ title: String, symbol: String, _ action: Selector, isOn: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let isOn { item.state = isOn ? .on : .off }
        return item
    }

    @objc private func showPermissions() { onboarding.show() }
    @objc private func toggleOtherSpaces() { Settings.showOtherSpaces.toggle() }
    @objc private func toggleMinimized() { Settings.showMinimized.toggle() }
    @objc private func toggleHiddenApps() { Settings.showHiddenApps.toggle() }
    @objc private func toggleWindowlessApps() { Settings.showWindowlessApps.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
