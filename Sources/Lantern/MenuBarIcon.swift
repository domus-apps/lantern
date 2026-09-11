import AppKit

/* The menu bar glyph: the app icon's lantern, drawn as a template image so
   it takes the menu bar's tint and stays crisp at any scale. There is no
   lantern SF Symbol, and the closest one (a beacon) has asymmetric rays
   that never look centered in a 20pt item. Drawn in an 18×18 point space
   with the glyph symmetric about x = 9, so the button's own centering is
   all it needs. */
enum MenuBarIcon {
    static func lantern() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let cx: CGFloat = 9

            // Foot
            NSBezierPath(
                roundedRect: NSRect(x: cx - 4, y: 0.6, width: 8, height: 1.3), xRadius: 0.65, yRadius: 0.65
            ).fill()

            // Cage with the flame cut out of it
            let cage = NSBezierPath(
                roundedRect: NSRect(x: cx - 5, y: 2.3, width: 10, height: 9.4), xRadius: 2.4, yRadius: 2.4)
            let flame = NSBezierPath()
            let fw: CGFloat = 3.4, fh: CGFloat = 4.8
            let fc = NSPoint(x: cx, y: 7.1)
            flame.move(to: NSPoint(x: fc.x, y: fc.y + fh / 2))
            flame.curve(
                to: NSPoint(x: fc.x, y: fc.y - fh / 2),
                controlPoint1: NSPoint(x: fc.x + fw * 0.95, y: fc.y + fh * 0.05),
                controlPoint2: NSPoint(x: fc.x + fw * 0.62, y: fc.y - fh / 2))
            flame.curve(
                to: NSPoint(x: fc.x, y: fc.y + fh / 2),
                controlPoint1: NSPoint(x: fc.x - fw * 0.62, y: fc.y - fh / 2),
                controlPoint2: NSPoint(x: fc.x - fw * 0.95, y: fc.y + fh * 0.05))
            flame.close()
            cage.append(flame)
            cage.windingRule = .evenOdd
            cage.fill()

            // Cap
            NSBezierPath(
                roundedRect: NSRect(x: cx - 3.8, y: 12.2, width: 7.6, height: 1.5), xRadius: 0.7, yRadius: 0.7
            ).fill()

            // Handle: the upper arc of a ring on the cap
            let handle = NSBezierPath()
            handle.appendArc(
                withCenter: NSPoint(x: cx, y: 14.1), radius: 2.3, startAngle: 15, endAngle: 165)
            handle.lineWidth = 1.5
            handle.lineCapStyle = .round
            handle.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lantern"
        return image
    }

    /* The stop button shown while recording: a red disc with a white
       square, drawn in fixed colors rather than as a template, so it reads
       the same on a light or dark menu bar and over any wallpaper. */
    static func recording() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let disc = rect.insetBy(dx: 1, dy: 1)
            NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).setFill()
            NSBezierPath(ovalIn: disc).fill()
            let square = NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = L("Stop Recording")
        return image
    }
}
