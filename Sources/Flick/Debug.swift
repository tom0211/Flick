import AppKit
import SwiftUI

/// Command-line helpers for working on Flick without driving the real UI.
///
///     Flick --list                        print the switcher's current window list
///     Flick --render out.png [--demo]     render the panel's layout offscreen (no glass: that needs a live window)
///     Flick --snapshot out [options]      show the real panel for a moment and save captures of it:
///                                           out-1.png        as it appears
///                                           out-2…6.png      frames across a selection move
///                                           out-context.png  the panel over whatever is behind it
///
/// Options: `--demo` swaps in synthetic windows with colourful previews; `--backdrop` puts a colourful backdrop
/// behind the panel (so screenshots don't show your desktop); `--light` / `--dark` force the appearance.
/// Run `--snapshot` through the bundle (`open -n Flick.app --args --snapshot …`) so it has Flick's permissions.
@MainActor
enum Debug {
    static func run(_ command: String, arguments: [String]) -> Bool {
        let path = arguments.first { !$0.hasPrefix("--") }
        let demo = arguments.contains("--demo")
        switch command {
        case "--list":
            listWindows()
        case "--render":
            render(to: path ?? "flick-render.png", demo: demo)
        case "--snapshot":
            let appearance: NSAppearance.Name? = arguments.contains("--dark") ? .darkAqua : arguments.contains("--light") ? .aqua : nil
            snapshotPanel(to: path ?? "flick-snapshot", demo: demo, backdrop: arguments.contains("--backdrop"), appearance: appearance)
        case "--help", "-h":
            print("usage: Flick [--list | --render <file.png> [--demo] | --snapshot <path prefix> [--demo] [--backdrop] [--light | --dark]]")
        default:
            return false
        }
        return true
    }

