import Foundation

/* GIF frame delays are whole centiseconds, and players treat anything under
   2 cs as 10 cs. So 60 fps cannot be expressed (1.67 cs) and even 30 fps
   (3.33 cs) has no exact delay: a fixed 3 cs would play 11% fast. The
   delays here are error-diffused — each run's delay is the difference of
   the rounded cumulative times — so the clip's total length is exact and
   the drift never exceeds half a centisecond. */
enum GIFTiming {
    /// Frame rates the GIF picker offers.
    static let allowedFPS = [30, 20, 15, 10]

    /// The closest allowed rate at or below `fps` (60 → 30).
    static func clampedFPS(_ fps: Int) -> Int {
        allowedFPS.first { $0 <= fps } ?? allowedFPS.last!
    }

    /// Per-run delays in seconds for a plan at `fps`.
    static func delays(for runs: [FrameRun], fps: Int) -> [Double] {
        runs.map { run in
            let start = Double(run.firstTick) / Double(fps)
            let end = Double(run.firstTick + run.tickCount) / Double(fps)
            let centiseconds = (end * 100).rounded() - (start * 100).rounded()
            return max(centiseconds, 2) / 100
        }
    }
}
