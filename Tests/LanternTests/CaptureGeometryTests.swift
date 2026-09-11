import Foundation
import Testing

@testable import Lantern

@Test func appKitRectFlipsIntoDisplayLocalTopLeftSpace() {
    // A 1000×800 display whose AppKit frame starts at (2000, 100).
    let screen = CGRect(x: 2000, y: 100, width: 1000, height: 800)
    let rect = CGRect(x: 2100, y: 200, width: 300, height: 100)  // AppKit, bottom-left origin
    let local = CaptureGeometry.displayLocalRect(fromAppKit: rect, screenFrame: screen)
    #expect(local == CGRect(x: 100, y: 600, width: 300, height: 100))
}

@Test func cgPointAndRectFlipAgainstThePrimaryScreen() {
    let point = CaptureGeometry.cgPoint(fromAppKit: CGPoint(x: 10, y: 20), primaryScreenHeight: 900)
    #expect(point == CGPoint(x: 10, y: 880))
    let rect = CaptureGeometry.appKitRect(
        fromCG: CGRect(x: 0, y: 100, width: 50, height: 50), primaryScreenHeight: 900)
    #expect(rect == CGRect(x: 0, y: 750, width: 50, height: 50))
}

@Test func stillPixelSizeIsExactAtAnyScale() {
    let sized = CaptureGeometry.pixelSize(points: CGSize(width: 333, height: 201), scale: 2, evenForVideo: false)
    #expect(sized.pixels == CGSize(width: 666, height: 402))
    let odd = CaptureGeometry.pixelSize(points: CGSize(width: 333, height: 201), scale: 1, evenForVideo: false)
    #expect(odd.pixels == CGSize(width: 333, height: 201))
}

@Test func videoPixelSizeRoundsDownToEvenAndShrinksTheRegion() {
    let sized = CaptureGeometry.pixelSize(points: CGSize(width: 333, height: 201), scale: 1, evenForVideo: true)
    #expect(sized.pixels == CGSize(width: 332, height: 200))
    #expect(sized.points == CGSize(width: 332, height: 200))
    // At 2x an odd point size is already even in pixels: nothing shaved.
    let retina = CaptureGeometry.pixelSize(points: CGSize(width: 333, height: 201), scale: 2, evenForVideo: true)
    #expect(retina.pixels == CGSize(width: 666, height: 402))
    #expect(retina.points == CGSize(width: 333, height: 201))
}

@Test func percentScalingKeepsAspectAndEvenness() {
    let source = CGSize(width: 2880, height: 1802)
    #expect(CaptureGeometry.scaled(source, percent: 50, even: true) == CGSize(width: 1440, height: 900))
    #expect(CaptureGeometry.scaled(source, percent: 25, even: false) == CGSize(width: 720, height: 451))
    #expect(CaptureGeometry.scaled(source, percent: 25, even: true) == CGSize(width: 720, height: 450))
}

@Test func widthFittingKeepsAspect() {
    let source = CGSize(width: 1600, height: 1000)
    #expect(CaptureGeometry.size(fittingWidth: 800, of: source, even: false) == CGSize(width: 800, height: 500))
    #expect(CaptureGeometry.size(fittingWidth: 801, of: source, even: true) == CGSize(width: 800, height: 500))
}
