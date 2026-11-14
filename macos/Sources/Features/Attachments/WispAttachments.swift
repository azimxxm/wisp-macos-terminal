import AppKit
import OSLog
import UniformTypeIdentifiers

/// Turns images and files that are pasted or dropped onto a terminal into paths an agent CLI
/// (Claude Code, Codex, Antigravity) can attach.
///
/// Those CLIs attach an image when its path arrives as a bracketed paste, but they can't do
/// anything with raw image bytes, and some only read the file when the prompt is submitted.
/// So clipboard images, promised files and short-lived files are written to a folder under
/// `$TMPDIR` (which macOS clears after a few days), with names that never need quoting.
enum WispAttachments {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Wisp",
        category: "WispAttachments"
    )

    /// Where saved attachments live. Each one gets its own subfolder so names never collide.
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-attachments", isDirectory: true)
    }

    /// Image formats every supported agent CLI reads. Anything else (HEIC, TIFF, BMP...) is
    /// converted to PNG when we own the file.
    private static let agentImageTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: Clipboard and raw image data

    /// Saves the image on `pasteboard` (a screenshot copied with ⌃⇧⌘4, an image copied in a
    /// browser) and returns the saved file, or nil when the pasteboard holds no image.
    static func saveImage(from pasteboard: NSPasteboard) -> URL? {
        let data: Data
        let fileExtension: String
        if let png = pasteboard.data(forType: .png) {
            (data, fileExtension) = (png, "png")
        } else if let jpeg = pasteboard.data(forType: .init(UTType.jpeg.identifier)) {
            (data, fileExtension) = (jpeg, "jpg")
        } else if let png = pngData(from: NSImage(pasteboard: pasteboard)) {
            (data, fileExtension) = (png, "png")
        } else {
            return nil
        }

        do {
            let url = try makeFolder().appendingPathComponent("pasted-image.\(fileExtension)")
            try data.write(to: url)
            return url
        } catch {
            logger.error("could not save pasted image: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: Short-lived files

    /// Returns a URL for `url` that will still exist when an agent CLI reads it.
    ///
    /// The floating screenshot thumbnail hands out a file in
    /// `$TMPDIR/TemporaryItems/NSIRD_screencaptureui_*` that is deleted soon after the drag
    /// ends, so a CLI that reads it on submit finds nothing. Files like that are copied first;
    /// every other file is returned unchanged. Must run before the drop returns.
    static func stableURL(for url: URL) -> URL {
        guard isShortLived(url) else { return url }
        do {
            let copy = try makeFolder().appendingPathComponent(safeName(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: copy)
            return try agentReady(copy)
        } catch {
            logger.error("could not copy short-lived file: \(error, privacy: .public)")
            return url
        }
    }

    private static func isShortLived(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        if path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") { return false }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return path.contains("/TemporaryItems/") || path.hasPrefix(temporary + "/")
    }

    // MARK: Promised files

    /// The file promises on a drag worth receiving: none when the drag already carries file
    /// paths, all of them when it carries no text, otherwise only the image ones. Remote-file
    /// drags (an sftp file from Transmit) still insert their URL text like upstream.
    static func promiseReceivers(for pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard pasteboard.availableType(from: [.fileURL]) == nil else { return [] }
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard pasteboard.availableType(from: [.string]) != nil else { return receivers }
        return receivers.filter { receiver in
            receiver.fileTypes.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }

    /// Asks each drag source (Photos, Mail, a browser) to write its files, then calls
    /// `handler` on the main queue once per file as it lands.
    static func receive(_ receivers: [NSFilePromiseReceiver], handler: @escaping @MainActor (URL) -> Void) {
        let folder: URL
        do {
            folder = try makeFolder()
        } catch {
            logger.error("could not create attachment folder: \(error, privacy: .public)")
            return
        }

        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: folder,
                options: [:],
                operationQueue: promiseQueue
            ) { url, error in
                if let error {
                    logger.error("could not receive promised file: \(error, privacy: .public)")
                    return
                }
                let ready: URL
                do {
                    ready = try agentReady(url)
                } catch {
                    logger.error("could not prepare promised file: \(error, privacy: .public)")
                    ready = url
                }
                DispatchQueue.main.async { handler(ready) }
            }
        }
    }

    // MARK: Helpers

    private static func makeFolder() throws -> URL {
        let folder = directory.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Renames a file we own to a quote-free name and converts images agents can't read to PNG.
    private static func agentReady(_ url: URL) throws -> URL {
        var url = url
        let name = safeName(url.lastPathComponent)
        if name != url.lastPathComponent {
            let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.moveItem(at: url, to: renamed)
            url = renamed
        }

        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              !agentImageTypes.contains(where: { type.conforms(to: $0) }),
              let png = pngData(from: NSImage(contentsOf: url)) else { return url }
        let converted = url.deletingPathExtension().appendingPathExtension("png")
        try png.write(to: converted)
        try FileManager.default.removeItem(at: url)
        return converted
    }

    /// Replaces anything other than letters, digits, `.`, `_` and `-` with `-`, so the path
    /// pastes the same way into every CLI. Screenshot names hold spaces and, in 12-hour
    /// locales, a narrow no-break space before AM/PM.
    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var safe = String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        while safe.contains("--") {
            safe = safe.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    private static func pngData(from image: NSImage?) -> Data? {
        guard let tiff = image?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
