import LanternGIF
import SwiftUI

/* The editor's GIF choices and what they make, shared by the inspector
   that shows them and the controller that encodes with them. Every change
   to a choice is reported through `onChange`. */
@MainActor
final class EditorOptions: ObservableObject {
    static let percents = [100, 75, 50, 25]

    /// A percentage of the video, or nil for a width typed in.
    @Published var percent: Int? { didSet { onChange?() } }
    /// Digits only, as typed; the controller reads it.
    @Published var customWidth = "" { didSet { onChange?() } }
    @Published var fps: Int { didSet { onChange?() } }
    @Published var playback: Playback { didSet { onChange?() } }
    @Published var quality: Int { didSet { onChange?() } }
    @Published var removesBorder: Bool { didSet { onChange?() } }

    /// Whether this video has a recording border to remove; the switch shows only then.
    @Published var borderAvailable = false
    /// Everything is locked while Save or Copy waits for the GIF.
    @Published var isLocked = false

    /// What the choices make, kept apart so its many updates redraw only the summary.
    let readout = EditorReadout()

    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        percent = Self.percents.contains(AppPreferences.exportScalePercent) ? AppPreferences.exportScalePercent : 50
        fps = GIFTiming.clampedFPS(AppPreferences.exportFPS)
        playback = AppPreferences.playback
        quality = min(max(AppPreferences.quality, 0), GIFEncoderOptions.qualityLevels - 1)
        removesBorder = AppPreferences.removesRecordingBorder
    }
}

/* The GIF the choices make. Its own object because progress changes many
   times a second while encoding: published from EditorOptions it redrew the
   whole form each time, and the form rebuilt its rows when the summary
   changed, taking the cursor out of the width field mid-typing. */
@MainActor
final class EditorReadout: ObservableObject {
    /// The GIF's file size once known, or a status line until then.
    @Published var sizeText = ""
    @Published var sizeIsKnown = false
    @Published var dimensions = ""
    /// Encoding progress; nil hides the progress circle.
    @Published var progress: Double?
}

/* The inspector beside the player, as in Photos' edit mode: what the GIF
   will be on top (size and resolution, next to Save in the toolbar above),
   then the choices in a grouped form like Lantern's settings. */
struct EditorInspector: View {
    @ObservedObject var options: EditorOptions
    @FocusState private var widthFocused: Bool
    @State private var widthDraft = ""

    var body: some View {
        Form {
            Section {
                EditorSummary(readout: options.readout, options: options)
            }
            Section {
                Picker(L("Size"), selection: $options.percent) {
                    ForEach(EditorOptions.percents, id: \.self) { Text("\($0)%").tag(Int?.some($0)) }
                    Divider()
                    Text(L("Custom Width…")).tag(Int?.none)
                }
                if options.percent == nil {
                    LabeledContent(L("Width")) {
                        TextField(L("Width"), text: $widthDraft)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .focused($widthFocused)
                            .onSubmit(commitWidth)
                            /* Only shown when Custom Width is picked, so
                               ready to type in; focus can only be given
                               once the field is in the window. */
                            .onAppear { DispatchQueue.main.async { widthFocused = true } }
                    }
                }
                Picker(L("Frame Rate"), selection: $options.fps) {
                    ForEach(GIFTiming.allowedFPS, id: \.self) { Text("\($0) fps").tag($0) }
                }
                /* Apple's names from Live Photo effects (Loop, Bounce). */
                Picker(L("Playback"), selection: $options.playback) {
                    Text(L("Loop")).tag(Playback.loop)
                    Text(L("Play Once")).tag(Playback.once)
                    Text(L("Bounce")).tag(Playback.bounce)
                }
            }
            .disabled(options.isLocked)
            Section(L("Quality")) {
                VStack(spacing: 4) {
                    Slider(value: quality, in: 0...Double(GIFEncoderOptions.qualityLevels - 1), step: 1)
                        .labelsHidden()
                    HStack {
                        Text(L("Smaller File"))
                        Spacer()
                        Text(L("Better Quality"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(options.isLocked)
            /* Only for videos that have the border, so most never see it.
               Off by default and explained right under its title: it
               changes the picture, if only by a pixel, so it is the
               user's call. */
            if options.borderAvailable {
                Section {
                    Toggle(isOn: $options.removesBorder) {
                        Text(L("Remove recording border"))
                        Text(L("Trims the thin line that macOS screen recordings leave around the edges."))
                    }
                }
                .disabled(options.isLocked)
            }
        }
        .formStyle(.grouped)
        .onAppear { widthDraft = options.customWidth }
        .onChange(of: options.customWidth) { _, width in widthDraft = width }
        .onChange(of: widthFocused) { _, focused in if !focused { commitWidth() } }
    }

    private var quality: Binding<Double> {
        Binding(get: { Double(options.quality) }, set: { options.quality = Int($0.rounded()) })
    }

    private func commitWidth() {
        if widthDraft != options.customWidth { options.customWidth = widthDraft }
    }
}

private struct EditorSummary: View {
    @ObservedObject var readout: EditorReadout
    @ObservedObject var options: EditorOptions

    /* One line, laid out like the rows below it: the GIF's resolution on
       the left, and in the value spot on the right its file size in bold,
       or a progress circle while the size is being worked out (and Cancel
       while Save or Copy waits for it). The resolution never moves, and the
       row's height is fixed at the button's so nothing below moves either. */
    var body: some View {
        HStack(spacing: 8) {
            Text(readout.dimensions)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            if let progress = readout.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityLabel(readout.sizeText)
            } else {
                Text(readout.sizeText)
                    .font(readout.sizeIsKnown ? .system(size: 15, weight: .semibold) : .body)
                    .foregroundStyle(readout.sizeIsKnown ? .primary : .secondary)
                    .monospacedDigit()
            }
            if options.isLocked {
                Button(L("Cancel")) { options.onCancel?() }
            }
        }
        .lineLimit(1)
        .frame(height: 24)
    }
}
