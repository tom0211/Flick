import AppKit

/// Runs `work` on the main actor after `delay` seconds.
func runOnMain(after delay: TimeInterval = 0, _ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated(work)
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension CGSize {
    /// The largest size with this aspect ratio that fits inside `box`.
    func aspectFit(in box: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return box }
        let scale = min(box.width / width, box.height / height)
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

extension Notification {
    var runningApplication: NSRunningApplication? {
        userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
}

extension NSImage {
    /// A stretchable rounded-rect mask for NSVisualEffectView, which otherwise draws square corners.
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
