import Foundation

enum Settings {
    private enum Key {
        static let otherSpaces = "showWindowsOnOtherSpaces"
        static let minimized = "showMinimizedWindows"
        static let hiddenApps = "showHiddenApps"
        static let windowlessApps = "showAppsWithoutWindows"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.otherSpaces: true,
            Key.minimized: true,
            Key.hiddenApps: true,
            Key.windowlessApps: true,
        ])
    }

    static var showOtherSpaces: Bool {
        get { defaults.bool(forKey: Key.otherSpaces) }
        set { defaults.set(newValue, forKey: Key.otherSpaces) }
    }

    static var showMinimized: Bool {
        get { defaults.bool(forKey: Key.minimized) }
        set { defaults.set(newValue, forKey: Key.minimized) }
    }

    static var showHiddenApps: Bool {
        get { defaults.bool(forKey: Key.hiddenApps) }
        set { defaults.set(newValue, forKey: Key.hiddenApps) }
    }

    static var showWindowlessApps: Bool {
        get { defaults.bool(forKey: Key.windowlessApps) }
        set { defaults.set(newValue, forKey: Key.windowlessApps) }
    }
}
