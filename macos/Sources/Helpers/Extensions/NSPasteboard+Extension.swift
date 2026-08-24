import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return Ghostty.Shell.escape(fileURL.path)
            } else {
                return item.string(forType: .string)
            }
        }

        guard !strings.isEmpty else {
            return nil
        }
        return strings.joined(separator: " ")
    }

    /// Gets the contents of the pasteboard as a string for a **drag-and-drop**, honoring the
    /// user's Wisp drop preferences.
    ///
    /// This is deliberately a sibling of `getOpinionatedStringContents()` rather than a
    /// parameterization of it: that function is shared by three *paste* paths
    /// (`Ghostty.App.readClipboard`, `SurfaceView.readSelection(from:)`, and the
    /// `pasteSelection` menu validation) which must keep upstream's semantics. Only
    /// `SurfaceView.performDragOperation` calls this one.
    ///
    /// - Parameters:
    ///   - quoting: How each file path is escaped or quoted.
    ///   - separator: What is placed between paths when more than one item is dropped.
    /// - Returns: The string to insert, or nil if the pasteboard held nothing usable.
    func getDropStringContents(
        quoting: WispDragDropQuoting,
        separator: WispMultiFileDropSeparator
    ) -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return quoting.apply(to: fileURL.path)
            } else {
                return item.string(forType: .string)
            }
        }

        guard !strings.isEmpty else {
            return nil
        }

        // A single item never sees the separator, so a lone drop behaves identically no matter
        // how the preference is set.
        guard strings.count > 1 else { return strings[0] }

        // A path may legally contain a newline on APFS. Neither `Ghostty.Shell.escape` (which
        // does not escape `\n`) nor `Ghostty.Shell.quote` (which preserves it inside the single
        // quotes) removes it from the token, so a newline-joined list would be unparseable by
        // any consumer that splits on lines — which is exactly the consumer this separator
        // exists for. Fall back to a space for that one drop.
        let containsNewline = strings.contains { $0.contains(where: \.isNewline) }
        let effective: WispMultiFileDropSeparator =
            (separator == .newline && containsNewline) ? .space : separator

        return strings.joined(separator: effective.literal)
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}
