import CoreGraphics

/// One window as WindowServer sees it.
struct ServerWindow {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    /// Only readable with Screen Recording permission.
    let title: String?
    let isOnScreen: Bool
}

/// A point-in-time listing of every window WindowServer knows about, on every Space.
struct WindowInventory {
    let windows: [ServerWindow]
    let byID: [CGWindowID: ServerWindow]
    /// Front-to-back position of each normal on-screen window.
    let stackingOrder: [CGWindowID: Int]

    init() {
        windows = Self.list([.optionAll, .excludeDesktopElements])
        byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stackingOrder = Dictionary(
            Self.onScreenStack().enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Normal-layer windows that are on screen, frontmost first.
    static func onScreenStack() -> [ServerWindow] {
        list([.optionOnScreenOnly, .excludeDesktopElements]).filter { $0.layer == 0 }
    }

    private static func list(_ options: CGWindowListOption) -> [ServerWindow] {
        let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let bounds = (entry[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return ServerWindow(
                id: id,
                pid: pid,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds,
                title: entry[kCGWindowName as String] as? String,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
    }
}
