import Foundation

/* Output size math, kept free of AppKit so it can be unit-tested. GIF has
   no chroma subsampling, so sizes need not be even. */
enum OutputGeometry {
    /// A pixel size scaled by a percentage.
    static func scaled(_ size: CGSize, percent: Int) -> CGSize {
        let factor = CGFloat(max(percent, 1)) / 100
        return fit(CGSize(width: size.width * factor, height: size.height * factor))
    }

    /* A pixel size resized to `width`, keeping the aspect ratio, and never
       wider than the source: a GIF gains nothing from enlarging, and a
       typed 100000 would ask the encoder for more than GIF's 65535. */
    static func size(fittingWidth width: Int, of source: CGSize) -> CGSize {
        guard source.width > 0 else { return source }
        let width = min(max(width, 1), Int(source.width.rounded()))
        let factor = CGFloat(width) / source.width
        return fit(CGSize(width: CGFloat(width), height: source.height * factor))
    }

    private static func fit(_ size: CGSize) -> CGSize {
        CGSize(width: max(Int(size.width.rounded()), 1), height: max(Int(size.height.rounded()), 1))
    }
}
