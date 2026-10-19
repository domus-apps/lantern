import Foundation
import ImageIO
import Testing
@testable import LanternGIF

/* The encoder is checked through ImageIO, the decoder macOS itself uses:
   with tolerance, dither and lossiness at zero and no more than 255 colors,
   every frame must come back exactly as it went in. */

private struct Frame {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let p = (y * width + x) * 4
                pixels[p] = r
                pixels[p + 1] = g
                pixels[p + 2] = b
            }
        }
    }
}

private let exact = GIFEncoderOptions(tolerance: 0, dither: 0, lossiness: 0, maxColors: 255, localPalettes: false)

private func encode(
    _ frames: [Frame], delays: [Int], options: GIFEncoderOptions = exact, loopsForever: Bool = true
) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-test-\(UUID().uuidString).gif")
    let encoder = GIFEncoder(width: frames[0].width, height: frames[0].height, options: options)
    for frame in frames {
        frame.pixels.withUnsafeBufferPointer { encoder.observe($0.baseAddress!) }
    }
    try encoder.beginWriting(to: url, loopsForever: loopsForever)
    for (frame, delay) in zip(frames, delays) {
        try frame.pixels.withUnsafeBufferPointer { try encoder.add($0.baseAddress!, delayCentiseconds: delay) }
    }
    try encoder.finish()
    return url
}

/// Each decoded frame (ImageIO composites them onto the canvas) as RGB, with its delay.
private func decode(_ url: URL) throws -> [(rgb: [UInt8], delay: Double)] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    var frames: [(rgb: [UInt8], delay: Double)] = []
    for index in 0..<CGImageSourceGetCount(source) {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for p in 0..<(width * height) {
            rgb.append(contentsOf: rgba[(p * 4)..<(p * 4 + 3)])
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        frames.append((rgb, delay))
    }
    return frames
}

private func rgb(_ frame: Frame) -> [UInt8] {
    var out: [UInt8] = []
    for p in 0..<(frame.width * frame.height) {
        out.append(contentsOf: frame.pixels[(p * 4)..<(p * 4 + 3)])
    }
    return out
}

@Test func flatScreenFramesRoundTripExactly() throws {
    // A UI-like canvas: a few flat colors, a box that moves, a frame that repeats.
    let background = { (_: Int, _: Int) -> (UInt8, UInt8, UInt8) in (246, 246, 248) }
    func withBox(at origin: Int) -> Frame {
        Frame(width: 120, height: 80) { x, y in
            if (origin..<(origin + 20)).contains(x), (20..<40).contains(y) { return (0, 122, 255) }
            if y < 10 { return (30, 30, 30) }
            return background(x, y)
        }
    }
    let frames = [withBox(at: 10), withBox(at: 30), withBox(at: 30), withBox(at: 70)]
    let url = try encode(frames, delays: [10, 10, 10, 20])
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try decode(url)
    // The repeated frame merges into the one before it.
    #expect(decoded.count == 3)
    #expect(decoded.map(\.delay) == [0.1, 0.2, 0.2])
    #expect(decoded[0].rgb == rgb(frames[0]))
    #expect(decoded[1].rgb == rgb(frames[1]))
    #expect(decoded[2].rgb == rgb(frames[3]))
}

@Test func denseFramesSplitAcrossBandsRoundTripExactly() throws {
    /* Every pixel changes in every frame, which is what makes the encoder
       compress in parallel bands joined by clear codes; 250 colors keep it
       lossless. Big enough for several bands. */
    let colors: [(UInt8, UInt8, UInt8)] = (0..<250).map { (i: Int) -> (UInt8, UInt8, UInt8) in
        let g = (i * 7) % 256
        let b = (i * 13) % 256
        return (UInt8(i), UInt8(g), UInt8(b))
    }
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33)
    }
    let frames = (0..<3).map { _ in
        Frame(width: 400, height: 300) { x, _ in
            // Runs of a color, as in real images, plus noise.
            colors[(x / 3 + next() % 5) % colors.count]
        }
    }
    let url = try encode(frames, delays: [5, 5, 5])
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try decode(url)
    #expect(decoded.count == 3)
    for (frame, result) in zip(frames, decoded) {
        #expect(result.rgb == rgb(frame))
    }
}

@Test func lossyFramesStayWithinTheirBound() throws {
    // A soft gradient: lossy matching may move pixels, but only so far.
    let frame = Frame(width: 200, height: 100) { x, y in
        (UInt8(x), UInt8(min(255, 50 + y)), 128)
    }
    var options = exact
    options.lossiness = 300
    let url = try encode([frame], delays: [10], options: options)
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try decode(url)[0].rgb
    let source = rgb(frame)
    var worst = 0
    for p in stride(from: 0, to: source.count, by: 3) {
        let d = (0..<3).map { abs(Int(decoded[p + $0]) - Int(source[p + $0])) }.max()!
        worst = max(worst, d)
    }
    // Quantization error plus a lossiness of 300 (≈ 6 per channel at the
    // weights 2·4·3) stays well inside this.
    #expect(worst <= 24)
}

@Test func paletteLookupFindsTheTrueNearestColor() {
    var seed: UInt64 = 42
    func next() -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Float(seed >> 56)
    }
    let palette = (0..<200).map { _ in SIMD3<Float>(next(), next(), next()) }
    for bits in [4, 5] {
        let lookup = PaletteLookup(colors: palette, bits: bits)
        for _ in 0..<2000 {
            let query = SIMD3<Float>(next(), next(), next())
            let found = colorDistance(query, palette[lookup.nearest(query)])
            let best = palette.map { colorDistance(query, $0) }.min()!
            #expect(found == best)
        }
    }
}

/* ImageIO's loop count is how many times the GIF plays: 0 (forever) from
   the NETSCAPE block, and 1 for a GIF without it. */
@Test func loopBlockIsWrittenOnlyForLoopingGIFs() throws {
    let frames = (0..<3).map { i in Frame(width: 8, height: 8) { _, _ in (UInt8(i * 80), 0, 0) } }
    for loops in [true, false] {
        let url = try encode(frames, delays: [10, 10, 10], loopsForever: loops)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let count = gif?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(count == (loops ? 0 : 1))
        #expect(try decode(url).count == 3)
    }
}
