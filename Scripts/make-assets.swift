#!/usr/bin/env swift
// Generates the app icon (Assets/AppIcon.iconset/*.png + icon-1024.png) and
// the README banner (Assets/banner.png) programmatically, so the artwork is
// reproducible from source. Run: swift Scripts/make-assets.swift
// Then:  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
//
// Styled after macOS Tahoe's Liquid Glass icon language, sibling to the other
// Domus icons: the same continuous-curvature squircle, frosted-glass glyph
// (real gaussian-blurred backdrop via CoreImage), specular rim highlights,
// and soft layered shadows — here a glass lantern, lit from within, on a
// signal-red gradient: the light that shows what is on the screen.

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

func radialBlob(_ cg: CGContext, center: CGPoint, radius: CGFloat, color c: CGColor) {
    let grad = CGGradient(colorsSpace: rgb, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve) — not a superellipse, whose sides
/// bulge. Radius fitted against the system's live icon mask (measured from
/// Calculator/Notes/Finder at 1024px: 214.5px on the 824px shape, ~0.16px RMS).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

/* The key color, signal red (#FF5252 on the website), as a gradient with
   both stops saturated (S≈70–85%, like the siblings) and a modest lightness
   drop (ΔL≈18) — the family rule. A paler top stop reads as salmon. */
let keyTop: UInt32 = 0xFF5252
let keyBottom: UInt32 = 0xD41F2B
let shadowTint: UInt32 = 0x4A0B10

/// Background layer: squircle, red gradient, top sheen, outer shadow.
func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(keyBottom))
    cg.fillPath()
    cg.restoreGState()

    linearGradient(
        cg, in: shape,
        colors: [color(keyTop), color(keyBottom)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.minY)
    )
    // Barely-there top light for depth
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 320)
    )
}

/// Specular rim: a stroke around `path` that is bright on top, fading below.
func glassRim(_ cg: CGContext, around path: CGPath, width: CGFloat, bounds: CGRect, top: CGFloat, bottom: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: stroked,
        colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
}

/// One frosted-glass shape: blurred backdrop, milky tint, specular rim.
func drawGlassShape(
    _ cg: CGContext, path: CGPath, bounds: CGRect, backdrop: CGImage,
    tintTop: CGFloat, tintBottom: CGFloat,
    rimWidth: CGFloat, rimTop: CGFloat, rimBottom: CGFloat,
    shadowBlur: CGFloat, shadowAlpha: CGFloat
) {
    // Drop shadow (opaque fill, replaced by the glass interior right after)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.4), blur: shadowBlur, color: color(shadowTint, shadowAlpha))
    cg.addPath(path)
    cg.setFillColor(color(0xFFD9D9))
    cg.fillPath()
    cg.restoreGState()

    // Blurred backdrop + milky tint
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(backdrop, in: designRect)
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF, tintTop), color(0xFFFFFF, tintBottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
    cg.restoreGState()

    glassRim(cg, around: path, width: rimWidth, bounds: bounds, top: rimTop, bottom: rimBottom)
}

// The glyph: a lantern. Frosted-glass cage, cap, foot, and a ring handle,
// with a solid flame inside — the one solid element, so the light reads at
// every size the way Louver's slider knobs do.
/* Optical centering: the glyph's outline (foot to handle top) is taller
   above the middle than below, but its visual mass is the cage. Shifting
   everything down 12pt splits the difference between the outline's center
   and the cage's. */
let glyphDY: CGFloat = -12
let cageRect = CGRect(x: 352, y: 292 + glyphDY, width: 320, height: 372)
let capRect = CGRect(x: 396, y: 672 + glyphDY, width: 232, height: 66)
let footRect = CGRect(x: 416, y: 246 + glyphDY, width: 192, height: 40)
let handleCenter = CGPoint(x: 512, y: 748 + glyphDY)
let handleRadius: CGFloat = 64
let handleWidth: CGFloat = 30
let flameCenter = CGPoint(x: 512, y: 470 + glyphDY)
let flameSize = CGSize(width: 96, height: 150)

func cagePath() -> CGPath {
    CGPath(roundedRect: cageRect, cornerWidth: 58, cornerHeight: 58, transform: nil)
}

