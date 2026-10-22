import AppKit

/// Remembers the order in which windows and apps were last focused, so the switcher can list them
/// most-recent first, the way ⌘⇥ orders apps.
@MainActor
final class FocusTracker {
    private var clock: UInt64 = 0
    private var windowStamps: [CGWindowID: UInt64] = [:]
    private var appStamps: [pid_t: UInt64] = [:]
    private var lastFocusedWindow: CGWindowID?
    private var observers: [pid_t: AXObserver] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    func start() {
        guard notificationTokens.isEmpty else { return }

        // Until real focus changes come in, the on-screen stacking order is the best guess at recency.
        for window in WindowInventory.onScreenStack().reversed() {
            clock += 1
            windowStamps[window.id] = clock
        }

        let center = NSWorkspace.shared.notificationCenter
        notificationTokens = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.runningApplication else { return }
                MainActor.assumeIsolated { self?.appDidActivate(app) }
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.runningApplication else { return }
                MainActor.assumeIsolated { self?.observe(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.runningApplication else { return }
                MainActor.assumeIsolated { self?.forget(app) }
            },
        ]

        NSWorkspace.shared.runningApplications.forEach { observe($0) }
        if let front = NSWorkspace.shared.frontmostApplication { appDidActivate(front) }
    }

    func windowStamp(_ id: CGWindowID) -> UInt64? { windowStamps[id] }
    func appStamp(_ pid: pid_t) -> UInt64? { appStamps[pid] }

    func noteFocused(windowID: CGWindowID?, pid: pid_t) {
        clock += 1
        appStamps[pid] = clock
        if let windowID {
            windowStamps[windowID] = clock
            lastFocusedWindow = windowID
        }
    }

    /// Re-reads which window has focus right now, in case a change slipped past the observers.
    @discardableResult
    func syncWithFrontmost() -> CGWindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let focused = AXUIElementCreateApplication(front.processIdentifier).focusedWindow?.windowID
        if let focused, focused != lastFocusedWindow {
            noteFocused(windowID: focused, pid: front.processIdentifier)
        }
        return focused
    }

    private func appDidActivate(_ app: NSRunningApplication) {
        observe(app)
        let focused = AXUIElementCreateApplication(app.processIdentifier).focusedWindow?.windowID
        noteFocused(windowID: focused, pid: app.processIdentifier)
    }

    fileprivate func focusedWindowChanged(_ element: AXUIElement) {
        // Background apps shuffle focus between their own windows too; only the frontmost app's changes count.
        guard let pid = element.pid, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let focused = element.windowID ?? AXUIElementCreateApplication(pid).focusedWindow?.windowID
        noteFocused(windowID: focused, pid: pid)
    }

    private func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, !app.isTerminated, observers[pid] == nil, pid != getpid() else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, focusedWindowCallback, &created) == .success, let observer = created else { return }
        let result = AXObserverAddNotification(
            observer,
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard result == .success || result == .notificationAlreadyRegistered else {
            // Apps that have only just launched often aren't ready to be observed yet.
            if attempt < 4 {
                runOnMain(after: 0.5 * Double(attempt + 1)) { [weak self] in self?.observe(app, attempt: attempt + 1) }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func forget(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        appStamps[pid] = nil
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}

private func focusedWindowCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.focusedWindowChanged(element) }
}
