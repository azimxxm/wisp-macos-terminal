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

    /// Gets the contents of the pasteboard for a **drag-and-drop**, one entry per dropped item,
    /// honoring the user's Wisp quoting preference. The caller inserts each entry as its own
    /// paste — see `SurfaceView.wispInsertAttachments`.
    ///
    /// This is deliberately a sibling of `getOpinionatedStringContents()` rather than a
    /// parameterization of it: that function is shared by three *paste* paths
    /// (`Ghostty.App.readClipboard`, `SurfaceView.readSelection(from:)`, and the
    /// `pasteSelection` menu validation) which must keep upstream's semantics. Only
    /// `SurfaceView.performDragOperation` calls this one.
    ///
    /// Short-lived files (the floating screenshot thumbnail) are copied somewhere stable first,
    /// so this must run before the drop returns. See `WispAttachments.stableURL(for:)`.
    ///
    /// - Parameter quoting: How each file path is escaped or quoted.
    /// - Returns: One string per usable item; empty if the pasteboard held nothing usable.
    func getDropItems(quoting: WispDragDropQuoting) -> [String] {
        (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return quoting.apply(to: WispAttachments.stableURL(for: fileURL).path)
            } else {
                return item.string(forType: .string)
            }
        }
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