func capPath() -> CGPath {
    CGPath(roundedRect: capRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
}

func footPath() -> CGPath {
    CGPath(roundedRect: footRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
}

/* The handle: the upper arc of a ring, sitting on the cap. */
func handlePath() -> CGPath {
    let arc = CGMutablePath()
    arc.addArc(
        center: handleCenter, radius: handleRadius,
        startAngle: .pi * 0.08, endAngle: .pi * 0.92, clockwise: false)
    return arc.copy(strokingWithWidth: handleWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func flamePath() -> CGPath {
    /* A teardrop: an ellipse whose top is pulled into a point. */
    let path = CGMutablePath()
    let w = flameSize.width, h = flameSize.height
    let c = flameCenter
    path.move(to: CGPoint(x: c.x, y: c.y + h / 2))
    path.addCurve(
        to: CGPoint(x: c.x, y: c.y - h / 2),
        control1: CGPoint(x: c.x + w * 0.95, y: c.y + h * 0.05),
        control2: CGPoint(x: c.x + w * 0.62, y: c.y - h / 2))
    path.addCurve(
        to: CGPoint(x: c.x, y: c.y + h / 2),
        control1: CGPoint(x: c.x - w * 0.62, y: c.y - h / 2),
        control2: CGPoint(x: c.x - w * 0.95, y: c.y + h * 0.05))
    path.closeSubpath()
    return path
}

/* The glow behind the cage: what makes the frosted body read as lit. */
func drawGlow(_ cg: CGContext) {
    radialBlob(cg, center: CGPoint(x: 512, y: 468 + glyphDY), radius: 230, color: color(0xFFE3B0, 0.95))
}

func drawFlame(_ cg: CGContext) {
    let path = flamePath()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(shadowTint, 0.35))
    cg.addPath(path)
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF), color(0xFFF0D2)],
        from: CGPoint(x: 512, y: flameCenter.y + flameSize.height / 2),
        to: CGPoint(x: 512, y: flameCenter.y - flameSize.height / 2)
    )
}

func drawLantern(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    let tintTop: CGFloat = boost ? 0.82 : 0.7
    let tintBottom: CGFloat = boost ? 0.7 : 0.52
    for path in [footPath(), handlePath(), capPath(), cagePath()] {
        drawGlassShape(
            cg, path: path, bounds: path.boundingBox, backdrop: backdrop,
            tintTop: tintTop, tintBottom: tintBottom,
            rimWidth: 5, rimTop: 0.9, rimBottom: 0.24,
            shadowBlur: 34, shadowAlpha: 0.3
        )
    }
    drawFlame(cg)
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    let blurRadius = max(36 * scale, 1)
    // Small sizes: more opaque glass keeps the glyph legible in the menu bar /
    // Dock, where the frosted subtlety would just vanish.
    let boost = px <= 64

    let shape = squircle(in: bgRect)

    /* Clip the glyph to the squircle, and at small sizes optically enlarge
       it (like Apple's small-size icon variants) so it stays prominent. */
    func drawGlyph(_ cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.14, y: 1.14)
            cg.translateBy(x: -512, y: -512)
        }
        body(cg)
        cg.restoreGState()
    }

    // Scene 1: the background (with the glow) the glass will frost over.
    let bgRep = makeBitmap(px, px)
    withContext(bgRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
        drawGlyph(cg) { drawGlow($0) }
    }
    let backdrop = gaussianBlur(bgRep.cgImage!, radius: blurRadius)

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(bgRep.cgImage!, in: designRect)
        drawGlyph(cg) { drawLantern($0, backdrop: backdrop, boost: boost) }
    }
    return rep
}

// MARK: - Icon Composer layers (macOS 26+ .icon document)

/* The .icon format gets dark/clear/tinted appearances for free: we ship flat
   transparent layers plus a background fill, and the system renders the
   Liquid Glass treatment (and the dark background) at runtime. In a .icon
   document the 1024pt canvas IS the icon shape — the system adds its own
   margins — whereas our design space puts the squircle at 100..924, so the
   glyph is remapped to land at the same visual position. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

func drawFlatLantern(_ cg: CGContext) {
    /* Cage slightly translucent, flame solid — the same two-tone reading
       the rendered icon has, flattened for Icon Composer. */
    cg.setFillColor(color(0xFFFFFF, 0.78))
    for path in [footPath(), handlePath(), capPath(), cagePath()] {
        cg.addPath(path)
    }
    cg.fillPath()
    cg.setFillColor(color(0xFFFFFF))
    cg.addPath(flamePath())
    cg.fillPath()
}

// MARK: - Shared banner elements

/// A faint four-point twinkle, the same quiet sky the sibling banners share.
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = CGPoint(x: center.x, y: center.y + radius)
    let e = CGPoint(x: center.x + radius, y: center.y)
    let s = CGPoint(x: center.x, y: center.y - radius)
    let w = CGPoint(x: center.x - radius, y: center.y)
    path.move(to: n)
    path.addQuadCurve(to: e, control: center)
    path.addQuadCurve(to: s, control: center)
    path.addQuadCurve(to: w, control: center)
    path.addQuadCurve(to: n, control: center)
    path.closeSubpath()
    return path
}

func drawSparkles(_ cg: CGContext, _ sparkles: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)]) {
    for s in sparkles {
        cg.addPath(sparklePath(center: CGPoint(x: s.x, y: s.y), radius: s.r))
        cg.setFillColor(color(0xFFFFFF, s.a))
        cg.fillPath()
    }
}

