import AppKit
import SwiftUI

/// The floating HUD. It never becomes key or activates Flick: the keyboard tap drives it, and mouse clicks
/// are hit-tested against the tile frames SwiftUI reports.
final class SwitcherPanel: NSPanel {
    init(model: SwitcherModel, onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        let host = SwitcherHostingView(rootView: SwitcherView(model: model))
        host.model = model
        host.onHover = onHover
        host.onClick = onClick
        host.sizingOptions = []

        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        contentView = Self.platter(hosting: host)
    }

    /// Liquid Glass on macOS 26 and later; the HUD material before that.
    private static func platter(hosting host: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = TileMetrics.panelCornerRadius
            glass.contentView = host
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = .roundedRectMask(radius: TileMetrics.panelCornerRadius)
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        return material
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(size: CGSize, on screen: NSScreen) {
        let area = screen.visibleFrame
        let frame = NSRect(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        if frame != self.frame { setFrame(frame, display: true) }
        guard !isVisible else { return invalidateShadow() }

        // A quick fade-in, the way glass surfaces materialize. Dismissal stays instant so switching never waits.
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = fades ? 0 : 1
        orderFrontRegardless()
        invalidateShadow()
        guard fades else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }
}

private final class SwitcherHostingView: NSHostingView<SwitcherView> {
    weak var model: SwitcherModel?
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private var pressedIndex: Int?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // .activeAlways because the panel is never key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // Only real mouse movement selects, so a panel appearing under a resting pointer doesn't steal the selection.
    override func mouseMoved(with event: NSEvent) {
        if let index = tileIndex(at: event) { onHover?(index) }
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = tileIndex(at: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedIndex = nil }
        guard let index = tileIndex(at: event), index == pressedIndex else { return }
        onClick?(index)
    }

    private func tileIndex(at event: NSEvent) -> Int? {
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        return MainActor.assumeIsolated { model?.tileFrames.first { $0.value.contains(point) }?.key }
    }
}
