import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedImage {
    let cgImage: CGImage
    /// Pixels per point at capture time (2 on Retina displays).
    let scale: CGFloat

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    var pointSize: CGSize { CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }
}

enum StillCapturer {
    static func capture(
        _ target: CaptureTarget, snapshot: ShareableSnapshot, showsCursor: Bool
    ) async throws -> CapturedImage {
        let built = StreamConfigurationBuilder.make(
            for: target, snapshot: snapshot, purpose: .still, showsCursor: showsCursor)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: built.filter, configuration: built.configuration)
        if case .window = target, let shadowed = WindowShadow.compose(image, scale: built.scale) {
            return CapturedImage(cgImage: shadowed, scale: built.scale)
        }
        return CapturedImage(cgImage: image, scale: built.scale)
    }
}

/* ScreenCaptureKit captures a lone window without its shadow (a display
   filter that includes only the window renders none either, measured), so
   the system look is composed here: the window on a transparent canvas with
   room around it, under a soft shadow in the proportions of macOS's own. */
enum WindowShadow {
    /// Transparent margin around the window, in points.
    static let margin: CGFloat = 64

    static func compose(_ window: CGImage, scale: CGFloat) -> CGImage? {
        let margin = Self.margin * scale
        let width = window.width + Int(margin * 2)
        let height = window.height + Int(margin * 2)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: margin, y: margin, width: CGFloat(window.width), height: CGFloat(window.height))
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18 * scale), blur: 36 * scale,
            color: CGColor(gray: 0, alpha: 0.5))
        context.draw(window, in: rect)
        context.restoreGState()
        return context.makeImage()
    }
}

/* PNG with DPI metadata: 144 at 2x, like the system's screenshots, so
   Preview and browsers show the image at its point size. */
enum PNGWriter {
    static func data(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard let data = data(image, scale: scale) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

/* Clipboard writes. The PNG goes on eagerly; the TIFF (which many apps ask
   for first, and which is ~60 MB for a 5K shot uncompressed) is provided
   lazily through the pasteboard owner protocol. */
final class ClipboardWriter: NSObject, NSPasteboardTypeOwner {
    private static var current: ClipboardWriter?
    private let image: CapturedImage

    private init(image: CapturedImage) {
        self.image = image
    }

    static func write(_ image: CapturedImage) {
        let writer = ClipboardWriter(image: image)
        current = writer
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: writer)
        if let png = PNGWriter.data(image.cgImage, scale: image.scale) {
            pasteboard.setData(png, forType: .png)
        }
    }

    static func write(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.pointSize
        if let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]) {
            sender.setData(tiff, forType: .tiff)
        }
    }
}
