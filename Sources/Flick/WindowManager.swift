import AppKit

/// One entry in the switcher: a window, or an app that has none.
struct SwitcherItem: Identifiable {
    let id: String
    let app: NSRunningApplication
    /// nil for an app with no windows.
    let windowID: CGWindowID?
    /// nil for windows the accessibility API can't reach, such as those on another Space.
    let axWindow: AXUIElement?
    let title: String
    let windowSize: CGSize
    var isMinimized: Bool
    var isHidden: Bool
    /// Set when the window lives on a Space that isn't showing, e.g. "Desktop 2".
    let spaceLabel: String?

    var pid: pid_t { app.processIdentifier }
    var appName: String { app.localizedName ?? "App" }
    var icon: NSImage { app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage() }
}

@MainActor
final class WindowManager {
    let tracker: FocusTracker
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let switchableSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

    init(tracker: FocusTracker) {
        self.tracker = tracker
    }

    /// The window with keyboard focus right now.
    func focusedWindowID() -> CGWindowID? {
        tracker.syncWithFrontmost()
    }

    /// Every switchable window (or just one app's), most recently focused first.
    func snapshot(onlyApp filter: pid_t? = nil) -> [SwitcherItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && !app.isTerminated
                && app.processIdentifier != ownPID
                && (filter == nil || app.processIdentifier == filter)
                && (Settings.showHiddenApps || !app.isHidden)
        }
        let inventory = WindowInventory()
        let spaces = Settings.showOtherSpaces ? PrivateAPI.spaceLayout() : nil

        var items: [SwitcherItem] = []
        var listed = Set<CGWindowID>()
        var unreachable = Set<pid_t>()

        for app in apps {
            guard let axWindows = AXUIElementCreateApplication(app.processIdentifier).windows else {
                unreachable.insert(app.processIdentifier)
                continue
            }
            for window in axWindows {
                guard let id = window.windowID, !listed.contains(id) else { continue }
                let attributes = window.windowAttributes
                guard let subrole = attributes.subrole, Self.switchableSubroles.contains(subrole) else { continue }
                let server = inventory.byID[id]
                guard (server?.layer ?? 0) == 0 else { continue }
                let minimized = attributes.isMinimized
                guard Settings.showMinimized || !minimized else { continue }
                let size = attributes.size ?? server?.bounds.size ?? .zero
                guard size.width >= 50, size.height >= 50 else { continue }

                var spaceLabel: String?
                if let spaces, let server, !server.isOnScreen, !minimized, !app.isHidden {
                    spaceLabel = spaces.label(forWindow: id)
                }
                listed.insert(id)
                items.append(SwitcherItem(
                    id: "w\(id)",
                    app: app,
                    windowID: id,
                    axWindow: window,
                    title: attributes.title.nonEmpty ?? server?.title.nonEmpty ?? app.localizedName ?? "",
                    windowSize: size,
                    isMinimized: minimized,
                    isHidden: app.isHidden,
                    spaceLabel: spaceLabel
                ))
            }
        }

        items += serverOnlyWindows(inventory: inventory, apps: apps, listed: listed, unreachable: unreachable, spaces: spaces)

        if Settings.showWindowlessApps {
            let withWindows = Set(items.map(\.pid))
            items += apps.filter { !withWindows.contains($0.processIdentifier) }.map { app in
                SwitcherItem(
                    id: "a\(app.processIdentifier)",
                    app: app,
                    windowID: nil,
                    axWindow: nil,
                    title: app.localizedName ?? "",
                    windowSize: .zero,
                    isMinimized: false,
                    isHidden: app.isHidden,
                    spaceLabel: nil
                )
            }
        }

