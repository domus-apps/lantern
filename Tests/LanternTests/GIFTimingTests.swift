import Testing

@testable import Lantern

@Test func sixtyFPSSnapsToThirtyForGIF() {
    #expect(GIFTiming.clampedFPS(60) == 30)
    #expect(GIFTiming.clampedFPS(30) == 30)
    #expect(GIFTiming.clampedFPS(24) == 20)
    #expect(GIFTiming.clampedFPS(5) == 10)
}

@Test func thirtyFPSDelaysAlternateThreeAndFourCentiseconds() {
    let runs = (0..<30).map { FrameRun(sourceIndex: $0, firstTick: $0, tickCount: 1) }
    let delays = GIFTiming.centiseconds(for: runs, fps: 30)
    #expect(delays.prefix(3) == [3, 4, 3])
    // One second of frames adds up to exactly one second.
    #expect(delays.reduce(0, +) == 100)
}

@Test func longRunsBecomeOneLongDelay() {
    let runs = [FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 45), FrameRun(sourceIndex: 1, firstTick: 45, tickCount: 15)]
    #expect(GIFTiming.centiseconds(for: runs, fps: 15) == [300, 100])
}

@Test func delaysNeverDropBelowTwoCentiseconds() {
    let runs = [FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 1)]
    #expect(GIFTiming.centiseconds(for: runs, fps: 100) == [2])
}
