import Foundation

/// Resolves a token pulled from terminal output (e.g. a filename printed by `ls`) into a
/// real file URL, relative to the terminal's current working directory. Backs the
/// Warp-style "⌘-click a path in the output to open it" behavior in the terminal surface.
enum TerminalFilePath {
    /// Extensions opened in the in-window Markdown/text pane. Anything else (images,
    /// binaries, …) is revealed in Finder instead.
    public static let paneTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "swift", "js", "jsx", "ts", "tsx", "json",
        "yaml", "yml", "toml", "sh", "zsh", "bash", "py", "go", "rs", "c", "h", "cpp",
        "cc", "hpp", "m", "mm", "css", "scss", "html", "xml", "zig", "conf", "cfg",
        "ini", "log", "rb", "java", "kt", "gradle", "lua", "php", "sql", "env", "rst",
    ]

    /// Returns true if the file URL points to a text or markdown file that can be previewed/edited in-window.
    public static func isTextOrMarkdownFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || paneTextExtensions.contains(ext)
    }

    /// Punctuation that commonly trails a path in output/prose but isn't part of it.
    private static let trailingJunk = CharacterSet(charactersIn: ":,;.!?)]}>\"'`*~_“”’")
    /// Bracketing/quoting/formatting characters to strip from both ends of a token (including Markdown bold/italic).
    private static let wrappers = CharacterSet(charactersIn: "\"'`()[]{}<>*~_#“”‘’«»")

    /// Cleans `token` and returns a URL if it points at an existing file or directory,
    /// resolving relative tokens against `cwd` or git root. Returns nil when nothing exists there — so
    /// a ⌘-click on ordinary text or an external URL simply falls through to normal handling.
    static func resolve(token: String, cwd: URL?) -> URL? {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // If it's a file:// URL (e.g. from OSC 8 hyperlinks or terminal file outputs)
        if value.hasPrefix("file://") {
            if let fileUrl = URL(string: value) {
                let path = fileUrl.path
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path).standardizedFileURL
                }
            }
        }

        // If it's formatted as a Markdown link [label](path/to/file)
        if let linkStart = value.range(of: "]("), value.hasSuffix(")") {
            value = String(value[linkStart.upperBound..<value.index(before: value.endIndex)])
        }

        // Strip leading emoji or bullet points often used by AI CLI tools (e.g. "👉 **file.md**")
        while let first = value.unicodeScalars.first,
              first.properties.isEmoji || wrappers.contains(first) || CharacterSet.whitespaces.contains(first) {
            value.unicodeScalars.removeFirst()
        }

        // Strip wrappers and trailing junk repeatedly until clean
        var changed = true
        while changed && !value.isEmpty {
            changed = false
            let before = value
            value = value.trimmingCharacters(in: wrappers)
            while let scalar = value.unicodeScalars.last, trailingJunk.contains(scalar) {
                value.unicodeScalars.removeLast()
            }
            if value != before { changed = true }
        }
        guard !value.isEmpty else { return nil }

        // Strip trailing line numbers or fragments (e.g. file.md:42, file.swift:10:5, file.md#L10-L20)
        var cleanedPath = value
        if let hashIndex = cleanedPath.firstIndex(of: "#") {
            cleanedPath = String(cleanedPath[..<hashIndex])
        }
        if let colonIndex = cleanedPath.lastIndex(of: ":") {
            let suffix = String(cleanedPath[cleanedPath.index(after: colonIndex)...])
            if Int(suffix) != nil {
                cleanedPath = String(cleanedPath[..<colonIndex])
                if let secondColonIndex = cleanedPath.lastIndex(of: ":") {
                    let secondSuffix = String(cleanedPath[cleanedPath.index(after: secondColonIndex)...])
                    if Int(secondSuffix) != nil {
                        cleanedPath = String(cleanedPath[..<secondColonIndex])
                    }
                }
            }
        }
        cleanedPath = cleanedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPath.isEmpty else { return nil }

        let fileManager = FileManager.default
        let expanded = (cleanedPath as NSString).expandingTildeInPath

        // 1. Absolute path (including ~-expanded)
        if expanded.hasPrefix("/") {
            if fileManager.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }

        // 2. Relative to the current working directory
        if let cwd {
            let candidate = cwd.appendingPathComponent(cleanedPath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }

            // 3. Relative to git repository root (CLI tools often print paths relative to repo root)
            if let gitRoot = findGitRoot(from: cwd) {
                let repoCandidate = gitRoot.appendingPathComponent(cleanedPath)
                if fileManager.fileExists(atPath: repoCandidate.path) {
                    return repoCandidate.standardizedFileURL
                }

                // 4. If the path is a standalone filename (no slashes), search repo shallowly
                if !cleanedPath.contains("/") {
                    if let found = findFileByName(cleanedPath, in: gitRoot, maxDepth: 3) {
                        return found
                    }
                }
            } else if !cleanedPath.contains("/") {
                if let found = findFileByName(cleanedPath, in: cwd, maxDepth: 2) {
                    return found
                }
            }
        }

        return nil
    }

    /// Finds the enclosing git root directory starting from a given directory.
    private static func findGitRoot(from startURL: URL) -> URL? {
        var current = startURL.standardizedFileURL
        let fileManager = FileManager.default
        while true {
            let gitDir = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitDir.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    /// Searches for a file by exact name within a directory up to a given depth limit.
    private static func findFileByName(_ filename: String, in directory: URL, maxDepth: Int = 2) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if fileURL.lastPathComponent == filename {
                return fileURL.standardizedFileURL
            }
        }
        return nil
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
