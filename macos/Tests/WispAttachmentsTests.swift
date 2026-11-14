//
//  WispAttachmentsTests.swift
//  GhosttyTests
//
//  Tests for turning pasted and dropped images into paths agent CLIs can attach.
//

import Testing
import AppKit
@testable import Ghostty

struct WispAttachmentsTests {
    // MARK: - Test Helpers

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// A tiny real image, encoded as `type`.
    private func imageData(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: type, properties: [:]) ?? Data()
    }

    /// Writes a file where the floating screenshot thumbnail keeps its short-lived copy.
    private func makeScreenshotTempFile(named name: String, data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func isInsideAttachments(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path
            .hasPrefix(WispAttachments.directory.resolvingSymlinksInPath().path + "/")
    }

    // MARK: - Clipboard Images

    @Test func testSavesPNGFromPasteboard() throws {
        let pasteboard = makePasteboard()
        let png = imageData(.png)
        pasteboard.setData(png, forType: .png)

        let url = try #require(WispAttachments.saveImage(from: pasteboard))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(isInsideAttachments(url))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == png)
    }

    /// Screenshots copied with ⌃⇧⌘4 can arrive as TIFF only; agents need PNG.
    @Test func testConvertsTIFFOnlyPasteboardToPNG() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(imageData(.tiff), forType: .tiff)

        let url = try #require(WispAttachments.saveImage(from: pasteboard))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.pathExtension == "png")
        #expect(NSImage(contentsOf: url) != nil)
    }

    @Test func testTextOnlyPasteboardSavesNothing() {
        let pasteboard = makePasteboard()
        pasteboard.setString("hello", forType: .string)

        #expect(WispAttachments.saveImage(from: pasteboard) == nil)
    }

    /// The saved path must paste the same way into every CLI and every quoting mode.
    @Test func testSavedPathNeedsNoQuoting() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(imageData(.png), forType: .png)

        let url = try #require(WispAttachments.saveImage(from: pasteboard))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(Ghostty.Shell.escape(url.path) == url.path)
    }

    // MARK: - Short-Lived Files

    /// The screenshot thumbnail deletes its file once the drag ends, so the dropped path must
    /// point at a copy that survives that, under a name that needs no quoting.
    @Test func testScreenshotThumbnailFileIsCopiedWithSafeName() throws {
        let png = imageData(.png)
        let original = try makeScreenshotTempFile(named: "Screenshot 2026-10-27 at 2.56.05\u{202F}PM.png", data: png)

        let stable = WispAttachments.stableURL(for: original)
        defer { try? FileManager.default.removeItem(at: stable.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: original.deletingLastPathComponent())

        #expect(stable != original)
        #expect(isInsideAttachments(stable))
        #expect(stable.lastPathComponent == "Screenshot-2026-10-27-at-2.56.05-PM.png")
        #expect(try Data(contentsOf: stable) == png)
    }

    @Test func testShortLivedTIFFIsConvertedToPNG() throws {
        let original = try makeScreenshotTempFile(named: "shot.tiff", data: imageData(.tiff))

        let stable = WispAttachments.stableURL(for: original)
        defer { try? FileManager.default.removeItem(at: stable.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: original.deletingLastPathComponent())

        #expect(stable.lastPathComponent == "shot.png")
        #expect(NSImage(contentsOf: stable) != nil)
    }

    /// Ordinary files keep their real path; nothing is copied.
    @Test func testRegularFileIsReturnedUnchanged() {
        let url = URL(fileURLWithPath: "/Users/test/Pictures/photo one.png")

        #expect(WispAttachments.stableURL(for: url) == url)
    }

    // MARK: - Drop Items

    /// Each dropped file is its own entry, so it can be sent as its own paste.
    @Test func testDropItemsKeepsOneEntryPerFile() {
        let pasteboard = makePasteboard()
        let first = NSPasteboardItem()
        first.setString("file:///Users/test/a%20b.png", forType: .fileURL)
        let second = NSPasteboardItem()
        second.setString("file:///Users/test/c.png", forType: .fileURL)
        pasteboard.writeObjects([first, second])

        #expect(pasteboard.getDropItems(quoting: .spacesOnly) == [#"/Users/test/a\ b.png"#, "/Users/test/c.png"])
        #expect(pasteboard.getDropItems(quoting: .verbatim) == ["/Users/test/a b.png", "/Users/test/c.png"])
    }

    @Test func testDropItemsEmptyForImageOnlyPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.setData(imageData(.png), forType: .png)

        #expect(pasteboard.getDropItems(quoting: .spacesOnly).isEmpty)
    }
}
