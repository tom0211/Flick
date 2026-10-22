import AppKit
import ApplicationServices

enum Permissions {
    private static let requestedAccessibilityKey = "requestedAccessibility"
    private static let requestedScreenRecordingKey = "requestedScreenRecording"

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// macOS caches this per process: a grant made while Flick is running only shows up after a relaunch.
    /// The check is a ~15 ms TCC round trip, and the switcher asks on every open, so it's cached: a grant is kept for
    /// good, and a refusal is re-checked at most every couple of seconds.
    static var screenRecordingGranted: Bool {
        screenRecordingCheck.lock.withLock {
            let now = Date()
            if let cached = screenRecordingCheck.value, cached || now.timeIntervalSince(screenRecordingCheck.checkedAt) < 2 {
                return cached
            }
            let granted = CGPreflightScreenCaptureAccess()
            screenRecordingCheck.value = granted
            screenRecordingCheck.checkedAt = now
            return granted
        }
    }

    private final class CachedCheck: @unchecked Sendable {
        let lock = NSLock()
        var value: Bool?
        var checkedAt = Date.distantPast
    }

    private static let screenRecordingCheck = CachedCheck()

    /// Asking adds Flick to the list in System Settings (again, if its entry was removed) and shows the system
    /// prompt the first time. The prompt doesn't come back after that, so repeat clicks also open the pane.
    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if UserDefaults.standard.bool(forKey: requestedAccessibilityKey) { open("Privacy_Accessibility") }
        UserDefaults.standard.set(true, forKey: requestedAccessibilityKey)
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        if UserDefaults.standard.bool(forKey: requestedScreenRecordingKey) { open("Privacy_ScreenCapture") }
        UserDefaults.standard.set(true, forKey: requestedScreenRecordingKey)
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app bundle, which is what it takes for a Screen Recording grant to apply.
    @MainActor
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return NSApp.terminate(nil) }
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", bundlePath]
        try? relauncher.run()
        NSApp.terminate(nil)
    }
}
