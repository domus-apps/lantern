@preconcurrency import AVFoundation
import CoreImage
import Foundation
import LanternGIF

struct OutputScale: Equatable {
    enum Kind: Equatable {
        case percent(Int)
        case width(Int)
    }

    var kind: Kind

    static func percent(_ value: Int) -> OutputScale { OutputScale(kind: .percent(value)) }
    static func width(_ value: Int) -> OutputScale { OutputScale(kind: .width(value)) }

    func apply(to pixelSize: CGSize) -> CGSize {
        switch kind {
        case .percent(let percent): OutputGeometry.scaled(pixelSize, percent: percent)
        case .width(let width): OutputGeometry.size(fittingWidth: width, of: pixelSize)
        }
    }
}

/* How the GIF plays: over and over, once (stopping on the last frame), or
   forward then backward over and over, like a Live Photo's Bounce. */
enum Playback: String, CaseIterable {
    case loop, once, bounce

    /// The order the clip's frames are written in. Bounce goes back down
    /// without repeating either end, so the turns don't stutter.
    static func sequence(frameCount: Int, playback: Playback) -> [Int] {
        let forward = Array(0..<frameCount)
        guard playback == .bounce, frameCount > 2 else { return forward }
        return forward + (1..<(frameCount - 1)).reversed()
    }
}

struct ExportSettings: Equatable {
    var scale: OutputScale
    var fps: Int
    /// 0 (smallest file) … GIFEncoderOptions.qualityLevels - 1 (best quality).
    var quality: Int
    /// nil means the whole video.
    var trim: CMTimeRange?
    var playback: Playback = .loop
    /// Cut from the upright frame before scaling (a recording's border).
    var crop: PixelInsets = .zero

    /// The size of the video's picture this GIF is made from.
    func sourceSize(of video: SourceVideo) -> CGSize {
        crop.apply(to: video.pixelSize)
    }

    func outputSize(of video: SourceVideo) -> CGSize {
        scale.apply(to: sourceSize(of: video))
    }
}

/* A video file as the editor and exporter see it. The pixel size is the
   upright one: phone videos are stored sideways with a rotation to apply,
   and the frames are turned upright before scaling. */
struct SourceVideo {
    let url: URL
    let pixelSize: CGSize
    let duration: CMTime
    let orientation: CGImagePropertyOrientation

    var name: String { url.deletingPathExtension().lastPathComponent }

    static func load(_ url: URL) async throws -> SourceVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        guard natural.width > 0, natural.height > 0, duration.seconds > 0 else { throw ExportError.noVideoTrack }
        let orientation = Self.orientation(of: transform)
        let turned = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let size = turned ? CGSize(width: natural.height, height: natural.width) : natural
        return SourceVideo(
            url: url, pixelSize: CGSize(width: size.width.rounded(), height: size.height.rounded()),
            duration: duration, orientation: orientation)
    }

    /// The EXIF orientation that turns stored frames upright.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }
}

