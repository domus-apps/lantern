import Foundation
import Testing

@testable import Lantern

private let date = Date(timeIntervalSince1970: 1_789_004_492)  // 2026-09-10 10:41:32 KST
private let seoul = TimeZone(identifier: "Asia/Seoul")!

@Test func screenshotNameMatchesTheSystemStyle() {
    let name = OutputNaming.fileName(kind: .screenshot, date: date, ext: "png", timeZone: seoul)
    #expect(name == "\(L("Screenshot")) 2026-09-10 at 10.41.32.png")
}

@Test func recordingNameUsesTheRecordingPrefix() {
    let name = OutputNaming.fileName(kind: .recording, date: date, ext: "mp4", timeZone: seoul)
    #expect(name == "\(L("Screen Recording")) 2026-09-10 at 10.41.32.mp4")
}

@Test func collisionsGetACounterSuffix() {
    var taken: Set<String> = [
        "\(L("Screenshot")) 2026-09-10 at 10.41.32.png",
        "\(L("Screenshot")) 2026-09-10 at 10.41.32 (2).png",
    ]
    let name = OutputNaming.fileName(kind: .screenshot, date: date, ext: "png", timeZone: seoul) { taken.contains($0) }
    #expect(name == "\(L("Screenshot")) 2026-09-10 at 10.41.32 (3).png")
    taken.insert(name)
}

@Test func uniqueURLAvoidsExistingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = OutputNaming.uniqueURL(in: directory, kind: .screenshot, ext: "png", date: date)
    try Data().write(to: first)
    let second = OutputNaming.uniqueURL(in: directory, kind: .screenshot, ext: "png", date: date)
    #expect(second != first)
    #expect(second.lastPathComponent.contains("(2)"))
}
