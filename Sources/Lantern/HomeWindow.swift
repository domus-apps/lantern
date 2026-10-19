import AppKit
import UniformTypeIdentifiers

/* The window Lantern shows when it is opened on its own (first launch, or
   launched again while running): one place to drop or paste a video and a
   button for the Open panel. */
@MainActor
final class HomeWindowController: NSWindowController {
    private let onOpen: ([URL]) -> Void
    private let onChoose: () -> Void

    init(onOpen: @escaping ([URL]) -> Void, onChoose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onChoose = onChoose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        /* The editor's roomy title bar: an empty unified toolbar centers the
           traffic lights in a 52pt bar, with no title or separator line. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Lantern"
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent() -> NSView {
        let drop = DropZoneView()
        drop.onDrop = { [weak self] urls in self?.onOpen(urls) }
        drop.translatesAutoresizingMaskIntoConstraints = false

        let symbol = NSImageView(
            image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: L("Drop or paste a video to make a GIF"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let choose = NSButton(title: L("Choose Video…"), target: self, action: #selector(chooseClicked))
        choose.bezelStyle = .glass
        choose.tintProminence = .primary
        choose.controlSize = .large
        choose.keyEquivalent = "\r"

        let inner = NSStackView(views: [symbol, title, choose])
        inner.orientation = .vertical
        inner.alignment = .centerX
        /* Set by what shows on screen, not by frames: the title's frame
           starts above its capitals and the button's glass sits inside its
           frame. These leave about 16pt of air under the symbol and 20pt
           above the button (12 and 18 left 9 and 21, the symbol touching
           the title). */
        inner.spacing = 0
        inner.setCustomSpacing(21, after: symbol)
        inner.setCustomSpacing(17, after: title)
        inner.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(inner)

        let container = NSView()
        container.addSubview(drop)
        NSLayoutConstraint.activate([
            /* Flush with the 52pt title bar, as in the editor. */
            drop.topAnchor.constraint(equalTo: container.topAnchor),
            drop.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            drop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            inner.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            drop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
        return container
    }

    @objc private func chooseClicked() {
        onChoose()
    }
}

/* A rounded, dashed well that takes dropped movie files and lights up with
   the accent color while a drag hovers over it. */
final class DropZoneView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var isTargeted = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        if isTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            path.fill()
        }
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        (isTargeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !VideoDrop.urls(from: sender.draggingPasteboard).isEmpty
        isTargeted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        let urls = VideoDrop.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/* What counts as a droppable video: file URLs whose type conforms to
   public.movie (QuickTime, MPEG-4, …), shared by every drop target. */
enum VideoDrop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter(isVideo)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .movie)
    }
}
