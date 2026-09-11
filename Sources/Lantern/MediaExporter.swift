@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case png, mp4, gif

    var fileExtension: String { rawValue }
    var utType: UTType {
        switch self {
        case .png: .png
        case .mp4: .mpeg4Movie
        case .gif: .gif
        }
    }
}

enum OutputScale: Equatable {
    case percent(Int)
    case width(Int)

    func apply(to pixelSize: CGSize, even: Bool) -> CGSize {
        switch self {
        case .percent(let percent):
            CaptureGeometry.scaled(pixelSize, percent: percent, even: even)
        case .width(let width):
            CaptureGeometry.size(fittingWidth: width, of: pixelSize, even: even)
        }
    }
}

struct ExportSettings {
    var format: ExportFormat
    var scale: OutputScale
    /// Output frame rate for video; ignored for PNG.
    var fps: Int
    /// nil means the whole recording.
    var trim: CMTimeRange?
}

enum CapturedMedia {
    case image(CapturedImage)
    case video(RecordedVideo)

    var pixelSize: CGSize {
        switch self {
        case .image(let image): image.pixelSize
        case .video(let video): video.pixelSize
        }
    }
}

enum ExportError: LocalizedError {
    case cancelled
    case encodingFailed
    case noVideoTrack
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: L("Export cancelled.")
        case .encodingFailed: L("The file couldn't be encoded.")
        case .noVideoTrack: L("The recording has no video.")
        case .writerFailed(let message): message
        }
    }
}

/* Cancellation flag shared between the editor (main thread) and the export
   queue; checked once per frame. The lock is what makes it safe to share. */
final class ExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/* One re-encode path serves trim, resize, frame-rate change, and both video
   formats: pass 1 reads the source frame timestamps without decoding, the
   FrameSampler turns them into output runs at the target rate, and pass 2
   decodes sequentially, scales each needed frame through CoreImage, and
   hands it to the MP4 writer or the GIF destination. Nothing but the
   current frame is held in memory for MP4; ImageIO retains GIF frames until
   finalize (see SizeEstimator.gifWorkingSetBytes). */
enum MediaExporter {
    private static let queue = DispatchQueue(label: "com.jhaemin.lantern.export", qos: .userInitiated)
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false,
    ])

    static func export(
        _ media: CapturedMedia, settings: ExportSettings, to url: URL, job: ExportJob,
        progress: @escaping (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        switch media {
        case .image(let image):
            try exportImage(image, settings: settings, to: url)
        case .video(let video):
            try await exportVideo(video, settings: settings, to: url, job: job, progress: progress)
        }
    }

    // MARK: - Still

    private static func exportImage(_ image: CapturedImage, settings: ExportSettings, to url: URL) throws {
        let target = settings.scale.apply(to: image.pixelSize, even: false)
        if target == image.pixelSize {
            try PNGWriter.write(image.cgImage, scale: image.scale, to: url)
            return
        }
        let scaled = scale(CIImage(cgImage: image.cgImage), to: target)
        guard let cgImage = ciContext.createCGImage(scaled, from: CGRect(origin: .zero, size: target)) else {
            throw ExportError.encodingFailed
        }
        /* Resized output is a plain bitmap: 72 dpi, point size = pixel size. */
        try PNGWriter.write(cgImage, scale: 1, to: url)
    }

    // MARK: - Video

    private static func exportVideo(
        _ video: RecordedVideo, settings: ExportSettings, to url: URL, job: ExportJob,
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: video.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let range = settings.trim ?? CMTimeRange(start: .zero, duration: duration)
        let outputSize = settings.scale.apply(to: video.pixelSize, even: true)

        /* Nothing to re-encode: the recording as it is. */
        if settings.format == .mp4, outputSize == video.pixelSize, settings.fps >= 60,
            settings.trim == nil
        {
            try FileManager.default.copyItem(at: video.url, to: url)
            progress(1)
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try encode(
                        asset: asset, track: track, range: range, outputSize: outputSize,
                        settings: settings, to: url, job: job, progress: progress)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on the export queue.
    private static func encode(
        asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, outputSize: CGSize,
        settings: ExportSettings, to url: URL, job: ExportJob, progress: @escaping (Double) -> Void
    ) throws {
        // Pass 1: timestamps only (compressed samples, no decode).
        let sourceTimes = try sourceTimestamps(asset: asset, track: track, range: range)
        let fps = settings.format == .gif ? GIFTiming.clampedFPS(settings.fps) : settings.fps
        let runs = FrameSampler.plan(sourceTimes: sourceTimes, range: range, fps: fps)
        guard !runs.isEmpty else { throw ExportError.noVideoTrack }

        // Pass 2: decode in order, scale the frames the plan uses, write.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else {
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "reader")
        }

        let sink: FrameSink =
            settings.format == .gif
            ? try GIFSink(url: url, runs: runs, fps: fps)
            : try MP4Sink(url: url, size: outputSize, fps: fps, totalTicks: FrameSampler.totalTicks(runs))

        var runIndex = 0
        var frameIndex = 0
        let total = Double(runs.count)
        var lastReported = 0.0
        while runIndex < runs.count {
            guard !job.isCancelled else {
                reader.cancelReading()
                sink.cancel()
                throw ExportError.cancelled
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            try autoreleasepool {
                defer { frameIndex += 1 }
                guard runs[runIndex].sourceIndex == frameIndex,
                    let buffer = CMSampleBufferGetImageBuffer(sample)
                else { return }
                var image = CIImage(cvPixelBuffer: buffer)
                if outputSize != CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) {
                    image = scale(image, to: outputSize)
                }
                /* Several runs can reuse one source frame only if the
                   sampler produced them from different ticks — it merges
                   those, so each source index appears at most once. */
                try sink.write(image, run: runs[runIndex], source: buffer)
                runIndex += 1
                let fraction = Double(runIndex) / total
                if fraction - lastReported >= 0.02 || runIndex == runs.count {
                    lastReported = fraction
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
        }
        if reader.status == .failed {
            sink.cancel()
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "reader")
        }
        try sink.finish()
    }

    private static func sourceTimestamps(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else {
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "reader")
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(time)
            }
        }
        /* Compressed samples arrive in decode order; decoded frames come out
           in presentation order, which is what pass 2 indexes by. */
        return times.sorted { $0 < $1 }
    }

    // MARK: - Scaling

    static func scale(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let factor = size.width / extent.width
        let aspect = (size.height / extent.height) / factor
        return image
            .applyingFilter(
                "CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: aspect])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    static func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        ciContext.render(
            image, to: buffer,
            bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            colorSpace: colorSpace)
    }

    static func cgImage(_ image: CIImage, size: CGSize) -> CGImage? {
        ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size))
    }
}

