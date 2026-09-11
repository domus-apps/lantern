import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Window

enum SettingsPane: Int, CaseIterable {
    case general
    case capture

    var title: String {
        switch self {
        case .general: L("General")
        case .capture: L("Capture")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        }
    }
}

/* System Settings-style window: full-height sidebar on the left, panes on
   the right. The style mask keeps all three traffic lights live (zoom stays
   disabled by macOS itself while the window is not resizable-by-content,
   matching native settings windows). */
final class SettingsWindowController: NSWindowController {
    private let splitViewController: SettingsSplitViewController

    init(updater: UpdaterController) {
        splitViewController = SettingsSplitViewController(updater: updater)
        let window = NSWindow(contentViewController: splitViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        /* A toolbar (even an empty one) is required for the full-height
           sidebar look. The tall unified style centers the traffic lights
           in a roomier title bar (like Xcode's settings window) instead of
           pinning them to the top-left corner. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        /* An empty toolbar defaults to .iconAndLabel, which inflates the
           unified title bar to 66pt; .iconOnly gives the standard 52pt that
           Xcode's settings window uses. */
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 440))
        window.center()

        super.init(window: window)
        splitViewController.onPaneChange = { [weak window] pane in
            window?.title = pane.title
        }
        splitViewController.show(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class SettingsSplitViewController: NSSplitViewController {
    var onPaneChange: ((SettingsPane) -> Void)?

    private let sidebar = SettingsSidebarViewController()
    private let paneContainer = NSViewController()
    private let generalPane: NSViewController
    private let capturePane: NSViewController
    private var currentPane: NSViewController?

    init(updater: UpdaterController) {
        /* The panes are SwiftUI grouped Forms — the exact section-header +
           rounded-box arrangement Xcode's settings use — hosted inside the
           AppKit split chrome. */
        let model = SettingsModel(updater: updater)
        generalPane = NSHostingController(rootView: GeneralSettingsView(model: model))
        capturePane = NSHostingController(rootView: CaptureSettingsView(model: model))
        super.init(nibName: nil, bundle: nil)

        paneContainer.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 160
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: paneContainer))

        sidebar.onSelect = { [weak self] pane in
            self?.show(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ pane: SettingsPane) {
        let next: NSViewController =
            switch pane {
            case .general: generalPane
            case .capture: capturePane
            }
        guard next !== currentPane else { return }

        if let currentPane {
            currentPane.view.removeFromSuperview()
            currentPane.removeFromParent()
        }
        paneContainer.addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: paneContainer.view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: paneContainer.view.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: paneContainer.view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: paneContainer.view.trailingAnchor),
        ])
        currentPane = next

        sidebar.select(pane)
        onPaneChange?(pane)
    }
}

// MARK: - Sidebar

