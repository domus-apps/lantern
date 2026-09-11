import Foundation

/* Rough output sizes for the editor's label. Constants are ballpark
   figures for screen content (flat colors, text); they only need to be
   monotonic and in the right order of magnitude. */
enum SizeEstimator {
    static func bytes(format: ExportFormat, pixelSize: CGSize, fps: Int, duration: Double) -> Int {
        let pixels = Double(pixelSize.width * pixelSize.height)
        switch format {
        case .png:
            return Int(pixels * 1.2)
        case .mp4:
            /* ≈0.08 bit per pixel per frame at a screen-recording quality. */
            return Int(pixels * Double(fps) * duration * 0.08 / 8)
        case .gif:
            /* ≈0.35 byte per pixel per frame, LZW on 256 colors. */
            return Int(pixels * Double(fps) * duration * 0.35)
        }
    }

    /// Memory ImageIO holds while assembling a GIF: every added frame stays
    /// resident until finalize, at output size, 4 bytes per pixel.
    static func gifWorkingSetBytes(pixelSize: CGSize, fps: Int, duration: Double) -> Int {
        Int(Double(pixelSize.width * pixelSize.height) * 4 * Double(fps) * duration)
    }
}