// MARK: - Sinks

private protocol FrameSink {
    func write(_ image: CIImage, run: FrameRun, source: CVPixelBuffer) throws
    func finish() throws
    func cancel()
}

/* H.264 in MP4 at the target rate. One sample per run, so a static screen
   produces a handful of samples rather than sixty per second; the final
   endSession holds the last frame to the trim end. */
private final class MP4Sink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int
    private let totalTicks: Int
    private let size: CGSize

    init(url: URL, size: CGSize, fps: Int, totalTicks: Int) throws {
        self.fps = fps
        self.totalTicks = totalTicks
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = Double(size.width * size.height)
        let bitrate = Int(min(pixels * Double(fps) * 0.08, 40_000_000))
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(bitrate, 500_000),
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "writer")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func write(_ image: CIImage, run: FrameRun, source: CVPixelBuffer) throws {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let buffer: CVPixelBuffer
        if CVPixelBufferGetWidth(source) == Int(size.width), CVPixelBufferGetHeight(source) == Int(size.height) {
            buffer = source
        } else {
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.encodingFailed }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            guard let created else { throw ExportError.encodingFailed }
            MediaExporter.render(image, into: created)
            buffer = created
        }
        let time = CMTime(value: CMTimeValue(run.firstTick), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append")
        }
    }

    func finish() throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(totalTicks), timescale: CMTimeScale(fps)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}

/* Animated GIF through ImageIO: one local 256-color palette per frame,
   looping forever, delays from GIFTiming so the total length is exact. */
private final class GIFSink: FrameSink {
    private let destination: CGImageDestination
    private let delays: [Double]
    private let size: CGSize?
    private var index = 0

    init(url: URL, runs: [FrameRun], fps: Int) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, runs.count, nil)
        else { throw ExportError.encodingFailed }
        self.destination = destination
        delays = GIFTiming.delays(for: runs, fps: fps)
        size = nil
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
                kCGImagePropertyGIFHasGlobalColorMap: false,
            ]
        ]
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
    }

    func write(_ image: CIImage, run: FrameRun, source: CVPixelBuffer) throws {
        guard let cgImage = MediaExporter.cgImage(image, size: image.extent.size) else {
            throw ExportError.encodingFailed
        }
        let delay = delays[min(index, delays.count - 1)]
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        index += 1
    }

    func finish() throws {
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
    }

    func cancel() {}
}
