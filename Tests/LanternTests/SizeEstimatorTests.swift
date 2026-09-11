import Foundation
import Testing

@testable import Lantern

@Test func estimatesGrowWithPixelsFramesAndDuration() {
    let small = CGSize(width: 640, height: 400)
    let large = CGSize(width: 1280, height: 800)
    #expect(SizeEstimator.bytes(format: .mp4, pixelSize: small, fps: 30, duration: 5)
        < SizeEstimator.bytes(format: .mp4, pixelSize: large, fps: 30, duration: 5))
    #expect(SizeEstimator.bytes(format: .gif, pixelSize: small, fps: 10, duration: 5)
        < SizeEstimator.bytes(format: .gif, pixelSize: small, fps: 20, duration: 5))
    #expect(SizeEstimator.bytes(format: .mp4, pixelSize: small, fps: 30, duration: 5)
        < SizeEstimator.bytes(format: .mp4, pixelSize: small, fps: 30, duration: 10))
}

@Test func pngEstimateIgnoresTime() {
    let size = CGSize(width: 800, height: 600)
    #expect(SizeEstimator.bytes(format: .png, pixelSize: size, fps: 60, duration: 1)
        == SizeEstimator.bytes(format: .png, pixelSize: size, fps: 10, duration: 100))
}

@Test func gifWorkingSetIsFourBytesPerPixelPerFrame() {
    #expect(SizeEstimator.gifWorkingSetBytes(pixelSize: CGSize(width: 100, height: 100), fps: 10, duration: 2) == 800_000)
}
