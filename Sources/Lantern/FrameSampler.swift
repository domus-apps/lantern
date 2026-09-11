import CoreMedia

/* Retiming a recording to a target frame rate. Output "ticks" fall every
   1/fps from the start of the trim range; each tick shows the latest source
   frame that had appeared by then (sample-and-hold — screen content only
   changes when something happens, and the recorder only emits frames when
   it does, so "nearest" would show a frame before it existed). Consecutive
   ticks showing the same frame merge into one run, which is what the
   encoders want: one sample held for a while, not duplicates. */
struct FrameRun: Equatable {
    /// Index into the sorted source frame list.
    let sourceIndex: Int
    /// First output tick (in 1/fps units, counted from the trim start).
    let firstTick: Int
    let tickCount: Int
}

enum FrameSampler {
    /// - sourceTimes: presentation times of every source frame in the trim
    ///   range, ascending.
    /// - range: the trim range; ticks cover it end-inclusive of the last
    ///   partial interval.
    static func plan(sourceTimes: [CMTime], range: CMTimeRange, fps: Int) -> [FrameRun] {
        guard fps > 0, !sourceTimes.isEmpty, range.duration.seconds > 0 else { return [] }
        let start = range.start.seconds
        let tickCount = max(1, Int((range.duration.seconds * Double(fps)).rounded(.up)))
        let times = sourceTimes.map(\.seconds)

        var runs: [FrameRun] = []
        var sourceIndex = 0
        for tick in 0..<tickCount {
            let t = start + Double(tick) / Double(fps)
            /* Advance to the latest frame at or before t. A tiny tolerance
               absorbs float error between the two passes' timestamps. */
            while sourceIndex + 1 < times.count, times[sourceIndex + 1] <= t + 1e-6 {
                sourceIndex += 1
            }
            if let last = runs.last, last.sourceIndex == sourceIndex {
                runs[runs.count - 1] = FrameRun(
                    sourceIndex: last.sourceIndex, firstTick: last.firstTick,
                    tickCount: last.tickCount + 1)
            } else {
                runs.append(FrameRun(sourceIndex: sourceIndex, firstTick: tick, tickCount: 1))
            }
        }
        return runs
    }

    /// Total ticks a plan spans (the output duration in 1/fps units).
    static func totalTicks(_ runs: [FrameRun]) -> Int {
        guard let last = runs.last else { return 0 }
        return last.firstTick + last.tickCount
    }
}
