import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = PermissionState()

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Flick"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(state: state))
            window.center()
            self.window = window
        }
        state.startWatching()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.stopWatching()
    }
}

@MainActor
final class PermissionState: ObservableObject {
    @Published var accessibility = Permissions.accessibilityGranted
    @Published var screenRecording = Permissions.screenRecordingGranted
    @Published var requestedScreenRecording = false
    private var timer: Timer?

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        accessibility = Permissions.accessibilityGranted
        screenRecording = Permissions.screenRecordingGranted
    }
}

private struct OnboardingView: View {
    @ObservedObject var state: PermissionState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Flick").font(.title2.weight(.semibold))
                    Text("Hold ⌥ Option and press ⇥ Tab to flip between windows.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required. Lets Flick list and focus windows, and catch ⌥⇥.",
                    granted: state.accessibility,
                    action: Permissions.requestAccessibility
                )
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Optional. Shows live window previews instead of app icons.",
                    granted: state.screenRecording,
                    action: {
                        Permissions.requestScreenRecording()
                        state.requestedScreenRecording = true
                    }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Switched a permission on but nothing changed? Each new build needs fresh approval: remove Flick from the list with − and enable it again. Screen Recording only applies after a restart.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.requestedScreenRecording && !state.screenRecording {
                    Button("Restart Flick") { Permissions.relaunch() }
                        .controlSize(.small)
                        .secondaryGlassButton()
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 480)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Enabled").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Enable…", action: action)
                    .prominentGlassButton()
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension View {
    /// Glass button styles on macOS 26, their bordered equivalents before.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
