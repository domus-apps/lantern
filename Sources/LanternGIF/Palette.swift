import Foundation
import simd

/* Weighted squared RGB distance, used for every color decision in the
   encoder: the eye resolves green best and blue worst. */
let channelWeights = SIMD3<Float>(2, 4, 3)

@inline(__always)
func colorDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let d = a - b
    return (d * d * channelWeights).sum()
}

/* Color histogram at 6 bits per channel. Each bin keeps its weight and the
   weighted sum of the exact colors that fell in it, so a bin holding one
   flat UI color gives back exactly that color. Only touched bins are reset,
   which keeps a per-frame histogram cheap. */
struct ColorHistogram {
    private var weights = [Double](repeating: 0, count: 1 << 18)
    private var sums = [SIMD3<Double>](repeating: .zero, count: 1 << 18)
    private var touched: [Int32] = []

    var isEmpty: Bool { touched.isEmpty }

    @inline(__always)
    mutating func add(packed color: UInt32, weight: Double) {
        let r = UInt8(truncatingIfNeeded: color >> 16)
        let g = UInt8(truncatingIfNeeded: color >> 8)
        let b = UInt8(truncatingIfNeeded: color)
        let bin = Int(r >> 2) << 12 | Int(g >> 2) << 6 | Int(b >> 2)
        if weights[bin] == 0 { touched.append(Int32(bin)) }
        weights[bin] += weight
        sums[bin] += SIMD3(Double(r), Double(g), Double(b)) * weight
    }

    mutating func reset() {
        for bin in touched {
            weights[Int(bin)] = 0
            sums[Int(bin)] = .zero
        }
        touched.removeAll(keepingCapacity: true)
    }

    /// The occupied bins as mean colors with their weights.
    func bins() -> (colors: [SIMD3<Float>], weights: [Float]) {
        var colors: [SIMD3<Float>] = []
        var binWeights: [Float] = []
        colors.reserveCapacity(touched.count)
        binWeights.reserveCapacity(touched.count)
        for bin in touched {
            let weight = weights[Int(bin)]
            let mean = sums[Int(bin)] / weight
            colors.append(SIMD3(Float(mean.x), Float(mean.y), Float(mean.z)))
            binWeights.append(Float(weight))
        }
        return (colors, binWeights)
    }
}

@inline(__always)
func packRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
}

/* Median cut, then k-means. The cut repeatedly splits the box with the
   largest weighted variance along its widest channel at the weighted
   median; the k-means passes then settle each center on the mean of the
   colors nearest to it. */
enum Quantizer {
    static func palette(
        colors: [SIMD3<Float>], weights: [Float], maxColors: Int, refinements: Int
    ) -> [SIMD3<Float>] {
        guard !colors.isEmpty else { return [SIMD3(0, 0, 0)] }
        if colors.count <= maxColors {
            return colors.map { $0.rounded(.toNearestOrEven) }
        }
        var palette = medianCut(colors: colors, weights: weights, maxColors: maxColors)
        for _ in 0..<refinements {
            palette = kMeansStep(palette: palette, colors: colors, weights: weights)
        }
        return palette.map { $0.rounded(.toNearestOrEven) }
    }

    private struct Box {
        var lower: Int
        var upper: Int
        var error: Float
        var axis: Int
    }

    private static func medianCut(colors: [SIMD3<Float>], weights: [Float], maxColors: Int) -> [SIMD3<Float>] {
        let scale = channelWeights.squareRoot()
        var order = Array(0..<colors.count)

        func makeBox(_ lower: Int, _ upper: Int) -> Box {
            var total: Float = 0
            var sum = SIMD3<Float>.zero
            var squares = SIMD3<Float>.zero
            for i in lower..<upper {
                let c = colors[order[i]] * scale
                let w = weights[order[i]]
                total += w
                sum += c * w
                squares += c * c * w
            }
            let mean = sum / total
            let variance = squares / total - mean * mean
            let axis = variance.x >= variance.y && variance.x >= variance.z ? 0 : (variance.y >= variance.z ? 1 : 2)
            return Box(
                lower: lower, upper: upper, error: upper - lower > 1 ? max(variance.sum(), 0) * total : 0,
                axis: axis)
        }

        var boxes = [makeBox(0, colors.count)]
        while boxes.count < maxColors {
            guard let target = boxes.indices.max(by: { boxes[$0].error < boxes[$1].error }),
                boxes[target].error > 0
            else { break }
            let box = boxes[target]
            let axis = box.axis
            order[box.lower..<box.upper].sort { colors[$0][axis] < colors[$1][axis] }
            var half: Float = 0
            for i in box.lower..<box.upper { half += weights[order[i]] }
            half /= 2
            var running: Float = 0
            var split = box.upper - 1
            for i in box.lower..<(box.upper - 1) {
                running += weights[order[i]]
                if running >= half {
                    split = i + 1
                    break
                }
            }
            split = min(max(split, box.lower + 1), box.upper - 1)
            boxes[target] = makeBox(box.lower, split)
            boxes.append(makeBox(split, box.upper))
        }
        return boxes.map { box in
            var total: Float = 0
            var sum = SIMD3<Float>.zero
            for i in box.lower..<box.upper {
                total += weights[order[i]]
                sum += colors[order[i]] * weights[order[i]]
            }
            return sum / total
        }
    }

