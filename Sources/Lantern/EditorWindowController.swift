import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/* The post-capture window: a preview with the output controls beneath —
   size, frame rate and format for video, Trim (the player view's own
   QuickTime-style trim bar), and Copy / Save. */
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let media: CapturedMedia
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var trim: CMTimeRange?
    private var job: ExportJob?
    /// Files handed to the clipboard stay until the app quits.
    private var clipboardExports: [URL] = []

    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField(string: "")
    private let dimensionLabel = NSTextField(labelWithString: "")
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatControl = NSSegmentedControl(
        labels: ["MP4", "GIF"], trackingMode: .selectOne, target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private lazy var cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelExport))
    private lazy var trimButton = NSButton(title: L("Trim"), target: self, action: #selector(beginTrim))
    private lazy var copyButton = NSButton(title: L("Copy"), target: self, action: #selector(copyClicked))
    private lazy var saveButton = NSButton(title: L("Save"), target: self, action: #selector(saveClicked))

    private static let percents = [100, 75, 50, 25]

    init(media: CapturedMedia) {
        self.media = media
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        /* The roomy title bar of the settings window: an empty unified
           toolbar centers the traffic lights in a 52pt bar (the same trick
           as SettingsWindowController), and no separator line under it. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        switch media {
        case .image: window.title = L("Screenshot")
        case .video: window.title = L("Screen Recording")
        }
        window.contentView = makeContent()
        /* Same size for every capture; the content view's own fitting size
           must not decide it. */
        window.setContentSize(NSSize(width: 680, height: 560))
        window.center()
        refreshLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var isVideo: Bool {
        if case .video = media { return true }
        return false
    }

    // MARK: - Content

    private func makeContent() -> NSView {
        let preview: NSView
        switch media {
        case .image(let image):
            let imageView = NSImageView()
            imageView.image = NSImage(cgImage: image.cgImage, size: image.pointSize)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            preview = imageView
        case .video(let video):
            let player = AVPlayer(url: video.url)
            let view = AVPlayerView()
            view.player = player
            view.controlsStyle = .inline
            view.showsFullScreenToggleButton = false
            self.player = player
            playerView = view
            preview = view
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        /* The preview scales to the window, never the other way round: an
           image view's intrinsic size is the image's, which would balloon
           the window to a full-display capture and pin it there. */
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentCompressionResistancePriority(.defaultLow - 1, for: axis)
            preview.setContentHuggingPriority(.defaultLow - 1, for: axis)
        }

        // Size row
        for percent in Self.percents {
            sizePopup.addItem(withTitle: "\(percent)%")
        }
        sizePopup.addItem(withTitle: L("Custom Width…"))
        let savedPercent = AppPreferences.exportScalePercent
        sizePopup.selectItem(at: Self.percents.firstIndex(of: savedPercent) ?? 0)
        sizePopup.target = self
        sizePopup.action = #selector(controlsChanged)

        widthField.placeholderString = L("Width")
        widthField.alignment = .right
        widthField.isHidden = true
        widthField.target = self
        widthField.action = #selector(controlsChanged)
        (widthField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        widthField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        dimensionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        dimensionLabel.textColor = .secondaryLabelColor

        let sizeRow = NSStackView(views: [label(L("Size")), sizePopup, widthField, dimensionLabel])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        // Video row
        fpsPopup.target = self
        fpsPopup.action = #selector(controlsChanged)
        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        formatControl.selectedSegment = AppPreferences.videoFormat == .gif ? 1 : 0
        trimButton.bezelStyle = .rounded
        let videoRow = NSStackView(views: [
            label(L("Frame Rate")), fpsPopup, label(L("Format")), formatControl, trimButton,
        ])
        videoRow.orientation = .horizontal
        videoRow.spacing = 8
        videoRow.setCustomSpacing(16, after: fpsPopup)
        videoRow.setCustomSpacing(16, after: formatControl)
        videoRow.isHidden = !isVideo
        populateFPS()

        // Buttons row
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 160).isActive = true
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        copyButton.bezelStyle = .rounded
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [progress, cancelButton, spacer, copyButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let controls = NSStackView(views: [sizeRow, videoRow, buttons])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(preview)
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            preview.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    private var format: ExportFormat {
        if !isVideo { return .png }
        return formatControl.selectedSegment == 1 ? .gif : .mp4
    }

    private var scale: OutputScale {
        let index = sizePopup.indexOfSelectedItem
        if index < Self.percents.count {
            return .percent(Self.percents[index])
        }
        return .width(max(widthField.integerValue, 16))
    }

    private var fps: Int {
        fpsPopup.selectedItem?.tag ?? 60
    }

    private func populateFPS() {
        let wanted = fpsPopup.selectedItem?.tag ?? AppPreferences.exportFPS
        fpsPopup.removeAllItems()
        let rates = format == .gif ? GIFTiming.allowedFPS : [60, 30, 15, 10]
        for rate in rates {
            fpsPopup.addItem(withTitle: "\(rate) fps")
            fpsPopup.lastItem?.tag = rate
        }
        let target = format == .gif ? GIFTiming.clampedFPS(wanted) : (rates.contains(wanted) ? wanted : 60)
        fpsPopup.selectItem(at: rates.firstIndex(of: target) ?? 0)
    }

    private var trimDuration: Double {
        guard case .video(let video) = media else { return 0 }
        return (trim?.duration ?? video.duration).seconds
    }

    private func refreshLabels() {
        let source = media.pixelSize
        let target = scale.apply(to: source, even: isVideo)
        var text = "\(Int(source.width)) × \(Int(source.height))"
        if target != source {
            text += "  →  \(Int(target.width)) × \(Int(target.height))"
        }
        let bytes = SizeEstimator.bytes(format: format, pixelSize: target, fps: fps, duration: trimDuration)
        text += "  ·  ~" + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        dimensionLabel.stringValue = text

        /* No footnote row: the frame-rate menu already shows what GIF can
           do, and an unwieldy GIF is flagged on the estimate itself, so the
           layout never shifts between formats. */
        let unwieldy =
            format == .gif
            && SizeEstimator.gifWorkingSetBytes(pixelSize: target, fps: fps, duration: trimDuration) > 1_000_000_000
        dimensionLabel.textColor = unwieldy ? .systemOrange : .secondaryLabelColor
        dimensionLabel.toolTip =
            unwieldy ? L("This GIF will be large. A smaller size or a lower frame rate keeps it manageable.") : nil
    }

    // MARK: - Actions

    @objc private func controlsChanged() {
        widthField.isHidden = sizePopup.indexOfSelectedItem < Self.percents.count
        if !widthField.isHidden, widthField.integerValue == 0 {
            widthField.integerValue = Int(media.pixelSize.width)
            window?.makeFirstResponder(widthField)
        }
        rememberSettings()
        refreshLabels()
    }

    @objc private func formatChanged() {
        populateFPS()
        rememberSettings()
        refreshLabels()
    }

    @objc private func beginTrim() {
        guard let playerView, playerView.canBeginTrimming else { return }
        player?.pause()
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self, result == .okButton, let item = self.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid && item.reversePlaybackEndTime != .invalid
                    ? max(item.reversePlaybackEndTime, .zero) : CMTime.zero
                let end = item.forwardPlaybackEndTime.isValid && item.forwardPlaybackEndTime != .indefinite
                    ? item.forwardPlaybackEndTime : item.duration
                if end > start {
                    self.trim = CMTimeRange(start: start, end: end)
                }
                self.refreshLabels()
            }
        }
    }

    private var settings: ExportSettings {
        ExportSettings(format: format, scale: scale, fps: fps, trim: trim)
    }

    /* Every choice is remembered as it is made, so the next capture opens
       with the same size, frame rate, and format. A custom width is stored
       as 100% for next time: the pixel width is specific to this capture. */
    private func rememberSettings() {
        if case .percent(let percent) = scale {
            AppPreferences.exportScalePercent = percent
        } else {
            AppPreferences.exportScalePercent = 100
        }
        if isVideo {
            AppPreferences.exportFPS = fps
            AppPreferences.videoFormat = format
        }
    }

    @objc private func saveClicked() {
        rememberSettings()
        let kind: OutputNaming.Kind = isVideo ? .recording : .screenshot
        let destination: URL
        if let directory = AppPreferences.resolvedSaveDirectory {
            destination = OutputNaming.uniqueURL(in: directory, kind: kind, ext: format.fileExtension)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.utType]
            panel.nameFieldStringValue = OutputNaming.fileName(kind: kind, date: Date(), ext: format.fileExtension)
            panel.directoryURL = AppPreferences.desktopDirectory
            guard let window, panel.runModal() == .OK, let url = panel.url else { return }
            _ = window
            destination = url
        }
        runExport(to: destination) { [weak self] url in
            guard let self else { return }
            if case .image = self.media {
                Self.copyToClipboard(fileURL: url, includingImageData: true)
            }
            self.close()
        }
    }

    @objc private func copyClicked() {
        rememberSettings()
        let url = TempFiles.newExportURL(ext: format.fileExtension)
        runExport(to: url) { [weak self] url in
            guard let self else { return }
            self.clipboardExports.append(url)
            Self.copyToClipboard(fileURL: url, includingImageData: !self.isVideo)
        }
    }

    /* One pasteboard item carrying the file and, for images, the PNG bytes,
       so both Finder-style and image-style pastes work. */
    private static func copyToClipboard(fileURL: URL, includingImageData: Bool) {
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        if includingImageData, let data = try? Data(contentsOf: fileURL) {
            item.setData(data, forType: .png)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func runExport(to url: URL, completion: @escaping (URL) -> Void) {
        guard job == nil else { return }
        let job = ExportJob()
        self.job = job
        setExporting(true)
        player?.pause()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await MediaExporter.export(media, settings: settings, to: url, job: job) { [weak self] fraction in
                    self?.progress.doubleValue = fraction
                }
                self.job = nil
                setExporting(false)
                completion(url)
            } catch ExportError.cancelled {
                self.job = nil
                setExporting(false)
            } catch {
                self.job = nil
                setExporting(false)
                Alerts.show(title: L("The export failed"), message: error.localizedDescription)
            }
        }
    }

    private func setExporting(_ exporting: Bool) {
        progress.isHidden = !exporting
        cancelButton.isHidden = !exporting
        progress.doubleValue = 0
        for control in [sizePopup, widthField, fpsPopup, formatControl, trimButton, copyButton, saveButton] as [NSControl] {
            control.isEnabled = !exporting
        }
    }

    @objc private func cancelExport() {
        job?.cancel()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        job?.cancel()
        player?.pause()
        if case .video(let video) = media {
            TempFiles.remove(video.url)
        }
        onClose?()
    }
}
