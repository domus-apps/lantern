import Foundation
import simd

/* Knobs of the encoder. The presets behind the quality slider are in
   `quality(_:)`; everything else is fixed tuning inside GIFEncoder. */
public struct GIFEncoderOptions: Sendable, Equatable {
    /// A pixel is repainted when its source color moves more than this
    /// (sum of the three channel differences) from the color it was last
    /// painted for. Below it, the canvas keeps what it shows, so video noise
    /// doesn't repaint static areas.
    public var tolerance: Int
    /// Floyd–Steinberg strength, 0…1.
    public var dither: Float
    /// How far (weighted squared RGB distance) a lossy LZW match may move a
    /// pixel from its exact color. 0 is lossless.
    public var lossiness: Float
    /// Palette size, at most 255 (index 255 is transparent).
    public var maxColors: Int
    /// Lets frames that the clip's palette serves badly carry their own.
    public var localPalettes: Bool

    public init(
        tolerance: Int = 6, dither: Float = 0.75, lossiness: Float = 0, maxColors: Int = 255,
        localPalettes: Bool = true
    ) {
        self.tolerance = tolerance
        self.dither = dither
        self.lossiness = lossiness
        self.maxColors = maxColors
        self.localPalettes = localPalettes
    }

    /// Quality levels behind the editor's slider, smallest file first.
    public static let qualityLevels = 5
    public static let defaultQuality = 3

    public static func quality(_ level: Int) -> GIFEncoderOptions {
        /* Calibrated on screen recordings and camera clips (2026-10-10):
           tolerance does the most for both, lossy LZW next, and fewer colors
           only pay off at the very bottom. */
        switch min(max(level, 0), qualityLevels - 1) {
        case 0: GIFEncoderOptions(tolerance: 32, lossiness: 1500, maxColors: 128)
        case 1: GIFEncoderOptions(tolerance: 24, lossiness: 800)
        case 2: GIFEncoderOptions(tolerance: 16, lossiness: 300)
        case 3: GIFEncoderOptions(tolerance: 10, lossiness: 100)
        default: GIFEncoderOptions(tolerance: 6, lossiness: 0)
        }
    }
}

public enum GIFEncoderError: Error {
    case noFrames
    case notStarted
}

/* An animated GIF made for screen recordings first, video second.

   Two passes over the same frames. `observe` sees every frame once and
   collects the colors each one actually adds (pixels that changed beyond
   the tolerance), and `beginWriting` turns them into one palette for the
   whole clip. `add` then paints each frame onto a running canvas:

   - Only changed pixels are painted. The frame is the bounding box of the
     changed pixels, unchanged pixels inside it are transparent, and frames
     are left in place, so a moving cursor costs a few hundred bytes.
   - A frame with no changed pixels extends the previous frame's delay.
   - Flat colors that the palette holds (almost) exactly are painted with
     that entry and take part in no dithering, which keeps UI crisp. If the
     canvas shows something visibly different over such a color (a fade's
     dither left behind), it is repainted, so ghosts don't linger.
   - Everything else is dithered (serpentine Floyd–Steinberg), within the
     changed pixels only: static areas are never re-dithered and can't
     shimmer.
   - A frame whose changed pixels the clip palette serves badly (camera
     footage shifts color every frame) gets a palette of its own.
   - LZW may be lossy (see LZW.swift).

   Each frame is split into bands of rows that are dithered and compressed
   on separate cores; the band streams are joined with clear codes. */
public final class GIFEncoder {
    public let width: Int
    public let height: Int
    public let options: GIFEncoderOptions

    static let transparent: UInt8 = 255
    /// A palette entry this close to a source color counts as that color.
    static let flatEpsilon: Float = 18
    /// How far the canvas may sit from a flat source before it is repainted.
    static let cleanDistance: Float = 60
    static let errorClamp: Float = 32
    /// A local palette is used when its error is below this share of the
    /// clip palette's, and only tried when the clip palette's mean error
    /// on the frame exceeds the trigger.
    static let localGain: Float = 0.6
    static let localTrigger: Float = 12

