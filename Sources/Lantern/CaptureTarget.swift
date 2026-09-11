import AppKit
import ScreenCaptureKit

/* What gets captured: a display, one window, or a display-local area (in
   points, top-left origin — ScreenCaptureKit's space, see CaptureGeometry). */
enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(display: SCDisplay, rect: CGRect)

    var display: SCDisplay? {
        switch self {
        case .display(let display), .area(let display, _): display
        case .window: nil
        }
    }

    /// Size in points of what will be captured.
    var pointSize: CGSize {
        switch self {
        case .display(let display): display.frame.size
        case .window(let window): window.frame.size
        case .area(_, let rect): rect.size
        }
    }
}

enum CapturePurpose {
    case still, video
}

/* One SCShareableContent fetch (100–300 ms) when the toolbar opens; the
   overlay hit-tests against these lists, never re-fetching per click. */
struct ShareableSnapshot {
    let displays: [SCDisplay]
    /// On-screen, layer-0, non-Lantern windows, front to back.
    let windows: [SCWindow]
    let selfApp: SCRunningApplication?

    static func fetch() async throws -> ShareableSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        /* SCShareableContent's window order isn't documented as z-order;
           the window server's list is front to back. Use it to rank the
           windows (and to skip fully transparent ones, which would catch
           the pointer while showing nothing). */
        var rank: [CGWindowID: Int] = [:]
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for (index, entry) in info.enumerated() {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }
            rank[id] = index
        }
        let windows = content.windows.filter { window in
            window.windowLayer == 0 && window.isOnScreen
                && window.frame.width >= 1 && window.frame.height >= 1
                && window.owningApplication?.processID != pid
                && rank[window.windowID] != nil
        }.sorted { rank[$0.windowID]! < rank[$1.windowID]! }
        return ShareableSnapshot(
            displays: content.displays,
            windows: windows,
            selfApp: content.applications.first { $0.processID == pid })
    }

    /* The app list only contains apps that had windows when the snapshot
       was taken. The picker's snapshot is fetched before Lantern shows any
       window, so `selfApp` is nil there; a recording refreshes it once the
       recording frame is up, or the frame would be recorded. */
    func refreshingSelfApp() async -> ShareableSnapshot {
        guard selfApp == nil,
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return self }
        let pid = ProcessInfo.processInfo.processIdentifier
        return ShareableSnapshot(
            displays: displays, windows: windows,
            selfApp: content.applications.first { $0.processID == pid })
    }

    func display(for id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }

    func display(for screen: NSScreen) -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return display(for: number.uint32Value)
    }

    /// The frontmost window under a CoreGraphics global point.
    func window(under point: CGPoint) -> SCWindow? {
        windows.first { $0.frame.contains(point) }
    }
}

/* Maps a target to the filter + configuration both the screenshot and the
   recording paths use. Lantern's own windows (overlay, toolbar, recording
   frame) are excluded by application, so nothing has to be hidden before a
   capture and windows created later stay excluded too. */
enum StreamConfigurationBuilder {
    struct Result {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        /// Output size in pixels.
        let pixelSize: CGSize
        let scale: CGFloat
    }

    static func make(
        for target: CaptureTarget, snapshot: ShareableSnapshot, purpose: CapturePurpose,
        showsCursor: Bool
    ) -> Result {
        let excluded = snapshot.selfApp.map { [$0] } ?? []
        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let display):
            filter = SCContentFilter(
                display: display, excludingApplications: excluded, exceptingWindows: [])
        case .area(let display, let rect):
            filter = SCContentFilter(
                display: display, excludingApplications: excluded, exceptingWindows: [])
            sourceRect = rect
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        /* SCK's own notion of the backing scale, not NSScreen's. */
        let scale = CGFloat(filter.pointPixelScale)
        let points = sourceRect?.size ?? target.pointSize
        let sized = CaptureGeometry.pixelSize(
            points: points, scale: scale, evenForVideo: purpose == .video)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(sized.pixels.width)
        configuration.height = Int(sized.pixels.height)
        if let sourceRect {
            /* Shaved to the even pixel size so the sampling stays 1:1. */
            configuration.sourceRect = CGRect(origin: sourceRect.origin, size: sized.points)
        }
        configuration.showsCursor = showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.presenterOverlayPrivacyAlertSetting = .never
        switch purpose {
        case .still:
            configuration.shouldBeOpaque = false
        case .video:
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            /* H.264 has no alpha: transparent window corners become white
               rather than black. */
            configuration.shouldBeOpaque = true
        }
        return Result(filter: filter, configuration: configuration, pixelSize: sized.pixels, scale: scale)
    }
}
