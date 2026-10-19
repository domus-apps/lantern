@preconcurrency import AVFoundation
import CoreGraphics

/// Pixels to cut from each side of the upright frame before scaling.
struct PixelInsets: Equatable, Sendable {
    var top = 0
    var left = 0
    var bottom = 0
    var right = 0

    static let zero = PixelInsets()

    var isZero: Bool { self == .zero }

    func apply(to size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width - CGFloat(left + right), 1), height: max(size.height - CGFloat(top + bottom), 1))
    }

    /// The deeper cut on each side: a crop and a border both apply, and the
    /// border needs nothing more on a side cropped past it.
    func combined(with other: PixelInsets) -> PixelInsets {
        PixelInsets(
            top: max(top, other.top), left: max(left, other.left), bottom: max(bottom, other.bottom),
            right: max(right, other.right))
    }
}

/* The frame macOS screen recordings carry around their edges (measured on
   the Screenshot app's recordings, macOS 15 and 26, 2026-10-18): a 1px line
   about 11% darker than what it covers on every side, square-cornered, so
   an outline drawn over the screen rather than a window's edge; and on some
   recordings a pure black column on the left and right, with the picture
   pushed in by one pixel. Neither is on the screen, and both show as a dark
   line around a GIF.

   Found by looking, not assumed: each side's outermost lines are compared
   in a few frames across the clip, and a side is cut only where most of the
   frames agree, so footage without the frame keeps every pixel. */
enum RecordingBorder {
    /// Looks at a handful of frames across the video. Nil when it can't read them.
    static func detect(in video: SourceVideo, samples: Int = 5) async -> PixelInsets? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let duration = video.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        var found: [PixelInsets] = []
        for index in 0..<samples {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(samples), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image,
                let frame = LumaFrame(image)
            else { continue }
            found.append(insets(in: frame))
        }
        return found.isEmpty ? nil : agreed(found)
    }

    /// Per side, the deepest cut that at least half of the frames call for.
    static func agreed(_ frames: [PixelInsets]) -> PixelInsets {
        func side(_ value: (PixelInsets) -> Int) -> Int {
            let values = frames.map(value)
            let needed = (values.count + 1) / 2
            return (0...(values.max() ?? 0)).last { depth in values.filter { $0 >= depth }.count >= needed } ?? 0
        }
        return PixelInsets(
            top: side(\.top), left: side(\.left), bottom: side(\.bottom), right: side(\.right))
    }

    /// The cut one frame calls for: a black column first, then a darker line.
    static func insets(in frame: LumaFrame) -> PixelInsets {
        func side(_ line: (Int) -> [UInt8]) -> Int {
            let start = isBlack(line(0)) ? 1 : 0
            let outline = isOutline(line(start), inside: line(start + 1), next: line(start + 2))
            return start + (outline ? 1 : 0)
        }
        let w = frame.width, h = frame.height
        guard w > 8, h > 8 else { return .zero }
        return PixelInsets(
            top: side { frame.row($0) }, left: side { frame.column($0) },
            bottom: side { frame.row(h - 1 - $0) }, right: side { frame.column(w - 1 - $0) })
    }

    /// Padding, not picture: (nearly) every pixel of the line is black.
    static func isBlack(_ line: [UInt8]) -> Bool {
        line.filter { $0 <= 6 }.count * 100 >= line.count * 98
    }

    /* The outline darkens what it covers by a fixed fraction, 6–16% in the
       recordings measured (223 over 252, 74 over 86), so it is judged
       against the line just inside, on the pixels bright enough to show it:
       most of them darker, by a ratio in that range, and a step that stops
       at the outermost line. A gradient or vignette darkens toward the edge
       too, but keeps darkening the line inside by about as much. */
    static func isOutline(_ line: [UInt8], inside: [UInt8], next: [UInt8]) -> Bool {
        var outer: [Double] = []
        var inner: [Double] = []
        var darker = 0
        for index in line.indices where inside[index] >= 24 && next[index] >= 24 {
            outer.append(Double(line[index]) / Double(inside[index]))
            inner.append(Double(inside[index]) / Double(next[index]))
            if Int(line[index]) + 2 <= Int(inside[index]) { darker += 1 }
        }
        guard outer.count * 2 >= line.count else { return false }
        let step = median(outer)
        return darker * 10 >= outer.count * 8 && (0.75...0.97).contains(step) && median(inner) - step >= 0.04
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }
}

/* A frame's edges as 8-bit luminance: the outer `rim` rows and columns
   on each side, the most `insets(in:)` reads. Only those strips are
   drawn; drawing a whole 4K frame to read its edges took 33 MB a sample. */
struct LumaFrame {
    static let rim = 4

    let width: Int
    let height: Int
    private let luma: (Int, Int) -> UInt8

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        luma = { x, y in pixels[y * width + x] }
    }

    init?(_ image: CGImage) {
        let width = image.width, height = image.height, rim = Self.rim
        guard width >= rim, height >= rim,
            let top = Self.strip(of: image, CGRect(x: 0, y: 0, width: width, height: rim)),
            let bottom = Self.strip(of: image, CGRect(x: 0, y: height - rim, width: width, height: rim)),
            let left = Self.strip(of: image, CGRect(x: 0, y: 0, width: rim, height: height)),
            let right = Self.strip(of: image, CGRect(x: width - rim, y: 0, width: rim, height: height))
        else { return nil }
        self.width = width
        self.height = height
        luma = { x, y in
            if y < rim { return top[y * width + x] }
            if y >= height - rim { return bottom[(y - height + rim) * width + x] }
            if x < rim { return left[y * rim + x] }
            if x >= width - rim { return right[y * rim + x - width + rim] }
            return 0  // the middle is never read
        }
    }

    /// One part of the image as luminance, row by row from its top.
    private static func strip(of image: CGImage, _ rect: CGRect) -> [UInt8]? {
        guard let part = image.cropping(to: rect) else { return nil }
        let width = part.width, height = part.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width == Int(rect.width), height == Int(rect.height) else { return nil }
        // Rec. 709 weights
        return (0..<width * height).map { i in
            let p = i * 4
            return UInt8((Int(rgba[p]) * 54 + Int(rgba[p + 1]) * 183 + Int(rgba[p + 2]) * 19) >> 8)
        }
    }

    func row(_ y: Int) -> [UInt8] { (0..<width).map { luma($0, y) } }
    func column(_ x: Int) -> [UInt8] { (0..<height).map { luma(x, $0) } }
}
