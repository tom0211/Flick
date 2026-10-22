import AppKit
import SwiftUI

@MainActor
final class SwitcherController {
    private(set) var isActive = false

    private let windows: WindowManager
    private let thumbnails = ThumbnailStore()
    private let model = SwitcherModel()
    private lazy var panel = SwitcherPanel(
        model: model,
        onHover: { [weak self] index in MainActor.assumeIsolated { self?.select(index) } },
        onClick: { [weak self] index in
            MainActor.assumeIsolated {
                self?.select(index)
                self?.commit()
            }
        }
    )

    private var appFilter: pid_t?
    private var screen: NSScreen?
    private var panelSize: CGSize = .zero
    private var reveal: DispatchWorkItem?
    private var releaseWatch: Timer?
    /// Apps we've asked to quit during this session of the switcher, kept out of refreshed lists while they wind down.
    private var quitting = Set<pid_t>()

    /// How long ⌥ has to stay down before the panel appears, so a quick ⌥⇥ flips to the previous window
    /// without flashing any UI.
    private let revealDelay: TimeInterval = 0.1

    init(windows: WindowManager) {
        self.windows = windows
    }

    /// Called from inside the keyboard tap. Opening is flagged right away so the keystrokes that follow are routed
    /// to the switcher, but the work itself waits for the next main-queue turn to keep the tap callback fast.
    func handle(_ action: KeyboardTap.Action) {
        if case .open = action { isActive = true }
        runOnMain { [weak self] in self?.perform(action) }
    }

    private func perform(_ action: KeyboardTap.Action) {
        if case let .open(sameApp, reverse) = action {
            return open(sameApp: sameApp, reverse: reverse)
        }
        guard isActive else { return }
        switch action {
        case .open: break
        case .step(let delta): step(delta)
        case .vertical(let delta): moveVertically(delta)
        case .commit: commit()
        case .cancel: dismiss()
        case .close, .minimize, .hide, .quit: run(action)
        }
    }

    // MARK: - Lifecycle

    private func open(sameApp: Bool, reverse: Bool) {
        let focused = windows.focusedWindowID()
        appFilter = sameApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        quitting = []
        let items = windows.snapshot(onlyApp: appFilter)
        guard !items.isEmpty else {
            isActive = false
            return
        }

        // ⌥⇥ goes to the *previous* window, so skip past the one that already has focus.
        let firstIsFocused = items[0].windowID != nil && items[0].windowID == focused
        model.items = items
        model.selection = reverse ? items.count - 1 : (firstIsFocused && items.count > 1 ? 1 : 0)
        model.thumbnails = thumbnails.cached(for: items.compactMap(\.windowID))
        if appFilter == nil { thumbnails.prune(keeping: Set(items.compactMap(\.windowID))) }

        screen = NSScreen.underMouse ?? NSScreen.main
        applyLayout()
        refreshThumbnails()

        let reveal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, let screen = self.screen else { return }
                self.panel.show(size: self.panelSize, on: screen)
            }
        }
        self.reveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: reveal)

        // Backstop for a missed ⌥ release (Secure Input switching on mid-switch can swallow it).
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { self?.commit() }
            }
        }
    }

    private func commit() {
        guard isActive else { return }
        let item = model.selectedItem
        dismiss()
        if let item { windows.focus(item) }
    }

    private func dismiss() {
        isActive = false
        reveal?.cancel()
        reveal = nil
        releaseWatch?.invalidate()
        releaseWatch = nil
        panel.orderOut(nil)
    }

    private func applyLayout() {
        guard let screen else { return }
        let layout = SwitcherLayout.fitting(count: model.items.count, in: screen.visibleFrame.size)
        model.metrics = layout.metrics
        model.columns = layout.columns
        model.scrolls = layout.scrolls
        panelSize = layout.size
        if panel.isVisible { panel.show(size: layout.size, on: screen) }
    }

    private func refreshThumbnails() {
        let scale = screen?.backingScaleFactor ?? 2
        let box = CGSize(width: model.metrics.previewWidth * scale, height: model.metrics.previewHeight * scale)
        // Minimized and hidden windows can't be captured; their cached image (if any) stays.
        let ids = model.items.filter { !$0.isMinimized && !$0.isHidden }.compactMap(\.windowID)
        thumbnails.refresh(ids, fitting: box) { [weak self] id, image in
            self?.model.thumbnails[id] = image
        }
    }

    // MARK: - Navigation

    private func select(_ index: Int) {
        guard isActive, model.items.indices.contains(index) else { return }
        moveSelection(to: index)
    }

    /// Moves the selection lens with a short spring. Opening the switcher sets the selection directly instead,
    /// so the lens never slides in from wherever it was last time.
    private func moveSelection(to index: Int) {
        guard index != model.selection else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.selection = index
            return
        }
        withAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) { model.selection = index }
    }

    private func step(_ delta: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        moveSelection(to: ((model.selection + delta) % count + count) % count)
    }

    private func moveVertically(_ delta: Int) {
        let count = model.items.count
        let columns = max(model.columns, 1)
        guard count > columns else { return }
        let column = model.selection % columns
        var target = model.selection + delta * columns
        if target < 0 {
            // Wrap to the same column on the last row, or the row above it when the last row is short.
            target = (count - 1) / columns * columns + column
            if target >= count { target -= columns }
        } else if target >= count {
            target = column
        }
        moveSelection(to: target)
    }

    // MARK: - Window commands

    private func run(_ command: KeyboardTap.Action) {
        guard let item = model.selectedItem else { return }
        let index = model.selection

        switch command {
        case .close:
            guard windows.close(item) else { return NSSound.beep() }
            model.items.remove(at: index)
        case .minimize:
            guard item.windowID != nil, windows.setMinimized(item, !item.isMinimized) else { return NSSound.beep() }
            model.items[index].isMinimized.toggle()
        case .hide:
            let hide = !item.app.isHidden
            windows.setHidden(item, hide)
            for i in model.items.indices where model.items[i].pid == item.pid { model.items[i].isHidden = hide }
        case .quit:
            quitting.insert(item.pid)
            windows.quit(item)
            model.items.removeAll { $0.pid == item.pid }
        default:
            return
        }

        guard !model.items.isEmpty else { return dismiss() }
        model.selection = min(model.selection, model.items.count - 1)
        applyLayout()
        // Give the app a moment, then reconcile with what actually happened (a "Save changes?" sheet can keep a
        // window open; some apps refuse to quit).
        runOnMain(after: 0.4) { [weak self] in self?.resync() }
    }

    private func resync() {
        guard isActive else { return }
        let selectedID = model.selectedItem?.id
        let items = windows.snapshot(onlyApp: appFilter).filter { !quitting.contains($0.pid) }
        guard !items.isEmpty else { return dismiss() }
        model.items = items
        model.selection = items.firstIndex { $0.id == selectedID } ?? min(model.selection, items.count - 1)
        applyLayout()
        refreshThumbnails()
    }
}