enum ExportError: LocalizedError {
    case cancelled
    case noVideoTrack
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: L("Export cancelled.")
        case .noVideoTrack: L("This file has no video Lantern can read.")
        case .failed(let message): message
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

/* Video → GIF. Pass 0 reads the frame timestamps without decoding, and
   FrameSampler turns them into runs at the GIF's rate (sample-and-hold, so
   a still stretch of the video becomes one long frame). The encoder then
   needs every frame twice: once to build the clip's palette, once to write.
   Pass 1 decodes in order, turns each frame upright, scales it (Lanczos, in
   sRGB) and packs a copy into the frame cache; pass 2 and any later encode
   at the same size, frame rate and trim (a quality change) unpack those
   instead of decoding again. Frames that won't fit the cache are decoded a
   second time. Either way a producer thread prepares the next frames while
   the encoder works (FramePipe). */
enum GIFExporter {
    private static let queue = DispatchQueue(label: "com.jhaemin.lantern.export", qos: .userInitiated)
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false,
    ])

    static func export(
        _ video: SourceVideo, settings: ExportSettings, to url: URL, job: ExportJob, cache: FrameCache = FrameCache(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: video.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let range = settings.trim ?? CMTimeRange(start: .zero, duration: video.duration)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try encode(
                        asset: asset, track: track, video: video, range: range, settings: settings, to: url,
                        job: job, cache: cache, progress: progress)
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
        asset: AVAsset, track: AVAssetTrack, video: SourceVideo, range: CMTimeRange, settings: ExportSettings,
        to url: URL, job: ExportJob, cache: FrameCache, progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let fps = GIFTiming.clampedFPS(settings.fps)
        let size = settings.outputSize(of: video)
        let width = Int(size.width)
        let height = Int(size.height)
        let frameBytes = width * height * 4
        let key = FrameCache.Key(size: size, fps: fps, range: range, crop: settings.crop)
        let cached = cache.entry(for: key)
        if cached == nil {
            cache.clear()  // a different size, rate or trim: free the old frames first
        }
        let runs: [FrameRun]
        if let cached {
            runs = cached.runs
        } else {
            let sourceTimes = try sourceTimestamps(asset: asset, track: track, range: range)
            runs = FrameSampler.plan(sourceTimes: sourceTimes, range: range, fps: fps)
        }
        guard !runs.isEmpty else { throw ExportError.noVideoTrack }
        let delays = GIFTiming.centiseconds(for: runs, fps: fps)
        let encoder = GIFEncoder(width: width, height: height, options: .quality(settings.quality))

        let decoder: @Sendable (FramePipe) throws -> Void = { pipe in
            try decodeFrames(
                asset: asset, track: track, video: video, range: range, runs: runs, size: size, crop: settings.crop,
                job: job, into: pipe)
        }
        func unpacker(_ frames: [PackedFrame]) -> @Sendable (FramePipe) throws -> Void {
            { pipe in
                for frame in frames {
                    guard !job.isCancelled else { throw ExportError.cancelled }
                    guard try pipe.push({ try frame.unpack(into: $0, count: frameBytes) }) else { return }
                }
            }
        }

        /* Split the progress bar by how long each pass takes (measured on
           screen recordings): decoding is the slow part, unpacking is quick. */
        let firstShare = cached != nil ? 0.2 : 0.6
        var lastReported = -1.0
        func report(_ fraction: Double) {
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
            lastReported = fraction
            progress(fraction)
        }

        // Pass 1: the palette, packing the frames on the way when they're new.
        var packed: [PackedFrame]? = cached == nil ? [] : nil
        var packedBytes = 0
        try FramePipe(frameBytes: frameBytes).run(producer: cached.map { unpacker($0.frames) } ?? decoder) {
            index, pixels in
            guard !job.isCancelled else { throw ExportError.cancelled }
            encoder.observe(pixels)
            if packed != nil {
                let frame = PackedFrame.pack(pixels, count: frameBytes)
                packedBytes += frame.data.count
                if packedBytes > FrameCache.byteLimit {
                    packed = nil  // won't fit: give it up and decode again in pass 2
                } else {
                    packed?.append(frame)
                }
            }
            report(firstShare * Double(index + 1) / Double(runs.count))
        }
        if let packed, packed.count == runs.count {
            cache.store(FrameCache.Entry(runs: runs, frames: packed), for: key)
        }
        let frames = cached?.frames ?? packed.flatMap { $0.count == runs.count ? $0 : nil }

        /* Pass 2: write, in playback order. The palette pass saw each frame
           once, which is all the colors a bounce shows too. Going back down
           needs the frames again in reverse: from memory when they're there,
           otherwise from a spill file written on the way up. */
        let order = Playback.sequence(frameCount: runs.count, playback: settings.playback)
        let spill = frames == nil && order.count > runs.count ? try FrameSpill() : nil
        let producer: @Sendable (FramePipe) throws -> Void
        if let frames {
            producer = unpacker(order.map { frames[$0] })
        } else if let spill {
            producer = { pipe in
                pipe.onFill = { try spill.append(PackedFrame.pack($0, count: frameBytes)) }
                try decoder(pipe)
                pipe.onFill = nil
                for index in order[runs.count...] {
                    guard !job.isCancelled else { throw ExportError.cancelled }
                    guard index < spill.count else { return }  // the way up stopped short
                    let frame = try spill.frame(at: index)
                    guard try pipe.push({ try frame.unpack(into: $0, count: frameBytes) }) else { return }
                }
            }
        } else {
            producer = decoder
        }
        try encoder.beginWriting(to: url, loopsForever: settings.playback != .once)
        do {
            try FramePipe(frameBytes: frameBytes).run(producer: producer) { position, pixels in
                guard !job.isCancelled else { throw ExportError.cancelled }
                try encoder.add(pixels, delayCentiseconds: delays[order[position]])
                report(firstShare + (1 - firstShare) * Double(position + 1) / Double(order.count))
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            throw error
        }
    }

    /// Decodes the frames the plan uses, in order, as upright RGBA at `size`,
    /// into the pipe. Runs on the pipe's producer thread.
    private static func decodeFrames(
        asset: AVAsset, track: AVAssetTrack, video: SourceVideo, range: CMTimeRange, runs: [FrameRun], size: CGSize,
        crop: PixelInsets, job: ExportJob, into pipe: FramePipe
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "reader")
        }
        defer { reader.cancelReading() }

        var runIndex = 0
        var frameIndex = 0
        while runIndex < runs.count {
            guard !job.isCancelled else { throw ExportError.cancelled }
            guard let sample = output.copyNextSampleBuffer() else { break }
            let keepGoing = try autoreleasepool {
                defer { frameIndex += 1 }
                guard runs[runIndex].sourceIndex == frameIndex, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    return true
                }
                runIndex += 1
                return try pipe.push { pixels in
                    render(
                        CIImage(cvPixelBuffer: buffer), orientation: video.orientation, crop: crop, size: size,
                        into: pixels)
                }
            }
            guard keepGoing else { return }
        }
        if reader.status == .failed {
            throw ExportError.failed(reader.error?.localizedDescription ?? "reader")
        }
        /* A video that ends early (a truncated file) leaves the plan short:
           hold the last frame for the remaining runs so the timing stays
           whole. */
        while runIndex < runs.count, let last = pipe.lastPushed {
            guard try pipe.push({ $0.update(from: last, count: pipe.frameBytes) }) else { return }
            runIndex += 1
        }
    }

    static func render(
        _ frame: CIImage, orientation: CGImagePropertyOrientation, crop: PixelInsets = .zero, size: CGSize,
        into pixels: UnsafeMutablePointer<UInt8>
    ) {
        var image = frame.oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if !crop.isZero {
            // Core Image counts y from the bottom: the bottom inset is at y = 0.
            let extent = image.extent
            image = image.cropped(
                to: CGRect(
                    x: CGFloat(crop.left), y: CGFloat(crop.bottom),
                    width: extent.width - CGFloat(crop.left + crop.right),
                    height: extent.height - CGFloat(crop.top + crop.bottom)))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if image.extent.size != size {
            image = scale(image, to: size)
        }
        ciContext.render(
            image, toBitmap: pixels, rowBytes: Int(size.width) * 4,
            bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: colorSpace)
    }

    /* Clamped first: Lanczos samples past the edges, and an unclamped image
       is transparent there, which left a half-transparent outer row. */
    static func scale(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let factor = size.width / extent.width
        let aspect = (size.height / extent.height) / factor
        return image.clampedToExtent()
            .applyingFilter(
                "CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: aspect])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func sourceTimestamps(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "reader")
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(time)
            }
        }
        /* Compressed samples arrive in decode order; decoded frames come out
           in presentation order, which is what the decode passes index by. */
        return times.sorted { $0 < $1 }
    }
}
