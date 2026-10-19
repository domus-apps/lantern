import Foundation

/* LSB-first bit packing, the order GIF's LZW codes are stored in. Writers
   for separate bands are joined bit by bit, since a band rarely ends on a
   byte boundary. */
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var pending = 0

    @inline(__always)
    mutating func write(_ code: Int, width: Int) {
        accumulator |= UInt64(code) << UInt64(pending)
        pending += width
        while pending >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            pending -= 8
        }
    }

    mutating func append(_ other: BitWriter) {
        bytes.reserveCapacity(bytes.count + other.bytes.count + 1)
        for byte in other.bytes {
            write(Int(byte), width: 8)
        }
        if other.pending > 0 {
            write(Int(other.accumulator & ((1 << UInt64(other.pending)) - 1)), width: other.pending)
        }
    }

    /// The packed bytes, the last one padded with zero bits.
    func finished() -> [UInt8] {
        pending > 0 ? bytes + [UInt8(truncatingIfNeeded: accumulator)] : bytes
    }
}

/* What a band of pixels needs for lossy matching: each pixel's exact symbol
   (from quantization), what the canvas shows there now (for the transparent
   symbol), and the palette. */
struct LZWBand {
    /// Exact symbols in, chosen symbols out.
    let symbols: UnsafeMutablePointer<UInt8>
    let count: Int
    /// Width of the frame rectangle the band's rows belong to.
    let rowWidth: Int
    /// Canvas index of the band's first pixel, and the canvas row stride.
    let firstPixel: Int
    let canvasWidth: Int
    /// RGB, 3 bytes per canvas pixel.
    let shown: UnsafePointer<UInt8>
    let palette: UnsafePointer<SIMD3<Float>>
    let transparent: UInt8
    let lossiness: Float
    let isFirst: Bool
    let isLast: Bool
}

/* GIF's variable-width LZW with 8-bit symbols, after the classic compress
   encoder: codes widen once the table passes the current maximum, and a
   full table (4096 entries) emits a clear code and starts over.

   Lossy matching. When the next pixel's exact symbol doesn't extend the
   current string, any existing extension whose symbol would look close
   enough at that pixel is taken instead, so strings grow longer and fewer
   codes are written. "Close enough" is judged by what the viewer sees:
   the transparent symbol shows the canvas, so it can stand in for a color
   that is already there, and a color can stand in for "unchanged" only if
   it is exactly what the canvas shows (static areas never shimmer). With
   lossiness 0 only such exact equivalents are taken, so the picture is the
   same as with plain LZW.

   Bands are encoded independently (on separate cores) and joined: every
   band but the last ends with a clear code, so the next band starts from an
   empty table at 9 bits, exactly as a decoder expects after a clear. */
enum LZW {
    static let clearCode = 256
    static let endCode = 257

