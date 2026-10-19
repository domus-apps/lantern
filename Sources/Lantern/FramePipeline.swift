import Compression
import CoreMedia
import Foundation

/* Frames move from a producer thread (decoding the video, or unpacking the
   frame cache) to the encoder through a few reusable buffers, so decoding
   the next frame overlaps encoding this one. The consumer side runs on the
   caller's thread; frames arrive in order. */
final class FramePipe: @unchecked Sendable {
    let frameBytes: Int
    private let slots: [UnsafeMutablePointer<UInt8>]
    private let free: DispatchSemaphore
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var produced = 0
    private var finished = false
    private var stopped = false
    private var failure: Error?
    /// Producer side only: sees each frame once it is filled, before the
    /// consumer does.
    var onFill: ((UnsafePointer<UInt8>) throws -> Void)?

    init(frameBytes: Int, depth: Int = 3) {
        self.frameBytes = frameBytes
        slots = (0..<depth).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: frameBytes) }
        /* Starts at zero and is signalled up: libdispatch traps when a
           semaphore is freed below its initial value, which a pipe stopped
           mid-stream can leave behind. */
        free = DispatchSemaphore(value: 0)
        for _ in 0..<depth { free.signal() }
    }

    deinit {
        for slot in slots { slot.deallocate() }
    }

    // MARK: Producer side

    /// Fills the next buffer; false once the consumer has stopped listening.
    func push(_ fill: (UnsafeMutablePointer<UInt8>) throws -> Void) throws -> Bool {
        free.wait()
        lock.lock()
        let stop = stopped
        let slot = slots[produced % slots.count]
        lock.unlock()
        if stop { return false }
        try fill(slot)
        try onFill?(slot)
        lock.lock()
        produced += 1
        lock.unlock()
        ready.signal()
        return true
    }

    /* The frame pushed last. The producer only ever writes the slot after
       it, so this one stays intact while the next frame copies from it. */
    var lastPushed: UnsafePointer<UInt8>? {
        lock.lock()
        defer { lock.unlock() }
        return produced > 0 ? UnsafePointer(slots[(produced - 1) % slots.count]) : nil
    }

    // MARK: Consumer side

    /// Runs `producer` on its own thread and hands each frame to `consume`
    /// here, in order. Returns once the producer is done and every frame it
    /// made has been consumed; rethrows the first error from either side.
    func run(
        producer: @escaping @Sendable (FramePipe) throws -> Void,
        consume: (_ index: Int, _ pixels: UnsafePointer<UInt8>) throws -> Void
    ) throws {
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            do {
                try producer(self)
                self.finish(nil)
            } catch {
                self.finish(error)
            }
        }
        /* Whatever happens here, release the producer and wait for it: the
           buffers are freed with the pipe. */
        defer {
            lock.lock()
            stopped = true
            lock.unlock()
            for _ in slots { free.signal() }
            group.wait()
        }
        var index = 0
        while true {
            ready.wait()
            lock.lock()
            let available = produced
            let done = finished
            let error = failure
            lock.unlock()
            if index < available {
                try consume(index, slots[index % slots.count])
                index += 1
                free.signal()
            } else if done {
                if let error { throw error }
                return
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        finished = true
        failure = error
        lock.unlock()
        ready.signal()
    }
}

/// One frame, LZ4-packed (or kept as is when packing wouldn't shrink it).
struct PackedFrame: Sendable {
    let data: Data
    let isPacked: Bool

    static func pack(_ pixels: UnsafePointer<UInt8>, count: Int) -> PackedFrame {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        let size = compression_encode_buffer(buffer, count, pixels, count, nil, COMPRESSION_LZ4)
        return size > 0
            ? PackedFrame(data: Data(bytes: buffer, count: size), isPacked: true)
            : PackedFrame(data: Data(bytes: pixels, count: count), isPacked: false)
    }

    func unpack(into pixels: UnsafeMutablePointer<UInt8>, count: Int) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { throw ExportError.failed("cache") }
            if isPacked {
                let size = compression_decode_buffer(pixels, count, source, data.count, nil, COMPRESSION_LZ4)
                guard size == count else { throw ExportError.failed("cache") }
            } else {
                pixels.update(from: source, count: count)
            }
        }
    }
}

/* Frames written to disk on the way through, for a bounce whose frames are
   too many for the frame cache: going back down reads them in reverse
   instead of seeking the video backward. Producer thread only. The file
   goes with the spill. */
