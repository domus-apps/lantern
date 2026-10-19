import Foundation

/* GIF89a container pieces: header with a 256-entry global table and, for
   a looping GIF, the NETSCAPE loop-forever block, frames as sub-rectangles of the canvas with
   a transparent index and "leave in place" disposal, and the trailer. */
enum GIFStream {
    /// Without `loopsForever` the header has no loop block, and viewers play
    /// the animation once and stop on its last frame. (A loop count of 1
    /// would not do: browsers read it as one repeat, two plays.)
    static func header(width: Int, height: Int, palette: [SIMD3<Float>], loopsForever: Bool) -> Data {
        var data = Data()
        data.append(contentsOf: Array("GIF89a".utf8))
        appendShort(width, to: &data)
        appendShort(height, to: &data)
        data.append(0xF7)  // global table, 8-bit color resolution, 256 entries
        data.append(0)  // background index
        data.append(0)  // pixel aspect ratio
        appendTable(palette, to: &data)
        if loopsForever {
            data.append(contentsOf: [0x21, 0xFF, 0x0B])
            data.append(contentsOf: Array("NETSCAPE2.0".utf8))
            data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])  // loop count 0: forever
        }
        return data
    }

    static func frame(
        x: Int, y: Int, width: Int, height: Int, delayCentiseconds: Int, transparentIndex: UInt8,
        localPalette: [SIMD3<Float>]?, compressed: [UInt8]
    ) -> Data {
        var data = Data()
        data.reserveCapacity(compressed.count + compressed.count / 255 + 800)
        // Graphic control extension: disposal 1 (leave in place), transparency on.
        data.append(contentsOf: [0x21, 0xF9, 0x04, 1 << 2 | 1])
        appendShort(min(delayCentiseconds, 0xFFFF), to: &data)
        data.append(transparentIndex)
        data.append(0)
        // Image descriptor.
        data.append(0x2C)
        appendShort(x, to: &data)
        appendShort(y, to: &data)
        appendShort(width, to: &data)
        appendShort(height, to: &data)
        if let localPalette {
            data.append(0x87)  // local table, 256 entries
            appendTable(localPalette, to: &data)
        } else {
            data.append(0)
        }
        data.append(8)  // LZW minimum code size
        var offset = 0
        while offset < compressed.count {
            let length = min(255, compressed.count - offset)
            data.append(UInt8(length))
            data.append(contentsOf: compressed[offset..<(offset + length)])
            offset += length
        }
        data.append(0)
        return data
    }

    static let trailer = Data([0x3B])

    private static func appendTable(_ palette: [SIMD3<Float>], to data: inout Data) {
        for index in 0..<256 {
            let color = index < palette.count ? palette[index] : .zero
            data.append(contentsOf: [UInt8(color.x), UInt8(color.y), UInt8(color.z)])
        }
    }

    private static func appendShort(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}