    private let pixelCount: Int
    private let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)

    // Pass 1.
    private let reference: UnsafeMutablePointer<UInt8>
    private var histogram = ColorHistogram()
    private var observedFrames = 0

    // Pass 2.
    private var palette: [SIMD3<Float>] = []
    private var lookup: PaletteLookup?
    /// The source color each canvas pixel was last painted for.
    private let canvasSource: UnsafeMutablePointer<UInt8>
    /// What each canvas pixel shows.
    private let shown: UnsafeMutablePointer<UInt8>
    private let mask: UnsafeMutablePointer<UInt8>
    private var handle: FileHandle?
    private var outputURL: URL?
    private var pending: PendingFrame?
    private var addedFrames = 0
    /// The last local palette, reused while it keeps fitting (consecutive
    /// video frames have much the same colors).
    private var lastLocal: PaletteLookup?
    /// Building a local palette that then loses is the costly part, so
    /// after a loss the next few frames don't try; the wait doubles with
    /// every loss in a row and resets on a win.
    private var localBackoff = 0
    private var localWait = 0

    private struct PendingFrame {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var localPalette: [SIMD3<Float>]?
        var compressed: [UInt8]
        var delay: Int
    }

    public init(width: Int, height: Int, options: GIFEncoderOptions) {
        precondition(width > 0 && height > 0 && width <= 0xFFFF && height <= 0xFFFF)
        self.width = width
        self.height = height
        self.options = options
        pixelCount = width * height
        reference = .allocate(capacity: pixelCount * 3)
        canvasSource = .allocate(capacity: pixelCount * 3)
        shown = .allocate(capacity: pixelCount * 3)
        mask = .allocate(capacity: pixelCount)
        reference.initialize(repeating: 0, count: pixelCount * 3)
        canvasSource.initialize(repeating: 0, count: pixelCount * 3)
        shown.initialize(repeating: 0, count: pixelCount * 3)
        mask.initialize(repeating: 0, count: pixelCount)
    }

    deinit {
        reference.deallocate()
        canvasSource.deallocate()
        shown.deallocate()
        mask.deallocate()
        try? handle?.close()
    }

    // MARK: - Pass 1

    /// Feeds one frame of the palette pass: RGBA, 4 bytes per pixel, rows
    /// tightly packed (alpha is ignored).
    public func observe(_ frame: UnsafePointer<UInt8>) {
        let first = observedFrames == 0
        observedFrames += 1
        let bands = rowBands(rows: height, pixelsPerRow: width, minimumPixels: 0)
        let tolerance = options.tolerance
        let width = width
        let reference = reference
        var collected = [[UInt32]](repeating: [], count: bands.count)
        collected.withUnsafeMutableBufferPointer { collected in
            DispatchQueue.concurrentPerform(iterations: bands.count) { band in
                var colors: [UInt32] = []
                for y in bands[band] {
                    for x in 0..<width {
                        let p = y * width + x
                        let r = frame[p * 4], g = frame[p * 4 + 1], b = frame[p * 4 + 2]
                        let q = p * 3
                        if !first {
                            let difference =
                                abs(Int(r) - Int(reference[q])) + abs(Int(g) - Int(reference[q + 1]))
                                + abs(Int(b) - Int(reference[q + 2]))
                            if difference <= tolerance { continue }
                        }
                        reference[q] = r
                        reference[q + 1] = g
                        reference[q + 2] = b
                        colors.append(packRGB(r, g, b))
                    }
                }
                collected[band] = colors
            }
        }
        /* Camera footage changes every pixel of every frame; a few hundred
           thousand samples per frame describe its colors just as well. */
        let total = collected.reduce(0) { $0 + $1.count }
        let stride = max(1, total / 400_000)
        var counter = 0
        for colors in collected {
            for color in colors {
                if counter % stride == 0 {
                    histogram.add(packed: color, weight: Double(stride))
                }
                counter += 1
            }
        }
    }

    // MARK: - Pass 2

    /// Builds the clip palette from the observed frames and starts the file.
    /// A GIF that doesn't loop forever plays once.
    public func beginWriting(to url: URL, loopsForever: Bool = true) throws {
        guard !histogram.isEmpty else { throw GIFEncoderError.noFrames }
        let bins = histogram.bins()
        palette = Quantizer.palette(
            colors: bins.colors, weights: bins.weights, maxColors: min(options.maxColors, 255), refinements: 5)
        lookup = PaletteLookup(colors: palette, bits: 5)
        histogram.reset()

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(
            contentsOf: GIFStream.header(width: width, height: height, palette: palette, loopsForever: loopsForever))
        self.handle = handle
        outputURL = url
    }

    /// Adds the next frame (same layout as `observe`), shown for
    /// `delayCentiseconds`. Frames must come in the same order as in pass 1.
    public func add(_ frame: UnsafePointer<UInt8>, delayCentiseconds delay: Int) throws {
        guard let lookup, handle != nil else { throw GIFEncoderError.notStarted }
        let first = addedFrames == 0
        addedFrames += 1

        guard let box = markChanges(frame, first: first, lookup: lookup) else {
            pending?.delay += delay
            return
        }
        try flushPending()

        var framePalette = palette
        var frameLookup = lookup
        var isLocal = false
        if options.localPalettes, box.changed * 100 >= pixelCount,
            let local = localPalette(frame, box: box, clipLookup: lookup)
        {
            framePalette = local.colors
            frameLookup = local
            isLocal = true
        }

        let compressed = paint(frame, box: box, palette: framePalette, lookup: frameLookup)
        pending = PendingFrame(
            x: box.minX, y: box.minY, width: box.width, height: box.height,
            localPalette: isLocal ? framePalette : nil, compressed: compressed, delay: delay)
    }

    public func finish() throws {
        guard let handle else { throw GIFEncoderError.notStarted }
        try flushPending()
        try handle.write(contentsOf: GIFStream.trailer)
        try handle.close()
        self.handle = nil
    }

    /// Stops and deletes the partial file.
    public func cancel() {
        try? handle?.close()
        handle = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    }

    private func flushPending() throws {
        guard let frame = pending, let handle else { return }
        pending = nil
        try handle.write(
            contentsOf: GIFStream.frame(
                x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                delayCentiseconds: frame.delay, transparentIndex: Self.transparent,
                localPalette: frame.localPalette, compressed: frame.compressed))
    }

    // MARK: - Change mask

    struct ChangeBox {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
        var changed: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Fills `mask` and returns the bounding box of the changed pixels, or
    /// nil when nothing changed.
    private func markChanges(_ frame: UnsafePointer<UInt8>, first: Bool, lookup: PaletteLookup) -> ChangeBox? {
        let bands = rowBands(rows: height, pixelsPerRow: width, minimumPixels: 0)
        let width = width
        let tolerance = options.tolerance
        let canvasSource = canvasSource
        let shown = shown
        let mask = mask
        let palette = palette
        /* A lossy match may leave a pixel up to `lossiness` off, so cleaning
           anything closer than that would repaint it frame after frame. */
        let cleanDistance = max(Self.cleanDistance, options.lossiness)
        var boxes = [ChangeBox?](repeating: nil, count: bands.count)
        boxes.withUnsafeMutableBufferPointer { boxes in
            DispatchQueue.concurrentPerform(iterations: bands.count) { band in
                var box = ChangeBox(minX: width, minY: Int.max, maxX: -1, maxY: -1, changed: 0)
                for y in bands[band] {
                    for x in 0..<width {
                        let p = y * width + x
                        let q = p * 3
                        let r = frame[p * 4], g = frame[p * 4 + 1], b = frame[p * 4 + 2]
                        var changed = first
                        if !first {
                            let difference =
                                abs(Int(r) - Int(canvasSource[q])) + abs(Int(g) - Int(canvasSource[q + 1]))
                                + abs(Int(b) - Int(canvasSource[q + 2]))
                            if difference > tolerance {
                                changed = true
                            } else if difference > 0 {
                                // Visibly off first: cheap, and rules out almost every pixel.
                                let color = SIMD3<Float>(Float(r), Float(g), Float(b))
                                let seen = SIMD3<Float>(Float(shown[q]), Float(shown[q + 1]), Float(shown[q + 2]))
                                if colorDistance(seen, color) > cleanDistance {
                                    changed = colorDistance(color, palette[lookup.nearest(color)]) <= Self.flatEpsilon
                                }
                            }
                        }
                        mask[p] = changed ? 1 : 0
                        if changed {
                            box.changed += 1
                            box.minX = min(box.minX, x)
                            box.maxX = max(box.maxX, x)
                            box.minY = min(box.minY, y)
                            box.maxY = y
                        }
                    }
                }
                boxes[band] = box.changed > 0 ? box : nil
            }
        }
        var merged: ChangeBox?
        for case let box? in boxes {
            if var current = merged {
                current.minX = min(current.minX, box.minX)
                current.maxX = max(current.maxX, box.maxX)
                current.minY = min(current.minY, box.minY)
                current.maxY = max(current.maxY, box.maxY)
                current.changed += box.changed
                merged = current
            } else {
                merged = box
            }
        }
        return merged
    }

    // MARK: - Local palette

    private func localPalette(_ frame: UnsafePointer<UInt8>, box: ChangeBox, clipLookup: PaletteLookup) -> PaletteLookup? {
        let step = max(1, Int((Double(box.changed) / 20_000).squareRoot()))
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(box.changed / (step * step) + 1)
        for y in stride(from: box.minY, through: box.maxY, by: step) {
            for x in stride(from: box.minX, through: box.maxX, by: step) {
                let p = y * width + x
                guard mask[p] != 0 else { continue }
                samples.append(SIMD3(Float(frame[p * 4]), Float(frame[p * 4 + 1]), Float(frame[p * 4 + 2])))
            }
        }
        guard !samples.isEmpty else { return nil }
        var clipError: Float = 0
        for color in samples {
            clipError += colorDistance(color, palette[clipLookup.nearest(color)])
        }
        guard clipError / Float(samples.count) > Self.localTrigger else { return nil }

        func error(of candidate: PaletteLookup) -> Float {
            var total: Float = 0
            for color in samples {
                total += colorDistance(color, candidate.colors[candidate.nearest(color)])
            }
            return total
        }
        if let lastLocal, error(of: lastLocal) < clipError * Self.localGain {
            return lastLocal
        }
        if localWait > 0 {
            localWait -= 1
            return nil
        }

        histogram.reset()
        for color in samples {
            histogram.add(packed: packRGB(UInt8(color.x), UInt8(color.y), UInt8(color.z)), weight: 1)
        }
        let bins = histogram.bins()
        let colors = Quantizer.palette(
            colors: bins.colors, weights: bins.weights, maxColors: min(options.maxColors, 255), refinements: 2)
        let local = PaletteLookup(colors: colors, bits: 4)
        guard error(of: local) < clipError * Self.localGain else {
            localBackoff = min(max(localBackoff * 2, 2), 32)
            localWait = localBackoff
            return nil
        }
        localBackoff = 0
        lastLocal = local
        return local
    }

    // MARK: - Painting

    /// Quantizes, dithers and compresses the changed box, band by band, and
    /// updates the canvas to what the decoder will show.
    private func paint(
        _ frame: UnsafePointer<UInt8>, box: ChangeBox, palette: [SIMD3<Float>], lookup: PaletteLookup
    ) -> [UInt8] {
        let w = box.width
        let h = box.height
        let bands = rowBands(rows: h, pixelsPerRow: w, minimumPixels: 16_384)
        let width = width
        let canvasSource = canvasSource
        let shown = shown
        let mask = mask
        let options = options
        let transparent = Self.transparent
        var table = palette
        while table.count < 256 { table.append(.zero) }

        let indices = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        indices.initialize(repeating: transparent, count: w * h)
        defer { indices.deallocate() }

        /* Joining bands costs a fresh LZW table per band, which is cheap
           when every pixel changes (the table fills and clears every few
           thousand codes anyway) but expensive for sparse screen frames,
           whose long transparent runs take a while to learn. */
        let lzwBands = box.changed * 2 >= w * h ? bands : [0..<h]
        var writers = [BitWriter](repeating: BitWriter(), count: lzwBands.count)

        table.withUnsafeBufferPointer { table in
            DispatchQueue.concurrentPerform(iterations: bands.count) { band in
                Self.dither(
                    frame, rows: bands[band], box: box, canvasWidth: width, mask: mask, indices: indices,
                    palette: table, lookup: lookup, strength: options.dither)
            }
            writers.withUnsafeMutableBufferPointer { writers in
                DispatchQueue.concurrentPerform(iterations: lzwBands.count) { band in
                    let rows = lzwBands[band]
                    writers[band] = LZW.encode(
                        LZWBand(
                            symbols: indices + rows.lowerBound * w, count: rows.count * w, rowWidth: w,
                            firstPixel: (box.minY + rows.lowerBound) * width + box.minX, canvasWidth: width,
                            shown: shown, palette: table.baseAddress!, transparent: transparent,
                            lossiness: options.lossiness, isFirst: band == 0, isLast: band == lzwBands.count - 1))
                }
            }
            // The canvas now shows what the chosen symbols say.
            DispatchQueue.concurrentPerform(iterations: bands.count) { band in
                for row in bands[band] {
                    let y = box.minY + row
                    for col in 0..<w {
                        let p = y * width + box.minX + col
                        let symbol = indices[row * w + col]
                        if symbol != transparent {
                            let color = table[Int(symbol)]
                            shown[p * 3] = UInt8(color.x)
                            shown[p * 3 + 1] = UInt8(color.y)
                            shown[p * 3 + 2] = UInt8(color.z)
                        }
                        if mask[p] != 0 {
                            canvasSource[p * 3] = frame[p * 4]
                            canvasSource[p * 3 + 1] = frame[p * 4 + 1]
                            canvasSource[p * 3 + 2] = frame[p * 4 + 2]
                        }
                    }
                }
            }
        }
        var joined = BitWriter()
        for writer in writers { joined.append(writer) }
        return joined.finished()
    }

    /// Serpentine Floyd–Steinberg over the changed pixels of some rows of
    /// the box; error never flows into or through unchanged pixels.
    private static func dither(
        _ frame: UnsafePointer<UInt8>, rows: Range<Int>, box: ChangeBox, canvasWidth: Int,
        mask: UnsafePointer<UInt8>, indices: UnsafeMutablePointer<UInt8>, palette: UnsafeBufferPointer<SIMD3<Float>>,
        lookup: PaletteLookup, strength: Float
    ) {
        let w = box.width
        var current = [SIMD3<Float>](repeating: .zero, count: w + 2)
        var next = [SIMD3<Float>](repeating: .zero, count: w + 2)
        let low = SIMD3<Float>(repeating: 0)
        let high = SIMD3<Float>(repeating: 255)
        let clamp = SIMD3<Float>(repeating: errorClamp)
        for (n, row) in rows.enumerated() {
            let y = box.minY + row
            let forward = n % 2 == 0
            current.withUnsafeMutableBufferPointer { current in
                next.withUnsafeMutableBufferPointer { next in
                    for step in 0..<w {
                        let col = forward ? step : w - 1 - step
                        let p = y * canvasWidth + box.minX + col
                        guard mask[p] != 0 else { continue }
                        let source = SIMD3<Float>(Float(frame[p * 4]), Float(frame[p * 4 + 1]), Float(frame[p * 4 + 2]))
                        let snapped = lookup.nearest(source)
                        if strength == 0 || colorDistance(source, palette[snapped]) <= flatEpsilon {
                            indices[row * w + col] = UInt8(snapped)
                            continue
                        }
                        let wanted = simd_clamp(source + current[col + 1], low, high)
                        let j = lookup.nearest(wanted)
                        indices[row * w + col] = UInt8(j)
                        let error = simd_clamp((wanted - palette[j]) * strength, -clamp, clamp)
                        let ahead = forward ? col + 2 : col
                        let behind = forward ? col : col + 2
                        current[ahead] += error * (7.0 / 16)
                        next[behind] += error * (3.0 / 16)
                        next[col + 1] += error * (5.0 / 16)
                        next[ahead] += error * (1.0 / 16)
                    }
                }
            }
            swap(&current, &next)
            for i in next.indices { next[i] = .zero }
        }
    }

    /// Splits `rows` into contiguous bands, one per core at most, each with
    /// at least `minimumPixels` (so small boxes stay in one band and keep a
    /// single LZW table).
    private func rowBands(rows: Int, pixelsPerRow: Int, minimumPixels: Int) -> [Range<Int>] {
        let byPixels = minimumPixels > 0 ? max(1, rows * pixelsPerRow / minimumPixels) : rows
        let count = max(1, min(cores, byPixels, rows))
        let size = (rows + count - 1) / count
        return stride(from: 0, to: rows, by: size).map { $0..<min(rows, $0 + size) }
    }
}