final class FrameSpill: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private var entries: [(offset: UInt64, length: Int, isPacked: Bool)] = []
    private var end: UInt64 = 0

    init() throws {
        try FileManager.default.createDirectory(at: TempFiles.directory, withIntermediateDirectories: true)
        url = TempFiles.directory.appendingPathComponent("Spill-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    var count: Int { entries.count }

    func append(_ frame: PackedFrame) throws {
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: frame.data)
        entries.append((end, frame.data.count, frame.isPacked))
        end += UInt64(frame.data.count)
    }

    func frame(at index: Int) throws -> PackedFrame {
        let entry = entries[index]
        try handle.seek(toOffset: entry.offset)
        guard let data = try handle.read(upToCount: entry.length), data.count == entry.length else {
            throw ExportError.failed("spill")
        }
        return PackedFrame(data: data, isPacked: entry.isPacked)
    }
}

/* The editor's decoded frames for its current size, frame rate, trim and crop,
   kept LZ4-packed between encodes. Decoding and scaling is most of an
   encode's time, and a quality change needs the very same frames, so with
   the cache it only re-runs the encoder. Screen recordings pack about 10–20×
   (45 s at 1119×815: 2.1 GB of frames → 131 MB); footage that won't fit
   under the limit isn't cached and simply decodes again. The limit holds
   for all open editors together: storing frames empties the caches used
   longest ago until the total fits. Cleared when memory runs critically
   low. */
final class FrameCache: @unchecked Sendable {
    struct Key: Equatable {
        let size: CGSize
        let fps: Int
        let range: CMTimeRange
        var crop: PixelInsets = .zero

        static func == (a: Key, b: Key) -> Bool {
            a.size == b.size && a.fps == b.fps && CMTimeRangeEqual(a.range, b.range) && a.crop == b.crop
        }
    }

    struct Entry: Sendable {
        let runs: [FrameRun]
        let frames: [PackedFrame]
    }

    static let byteLimit = 1 << 30

    private let lock = NSLock()
    private var key: Key?
    private var entry: Entry?
    private var bytes = 0
    private var lastUse: TimeInterval = 0
    private let budget: Budget
    /* Critical only: a Mac can sit at "warning" for hours with plenty of
       room (measured 2026-10-11 at 41% free), and the source reports the
       current level as soon as it starts, which emptied the cache before
       the first re-encode could use it. */
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: .critical)

    init(budget: Budget = .shared) {
        self.budget = budget
        pressure.setEventHandler { [weak self] in self?.clear() }
        pressure.activate()
        budget.add(self)
    }

    deinit {
        pressure.cancel()
    }

    func entry(for key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard self.key == key else { return nil }
        lastUse = ProcessInfo.processInfo.systemUptime
        return entry
    }

    func store(_ entry: Entry, for key: Key) {
        lock.lock()
        self.key = key
        self.entry = entry
        bytes = entry.frames.reduce(0) { $0 + $1.data.count }
        lastUse = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        budget.fit(keeping: self)
    }

    func clear() {
        lock.lock()
        key = nil
        entry = nil
        bytes = 0
        lock.unlock()
    }

    fileprivate var usage: (bytes: Int, lastUse: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, lastUse)
    }

    /// The caches that share one byte limit: every editor's, in the app.
    final class Budget: @unchecked Sendable {
        static let shared = Budget(limit: FrameCache.byteLimit)

        private let limit: Int
        private let lock = NSLock()
        private var caches: [Weak] = []

        private struct Weak {
            weak var cache: FrameCache?
        }

        init(limit: Int) {
            self.limit = limit
        }

        fileprivate func add(_ cache: FrameCache) {
            lock.lock()
            caches.removeAll { $0.cache == nil }
            caches.append(Weak(cache: cache))
            lock.unlock()
        }

        /// Empties the others, least recently used first, until all fit.
        fileprivate func fit(keeping kept: FrameCache) {
            lock.lock()
            let all = caches.compactMap(\.cache)
            lock.unlock()
            var total = all.reduce(0) { $0 + $1.usage.bytes }
            let others = all.filter { $0 !== kept && $0.usage.bytes > 0 }.sorted { $0.usage.lastUse < $1.usage.lastUse }
            for cache in others where total > limit {
                total -= cache.usage.bytes
                cache.clear()
            }
        }
    }
}
