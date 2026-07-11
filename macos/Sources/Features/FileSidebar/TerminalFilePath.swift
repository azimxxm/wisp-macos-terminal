import Foundation

/// Resolves a token pulled from terminal output (e.g. a filename printed by `ls`) into a
/// real file URL, relative to the terminal's current working directory. Backs the
/// Warp-style "⌘-click a path in the output to open it" behavior in the terminal surface.
enum TerminalFilePath {
    /// Punctuation that commonly trails a path in output/prose but isn't part of it.
    private static let trailingJunk = CharacterSet(charactersIn: ":,;.!?)]}>\"'`")
    /// Bracketing/quoting characters to strip from both ends of a token.
    private static let wrappers = CharacterSet(charactersIn: "\"'`()[]{}<>")

    /// Cleans `token` and returns a URL if it points at an existing file or directory,
    /// resolving relative tokens against `cwd`. Returns nil when nothing exists there — so
    /// a ⌘-click on ordinary text or a URL simply falls through to normal handling.
    static func resolve(token: String, cwd: URL?) -> URL? {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: wrappers)
        while let scalar = value.unicodeScalars.last, trailingJunk.contains(scalar) {
            value.unicodeScalars.removeLast()
        }
        guard !value.isEmpty else { return nil }

        let fileManager = FileManager.default
        let expanded = (value as NSString).expandingTildeInPath

        // Absolute path (including a ~-expanded one).
        if expanded.hasPrefix("/") {
            return fileManager.fileExists(atPath: expanded)
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : nil
        }

        // Otherwise resolve relative to the terminal's current working directory.
        guard let cwd else { return nil }
        let candidate = cwd.appendingPathComponent(value)
        return fileManager.fileExists(atPath: candidate.path)
            ? candidate.standardizedFileURL
            : nil
    }
}

extension Notification.Name {
    /// Posted by a terminal surface when the user ⌘-clicks a resolvable file path in the
    /// output. `object` is the posting `Ghostty.SurfaceView` (so the owning window can
    /// filter for its own surface); `userInfo[wispOpenPathURLKey]` holds the resolved `URL`.
    static let wispOpenPath = Notification.Name("com.azimxxm.wisp.openPath")
}

/// `userInfo` key carrying the resolved `URL` on a `.wispOpenPath` notification.
let wispOpenPathURLKey = "com.azimxxm.wisp.openPath.url"