        return sortedByRecency(items, stackingOrder: inventory.stackingOrder)
    }

    /// Windows the accessibility API doesn't report: those on other Spaces, plus everything belonging to apps
    /// whose accessibility calls failed (hung, or Flick isn't trusted yet).
    private func serverOnlyWindows(
        inventory: WindowInventory,
        apps: [NSRunningApplication],
        listed: Set<CGWindowID>,
        unreachable: Set<pid_t>,
        spaces: SpaceLayout?
    ) -> [SwitcherItem] {
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let titlesReadable = Permissions.screenRecordingGranted

        return inventory.windows.compactMap { window in
            guard !listed.contains(window.id), window.layer == 0, window.alpha > 0,
                  window.bounds.width >= 150, window.bounds.height >= 100,
                  let app = appsByPID[window.pid] else { return nil }

            var spaceLabel: String?
            if unreachable.contains(window.pid) {
                guard window.isOnScreen else { return nil }
            } else {
                guard let spaces, !window.isOnScreen, let label = spaces.label(forWindow: window.id) else { return nil }
                // Apps park invisible helper windows on Spaces too. When titles are readable, a missing one gives them away.
                if titlesReadable && window.title.nonEmpty == nil { return nil }
                spaceLabel = label
            }
            return SwitcherItem(
                id: "w\(window.id)",
                app: app,
                windowID: window.id,
                axWindow: nil,
                title: window.title.nonEmpty ?? app.localizedName ?? "",
                windowSize: window.bounds.size,
                isMinimized: false,
                isHidden: app.isHidden,
                spaceLabel: spaceLabel
            )
        }
    }

    private func sortedByRecency(_ items: [SwitcherItem], stackingOrder: [CGWindowID: Int]) -> [SwitcherItem] {
        // Windows we've seen focused, newest first; then the rest of the visible stack, front to back; then
        // windows we know nothing about, grouped by app recency; then apps without windows.
        func key(_ item: SwitcherItem) -> (Int, UInt64, Int) {
            let appAge = UInt64.max - (tracker.appStamp(item.pid) ?? 0)
            guard let id = item.windowID else { return (3, appAge, 0) }
            if let stamp = tracker.windowStamp(id) { return (0, UInt64.max - stamp, 0) }
            if let depth = stackingOrder[id] { return (1, 0, depth) }
            return (2, appAge, 0)
        }
        return items.enumerated()
            .map { (key: key($0.element), offset: $0.offset, item: $0.element) }
            .sorted { ($0.key.0, $0.key.1, $0.key.2, $0.offset) < ($1.key.0, $1.key.1, $1.key.2, $1.offset) }
            .map(\.item)
    }

    // MARK: - Actions

    func focus(_ item: SwitcherItem) {
        let app = item.app
        guard let windowID = item.windowID else { return reopen(app) }

        if app.isHidden { app.unhide() }
        if item.isMinimized { item.axWindow?.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        if !PrivateAPI.makeFront(pid: item.pid, windowID: windowID) { app.activate() }
        if let window = item.axWindow {
            window.set(kAXMainAttribute, kCFBooleanTrue)
            window.perform(kAXRaiseAction)
        }
        tracker.noteFocused(windowID: windowID, pid: item.pid)
    }

    /// Like clicking an app's Dock icon: most apps answer the reopen event with a fresh window.
    private func reopen(_ app: NSRunningApplication) {
        PrivateAPI.makeFront(pid: app.processIdentifier, windowID: 0)
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.activate()
        }
        tracker.noteFocused(windowID: nil, pid: app.processIdentifier)
    }

    @discardableResult
    func close(_ item: SwitcherItem) -> Bool {
        guard let button: AXUIElement = item.axWindow?.value(kAXCloseButtonAttribute) else { return false }
        return button.perform(kAXPressAction)
    }

    @discardableResult
    func setMinimized(_ item: SwitcherItem, _ minimized: Bool) -> Bool {
        item.axWindow?.set(kAXMinimizedAttribute, minimized ? kCFBooleanTrue : kCFBooleanFalse) ?? false
    }

    func setHidden(_ item: SwitcherItem, _ hidden: Bool) {
        if hidden { item.app.hide() } else { item.app.unhide() }
    }

    func quit(_ item: SwitcherItem) {
        item.app.terminate()
    }
}