    /* One k-means pass, chunked across cores; each chunk accumulates into
       its own slice and the slices are summed afterwards. */
    private static func kMeansStep(
        palette: [SIMD3<Float>], colors: [SIMD3<Float>], weights: [Float]
    ) -> [SIMD3<Float>] {
        let k = palette.count
        let chunkSize = 4096
        let chunks = (colors.count + chunkSize - 1) / chunkSize
        var sums = [SIMD3<Double>](repeating: .zero, count: chunks * k)
        var totals = [Double](repeating: 0, count: chunks * k)
        palette.withUnsafeBufferPointer { palette in
            colors.withUnsafeBufferPointer { colors in
                weights.withUnsafeBufferPointer { weights in
                    sums.withUnsafeMutableBufferPointer { sums in
                        totals.withUnsafeMutableBufferPointer { totals in
                            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                                let base = chunk * k
                                let end = min(colors.count, (chunk + 1) * chunkSize)
                                for i in (chunk * chunkSize)..<end {
                                    var best = 0
                                    var bestDistance = Float.greatestFiniteMagnitude
                                    for j in 0..<k {
                                        let d = colorDistance(colors[i], palette[j])
                                        if d < bestDistance {
                                            bestDistance = d
                                            best = j
                                        }
                                    }
                                    let w = Double(weights[i])
                                    let c = colors[i]
                                    sums[base + best] += SIMD3(Double(c.x), Double(c.y), Double(c.z)) * w
                                    totals[base + best] += w
                                }
                            }
                        }
                    }
                }
            }
        }
        var next = palette
        for j in 0..<k {
            var sum = SIMD3<Double>.zero
            var total = 0.0
            for chunk in 0..<chunks {
                sum += sums[chunk * k + j]
                total += totals[chunk * k + j]
            }
            if total > 0 {
                let mean = sum / total
                next[j] = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
            }
        }
        return next
    }
}

/* Exact nearest-color search without a per-color memo, safe to share
   across threads. Color space is cut into cubes (`bits` per channel); each
   cube lists only the palette entries that can be nearest to some point in
   it — those whose closest possible distance to the cube is no larger than
   the best entry's farthest. A lookup scans that short list. */
struct PaletteLookup: @unchecked Sendable {
    let colors: [SIMD3<Float>]
    private let shift: Int
    private let bits: Int
    private let offsets: [Int32]
    private let candidates: [UInt8]

    init(colors: [SIMD3<Float>], bits: Int) {
        precondition(!colors.isEmpty && colors.count <= 256)
        self.colors = colors
        self.bits = bits
        shift = 8 - bits
        let side = 1 << bits
        let cellCount = side * side * side
        let step = Float(1 << (8 - bits))
        let chunkSize = 256
        let chunks = (cellCount + chunkSize - 1) / chunkSize
        var lists = [[UInt8]](repeating: [], count: chunks)
        colors.withUnsafeBufferPointer { palette in
            lists.withUnsafeMutableBufferPointer { lists in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    var out: [UInt8] = []
                    var counts: [UInt8] = []
                    var minDistances = [Float](repeating: 0, count: palette.count)
                    for cell in (chunk * chunkSize)..<min(cellCount, (chunk + 1) * chunkSize) {
                        let lower = SIMD3<Float>(
                            Float(cell >> (2 * bits)), Float((cell >> bits) & (side - 1)), Float(cell & (side - 1))) * step
                        let upper = lower + step
                        var bestFarthest = Float.greatestFiniteMagnitude
                        for j in 0..<palette.count {
                            let p = palette[j]
                            let below = lower - p
                            let above = p - upper
                            let gap = simd_max(simd_max(below, above), .zero)
                            minDistances[j] = (gap * gap * channelWeights).sum()
                            let far = simd_max(abs(p - lower), abs(p - upper))
                            bestFarthest = min(bestFarthest, (far * far * channelWeights).sum())
                        }
                        var count = 0
                        for j in 0..<palette.count where minDistances[j] <= bestFarthest {
                            out.append(UInt8(j))
                            count += 1
                        }
                        // Stored as count - 1: a cell always has at least one.
                        counts.append(UInt8(count - 1))
                    }
                    lists[chunk] = counts + out
                }
            }
        }
        var offsets = [Int32](repeating: 0, count: cellCount + 1)
        var candidates: [UInt8] = []
        var cell = 0
        for (chunk, list) in lists.enumerated() {
            let cellsInChunk = min(cellCount, (chunk + 1) * chunkSize) - chunk * chunkSize
            var cursor = cellsInChunk
            for local in 0..<cellsInChunk {
                let count = Int(list[local]) + 1
                offsets[cell] = Int32(candidates.count)
                candidates.append(contentsOf: list[cursor..<(cursor + count)])
                cursor += count
                cell += 1
            }
        }
        offsets[cellCount] = Int32(candidates.count)
        self.offsets = offsets
        self.candidates = candidates
    }

    @inline(__always)
    func nearest(_ color: SIMD3<Float>) -> Int {
        let c = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 255))
        let r = Int(c.x) >> shift
        let g = Int(c.y) >> shift
        let b = Int(c.z) >> shift
        let cell = (r << (2 * bits)) | (g << bits) | b
        return offsets.withUnsafeBufferPointer { offsets in
            candidates.withUnsafeBufferPointer { candidates in
                colors.withUnsafeBufferPointer { colors in
                    let start = Int(offsets[cell])
                    let end = Int(offsets[cell + 1])
                    var best = Int(candidates[start])
                    var bestDistance = colorDistance(c, colors[best])
                    var i = start + 1
                    while i < end {
                        let j = Int(candidates[i])
                        let d = colorDistance(c, colors[j])
                        if d < bestDistance {
                            bestDistance = d
                            best = j
                        }
                        i += 1
                    }
                    return best
                }
            }
        }
    }
}
