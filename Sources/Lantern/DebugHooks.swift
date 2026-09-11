import AppKit
import AVFoundation
import CoreMedia

/* Scripted checks for the parts that otherwise need a hand on the mouse.
   Every hook writes only to the path it is given and quits when done, so a
   test run never touches the Desktop or the real preferences beyond what
   any launch does.

   --debug-still <png-path>              captures the main display
   --debug-still-window <png-path>       captures the frontmost window (with its shadow)
   --debug-editor                        captures the main display and opens the editor on it
   --debug-record-ui                     starts an area recording through the normal path and leaves it running
   --debug-record <seconds> <mp4-path>   records the main display, then copies the file
   --debug-export <mp4> <out> <fps> <percent>   re-encodes an MP4 to .mp4 or .gif (by extension) */
enum DebugHooks {
    @MainActor
    static func run(arguments: [String], coordinator: CaptureCoordinator) -> Bool {
        if let index = arguments.firstIndex(of: "--debug-still"), arguments.count > index + 1 {
            let path = arguments[index + 1]
            Task { @MainActor in
                await still(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--debug-still-window"), arguments.count > index + 1 {
            let path = arguments[index + 1]
            Task { @MainActor in
                await stillWindow(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--debug-editor") {
            Task { @MainActor in
                do {
                    let snapshot = try await ShareableSnapshot.fetch()
                    guard let display = snapshot.displays.first else { return }
                    let image = try await StillCapturer.capture(.display(display), snapshot: snapshot, showsCursor: false)
                    coordinator.openEditorForDebugging(.image(image))
                } catch {
                    print("debug-editor: FAILED \(error)")
                }
            }
            return true
        }
        if arguments.contains("--debug-record-ui") {
            Task { @MainActor in
                if let snapshot = try? await ShareableSnapshot.fetch() {
                    coordinator.startRecordingForDebugging(snapshot: snapshot)
                }
            }
            return false  // the app keeps running normally: status item, editor
        }
        if let index = arguments.firstIndex(of: "--debug-record"), arguments.count > index + 2,
            let seconds = Double(arguments[index + 1])
        {
            let path = arguments[index + 2]
            Task { @MainActor in
                await record(seconds: seconds, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--debug-export"), arguments.count > index + 4,
            let fps = Int(arguments[index + 3]), let percent = Int(arguments[index + 4])
        {
            let source = URL(fileURLWithPath: arguments[index + 1])
            let output = URL(fileURLWithPath: arguments[index + 2])
            Task { @MainActor in
                await export(source: source, to: output, fps: fps, percent: percent)
                NSApp.terminate(nil)
            }
            return true
        }
        return false
    }

    @MainActor
    private static func still(to url: URL) async {
        do {
            let snapshot = try await ShareableSnapshot.fetch()
            guard let display = snapshot.displays.first else { throw ExportError.noVideoTrack }
            let image = try await StillCapturer.capture(.display(display), snapshot: snapshot, showsCursor: false)
            try PNGWriter.write(image.cgImage, scale: image.scale, to: url)
            print("debug-still: \(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) @\(image.scale)x -> \(url.path)")
        } catch {
            print("debug-still: FAILED \(error)")
        }
    }

    @MainActor
    private static func stillWindow(to url: URL) async {
        do {
            let snapshot = try await ShareableSnapshot.fetch()
            guard let window = snapshot.windows.first else { throw ExportError.noVideoTrack }
            let image = try await StillCapturer.capture(.window(window), snapshot: snapshot, showsCursor: false)
            try PNGWriter.write(image.cgImage, scale: image.scale, to: url)
            print("debug-still-window: \(window.owningApplication?.applicationName ?? "?") frame \(NSStringFromRect(window.frame)) -> \(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) @\(image.scale)x \(url.path)")
        } catch {
            print("debug-still-window: FAILED \(error)")
        }
    }

    @MainActor
    private static func record(seconds: Double, to url: URL) async {
        do {
            let snapshot = try await ShareableSnapshot.fetch()
            guard let display = snapshot.displays.first else { throw ExportError.noVideoTrack }
            let recorder = try ScreenRecorder(target: .display(display), snapshot: snapshot, showsCursor: true)
            try await recorder.start()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let video = try await recorder.stop()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: video.url, to: url)
            print("debug-record: \(Int(video.pixelSize.width))x\(Int(video.pixelSize.height)) \(video.duration.seconds)s -> \(url.path)")
        } catch {
            print("debug-record: FAILED \(error)")
        }
    }

    @MainActor
    private static func export(source: URL, to url: URL, fps: Int, percent: Int) async {
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noVideoTrack
            }
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration)
            let video = RecordedVideo(url: source, pixelSize: size, duration: duration)
            let format: ExportFormat = url.pathExtension.lowercased() == "gif" ? .gif : .mp4
            let settings = ExportSettings(format: format, scale: .percent(percent), fps: fps, trim: nil)
            let started = Date()
            try await MediaExporter.export(.video(video), settings: settings, to: url, job: ExportJob()) { _ in }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("debug-export: \(format.rawValue) \(bytes) bytes in \(String(format: "%.1f", Date().timeIntervalSince(started)))s -> \(url.path)")
        } catch {
            print("debug-export: FAILED \(error)")
        }
    }
}
