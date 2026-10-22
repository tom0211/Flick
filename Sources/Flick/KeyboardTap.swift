import AppKit

/// A session-wide keyboard tap. It claims ⌥⇥ and ⌥` to open the switcher and, while the switcher is up,
/// every other keystroke. Everything else passes through untouched.
@MainActor
final class KeyboardTap {
    enum Action {
        case open(sameApp: Bool, reverse: Bool)
        case step(Int)
        case vertical(Int)
        case commit
        case cancel
        case close
        case minimize
        case hide
        case quit
    }

    var isSwitcherActive: @MainActor () -> Bool = { false }
    var onAction: @MainActor (Action) -> Void = { _ in }
    private var port: CFMachPort?

    private enum KeyCode {
        static let tab: Int64 = 48
        static let grave: Int64 = 50
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    /// Needs Accessibility permission; returns false without it.
    func start() -> Bool {
        if port != nil { return true }
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return passThrough
        case .flagsChanged:
            if isSwitcherActive() && !event.flags.contains(.maskAlternate) { onAction(.commit) }
            return passThrough
        case .keyDown:
            return handleKeyDown(event) ? nil : passThrough
        case .keyUp:
            return isSwitcherActive() ? nil : passThrough
        default:
            return passThrough
        }
    }

    /// Returns true when the keystroke was consumed.
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let active = isSwitcherActive()

        if flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl),
           key == KeyCode.tab || key == KeyCode.grave {
            let reverse = flags.contains(.maskShift)
            onAction(active ? .step(reverse ? -1 : 1) : .open(sameApp: key == KeyCode.grave, reverse: reverse))
            return true
        }
        guard active else { return false }

        switch key {
        case KeyCode.escape: onAction(.cancel)
        case KeyCode.returnKey, KeyCode.keypadEnter: onAction(.commit)
        case KeyCode.left: onAction(.step(-1))
        case KeyCode.right: onAction(.step(1))
        case KeyCode.up: onAction(.vertical(-1))
        case KeyCode.down: onAction(.vertical(1))
        default:
            // Letter commands: match by character so they follow the keyboard layout, and ignore auto-repeat
            // so holding W doesn't close a whole row of windows.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() else { break }
            switch character {
            case "w": onAction(.close)
            case "m": onAction(.minimize)
            case "h": onAction(.hide)
            case "q": onAction(.quit)
            default: break
            }
        }
        // While the switcher is up, keystrokes belong to it rather than the app underneath.
        return true
    }
}

private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardTap>.fromOpaque(context).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop.
    return MainActor.assumeIsolated { tap.handle(type, event) }
}
