import AppKit
import AVFoundation
import AVKit
import LanternGIF
import SwiftUI
import UniformTypeIdentifiers

/* One window per video, laid out like Photos' edit mode: the player on the
   left (Crop and Trim in the toolbar above it: a crop frame over the
   picture, and the player's QuickTime-style trim bar),
   an inspector on the right with the GIF's size and the choices that make
   it (size, frame rate, playback, quality, recording border), and Copy and
   Save in the toolbar above the inspector.

   The GIF is encoded in the background as soon as the choices settle, so
   the size shown is the real file size and Save or Copy right after is
   instant: they reuse the finished file. Pressing either before it is done
   waits for the encode already running (with a progress circle) instead of
   starting another. */
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?

    let video: SourceVideo
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    /// The black rounded backdrop the player sits in, which crop mode shows around a smaller picture.
    private let stage = NSView()
    /// The player's insets in the stage: zero, or room for the crop frame while cropping.
    private var stageInsets: [NSLayoutConstraint] = []
    private var trim: CMTimeRange?
    /// The part of the picture kept, cut from the upright frame in video pixels.
    private var userCrop = PixelInsets.zero
    /// The crop frame over the player while crop mode is open.
    private var cropOverlay: CropOverlayView?
    private var isTrimming = false
    /// Decoded frames kept between encodes, so a quality change skips decoding.
    private let frameCache = FrameCache()

    private struct Encode {
        let settings: ExportSettings
        let job: ExportJob
        let url: URL
        var progress: Double = 0
        var bytes: Int?
        var error: Error?
    }

    private enum Action {
        /// To a file the user picked in the save panel, which already asked about replacing it.
        case save(URL)
        /// Into a folder, under a name free when the GIF is written (not when Save was pressed).
        case saveInto(URL)
        case copy
    }

    private var encode: Encode?
    private var pendingAction: Action?
    private var debounce: DispatchWorkItem?

    private let options = EditorOptions()
    /// The recording border found in this video; nil until the edges have been looked at.
    private var detectedBorder: PixelInsets?
    /// Set once the window closes; work finishing later is dropped.
    private var isClosed = false
    private let splitViewController = FixedInspectorSplitViewController()
    private lazy var toolsItem = makeToolsItem()
    private lazy var cropButton = NSButton(title: "", target: self, action: #selector(beginCrop))
    private lazy var trimButton = NSButton(title: "", target: self, action: #selector(beginTrim))
    private lazy var copyItem = makeItem(Self.copyItemID, title: L("Copy"), action: #selector(copyClicked))
    private lazy var saveItem = makeItem(Self.saveItemID, title: L("Save"), action: #selector(saveClicked))
    private lazy var resetCropItem = makeItem(Self.resetCropItemID, title: L("Reset"), action: #selector(resetCrop))
    private lazy var cancelCropItem = makeItem(Self.cancelCropItemID, title: L("Cancel"), action: #selector(cancelCrop))
    private lazy var doneCropItem = makeItem(Self.doneCropItemID, title: L("Done"), action: #selector(finishCrop))

    private static let toolsItemID = NSToolbarItem.Identifier("tools")
    private static let copyItemID = NSToolbarItem.Identifier("copy")
    private static let saveItemID = NSToolbarItem.Identifier("save")
    private static let resetCropItemID = NSToolbarItem.Identifier("resetCrop")
    private static let cancelCropItemID = NSToolbarItem.Identifier("cancelCrop")
    private static let doneCropItemID = NSToolbarItem.Identifier("doneCrop")
    private static let cropItemIDs: Set = [resetCropItemID, cancelCropItemID, doneCropItemID]
    private static let inspectorSeparatorID = NSToolbarItem.Identifier("inspectorSeparator")
    /// Inset of the player from the window's sides.
    private static let margin: CGFloat = 20
    /// Room around the picture in crop mode, so the frame and its handles
    /// never meet the stage's rounded corners.
    private static let cropMargin: CGFloat = 20
    private static let settleDelay: TimeInterval = 0.35

    init(video: SourceVideo) {
        self.video = video
        player = AVPlayer(url: video.url)
        /* The settings window's class: the inspector's switch is a hosted
           NSSwitch, which can leave a window undraggable on macOS 27.2. */
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 440)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        /* No line under the title bar over the player, as before the
           inspector: the player starts where the 52pt bar ends. */
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        super.init(window: window)

        let content = NSViewController()
        content.view = makePlayerArea()
        let playerItem = NSSplitViewItem(viewController: content)
        playerItem.titlebarSeparatorStyle = .none
        splitViewController.addSplitViewItem(playerItem)
        options.onChange = { [weak self] in self?.controlsChanged() }
        options.onCancel = { [weak self] in self?.cancelWaiting() }
        let inspector = NSSplitViewItem(
            inspectorWithViewController: NSHostingController(rootView: EditorInspector(options: options)))
        inspector.canCollapse = false
        splitViewController.addSplitViewItem(inspector)
        window.contentViewController = splitViewController

        /* Crop and Trim over the player, Copy and Save over the inspector,
           split where the inspector starts. */
        let toolbar = NSToolbar(identifier: "editor")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.delegate = self
        window.title = video.url.lastPathComponent
        window.representedURL = video.url
        window.setContentSize(NSSize(width: 960, height: 560))
        window.center()
        updateBorderCheckbox()
        refreshInfo()
        scheduleEncode(after: 0)
        detectBorder()
        if let crop = DebugHooks.editorCrop {
            DebugHooks.editorCrop = nil  // the first editor only
            userCrop = crop
            showCrop()
            scheduleEncode(after: 0)
            refreshInfo()
        }
        if DebugHooks.opensCropMode {
            DebugHooks.opensCropMode = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.beginCrop()
                DebugHooks.performCropDrags(in: window) { [weak self] in
                    guard let crop = self?.cropOverlay?.insets else { return "no crop mode" }
                    return "t\(crop.top) l\(crop.left) b\(crop.bottom) r\(crop.right)"
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func makePlayerArea() -> NSView {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false

        /* The stage rounds the player's corners, and in crop mode those of
           the frame drawn over it too. */
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.cornerRadius = 10
        stage.layer?.cornerCurve = .continuous
        stage.layer?.masksToBounds = true
        stage.addSubview(playerView)
        stageInsets = [
            playerView.topAnchor.constraint(equalTo: stage.topAnchor),
            stage.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
        ]

        let area = NSView()
        area.addSubview(stage)
        let margin = Self.margin
        NSLayoutConstraint.activate(stageInsets + [
            area.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            stage.topAnchor.constraint(equalTo: area.safeAreaLayoutGuide.topAnchor),
            stage.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: margin),
            stage.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -margin),
            stage.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -margin),
        ])
        return area
    }

    // MARK: - Toolbar

    private func makeItem(_ id: NSToolbarItem.Identifier, title: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title
        item.target = self
        item.action = action
        item.autovalidates = false
        item.title = title
        item.isBordered = true
        /* Save is the window's "Done", tinted like Photos', and so is Done
           while cropping. */
        if [Self.saveItemID, Self.doneCropItemID].contains(id) {
            item.style = .prominent
        }
        item.isHidden = Self.cropItemIDs.contains(id)
        return item
    }

    /* Glass circles the size of toolbar buttons, in a view with room on
       its right. The toolbar puts the last item before the inspector 9pt
       from it, which left the scissors overhanging the player; the padding
       lines their edge up with the player's (the glass draws 4pt past the
       button's frame). */
    private func makeToolsItem() -> NSToolbarItem {
        for (button, symbol, title) in [(cropButton, "crop", L("Crop")), (trimButton, "scissors", L("Trim"))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.bezelStyle = .glass
            button.borderShape = .circle
            button.controlSize = .extraLarge
            button.toolTip = title
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 36),
                button.heightAnchor.constraint(equalToConstant: 36),
            ])
        }
        let buttons = NSStackView(views: [cropButton, trimButton])
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -15),
            buttons.topAnchor.constraint(equalTo: box.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        let item = NSToolbarItem(itemIdentifier: Self.toolsItemID)
        item.view = box
        item.isBordered = false
        item.label = L("Crop")
        item.autovalidates = false
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace, Self.toolsItemID, Self.inspectorSeparatorID, .flexibleSpace,
            Self.resetCropItemID, Self.cancelCropItemID, Self.doneCropItemID, Self.copyItemID, Self.saveItemID,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toolsItemID: toolsItem
        case Self.copyItemID: copyItem
        case Self.saveItemID: saveItem
        case Self.resetCropItemID: resetCropItem
        case Self.cancelCropItemID: cancelCropItem
        case Self.doneCropItemID: doneCropItem
        case Self.inspectorSeparatorID:
            NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitViewController.splitView, dividerIndex: 0)
        default: nil
        }
    }

    // MARK: - Settings

    private var scale: OutputScale {
        if let percent = options.percent { return .percent(percent) }
        return .width(max(customWidth ?? 0, 16))
    }

    /* Digits only, both ways: a typed separator is ignored (NSTextField's
       integerValue once wrote "1,562" and read it back as 1). More digits
       than an Int holds read as the widest, which the source width caps. */
    private var customWidth: Int? {
        get {
            let digits = options.customWidth.filter { $0.isASCII && $0.isNumber }
            return digits.isEmpty ? nil : Int(digits) ?? .max
        }
        set { options.customWidth = newValue.map(String.init) ?? "" }
    }

    private var settings: ExportSettings {
        ExportSettings(
            scale: scale, fps: options.fps, quality: options.quality, trim: trim,
            playback: options.playback, crop: crop(userCrop))
    }

    /// A crop together with the recording border, when that is being removed.
    private func crop(_ user: PixelInsets) -> PixelInsets {
        user.combined(with: options.removesBorder ? (detectedBorder ?? .zero) : .zero)
    }

    /* Every choice is remembered as it is made, so the next video opens with
       the same size, frame rate, quality, playback and border choice. A
       custom width is remembered as 50%: the pixel width belongs to this
       video. The border choice is only remembered when it could be used. */
    private func rememberSettings() {
        AppPreferences.exportScalePercent = options.percent ?? 50
        AppPreferences.exportFPS = options.fps
        AppPreferences.quality = options.quality
        AppPreferences.playback = options.playback
        if options.borderAvailable {
            AppPreferences.removesRecordingBorder = options.removesBorder
        }
    }

    // MARK: - Recording border

    /* A quick look at a few frames (a tenth of a second for most screen
       recordings). When the box was left on and a border turns up, the GIF
       is made again without it. */
    private func detectBorder() {
        let video = video
        Task { @MainActor [weak self] in
            let found = await RecordingBorder.detect(in: video) ?? .zero
            guard let self, !self.isClosed else { return }
            self.detectedBorder = found
            self.updateBorderCheckbox()
            if self.pendingAction != nil {
                self.fulfillPendingAction()
            } else if self.options.removesBorder, !found.isZero {
                self.scheduleEncode(after: 0)
                self.refreshInfo()
            }
        }
    }

    private func updateBorderCheckbox() {
        let available = detectedBorder.map { !$0.isZero } ?? false
        options.borderAvailable = available
        if detectedBorder != nil, !available, options.removesBorder {
            options.removesBorder = false
        }
    }

    private func refreshInfo() {
        /* While cropping, the resolution follows the frame as it is dragged;
           the file size waits for Done. */
        var shown = settings
        if let cropOverlay { shown.crop = crop(cropOverlay.insets) }
        let target = shown.outputSize(of: video)
        options.readout.dimensions = "\(Int(target.width)) × \(Int(target.height))"
        let current = encode.flatMap { $0.settings == shown ? $0 : nil }
        if cropOverlay != nil, current == nil {
            options.readout.sizeText = ""
            options.readout.sizeIsKnown = false
            options.readout.progress = nil
        } else if let bytes = current?.bytes {
            options.readout.sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            options.readout.sizeIsKnown = true
            options.readout.progress = nil
        } else {
            options.readout.sizeText = current?.error != nil ? L("Couldn't make the GIF") : L("Calculating size…")
            options.readout.sizeIsKnown = false
            options.readout.progress = current?.error != nil ? nil : (current?.progress ?? 0)
        }
    }

    // MARK: - Background encode

    private func controlsChanged() {
        /* An empty field starts at the video's width, and a wider one is
           brought back to it, so the field shows the width the GIF gets. */
        if options.percent == nil {
            let widest = Int(settings.sourceSize(of: video).width)
            if (customWidth ?? 0) == 0 || (customWidth ?? 0) > widest {
                customWidth = widest
            }
        }
        rememberSettings()
        scheduleEncode(after: Self.settleDelay)
        refreshInfo()
    }

    /// Encodes the current settings once they have stayed put for `delay`.
    private func scheduleEncode(after delay: TimeInterval) {
        debounce?.cancel()
        if let encode, encode.settings == settings { return }
        cancelEncode()
        let work = DispatchWorkItem { [weak self] in self?.startEncode() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startEncode() {
        debounce?.cancel()
        debounce = nil
        let settings = settings
        // A failed encode is tried again: Save and Copy start here.
        if let encode, encode.settings == settings, encode.error == nil { return }
        cancelEncode()
        let job = ExportJob()
        let url = TempFiles.newEncodeURL()
        encode = Encode(settings: settings, job: job, url: url)
        refreshInfo()
        let video = video
        let cache = frameCache
        Task { @MainActor [weak self] in
            do {
                try await GIFExporter.export(video, settings: settings, to: url, job: job, cache: cache) { fraction in
                    DispatchQueue.main.async {
                        guard let self, self.encode?.job === job else { return }
                        self.encode?.progress = fraction
                        self.refreshInfo()
                    }
                }
                guard let self, self.encode?.job === job else {
                    TempFiles.remove(url)  // finished just as it was replaced or the window closed
                    return
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                self.encode?.bytes = bytes
                self.encode?.progress = 1
                self.refreshInfo()
                self.performPendingAction()
            } catch ExportError.cancelled {
                TempFiles.remove(url)
            } catch {
                TempFiles.remove(url)
                guard let self, self.encode?.job === job else { return }
                self.encode?.error = error
                self.refreshInfo()
                if self.pendingAction != nil {
                    self.pendingAction = nil
                    self.setWaiting(false)
                    Alerts.show(title: L("The GIF couldn't be made"), message: error.localizedDescription)
                }
            }
        }
    }

    private func cancelEncode() {
        guard let encode else { return }
        encode.job.cancel()
        if encode.bytes != nil { TempFiles.remove(encode.url) }
        self.encode = nil
    }

    // MARK: - Trim

    @objc private func beginTrim() {
        guard playerView.canBeginTrimming, cropOverlay == nil else { return }
        player.pause()
        isTrimming = true
        cropButton.isEnabled = false
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isTrimming = false
                self.cropButton.isEnabled = !self.options.isLocked
                guard result == .okButton, let item = self.player.currentItem else { return }
                let start =
                    item.reversePlaybackEndTime.isValid ? max(item.reversePlaybackEndTime, .zero) : CMTime.zero
                let end =
                    item.forwardPlaybackEndTime.isValid && item.forwardPlaybackEndTime != .indefinite
                    ? item.forwardPlaybackEndTime : item.duration
                if end > start {
                    let range = CMTimeRange(start: start, end: end)
                    let whole = CMTimeRange(start: .zero, duration: self.video.duration)
                    self.trim = range == whole ? nil : range
                }
                self.scheduleEncode(after: 0)
                self.refreshInfo()
            }
        }
    }

    // MARK: - Crop

    /* The whole picture with the crop frame over it: the player drops its
       cropped preview and its controls, and the toolbar trades Copy and
       Save for Reset, Cancel and Done. */
    @objc private func beginCrop() {
        guard cropOverlay == nil, !isTrimming, !options.isLocked else { return }
        player.pause()
        player.currentItem?.videoComposition = nil
        playerView.controlsStyle = .none
        /* The picture shrinks inside the stage, as in Photos, and the
           overlay covers the whole stage so the handles can be grabbed from
           just outside the picture too. */
        for constraint in stageInsets { constraint.constant = Self.cropMargin }
        let overlay = CropOverlayView(pixelSize: video.pixelSize, insets: userCrop, margin: Self.cropMargin)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onChange = { [weak self] _ in self?.refreshInfo() }
        overlay.onCancel = { [weak self] in self?.endCrop(keeping: false) }
        stage.addSubview(overlay, positioned: .above, relativeTo: playerView)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: stage.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
        cropOverlay = overlay
        window?.makeFirstResponder(overlay)
        setCropMode(true)
        refreshInfo()
    }

    @objc private func finishCrop() {
        endCrop(keeping: true)
    }

    @objc private func cancelCrop() {
        endCrop(keeping: false)
    }

    @objc private func resetCrop() {
        cropOverlay?.reset()
    }

    private func endCrop(keeping: Bool) {
        guard let overlay = cropOverlay else { return }
        if keeping { userCrop = overlay.insets }
        overlay.removeFromSuperview()
        cropOverlay = nil
        for constraint in stageInsets { constraint.constant = 0 }
        playerView.controlsStyle = .inline
        setCropMode(false)
        showCrop()
        scheduleEncode(after: 0)
        refreshInfo()
    }

    private func setCropMode(_ cropping: Bool) {
        for item in [resetCropItem, cancelCropItem, doneCropItem] {
            item.isHidden = !cropping
        }
        for item in [copyItem, saveItem] {
            item.isHidden = cropping
        }
        cropButton.isEnabled = !cropping
        trimButton.isEnabled = !cropping
    }

    /* The player plays only what the GIF will show: the crop is applied as
       a video composition, in the same upright pixels the exporter cuts,
       and scaled to fill the frame the player already fits on screen (a
       filter composition keeps the video's render size). The recording
       border is left out of the preview; a pixel or two would only make
       the picture jump. */
    private func showCrop() {
        guard let item = player.currentItem else { return }
        let crop = userCrop
        guard !crop.isZero else {
            item.videoComposition = nil
            return
        }
        let size = video.pixelSize
        /* Core Image's origin is the bottom left, hence the bottom inset for y. */
        let kept = CGRect(
            x: CGFloat(crop.left), y: CGFloat(crop.bottom),
            width: size.width - CGFloat(crop.left + crop.right), height: size.height - CGFloat(crop.top + crop.bottom))
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard
                let composition = try? await AVVideoComposition(
                    applyingFiltersTo: asset,
                    applier: { frame in
                        let render = frame.renderSize
                        let scale = min(render.width / kept.width, render.height / kept.height)
                        let placed = CGAffineTransform(translationX: -kept.minX, y: -kept.minY)
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                            .concatenating(
                                CGAffineTransform(
                                    translationX: (render.width - kept.width * scale) / 2,
                                    y: (render.height - kept.height * scale) / 2))
                        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: render))
                        let image = frame.sourceImage.cropped(to: kept).samplingLinear().transformed(by: placed)
                        return AVCIImageFilteringResult(resultImage: image.composited(over: background))
                    })
            else { return }
            guard let self, self.userCrop == crop, self.cropOverlay == nil else { return }
            item.videoComposition = composition
        }
    }

    // MARK: - Save & Copy

    @objc private func saveClicked() {
        rememberSettings()
        if let directory = AppPreferences.resolvedSaveDirectory(forVideoAt: video.url) {
            request(.saveInto(directory))
            return
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "\(video.name).gif"
        panel.directoryURL = video.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.request(.save(url))
        }
    }

    @objc private func copyClicked() {
        rememberSettings()
        request(.copy)
    }

    private func request(_ action: Action) {
        pendingAction = action
        /* With the border switch on, the GIF isn't known until the edges
           have been looked at; detection picks the request up when done. */
        if awaitsBorder {
            setWaiting(true)
            return
        }
        fulfillPendingAction()
    }

    /// The border switch is on but the edges haven't been looked at yet.
    private var awaitsBorder: Bool { detectedBorder == nil && options.removesBorder }

    private func fulfillPendingAction() {
        if let encode, encode.settings == settings, encode.bytes != nil {
            performPendingAction()
            return
        }
        setWaiting(true)
        startEncode()
    }

    private func performPendingAction() {
        guard let action = pendingAction, !awaitsBorder, let encode, encode.bytes != nil, encode.settings == settings
        else { return }
        pendingAction = nil
        setWaiting(false)
        do {
            switch action {
            case .save(let destination):
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: encode.url, to: destination)
                close()
            case .saveInto(let directory):
                let destination = OutputNaming.uniqueURL(in: directory, base: video.name, ext: "gif")
                try FileManager.default.copyItem(at: encode.url, to: destination)
                close()
            case .copy:
                let file = TempFiles.newCopyFolder().appendingPathComponent("\(video.name).gif")
                try FileManager.default.copyItem(at: encode.url, to: file)
                Task { @MainActor [weak self] in
                    await Self.copyToClipboard(file)
                    self?.flashCopied()
                }
            }
        } catch {
            Alerts.show(title: L("The GIF couldn't be saved"), message: error.localizedDescription)
        }
    }

    /* The file for Finder-style pastes, and the GIF bytes for apps that take
       images (up to a size where holding them in the clipboard is sane). */
    private static func copyToClipboard(_ file: URL) async {
        /* Read off the main thread: up to 50 MB stalled the window. */
        let data = await Task.detached { () -> Data? in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            return bytes <= 50_000_000 ? try? Data(contentsOf: file) : nil
        }.value
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let data {
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    private func flashCopied() {
        copyItem.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyItem.title = L("Copy")
        }
    }

    @objc private func cancelWaiting() {
        pendingAction = nil
        setWaiting(false)
    }

    private func setWaiting(_ waiting: Bool) {
        options.isLocked = waiting
        cropButton.isEnabled = !waiting
        trimButton.isEnabled = !waiting
        for item in [copyItem, saveItem] {
            item.isEnabled = !waiting
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        debounce?.cancel()
        pendingAction = nil
        if let encode {
            encode.job.cancel()
            TempFiles.remove(encode.url)
        }
        encode = nil
        player.pause()
        onClose?()
    }
}

/* The inspector keeps the system's fixed 270pt, but the split view still
   gave its edge a resize cursor that led nowhere. With no hit area there
   is no cursor and nothing to drag; the line is still drawn. */
private final class FixedInspectorSplitViewController: NSSplitViewController {
    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        _ = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return .zero
    }

    override func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        _ = super.splitView(splitView, additionalEffectiveRectOfDividerAt: dividerIndex)
        return .zero
    }
}

enum Alerts {
    @MainActor
    static func show(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