final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onSelect: ((SettingsPane) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /* Extra top inset below the safe area. Zero, like Xcode's settings
       sidebar: the first row sits flush against the title bar boundary. */
    private static let scrollEdgeFadeClearance: CGFloat = 0

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        /* Managed manually in viewDidLayout: the automatic inset stops at
           the safe area, which leaves the first row inside the fade. */
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateScrollEdgeFade()
        }
    }

    /* The soft scroll-edge fade (macOS 26) is not scroll-aware: its gradient
       backdrop hangs ~10pt below the title bar at all times, dimming a first
       row that sits flush against the boundary even when nothing is scrolled
       under the bar. Mirror Xcode's settings sidebar instead: fade only while
       content is actually scrolled under. The pocket is a private AppKit view
       (NSScrollPocket), so this is a defensive class-name lookup — if AppKit
       renames it, the system's default behavior simply returns. */
    private func updateScrollEdgeFade() {
        let restTop = -scrollView.contentInsets.top
        let atRest = scrollView.contentView.bounds.minY <= restTop + 0.5
        let target: CGFloat = atRest ? 0 : 1
        /* Only when the value changes. The animator sets the model value at
           once, so a pocket already at the target is skipped. Starting an
           animation on every layout pass dirtied the view for the next
           commit, which laid the sidebar out again, which started another
           animation: a loop that kept each app near 7% CPU for as long as
           it ran, the closed (retained) Settings window included. */
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket"
            && subview.alphaValue != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = target
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        /* The pocket can appear after the first layout pass, so re-evaluate
           on every layout, not only when the inset changes. */
        defer { updateScrollEdgeFade() }
        let top = view.safeAreaInsets.top + Self.scrollEdgeFadeClearance
        guard scrollView.contentInsets.top != top else { return }
        let wasAtTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if wasAtTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func select(_ pane: SettingsPane) {
        guard tableView.selectedRow != pane.rawValue else { return }
        tableView.selectRowIndexes(IndexSet(integer: pane.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPane.allCases.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let pane = SettingsPane(rawValue: row) else { return nil }

        let cell = NSTableCellView()
        let imageView = NSImageView(
            image: NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
                ?? NSImage())
        let textField = NSTextField(labelWithString: pane.title)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let pane = SettingsPane(rawValue: tableView.selectedRow) else { return }
        onSelect?(pane)
    }
}

// MARK: - SwiftUI bridge

/* The pane's model: preferences live in UserDefaults (via AppPreferences);
   this object just republishes their change notification so SwiftUI
   re-reads, and carries the pieces that aren't preferences (SMAppService,
   the updater). */
final class SettingsModel: ObservableObject {
    let updater: UpdaterController

    init(updater: UpdaterController) {
        self.updater = updater
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /* SMAppService needs a real app bundle; a bare `swift run` binary has
       no bundle identifier to register. */
    var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Lantern: launch-at-login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return version + build
    }

    func binding<Value>(
        _ get: @escaping () -> Value, _ set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

// MARK: - General pane

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Launch at login"),
                        isOn: model.binding({ model.launchAtLogin }, { model.launchAtLogin = $0 })
                    )
                    .disabled(!model.isBundledApp)
                    if !model.isBundledApp {
                        Text(L("Available in the bundled app only (Scripts/bundle.sh)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        L("Hide menu bar icon"),
                        isOn: model.binding(
                            { AppPreferences.isMenuBarIconHidden },
                            { AppPreferences.isMenuBarIconHidden = $0 }))
                    Text(L("While hidden, launch Lantern again to open Settings. The app appears in the Dock only while this window is open."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L("Capture shortcut")) {
                    ShortcutRecorder(
                        spec: model.binding({ AppPreferences.shortcut }, { AppPreferences.shortcut = $0 }))
                }
            } footer: {
                Text(L("Press the shortcut again to cancel a capture in progress, or to stop a recording."))
            }

            Section(L("Updates")) {
                LabeledContent(L("Version"), value: model.versionLabel)
                Button(L("Check for Updates…")) {
                    model.updater.checkForUpdates()
                }
                .disabled(!model.updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Capture pane

struct CaptureSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(
                    L("Save to"),
                    selection: model.binding(
                        { AppPreferences.saveLocation },
                        { location in
                            if location == .folder {
                                model.chooseSaveFolder()
                            } else {
                                AppPreferences.saveLocation = location
                            }
                        })
                ) {
                    Text(L("Desktop")).tag(AppPreferences.SaveLocation.desktop)
                    Text(AppPreferences.saveFolder.map { L("Folder: %@", $0.lastPathComponent) } ?? L("Other Folder…"))
                        .tag(AppPreferences.SaveLocation.folder)
                    Text(L("Ask Where to Save")).tag(AppPreferences.SaveLocation.ask)
                }
                if AppPreferences.saveLocation == .folder, let folder = AppPreferences.saveFolder {
                    LabeledContent(L("Folder"), value: folder.path)
                    Button(L("Choose Folder…")) { model.chooseSaveFolder() }
                }

                Toggle(
                    L("Show mouse pointer"),
                    isOn: model.binding({ AppPreferences.showsCursor }, { AppPreferences.showsCursor = $0 }))

                Picker(
                    L("Timer"),
                    selection: model.binding({ AppPreferences.timerSeconds }, { AppPreferences.timerSeconds = $0 })
                ) {
                    Text(L("None")).tag(0)
                    Text(L("5 Seconds")).tag(5)
                    Text(L("10 Seconds")).tag(10)
                }
            } footer: {
                Text(L("Images are also copied to the clipboard when saved. The same options are in the capture bar under Options."))
            }
        }
        .formStyle(.grouped)
    }
}

extension SettingsModel {
    func chooseSaveFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = L("Choose")
        open.message = L("Choose where captures are saved.")
        open.directoryURL = AppPreferences.saveFolder ?? AppPreferences.desktopDirectory
        if open.runModal() == .OK, let url = open.url {
            AppPreferences.saveFolder = url
            AppPreferences.saveLocation = .folder
        } else {
            objectWillChange.send()
        }
    }
}

// MARK: - Shortcut recorder

/* A button that records the next key combination: click, press the keys,
   done. Escape cancels; at least one of ⌃⌥⌘ is required so a plain letter
   can't be swallowed system-wide. */
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var spec: ShortcutSpec

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onRecord = { spec = $0 }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.spec = spec
    }
}

final class ShortcutRecorderButton: NSButton {
    var onRecord: ((ShortcutSpec) -> Void)?
    var spec = ShortcutSpec.defaultCapture {
        didSet { if !isRecording { refreshTitle() } }
    }
    private var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(toggleRecording)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func refreshTitle() {
        title = isRecording ? L("Type shortcut…") : spec.displayString
        font = isRecording ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == 53 {  // Escape
                self.stopRecording()
                return nil
            }
            let modifiers = ShortcutSpec.carbonModifiers(from: event.modifierFlags)
            let required = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
            guard modifiers & required != 0 else {
                NSSound.beep()
                return nil
            }
            let recorded = ShortcutSpec(
                keyCode: UInt32(event.keyCode), carbonModifiers: modifiers,
                keyLabel: ShortcutSpec.keyLabel(for: event))
            self.spec = recorded
            self.stopRecording()
            self.onRecord?(recorded)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        refreshTitle()
    }
}
