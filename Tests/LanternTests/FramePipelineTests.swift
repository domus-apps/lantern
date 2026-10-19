import CoreMedia
import Foundation
import Testing
@testable import Lantern

private struct Boom: Error {}

@Test func pipeDeliversEveryFrameInOrder() throws {
    let pipe = FramePipe(frameBytes: 4, depth: 3)
    var seen: [UInt8] = []
    try pipe.run(producer: { pipe in
        for value in 0..<50 {
            guard try pipe.push({ $0.initialize(repeating: UInt8(value), count: 4) }) else { return }
        }
    }) { index, pixels in
        #expect(Int(pixels[0]) == index)
        seen.append(pixels[3])
    }
    #expect(seen == (0..<50).map(UInt8.init))
}

@Test func pipeHoldsTheLastFrame() throws {
    let pipe = FramePipe(frameBytes: 2, depth: 2)
    var seen: [UInt8] = []
    try pipe.run(producer: { pipe in
        _ = try pipe.push { $0.initialize(repeating: 7, count: 2) }
        for _ in 0..<5 {
            let last = try #require(pipe.lastPushed)
            _ = try pipe.push { $0.update(from: last, count: 2) }
        }
    }) { _, pixels in
        seen.append(pixels[1])
    }
    #expect(seen == Array(repeating: 7, count: 6))
}

@Test func producerErrorReachesTheConsumerAfterItsFrames() {
    let pipe = FramePipe(frameBytes: 1)
    var consumed = 0
    #expect(throws: Boom.self) {
        try pipe.run(producer: { pipe in
            for _ in 0..<4 {
                _ = try pipe.push { $0.pointee = 1 }
            }
            throw Boom()
        }) { _, _ in consumed += 1 }
    }
    #expect(consumed == 4)
}

/* A consumer that stops early (cancel, write error) must release a producer
   blocked on a full pipe; this would hang otherwise. */
@Test func consumerErrorStopsAProducerWaitingForRoom() {
    let pipe = FramePipe(frameBytes: 1, depth: 2)
    let pushes = Counter()
    #expect(throws: Boom.self) {
        try pipe.run(producer: { pipe in
            for _ in 0..<10_000 {
                guard try pipe.push({ $0.pointee = 0 }) else { return }
                pushes.increment()
            }
        }) { index, _ in
            if index == 3 { throw Boom() }
        }
    }
    #expect(pushes.value < 10_000)
}

@Test func packedFramesRoundTrip() throws {
    let count = 64 * 64 * 4
    let flat = [UInt8](repeating: 200, count: count)
    var noise = [UInt8](repeating: 0, count: count)
    var state: UInt32 = 12345
    for i in noise.indices {
        state = state &* 1_664_525 &+ 1_013_904_223
        noise[i] = UInt8(truncatingIfNeeded: state >> 24)
    }
    for source in [flat, noise] {
        let frame = source.withUnsafeBufferPointer { PackedFrame.pack($0.baseAddress!, count: count) }
        var back = [UInt8](repeating: 0, count: count)
        try back.withUnsafeMutableBufferPointer { try frame.unpack(into: $0.baseAddress!, count: count) }
        #expect(back == source)
    }
    let flatFrame = flat.withUnsafeBufferPointer { PackedFrame.pack($0.baseAddress!, count: count) }
    #expect(flatFrame.isPacked && flatFrame.data.count < count / 20)
    let noiseFrame = noise.withUnsafeBufferPointer { PackedFrame.pack($0.baseAddress!, count: count) }
    #expect(!noiseFrame.isPacked && noiseFrame.data.count == count)
}

@Test func cacheAnswersOnlyForItsKey() {
    let cache = FrameCache()
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
    let key = FrameCache.Key(size: CGSize(width: 10, height: 10), fps: 15, range: range)
    cache.store(FrameCache.Entry(runs: [], frames: []), for: key)
    #expect(cache.entry(for: key) != nil)
    #expect(cache.entry(for: FrameCache.Key(size: CGSize(width: 10, height: 10), fps: 10, range: range)) == nil)
    cache.clear()
    #expect(cache.entry(for: key) == nil)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@Test func bounceGoesBackWithoutRepeatingTheEnds() {
    #expect(Playback.sequence(frameCount: 5, playback: .bounce) == [0, 1, 2, 3, 4, 3, 2, 1])
    #expect(Playback.sequence(frameCount: 5, playback: .loop) == [0, 1, 2, 3, 4])
    #expect(Playback.sequence(frameCount: 5, playback: .once) == [0, 1, 2, 3, 4])
    // Two frames already alternate when looped; one has nowhere to go.
    #expect(Playback.sequence(frameCount: 2, playback: .bounce) == [0, 1])
    #expect(Playback.sequence(frameCount: 1, playback: .bounce) == [0])
}

@Test func spillReturnsFramesInAnyOrder() throws {
    let spill = try FrameSpill()
    let count = 64
    var frames: [[UInt8]] = []
    for i in 0..<3 {
        let pixels = (0..<count).map { UInt8(truncatingIfNeeded: $0 * (i + 1)) }
        frames.append(pixels)
        pixels.withUnsafeBufferPointer { try? spill.append(PackedFrame.pack($0.baseAddress!, count: count)) }
    }
    #expect(spill.count == 3)
    for i in [2, 0, 1] {
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBufferPointer { try spill.frame(at: i).unpack(into: $0.baseAddress!, count: count) }
        #expect(out == frames[i])
    }
}

@Test func cachesShareOneLimitAndTheOldestGivesWay() {
    let budget = FrameCache.Budget(limit: 250)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
    let key = FrameCache.Key(size: CGSize(width: 10, height: 10), fps: 15, range: range)
    func entry(_ bytes: Int) -> FrameCache.Entry {
        FrameCache.Entry(runs: [], frames: [PackedFrame(data: Data(count: bytes), isPacked: false)])
    }
    let first = FrameCache(budget: budget), second = FrameCache(budget: budget), third = FrameCache(budget: budget)
    first.store(entry(100), for: key)
    second.store(entry(100), for: key)
    _ = first.entry(for: key)  // used again, so the second is now the oldest
    third.store(entry(100), for: key)
    #expect(first.entry(for: key) != nil)
    #expect(second.entry(for: key) == nil)
    #expect(third.entry(for: key) != nil)
}
