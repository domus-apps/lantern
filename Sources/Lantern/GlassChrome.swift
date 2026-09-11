import AppKit

/* The pieces around a Liquid Glass panel whose window-server shadow is off
   (it gets snapshotted at unpredictable times and shows up square behind a
   rounded card): an in-window shadow with an explicit rounded path, and a
   two-ring hairline rim. Both from Coffer's history panel. */

final class MenuShadowView: NSView {
    private let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        if let layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: -8)
        }
        updateShadowPath()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil)
        CATransaction.commit()
    }
}

final class HairlineBorderView: NSView {
    private let outerRing = CALayer()
    private let innerRing = CALayer()

    init(frame: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true

        outerRing.frame = bounds
        outerRing.cornerRadius = cornerRadius
        outerRing.borderWidth = 0.5

        innerRing.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        innerRing.cornerRadius = cornerRadius - 0.5
        innerRing.borderWidth = 1

        for ring in [outerRing, innerRing] {
            ring.cornerCurve = .continuous
            layer?.addSublayer(ring)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerRing.frame = bounds
        innerRing.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        outerRing.borderColor =
            NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.15).cgColor
        innerRing.borderColor =
            NSColor.white.withAlphaComponent(isDark ? 0.25 : 0.5).cgColor
    }

    /* Purely decorative: never swallow clicks meant for the controls. */
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/* Window levels for the capture UI. Above every app window, the menu bar
   (24) and the Dock (20), but just below the pop-up menu level (101): that
   is where tooltips and the Options menu are drawn, and at the shielding
   level they ended up hidden behind the overlay. */
enum CaptureLevels {
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 2)
    static let toolbar = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
}

extension NSImage {
    /// A symbol drawn in the dynamic label color, for controls that draw
    /// their images themselves (template tinting only happens inside
    /// NSButton and friends).
    static func labelTinted(_ symbolName: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor])))
    }

    /// A symbol with a small red recording dot at its bottom-right, for the
    /// toolbar's video row (only one badged variant ships as a symbol).
    static func recordBadged(_ symbolName: String, pointSize: CGFloat) -> NSImage? {
        /* Palette-colored with the dynamic label color: the drawing handler
           below runs per appearance, so the glyph follows light and dark. */
        guard
            let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor])))
        else { return nil }
        /* Same canvas as the bare symbol, so the glyph stays centered in its
           segment; the dot overlaps the glyph's bottom-right corner the way
           system badges do. */
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 7, y: 0, width: 7, height: 7)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        /* Not a template: the red dot must keep its color. */
        image.isTemplate = false
        return image
    }
}
