import AppKit
import CoreMedia
import LanternGIF

/* Scripted checks for the parts that otherwise need a hand on the mouse.
   Every hook writes only to the path it is given.

   --debug-export <video> <out.gif> <fps> <percent> <quality>[,<quality>…] [<start> <end>]
       encodes through the app's exporter (optionally trimmed to seconds
       start…end), prints time and size, quits. Several qualities encode
       one after another sharing a frame cache, as the editor does when the
       slider moves; each overwrites the output. `--playback loop|once|bounce`
       anywhere on the line sets how the GIF plays, and `--remove-border`
       cuts a recording border found by RecordingBorder.
   --debug-border <video>…
       prints the recording border found in each video, quits.
   --debug-open <video> [--crop <top>,<left>,<bottom>,<right>] [--crop-mode] [--crop-drag <x1>,<y1>,<x2>,<y2>]…
       opens the editor on a video through the normal path and keeps
       running, optionally with a crop already made (pixels off each side
       of the upright picture) and with crop mode open. Each --crop-drag
       is a left-button drag in window points from the top left, sent to
       the window from inside the app so the real pointer stays put (mouse
       events posted to the process from outside never reach its windows),
       and the crop is printed after each */
enum DebugHooks {
    /// A crop the next editor starts with (--debug-open … --crop).
    @MainActor static var editorCrop: PixelInsets?
    /// Whether the next editor opens crop mode (--debug-open … --crop-mode).
    @MainActor static var opensCropMode = false
    /// Drags to make in crop mode (--debug-open … --crop-drag).
    @MainActor static var cropDrags: [(CGPoint, CGPoint)] = []

    /// Sends each drag to the window as AppKit would deliver a real one.
    @MainActor static func performCropDrags(in window: NSWindow, report: @escaping () -> String) {
        var delay = 0.3
        for (from, to) in cropDrags {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let height = window.frame.height
                func send(_ type: NSEvent.EventType, _ point: CGPoint) {
                    guard
                        let event = NSEvent.mouseEvent(
                            with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                    else { return }
                    window.sendEvent(event)
                }
                send(.leftMouseDown, from)
                for step in 1...10 {
                    let t = CGFloat(step) / 10
                    send(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
                send(.leftMouseUp, to)
                print("crop-drag \(from) → \(to): \(report())")
                fflush(stdout)
            }
            delay += 0.3
        }
    }

    @MainActor
    static func run(arguments: [String], delegate: AppDelegate) -> Bool {
        if let index = arguments.firstIndex(of: "--debug-export"), arguments.count > index + 5,
            let fps = Int(arguments[index + 3]), let percent = Int(arguments[index + 4])
        {
            let qualities = arguments[index + 5].split(separator: ",").compactMap { Int($0) }
            let video = URL(fileURLWithPath: arguments[index + 1])
            let output = URL(fileURLWithPath: arguments[index + 2])
            Task { @MainActor in
                do {
                    let source = try await SourceVideo.load(video)
                    var trim: CMTimeRange?
                    if arguments.count > index + 7, let start = Double(arguments[index + 6]),
                        let end = Double(arguments[index + 7])
                    {
                        trim = CMTimeRange(
                            start: CMTime(seconds: start, preferredTimescale: 600),
                            end: CMTime(seconds: end, preferredTimescale: 600))
                    }
                    var playback = Playback.loop
                    if let flag = arguments.firstIndex(of: "--playback"), arguments.count > flag + 1 {
                        playback = Playback(rawValue: arguments[flag + 1]) ?? .loop
                    }
                    var crop = PixelInsets.zero
                    if arguments.contains("--remove-border") {
                        crop = await RecordingBorder.detect(in: source) ?? .zero
                    }
                    let cache = FrameCache()
                    for quality in qualities {
                        let started = Date()
                        let settings = ExportSettings(
                            scale: .percent(percent), fps: fps, quality: quality, trim: trim, playback: playback,
                            crop: crop)
                        try await GIFExporter.export(
                            source, settings: settings, to: output, job: ExportJob(), cache: cache) { _ in }
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                        print(
                            String(
                                format: "debug-export: %@ %.0fx%.0f q%d %@ → %d bytes in %.2fs", output.lastPathComponent,
                                settings.outputSize(of: source).width,
                                settings.outputSize(of: source).height, quality, playback.rawValue, bytes,
                                Date().timeIntervalSince(started)))
                    }
                } catch {
                    print("debug-export: FAILED \(error)")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--debug-border") {
            let videos = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
            Task { @MainActor in
                for path in videos {
                    let started = Date()
                    guard let source = try? await SourceVideo.load(URL(fileURLWithPath: path)) else {
                        print("debug-border: unreadable \(path)")
                        continue
                    }
                    let found = await RecordingBorder.detect(in: source)
                    print(
                        String(
                            format: "debug-border: t%d l%d b%d r%d in %.2fs  %@", found?.top ?? -1, found?.left ?? -1,
                            found?.bottom ?? -1, found?.right ?? -1, Date().timeIntervalSince(started),
                            URL(fileURLWithPath: path).lastPathComponent))
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--debug-open"), arguments.count > index + 1 {
            if let flag = arguments.firstIndex(of: "--crop"), arguments.count > flag + 1 {
                let sides = arguments[flag + 1].split(separator: ",").compactMap { Int($0) }
                if sides.count == 4 {
                    editorCrop = PixelInsets(top: sides[0], left: sides[1], bottom: sides[2], right: sides[3])
                }
            }
            opensCropMode = arguments.contains("--crop-mode")
            for (flag, value) in zip(arguments, arguments.dropFirst()) where flag == "--crop-drag" {
                let n = value.split(separator: ",").compactMap { Double($0) }
                if n.count == 4 { cropDrags.append((CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]))) }
            }
            delegate.open([URL(fileURLWithPath: arguments[index + 1])])
            return true
        }
        return false
    }
}