let pillLabelColor = NSColor(srgbRed: 0.99, green: 0.88, blue: 0.88, alpha: 1)
let taglineColor = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.80, alpha: 1)
let tagline = "Screenshots, recordings, and GIFs"

func pillText(_ label: String, fontSize: CGFloat) -> NSAttributedString {
    NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: pillLabelColor,
    ])
}

func pillWidth(label: String, fontSize: CGFloat, pad: CGFloat) -> CGFloat {
    pad + pillText(label, fontSize: fontSize).size().width + pad
}

/// One text pill; returns its maxX. Width is computed, never measured by
/// drawing — a nested bitmap context would clear NSGraphicsContext.current
/// mid-render and silently drop every text draw after it.
@discardableResult
func drawPill(
    _ cg: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, label: String,
    fontSize: CGFloat, pad: CGFloat
) -> CGFloat {
    let text = pillText(label, fontSize: fontSize)
    let pill = CGRect(
        x: x, y: y, width: pillWidth(label: label, fontSize: fontSize, pad: pad), height: height)

    cg.addPath(CGPath(roundedRect: pill, cornerWidth: height / 4, cornerHeight: height / 4, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.07))
    cg.fillPath()
    cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerWidth: height / 4 - 1, cornerHeight: height / 4 - 1, transform: nil))
    cg.setStrokeColor(color(0xFFFFFF, 0.14))
    cg.setLineWidth(2.5)
    cg.strokePath()

    text.draw(at: NSPoint(
        x: pill.minX + pad, y: pill.minY + (pill.height - text.size().height) / 2))
    return pill.maxX
}

let pillLabels = ["Image or video", "Any size, any frame rate", "MP4 or GIF"]

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    /* The family rule: each banner is a deep tint of the app's own key
       color (Coffer 122E24, Jamb 0E2C2E, Keystone 30130A, Louver 1C300E) —
       here Lantern's red, darkened. */
    linearGradient(
        cg, in: frame,
        colors: [color(0x3A0F12), color(0x1E0709)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // A faint night sky on the right
    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    drawSparkles(cg, [
        (1420, 470, 26, 0.07), (1580, 320, 40, 0.06), (1710, 480, 18, 0.06),
        (1500, 130, 22, 0.05), (1680, 190, 30, 0.07), (1350, 250, 14, 0.05),
    ])
    cg.restoreGState()

    // App icon on the left
    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    // Wordmark + tagline
    let title = NSAttributedString(string: "Lantern", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 300))

    let taglineText = NSAttributedString(string: tagline, attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: taglineColor,
    ])
    taglineText.draw(at: NSPoint(x: 528, y: 218))

    var x: CGFloat = 528
    for label in pillLabels {
        x = drawPill(cg, x: x, y: 108, height: 72, label: label, fontSize: 36, pad: 28) + 22
    }
}

// MARK: - GitHub social preview (1280 x 640 design space, rendered @2x)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    // Full bleed — GitHub renders the preview edge to edge and rounds the
    // corners itself, so transparent corners would show through as white.
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(0x4A1216), color(0x1E0709)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint night sky drifting off the corners
    drawSparkles(cg, [
        (90, 560, 26, 0.06), (230, 620, 16, 0.05), (170, 480, 12, 0.05),
        (1160, 120, 30, 0.06), (1060, 40, 18, 0.05), (1230, 260, 14, 0.05),
    ])

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    // Centered stack: icon, wordmark, tagline, feature pills — sized up so
    // the card stays legible at the small sizes link previews render at.
    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 355, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Lantern", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 238)

    drawCentered(
        NSAttributedString(string: tagline, attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: taglineColor,
        ]), y: 176)

    let gap: CGFloat = 16
    let widths = pillLabels.map { pillWidth(label: $0, fontSize: 30, pad: 24) }
    var x = canvas.midX - (widths.reduce(0, +) + gap * CGFloat(pillLabels.count - 1)) / 2
    for (label, width) in zip(pillLabels, widths) {
        drawPill(cg, x: x, y: 82, height: 62, label: label, fontSize: 30, pad: 24)
        x += width + gap
    }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.iconset", withIntermediateDirectories: true)

// Iconset: render each size directly from vectors (crisper than downscaling)
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconSizes {
    savePNG(makeIcon(px: px), "Assets/AppIcon.iconset/\(name).png")
}

let master = makeIcon(px: 1024)
savePNG(master, "Assets/icon-1024.png")

// Icon Composer layer for the macOS 26+ .icon document (front only — the
// fill gradient in icon.json is the whole background)
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
savePNG(makeIconLayer(drawFlatLantern), "Assets/AppIcon.icon/Assets/front.png")

let bannerIcon = makeIcon(px: 728).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

// GitHub social preview: exactly 1280x640, GitHub's recommended size.
let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")
