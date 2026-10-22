import AppKit
import ApplicationServices

/// The handful of private WindowServer and accessibility symbols every serious window tool on macOS
/// (yabai, Hammerspoon, AltTab) relies on. They're resolved with dlsym so that a symbol disappearing in a
/// future macOS degrades one feature instead of stopping the app from launching.
enum PrivateAPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let linked = dlopen(nil, RTLD_LAZY)

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let getWindow: GetWindowFn? = load(linked, "_AXUIElementGetWindow")
    private static let getProcessForPID: GetProcessForPIDFn? = load(linked, "GetProcessForPID")
    private static let setFrontProcess: SetFrontProcessFn? = load(skyLight, "_SLPSSetFrontProcessWithOptions")
    private static let postEventRecord: PostEventRecordFn? = load(skyLight, "SLPSPostEventRecordTo")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = load(skyLight, "SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindowsFn? = load(skyLight, "SLSCopySpacesForWindows")
    private static let connection: Int32 = (load(skyLight, "SLSMainConnectionID") as MainConnectionFn?)?() ?? 0

    /// kCPSUserGenerated: treat the activation as if the user clicked.
    private static let userGenerated: UInt32 = 0x200
    /// Selector for SLSCopySpacesForWindows: current, other and user Spaces.
    private static let allSpaces: Int32 = 0x7

    /// The WindowServer id behind an accessibility window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Brings `pid` to the front and makes `windowID` its key window, switching Spaces if needed. This is what
    /// WindowServer does on a real click. `NSRunningApplication.activate` can't target a specific window and is
    /// subject to cooperative activation since macOS 14. Pass 0 to front the process without picking a window.
    @discardableResult
    static func makeFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr,
              setFrontProcess(&psn, windowID, userGenerated) == .success else { return false }
        guard windowID != 0 else { return true }

        // Synthesize the pair of "window became key" records WindowServer posts for a mouse-down/up on a window.
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { record.replaceSubrange(0x3c..<0x40, with: $0) }
        record.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        for phase: UInt8 in [0x01, 0x02] {
            record[0x08] = phase
            _ = postEventRecord(&psn, &record)
        }
        return true
    }

    /// Ids of the Spaces `windowID` lives on; empty for windows that aren't on any (minimized, unmapped helpers).
    static func spaces(forWindow windowID: CGWindowID) -> [UInt64] {
        guard let copySpacesForWindows,
              let ids = copySpacesForWindows(connection, allSpaces, [windowID] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return ids.map(\.uint64Value)
    }

    /// Every Space on every display, numbered the way Mission Control numbers them.
    static func spaceLayout() -> SpaceLayout? {
        guard let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }

        func id(of space: [String: Any]) -> UInt64? {
            ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
        }

        var current = Set<UInt64>()
        var names: [UInt64: String] = [:]
        var desktopNumber = 0
        for display in displays {
            if let space = display["Current Space"] as? [String: Any], let spaceID = id(of: space) {
                current.insert(spaceID)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let spaceID = id(of: space) else { continue }
                if (space["type"] as? Int) == 0 {
                    desktopNumber += 1
                    names[spaceID] = "Desktop \(desktopNumber)"
                } else {
                    names[spaceID] = "Full Screen"
                }
            }
        }
        return SpaceLayout(current: current, names: names)
    }
}

struct SpaceLayout {
    /// The Space showing on each display right now.
    let current: Set<UInt64>
    let names: [UInt64: String]

    /// A name like "Desktop 3" when the window lives only on Spaces that aren't showing; nil otherwise.
    func label(forWindow windowID: CGWindowID) -> String? {
        let spaces = PrivateAPI.spaces(forWindow: windowID)
        guard !spaces.isEmpty, current.isDisjoint(with: spaces) else { return nil }
        return spaces.lazy.compactMap { names[$0] }.first ?? "Other Space"
    }
}
