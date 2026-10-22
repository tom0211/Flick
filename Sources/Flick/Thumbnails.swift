import AppKit
import ScreenCaptureKit

/// Window previews captured with ScreenCaptureKit. The cache lets the switcher show the last known image
/// instantly while a fresh one is captured.
@MainActor
final class ThumbnailStore {
    private var cache: [CGWindowID: NSImage] = [:]
    private var capture: Task<Void, Never>?

    func cached(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in cache[id].map { (id, $0) } })
    }

    func prune(keeping ids: Set<CGWindowID>) {
        cache = cache.filter { ids.contains($0.key) }
    }

    /// Captures `ids` at no more than `box` pixels, calling `onImage` as each one lands.
    func refresh(_ ids: [CGWindowID], fitting box: CGSize, onImage: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        guard !ids.isEmpty, Permissions.screenRecordingGranted else { return }
        capture?.cancel()
        capture = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
                  !Task.isCancelled else { return }
            let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in ids {
                    guard let window = windows[id] else { continue }
                    group.addTask { (id, await Self.capture(window, fitting: box)) }
                }
                for await (id, image) in group {
                    guard let image, !Task.isCancelled else { continue }
                    let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self?.cache[id] = thumbnail
                    onImage(id, thumbnail)
                }
            }
        }
    }

    private nonisolated static func capture(_ window: SCWindow, fitting box: CGSize) async -> CGImage? {
        let frame = window.frame
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        let scale = min(box.width / frame.width, box.height / frame.height, 2)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
