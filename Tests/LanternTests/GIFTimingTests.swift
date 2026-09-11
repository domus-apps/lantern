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
    let delays = GIFTiming.delays(for: runs, fps: 30)
    #expect(delays.prefix(3) == [0.03, 0.04, 0.03])
    // One second of frames adds up to exactly one second.
    #expect(abs(delays.reduce(0, +) - 1.0) < 1e-9)
}

@Test func longRunsBecomeOneLongDelay() {
    let runs = [FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 45), FrameRun(sourceIndex: 1, firstTick: 45, tickCount: 15)]
    let delays = GIFTiming.delays(for: runs, fps: 15)
    #expect(delays == [3.0, 1.0])
}

@Test func delaysNeverDropBelowTwoCentiseconds() {
    let runs = [FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 1)]
    #expect(GIFTiming.delays(for: runs, fps: 100) == [0.02])
}
