import Foundation
import Testing

@testable import Lantern

@Test func gifIsNamedAfterItsVideo() {
    #expect(OutputNaming.fileName(base: "Screen Recording 2026-10-10 at 9.41.12", ext: "gif")
        == "Screen Recording 2026-10-10 at 9.41.12.gif")
}

@Test func collisionsGetACounterSuffix() {
    let taken: Set<String> = ["Demo.gif", "Demo (2).gif"]
    #expect(OutputNaming.fileName(base: "Demo", ext: "gif") { taken.contains($0) } == "Demo (3).gif")
}

@Test func uniqueURLAvoidsExistingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = OutputNaming.uniqueURL(in: directory, base: "Demo", ext: "gif")
    try Data().write(to: first)
    let second = OutputNaming.uniqueURL(in: directory, base: "Demo", ext: "gif")
    #expect(second.lastPathComponent == "Demo (2).gif")
}