    /// Shows a real SwitcherPanel and captures its window, which is the only way to see Liquid Glass as it
    /// actually composites. Never returns: it exits once the captures are written.
    private static func snapshotPanel(to prefix: String, demo: Bool, backdrop: Bool, appearance: NSAppearance.Name?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let appearance { app.appearance = NSAppearance(named: appearance) }

        let model = SwitcherModel()
        let items = demo ? demoItems(from: snapshot()) : snapshot()
        // The sharpest screen, so captures come out at Retina resolution.
        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }), !items.isEmpty else {
            print("nothing to show")
            exit(1)
        }
        let layout = SwitcherLayout.fitting(count: items.count, in: screen.visibleFrame.size)
        model.items = items
        model.selection = min(1, items.count - 1)
        model.metrics = layout.metrics
        model.columns = layout.columns
        model.scrolls = layout.scrolls

        let thumbnails = ThumbnailStore()
        if demo {
            for (index, item) in items.enumerated() where !item.isMinimized {
                guard let id = item.windowID else { continue }
                model.thumbnails[id] = fakePreview(size: item.windowSize, hue: CGFloat(index) * 0.13)
            }
        } else {
            let scale = screen.backingScaleFactor
            let box = CGSize(width: layout.metrics.previewWidth * scale, height: layout.metrics.previewHeight * scale)
            thumbnails.refresh(items.compactMap(\.windowID), fitting: box) { id, image in model.thumbnails[id] = image }
        }

        let panel = SwitcherPanel(model: model, onHover: { _ in }, onClick: { _ in })
        panel.show(size: layout.size, on: screen)
        let backdropWindow = backdrop ? showBackdrop(behind: panel) : nil

        // -1: as shown. Then the selection moves and -2…-6 sample the slide. -context: the panel over whatever is
        // behind it (other apps' windows only appear with Screen Recording permission).
        // Frames are only grabbed into memory during the slide; encoding PNGs takes long enough to stall the run
        // loop and starve SwiftUI of the chance to draw in between.
        let target = min(3, items.count - 1)
        let frames = FrameLog()
        runOnMain(after: 1.2) {
            frames.grab(panel)
            frames.start = Date()
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) { model.selection = target }
        }
        for delay in [0.03, 0.07, 0.12, 0.18, 0.5] {
            runOnMain(after: 1.2 + delay) { frames.grab(panel) }
        }
        runOnMain(after: 1.9) {
            for (index, frame) in frames.images.enumerated() {
                writePNG(frame.image, to: "\(prefix)-\(index + 1).png")
                print("  frame \(index + 1) at +\(Int(frame.offset * 1000)) ms")
            }
            if let context = capture(panel, withBackground: true) { writePNG(context, to: "\(prefix)-context.png") }
            withExtendedLifetime((thumbnails, backdropWindow)) {}
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// A colourful stand-in for a desktop, just below the panel, so the glass has something to refract.
    private static func showBackdrop(behind panel: NSWindow) -> NSWindow {
        let window = NSWindow(contentRect: panel.frame.insetBy(dx: -160, dy: -160), styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Backdrop())
        window.orderFrontRegardless()
        return window
    }

    private struct Backdrop: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let dark = colorScheme == .dark
            ZStack {
                LinearGradient(
                    colors: dark
                        ? [Color(red: 0.10, green: 0.10, blue: 0.24), Color(red: 0.24, green: 0.10, blue: 0.30)]
                        : [Color(red: 0.62, green: 0.76, blue: 0.98), Color(red: 0.98, green: 0.78, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                blob(Color(red: 1.0, green: 0.55, blue: 0.25), size: 520, x: -0.32, y: -0.22)
                blob(Color(red: 0.20, green: 0.75, blue: 0.70), size: 620, x: 0.34, y: 0.20)
                blob(Color(red: 0.55, green: 0.35, blue: 0.95), size: 460, x: 0.02, y: 0.30)
            }
            .opacity(dark ? 0.9 : 1)
        }

        private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
            GeometryReader { geometry in
                Circle()
                    .fill(color.opacity(0.75))
                    .frame(width: size, height: size)
                    .blur(radius: 90)
                    .position(x: geometry.size.width * (0.5 + x), y: geometry.size.height * (0.5 + y))
            }
        }
    }

    @MainActor
    private final class FrameLog {
        var start: Date?
        var images: [(image: CGImage, offset: TimeInterval)] = []

        func grab(_ window: NSWindow) {
            guard let image = capture(window) else { return }
            images.append((image, start.map { Date().timeIntervalSince($0) } ?? 0))
        }
    }

    /// Captures one of our own windows, as WindowServer composites it (glass, shadow and all), optionally with
    /// everything beneath it.
    private static func capture(_ window: NSWindow, withBackground: Bool = false) -> CGImage? {
        // Deprecated in favour of ScreenCaptureKit, but still the simplest way to grab our own window, and it
        // needs no permission for that. Loaded dynamically because Swift marks it unavailable on newer SDKs.
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)

        var bounds = CGRect.null
        var options: CGWindowListOption = .optionIncludingWindow
        if withBackground, let primary = NSScreen.screens.first {
            // CoreGraphics uses top-left-origin global coordinates.
            let frame = window.frame.insetBy(dx: -40, dy: -40)
            bounds = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            options = [.optionOnScreenBelowWindow, .optionIncludingWindow]
        }
        return createImage(bounds, options, CGWindowID(window.windowNumber), .bestResolution)?.takeRetainedValue()
    }

    /// Writes `image` as an 8-bit sRGB PNG. On an HDR display AppKit and SwiftUI hand back 16-bit extended-range
    /// images that most viewers show washed out.
    private static func writePNG(_ image: CGImage, to path: String) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return print("couldn't convert \(path)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:]) else {
            return print("couldn't encode \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("couldn't write \(path): \(error.localizedDescription)")
        }
    }

    private static func snapshot() -> [SwitcherItem] {
        Settings.registerDefaults()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        return WindowManager(tracker: FocusTracker()).snapshot()
    }

    private static func listWindows() {
        print("Accessibility: \(Permissions.accessibilityGranted ? "granted" : "missing (only on-screen windows, via WindowServer)")")
        print("Screen Recording: \(Permissions.screenRecordingGranted ? "granted" : "missing (no previews, fewer titles)")")
        let items = snapshot()
        for (index, item) in items.enumerated() {
            var notes: [String] = []
            if item.windowID == nil { notes.append("no windows") }
            if item.isMinimized { notes.append("minimized") }
            if item.isHidden { notes.append("hidden") }
            if let space = item.spaceLabel { notes.append(space) }
            if item.windowID != nil && item.axWindow == nil { notes.append("server-only") }
            let id = item.windowID.map(String.init) ?? "-"
            print("\(String(index + 1).padding(3)) \(item.appName.padding(18)) \(id.padding(7)) \(item.title.prefix(48))  \(notes.joined(separator: ", "))")
        }
        print("\(items.count) item(s)")
    }

    private static func render(to path: String, demo: Bool) {
        _ = NSApplication.shared
        var items = snapshot()
        let model = SwitcherModel()

        if demo {
            items = demoItems(from: items)
            for (index, item) in items.enumerated() where !item.isMinimized {
                guard let id = item.windowID else { continue }
                model.thumbnails[id] = fakePreview(size: item.windowSize, hue: CGFloat(index) * 0.13)
            }
        }

        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 900)
        let layout = SwitcherLayout.fitting(count: items.count, in: screen)
        model.items = items
        model.selection = min(1, max(items.count - 1, 0))
        model.metrics = layout.metrics
        model.columns = layout.columns
        model.scrolls = false

        let view = SwitcherView(model: model)
            .frame(width: layout.size.width, height: layout.size.height)
            .background(
                RoundedRectangle(cornerRadius: TileMetrics.panelCornerRadius, style: .continuous)
                    .fill(Color(white: 0.16).opacity(0.96))
            )
            .padding(40)
            .background(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return print("render failed") }
        writePNG(rendered, to: path)
        print("\(items.count) items, \(layout.columns) columns, \(Int(layout.size.width))×\(Int(layout.size.height)) pt")
    }

    /// Plausible windows for the running apps, for judging the layout (and taking screenshots) without showing
    /// anyone's real windows.
    private static func demoItems(from real: [SwitcherItem]) -> [SwitcherItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let titles: [String: String] = [
            "com.apple.finder": "Downloads",
            "com.apple.Notes": "Quarterly planning",
            "com.apple.Safari": "Release notes",
            "com.google.Chrome": "Release checklist",
            "com.microsoft.VSCode": "SwitcherView.swift — flick",
            "com.apple.dt.Xcode": "SwitcherPanel.swift — flick",
            "com.apple.Terminal": "zsh — 120×40",
            "com.apple.Music": "Recently Added",
            "com.apple.mail": "Inbox — 3 unread",
            "com.apple.MobileSMS": "Messages",
            "com.tinyspeck.slackmacgap": "#design",
        ]
        let sizes = [CGSize(width: 1440, height: 900), CGSize(width: 1200, height: 800), CGSize(width: 900, height: 700), CGSize(width: 1600, height: 1000), CGSize(width: 800, height: 900)]
        var items: [SwitcherItem] = []
        // Five fit on one row even on a laptop screen, which makes for a tidier screenshot.
        for (index, app) in apps.prefix(5).enumerated() {
            let name = app.localizedName ?? ""
            items.append(SwitcherItem(
                id: "demo\(index)",
                app: app,
                windowID: CGWindowID(900_000 + index),
                axWindow: nil,
                title: app.bundleIdentifier.flatMap { titles[$0] } ?? name,
                windowSize: sizes[index % sizes.count],
                isMinimized: index == 4,
                isHidden: false,
                spaceLabel: index == 3 ? "Desktop 2" : nil
            ))
        }
        return items.isEmpty ? real : items
    }

    private static func fakePreview(size: CGSize, hue: CGFloat) -> NSImage {
        let scaled = size.aspectFit(in: CGSize(width: 460, height: 288))
        return NSImage(size: scaled, flipped: true) { rect in
            NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.18, brightness: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 22).fill()
            for (offset, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 8 + CGFloat(offset) * 14, y: 6, width: 10, height: 10)).fill()
            }
            NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.75, alpha: 0.35).setFill()
            for line in 0..<6 {
                let width = rect.width * (line.isMultiple(of: 2) ? 0.7 : 0.5)
                NSBezierPath(roundedRect: NSRect(x: 18, y: 40 + CGFloat(line) * 24, width: width, height: 10), xRadius: 5, yRadius: 5).fill()
            }
            return true
        }
    }
}

private extension String {
    func padding(_ width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
}
