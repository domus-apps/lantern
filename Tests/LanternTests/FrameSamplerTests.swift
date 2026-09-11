import CoreMedia
import Testing

@testable import Lantern

private func seconds(_ values: [Double]) -> [CMTime] {
    values.map { CMTime(seconds: $0, preferredTimescale: 600) }
}

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        end: CMTime(seconds: end, preferredTimescale: 600))
}

@Test func steadySourceMapsOneFramePerTick() {
    let runs = FrameSampler.plan(sourceTimes: seconds([0, 0.1, 0.2, 0.3]), range: range(0, 0.4), fps: 10)
    #expect(runs == [
        FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 1),
        FrameRun(sourceIndex: 1, firstTick: 1, tickCount: 1),
        FrameRun(sourceIndex: 2, firstTick: 2, tickCount: 1),
        FrameRun(sourceIndex: 3, firstTick: 3, tickCount: 1),
    ])
    #expect(FrameSampler.totalTicks(runs) == 4)
}

@Test func idleGapsHoldThePreviousFrameAsOneRun() {
    // Frames at 0 and 0.5 s; nothing changed in between.
    let runs = FrameSampler.plan(sourceTimes: seconds([0, 0.5]), range: range(0, 1), fps: 10)
    #expect(runs == [
        FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 5),
        FrameRun(sourceIndex: 1, firstTick: 5, tickCount: 5),
    ])
}

@Test func downsamplingDropsFramesBetweenTicks() {
    let source = seconds(stride(from: 0, to: 1, by: 1.0 / 60).map { $0 })
    let runs = FrameSampler.plan(sourceTimes: source, range: range(0, 1), fps: 15)
    #expect(runs.count == 15)
    // Every tick shows the latest frame at or before it: tick k at k/15 s = frame 4k.
    #expect(runs[3].sourceIndex == 12)
}

@Test func ticksBeforeTheFirstFrameShowTheFirstFrame() {
    let runs = FrameSampler.plan(sourceTimes: seconds([0.25, 0.5]), range: range(0, 1), fps: 4)
    #expect(runs.first == FrameRun(sourceIndex: 0, firstTick: 0, tickCount: 2))
}

@Test func trimStartShiftsTheTickGrid() {
    let runs = FrameSampler.plan(sourceTimes: seconds([0, 1, 2, 3]), range: range(1.5, 3.5), fps: 1)
    // Ticks at 1.5 and 2.5 → frames 1 and 2.
    #expect(runs == [
        FrameRun(sourceIndex: 1, firstTick: 0, tickCount: 1),
        FrameRun(sourceIndex: 2, firstTick: 1, tickCount: 1),
    ])
}

@Test func emptyInputsProduceNoPlan() {
    #expect(FrameSampler.plan(sourceTimes: [], range: range(0, 1), fps: 30).isEmpty)
    #expect(FrameSampler.plan(sourceTimes: seconds([0]), range: range(0, 0), fps: 30).isEmpty)
    #expect(FrameSampler.plan(sourceTimes: seconds([0]), range: range(0, 1), fps: 0).isEmpty)
}
