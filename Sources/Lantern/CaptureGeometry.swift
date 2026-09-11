import Foundation

/* Coordinate and size math for captures, kept free of AppKit and
   ScreenCaptureKit so it can be unit-tested. Two spaces are involved:
   AppKit's (global, origin at the bottom-left of the primary screen, y up)
   and ScreenCaptureKit's display-local space (origin at the display's
   top-left, y down, in points). */
enum CaptureGeometry {
    /// An AppKit global rect → the display-local, top-left-origin rect
    /// ScreenCaptureKit expects, given that display's AppKit frame.
    static func displayLocalRect(fromAppKit rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// An AppKit global point → CoreGraphics global (top-left origin) point.
    static func cgPoint(fromAppKit point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// A CoreGraphics global rect (window frames from the window server)
    /// → AppKit global.
    static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// Output size in pixels for a region of `points` at `scale`. Video
    /// (H.264, 4:2:0 chroma) needs even dimensions; the region is shaved to
    /// the largest even size so sampling stays 1:1 instead of resampling.
    /// Stills keep the exact size.
    static func pixelSize(points: CGSize, scale: CGFloat, evenForVideo: Bool)
        -> (pixels: CGSize, points: CGSize)
    {
        var width = (points.width * scale).rounded()
        var height = (points.height * scale).rounded()
        if evenForVideo {
            width = CGFloat(evenDown(Int(width)))
            height = CGFloat(evenDown(Int(height)))
        }
        width = max(width, evenForVideo ? 2 : 1)
        height = max(height, evenForVideo ? 2 : 1)
        return (
            CGSize(width: width, height: height),
            CGSize(width: width / scale, height: height / scale)
        )
    }

    /// A pixel size scaled by a percentage; even for video.
    static func scaled(_ size: CGSize, percent: Int, even: Bool) -> CGSize {
        let factor = CGFloat(max(percent, 1)) / 100
        return fit(CGSize(width: size.width * factor, height: size.height * factor), even: even)
    }

    /// A pixel size resized to `width`, keeping the aspect ratio; even for video.
    static func size(fittingWidth width: Int, of source: CGSize, even: Bool) -> CGSize {
        guard source.width > 0 else { return source }
        let factor = CGFloat(max(width, 1)) / source.width
        return fit(CGSize(width: CGFloat(width), height: source.height * factor), even: even)
    }

    private static func fit(_ size: CGSize, even: Bool) -> CGSize {
        var width = Int(size.width.rounded())
        var height = Int(size.height.rounded())
        if even {
            width = evenDown(width)
            height = evenDown(height)
        }
        return CGSize(width: max(width, even ? 2 : 1), height: max(height, even ? 2 : 1))
    }

    static func evenDown(_ value: Int) -> Int {
        value - (value % 2)
    }
}
