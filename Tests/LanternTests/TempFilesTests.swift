import Foundation
import Testing

@testable import Lantern

@Test func sweepKeepsOnlyTheCopyOnTheClipboard() throws {
    // Under the temporary directory, which sits behind /var → /private/var.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanternSweep-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let encode = root.appendingPathComponent("Encode-1.gif")
    let old = root.appendingPathComponent("Copies/a/clip.gif")
    let pasted = root.appendingPathComponent("Copies/b/clip.gif")
    for file in [encode, old, pasted] {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
    }
    let clipboard = URL(fileURLWithPath: pasted.resolvingSymlinksInPath().path)
    TempFiles.sweep(root, keeping: [clipboard])
    #expect(!FileManager.default.fileExists(atPath: encode.path))
    #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: pasted.path))
    TempFiles.sweep(root, keeping: [])
    #expect(!FileManager.default.fileExists(atPath: pasted.deletingLastPathComponent().path))
}