    static func encode(_ band: LZWBand) -> BitWriter {
        var writer = BitWriter()
        writer.bytesReserve(band.count / 2)
        var bits = 9
        var maxCode = (1 << bits) - 1
        var nextCode = 258
        var clearFlag = false

        let tables = LZWTables.take()
        defer { LZWTables.give(tables) }

        @inline(__always)
        func emit(_ code: Int) {
            writer.write(code, width: bits)
            if clearFlag {
                bits = 9
                maxCode = (1 << bits) - 1
                clearFlag = false
            } else if nextCode > maxCode {
                bits += 1
                maxCode = bits == 12 ? 4096 : (1 << bits) - 1
            }
        }

        if band.isFirst { emit(clearCode) }
        guard band.count > 0 else {
            emit(band.isLast ? endCode : clearCode)
            return writer
        }

        let symbols = band.symbols
        let palette = band.palette
        let transparent = band.transparent
        let lossiness = band.lossiness

        @inline(__always)
        func shownColor(_ i: Int) -> SIMD3<Float> {
            let row = i / band.rowWidth
            let p = (band.firstPixel + row * band.canvasWidth + (i - row * band.rowWidth)) * 3
            return SIMD3(Float(band.shown[p]), Float(band.shown[p + 1]), Float(band.shown[p + 2]))
        }

        /// Whether `candidate` may stand in for `exact` at pixel `i`.
        @inline(__always)
        func acceptable(_ candidate: UInt8, for exact: UInt8, at i: Int) -> Bool {
            if exact == transparent {
                return candidate != transparent && palette[Int(candidate)] == shownColor(i)
            }
            let target = palette[Int(exact)]
            let seen = candidate == transparent ? shownColor(i) : palette[Int(candidate)]
            return colorDistance(seen, target) <= lossiness
        }

        tables.table.withUnsafeMutableBufferPointer { table in
            tables.firstChild.withUnsafeMutableBufferPointer { firstChild in
                tables.nextSibling.withUnsafeMutableBufferPointer { nextSibling in
                    tables.symbolOf.withUnsafeMutableBufferPointer { symbolOf in
                        var prefix = Int(symbols[0])
                        for i in 1..<band.count {
                            let exact = symbols[i]
                            let child = Int(table[prefix << 8 | Int(exact)])
                            if child != 0 {
                                prefix = child
                                continue
                            }
                            var sibling = Int(firstChild[prefix])
                            var substitute = -1
                            while sibling >= 0 {
                                if acceptable(symbolOf[sibling], for: exact, at: i) {
                                    substitute = sibling
                                    break
                                }
                                sibling = Int(nextSibling[sibling])
                            }
                            if substitute >= 0 {
                                symbols[i] = symbolOf[substitute]
                                prefix = substitute
                                continue
                            }
                            emit(prefix)
                            if nextCode < 4096 {
                                let key = prefix << 8 | Int(exact)
                                table[key] = UInt16(nextCode)
                                tables.used.append(key)
                                symbolOf[nextCode] = exact
                                nextSibling[nextCode] = firstChild[prefix]
                                firstChild[prefix] = Int16(nextCode)
                                nextCode += 1
                            } else {
                                for key in tables.used {
                                    table[key] = 0
                                    firstChild[key >> 8] = -1
                                }
                                tables.used.removeAll(keepingCapacity: true)
                                nextCode = 258
                                clearFlag = true
                                emit(clearCode)
                            }
                            prefix = Int(exact)
                        }
                        emit(prefix)
                    }
                }
            }
        }
        if band.isLast {
            emit(endCode)
        } else {
            clearFlag = true
            emit(clearCode)
        }
        return writer
    }
}

/* A code table set: exact child lookup, and per-code sibling lists for
   lossy matching. Kept between bands, since zeroing a fresh 2 MiB table for
   every band of every changed frame was avoidable work on the hot path.
   Bands encode in parallel, so each takes its own set from a small pool;
   a returned set is reset through `used`, which lists every entry set
   (sibling lists and symbols are written before they are read). */
final class LZWTables: @unchecked Sendable {
    var table = [UInt16](repeating: 0, count: 4096 * 256)
    var firstChild = [Int16](repeating: -1, count: 4096)
    var nextSibling = [Int16](repeating: -1, count: 4096)
    var symbolOf = [UInt8](repeating: 0, count: 4096)
    var used: [Int] = []

    private init() {
        used.reserveCapacity(4096)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pool: [LZWTables] = []

    static func take() -> LZWTables {
        lock.lock()
        defer { lock.unlock() }
        return pool.popLast() ?? LZWTables()
    }

    static func give(_ tables: LZWTables) {
        for key in tables.used {
            tables.table[key] = 0
            tables.firstChild[key >> 8] = -1
        }
        tables.used.removeAll(keepingCapacity: true)
        lock.lock()
        defer { lock.unlock() }
        if pool.count < 16 { pool.append(tables) }
    }
}

extension BitWriter {
    fileprivate mutating func bytesReserve(_ capacity: Int) {
        bytes.reserveCapacity(capacity)
    }
}
