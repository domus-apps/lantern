import AppKit
import SwiftUI

/* Shown once to someone coming from Lantern 1.x, the screen capture app,
   the way Apple's apps introduce a new version: what Lantern does now, and
   where screen capture went. Sparkle relaunches the app after the update,
   so this is the first thing they see in place of the home window. Closing
   it either way counts as seen. */
@MainActor
final class IntroWindowController: NSWindowController, NSWindowDelegate {
    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Lantern"
        /* Only close, as in Apple's What's New windows. */
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: IntroView { [weak window] in window?.close() })
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onDone()
    }
}

private struct IntroView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text(L("What's New in Lantern"))
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 12)
            Text(L("Lantern now turns videos into GIFs."))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 18) {
                IntroRow(
                    symbol: "film.stack", title: L("Videos to GIFs"),
                    text: L("Drop a video on Lantern's window or its Dock icon to save a small, sharp GIF."))
                /* Measured against 1.0.5 on the same recordings at 15 fps,
                   half size (2026-10-19): a tenth of the bytes or less on
                   screen recordings (30.5 → 2.6 MB for 45 s), 25–37% less
                   time, SSIM within ±0.01 of 1.x's and mostly above it. */
                IntroRow(
                    symbol: "bolt", title: L("Smaller GIFs, made faster"),
                    text: L("A new encoder makes GIFs of screen recordings about a tenth the size and just as sharp, and it takes less time."))
                IntroRow(
                    symbol: "slider.horizontal.3", title: L("The size before you save"),
                    text: L("Change the size, frame rate, quality, trim, or crop, and the exact file size shows right away."))
                IntroRow(
                    symbol: "rectangle.dashed.badge.record", title: L("Recording with Screenshot"),
                    text: L("Record the screen with the Screenshot app (⌘⇧5) and drop the recording on Lantern. Lantern's capture shortcut and menu bar icon are gone."))
            }
            .padding(.top, 28)
            Button(L("Continue"), action: onContinue)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 32)
        }
        .padding(.horizontal, 44)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 480)
    }
}

private struct IntroRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
