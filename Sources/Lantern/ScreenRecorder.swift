import AVFoundation
import Foundation
import ScreenCaptureKit

struct RecordedVideo {
    let url: URL
    let pixelSize: CGSize
    let duration: CMTime
}

enum RecorderError: LocalizedError {
    case diskFull
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .diskFull: L("There isn't enough free disk space to record.")
        case .failed(let message): message
        }
    }
}

/* Screen recording: an SCStream feeding ScreenCaptureKit's own
   SCRecordingOutput, which encodes H.264 into an MP4 as frames arrive and
   handles the timing details itself (first-frame session start, idle
   stretches where nothing on screen changes). start() resolves once the
   file is being written; stop() resolves with the finished file.

   Delegate callbacks arrive on ScreenCaptureKit's queues and are hopped to
   the main thread, where the coordinator lives. */
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    /* @unchecked Sendable: every piece of mutable state is touched on the
       main thread only (the delegate callbacks hop there first). */
    private static let minimumFreeBytes: Int64 = 500 * 1024 * 1024

    private var stream: SCStream!
    private var output: SCRecordingOutput!
    private let url: URL
    private let pixelSize: CGSize

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var hasStarted = false
    private var hasFinished = false
    private var finishError: Error?

    /// The stream ended without stop() being called: the user clicked the
    /// system's recording indicator, the captured window closed, or the
    /// system stopped it. Delivered on the main thread.
    var onStoppedExternally: (() -> Void)?

    init(target: CaptureTarget, snapshot: ShareableSnapshot, showsCursor: Bool) throws {
        guard Self.freeBytes() > Self.minimumFreeBytes else { throw RecorderError.diskFull }

        let built = StreamConfigurationBuilder.make(
            for: target, snapshot: snapshot, purpose: .video, showsCursor: showsCursor)
        url = TempFiles.newRecordingURL()
        pixelSize = built.pixelSize
        super.init()

        stream = SCStream(filter: built.filter, configuration: built.configuration, delegate: self)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.videoCodecType = .h264
        recording.outputFileType = .mp4
        output = SCRecordingOutput(configuration: recording, delegate: self)
    }

    var elapsed: CMTime { output.recordedDuration }

    private static func freeBytes() -> Int64 {
        (try? TempFiles.directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
    }

    func start() async throws {
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                if self.hasStarted {
                    continuation.resume()
                } else if let error = self.finishError {
                    continuation.resume(throwing: error)
                } else {
                    self.startContinuation = continuation
                }
            }
        }
    }

    func stop() async throws -> RecordedVideo {
        /* Already-stopped streams throw here; the file is still finalized. */
        try? await stream.stopCapture()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                if self.hasFinished {
                    if let error = self.finishError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                } else {
                    self.stopContinuation = continuation
                    /* SCK normally reports the finish within a second;
                       if it never does, hand over whatever was written. */
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard let pending = self.stopContinuation else { return }
                        self.stopContinuation = nil
                        self.hasFinished = true
                        pending.resume()
                    }
                }
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecorderError.failed(L("The recording was interrupted before anything was saved."))
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? output.recordedDuration
        return RecordedVideo(url: url, pixelSize: pixelSize, duration: duration)
    }

    func discard() {
        TempFiles.remove(url)
    }

    // MARK: - SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.hasStarted = true
            self.startContinuation?.resume()
            self.startContinuation = nil
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            NSLog("Lantern: recording output ended with error: %@", error.localizedDescription)
            /* A stop from outside (the system's menu bar indicator, the
               window closing) can arrive here rather than as a clean
               finish, with a perfectly good file already written. Only an
               empty file is a failure. SCK's dedicated storage error code is
               newer than this SDK's deployment target, so judge by the
               volume itself. */
            let written = (try? FileManager.default.attributesOfItem(atPath: self.url.path)[.size] as? Int) ?? 0
            let mapped: Error? =
                written > 0
                ? nil
                : (Self.freeBytes() < Self.minimumFreeBytes
                    ? RecorderError.diskFull : RecorderError.failed(error.localizedDescription))
            self.finishError = mapped
            self.hasFinished = true
            if let mapped {
                self.startContinuation?.resume(throwing: mapped)
            } else {
                self.startContinuation?.resume()
            }
            self.startContinuation = nil
            if let stop = self.stopContinuation {
                self.stopContinuation = nil
                if let mapped { stop.resume(throwing: mapped) } else { stop.resume() }
            } else {
                self.onStoppedExternally?()
            }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.hasFinished = true
            self.stopContinuation?.resume()
            self.stopContinuation = nil
        }
    }

    // MARK: - SCStreamDelegate

    /* The stream ended on its own: the user stopped it from the system's
       menu bar indicator, the window went away, or macOS stopped it. The
       recording output still finalizes the file, so this is a normal stop
       from the coordinator's point of view. */
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            NSLog("Lantern: stream stopped: %@", error.localizedDescription)
            guard self.stopContinuation == nil, !self.hasFinished else { return }
            self.onStoppedExternally?()
        }
    }
}
