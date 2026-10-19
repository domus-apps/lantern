import Foundation
import Testing

@testable import Lantern

@Test func percentScalingKeepsAspect() {
    let source = CGSize(width: 2880, height: 1802)
    #expect(OutputGeometry.scaled(source, percent: 50) == CGSize(width: 1440, height: 901))
    #expect(OutputGeometry.scaled(source, percent: 25) == CGSize(width: 720, height: 451))
    #expect(OutputGeometry.scaled(CGSize(width: 3, height: 3), percent: 25) == CGSize(width: 1, height: 1))
}

@Test func widthFittingKeepsAspect() {
    let source = CGSize(width: 1600, height: 1000)
    #expect(OutputGeometry.size(fittingWidth: 800, of: source) == CGSize(width: 800, height: 500))
    #expect(OutputGeometry.size(fittingWidth: 801, of: source) == CGSize(width: 801, height: 501))
    // Never enlarged.
    #expect(OutputGeometry.size(fittingWidth: 100_000, of: source) == source)
}
