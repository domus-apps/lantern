import CoreGraphics
import Foundation
import Testing
@testable import Lantern

/* Frames shaped like the measured recordings: an outline that darkens what
   it covers by about 11% on every side, sometimes inside a black column on
   the left and right, and content that must not be mistaken for either. */

private func frame(width: Int = 64, height: Int = 40, _ value: (Int, Int) -> UInt8) -> LumaFrame {
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = value(x, y)
        }
    }
    return LumaFrame(width: width, height: height, pixels: pixels)
}

/// `content` with the recording outline drawn on its outermost pixels.
private func outlined(width: Int = 64, height: Int = 40, content: @escaping (Int, Int) -> UInt8) -> LumaFrame {
    frame(width: width, height: height) { x, y in
        let edge = x == 0 || y == 0 || x == width - 1 || y == height - 1
        let value = content(x, y)
        return edge ? UInt8(Double(value) * 0.885) : value
    }
}

@Test func outlineOnEverySideIsOnePixel() {
    let found = RecordingBorder.insets(in: outlined { _, _ in 252 })
    #expect(found == PixelInsets(top: 1, left: 1, bottom: 1, right: 1))
}

@Test func outlineIsFoundOverDetailedContent() {
    // Blocks of light and dark, like a UI touching the edge.
    let found = RecordingBorder.insets(in: outlined { x, y in (x / 6 + y / 6) % 2 == 0 ? 120 : 240 })
    #expect(found == PixelInsets(top: 1, left: 1, bottom: 1, right: 1))
}

@Test func blackColumnsComeOffWithTheOutlineInsideThem() {
    let width = 64, height = 40
    let found = RecordingBorder.insets(
        in: frame(width: width, height: height) { x, y in
            if x == 0 || x == width - 1 { return 0 }  // the padding
            let edge = x == 1 || y == 0 || x == width - 2 || y == height - 1
            return edge ? 204 : 229
        })
    #expect(found == PixelInsets(top: 1, left: 2, bottom: 1, right: 2))
}

@Test func cleanFramesKeepEveryPixel() {
    #expect(RecordingBorder.insets(in: frame { _, _ in 252 }) == .zero)
    // Gradients darken toward the edge, but all the way in.
    #expect(RecordingBorder.insets(in: frame { x, y in UInt8(40 + x * 2 + y) }) == .zero)
    #expect(RecordingBorder.insets(in: frame { x, _ in UInt8(min(250, 120 + x * 12)) }) == .zero)
    // A window edge in the shot: darker on one side only, by far more.
    #expect(RecordingBorder.insets(in: frame { x, _ in x == 0 ? 90 : 240 }) == .zero)
}

@Test func darkContentHidesTheOutline() {
    // Over near-black the outline changes nothing visible, and nothing is cut.
    #expect(RecordingBorder.insets(in: outlined { _, _ in 12 }) == .zero)
}

@Test func mostFramesHaveToAgree() {
    let one = PixelInsets(top: 1, left: 1, bottom: 1, right: 1)
    let padded = PixelInsets(top: 1, left: 2, bottom: 1, right: 2)
    #expect(RecordingBorder.agreed([one, one, .zero, one, .zero]) == one)
    #expect(RecordingBorder.agreed([one, .zero, .zero, .zero, one]) == .zero)
    #expect(RecordingBorder.agreed([padded, padded, one, padded, .zero]) == padded)
}

@Test func insetsShrinkTheSourceSize() {
    let insets = PixelInsets(top: 1, left: 2, bottom: 1, right: 2)
    #expect(insets.apply(to: CGSize(width: 1012, height: 386)) == CGSize(width: 1008, height: 384))
}

@Test func aCropAndTheBorderCutTheMostOfEachSide() {
    let crop = PixelInsets(top: 40, left: 0, bottom: 0, right: 120)
    let border = PixelInsets(top: 1, left: 2, bottom: 1, right: 2)
    // A side the crop already cuts deeper loses no more; the others lose the border.
    #expect(crop.combined(with: border) == PixelInsets(top: 40, left: 2, bottom: 1, right: 120))
    #expect(border.combined(with: crop) == crop.combined(with: border))
    #expect(crop.combined(with: .zero) == crop)
}

@Test func edgesReadFromAnImageMatchTheWholeFrame() throws {
    // A 23×17 image whose every pixel differs, drawn whole for reference.
    let width = 23, height = 17
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = (y * width + x) * 4
            rgba[p] = UInt8(x * 11 % 256)
            rgba[p + 1] = UInt8(y * 15 % 256)
            rgba[p + 2] = UInt8((x + y) * 7 % 256)
        }
    }
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let image = try #require(
        CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let luma = (0..<width * height).map { i in
        UInt8((Int(rgba[i * 4]) * 54 + Int(rgba[i * 4 + 1]) * 183 + Int(rgba[i * 4 + 2]) * 19) >> 8)
    }
    let whole = LumaFrame(width: width, height: height, pixels: luma)
    let edges = try #require(LumaFrame(image))
    for depth in 0..<LumaFrame.rim {
        #expect(edges.row(depth) == whole.row(depth))
        #expect(edges.row(height - 1 - depth) == whole.row(height - 1 - depth))
        #expect(edges.column(depth) == whole.column(depth))
        #expect(edges.column(width - 1 - depth) == whole.column(width - 1 - depth))
    }
}
