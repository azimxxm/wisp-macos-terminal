import SwiftUI

// MARK: - Preferences

/// How a filesystem path coming from a **drag-and-drop** is quoted before it is inserted into
/// the terminal. Modeled on WezTerm's `quote_dropped_files`, the only shipping terminal that
/// exposes this as a user preference.
///
/// This governs drops only. Paste (⌘V, `paste_from_clipboard`, OSC 52) deliberately keeps
/// upstream Ghostty's behavior — see `NSPasteboard.getOpinionatedStringContents()`, which is
/// shared by three paste paths and is never routed through this type.
enum WispDragDropQuoting: String, CaseIterable, Identifiable {
    /// Insert the path verbatim, like kitty. Best for agent CLIs, which read the drop as
    /// prompt text rather than as a shell word — but ambiguous to a shell if the path
    /// contains a space.
    ///
    /// Named `verbatim` rather than `none` so it can never be confused with `Optional.none`
    /// in a `WispDragDropQuoting?` context; the raw value is pinned so the stored preference
    /// is independent of the case name.
    case verbatim = "none"

    /// Upstream Ghostty's behavior: backslash-escape shell metacharacters via
    /// `Ghostty.Shell.escape`. Despite the name — inherited from WezTerm's `SpacesOnly` — this
    /// escapes 22 characters, not just spaces. It does *not* escape a newline.
    case spacesOnly = "spacesOnly"

    /// Wrap the path in single quotes when it needs them, like Python's `shlex.quote`, via the
    /// existing `Ghostty.Shell.quote`. This is the only mode that keeps a path containing a
    /// newline as a single *shell* word — note that a newline-joined multi-file drop still
    /// falls back to a space in that case, because a line-splitting consumer cannot tell the
    /// embedded newline from a separator. See `SurfaceView.wispInsertAttachments`.
    case posixQuote = "posixQuote"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .verbatim: return "None"
        case .spacesOnly: return "Backslash Escape"
        case .posixQuote: return "Single Quotes"
        }
    }

    /// Applies this quoting style to a filesystem path.
    ///
    /// `Ghostty.Shell.escape` and `Ghostty.Shell.quote` are upstream-owned and have other live
    /// callers — the paste path and `AppDelegate.application(_:openFile:)` respectively — so
    /// they are *called* here, never edited.
    func apply(to path: String) -> String {
        switch self {
        case .verbatim: return path
        case .spacesOnly: return Ghostty.Shell.escape(path)
        case .posixQuote: return Ghostty.Shell.quote(path)
        }
    }
}

/// The separator placed between paths when more than one file is dropped at once.
///
/// Upstream Ghostty always uses a space (PR #4956, "macos: paste multiple files separated by
/// space"). Agent CLIs that read the terminal as a multi-line prompt — Claude Code, Codex,
/// aider — treat a space-joined list as one broken argument line and want one path per line.
enum WispMultiFileDropSeparator: String, CaseIterable, Identifiable {
    case space
    case newline

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .space: return "Space"
        case .newline: return "Newline"
        }
    }

    /// The literal string joined between paths.
    var literal: String {
        switch self {
        case .space: return " "
        case .newline: return "\n"
        }
    }
}

/// Keys + defaults for Wisp's drag-and-drop behavior, read by both the Settings UI and
/// `SurfaceView.performDragOperation`. Backed by `UserDefaults.standard`, the same store
/// `@AppStorage` writes to.
enum WispDragDropDefaults {
    static let quotingKey = "com.azimxxm.wisp.dragDrop.quoting"
    static let separatorKey = "com.azimxxm.wisp.dragDrop.multiFileSeparator"

    /// Defaults to `.spacesOnly` so an untouched install drops exactly like upstream Ghostty.
    static var quoting: WispDragDropQuoting {
        UserDefaults.standard.string(forKey: quotingKey)
            .flatMap(WispDragDropQuoting.init(rawValue:)) ?? .spacesOnly
    }

    /// Defaults to `.space` to match upstream Ghostty PR #4956. Newline is opt-in because a
    /// newline-joined drop into a prompt with bracketed paste *off* is rewritten `\n` -> `\r`
    /// by the core and would execute each path as a command.
    static var separator: WispMultiFileDropSeparator {
        UserDefaults.standard.string(forKey: separatorKey)
            .flatMap(WispMultiFileDropSeparator.init(rawValue:)) ?? .space
    }
}

// MARK: - Settings pane

/// The "Drag & Drop" settings pane. Controls how file paths dropped onto a terminal surface are
/// quoted and joined. Nothing here affects paste, and nothing here is ever written to the user's
/// Ghostty configuration file.
struct DragDropSettingsView: View {
    @AppStorage(WispDragDropDefaults.quotingKey)
    private var quoting: WispDragDropQuoting = .spacesOnly

    @AppStorage(WispDragDropDefaults.separatorKey)
    private var separator: WispMultiFileDropSeparator = .space

    /// Sample paths for the live preview. The first deliberately contains a space so the effect
    /// of each quoting mode is visible at a glance.
    private static let samplePaths = [
        "/Users/you/My Project/notes.md",
        "/Users/you/src/main.swift",
    ]

    /// Fixed height for the preview box so switching between space and newline doesn't make the
    /// rest of the Form jump.
    private static let previewHeight: CGFloat = 44

    /// Built through the exact same `apply(to:)` + `literal` code path the real drop uses, so the
    /// preview can never drift from actual behavior.
    private var preview: String {
        Self.samplePaths
            .map { quoting.apply(to: $0) }
            .joined(separator: separator.literal)
    }

    var body: some View {
        Form {
            Section {
                Picker("Quoting", selection: $quoting) {
                    ForEach(WispDragDropQuoting.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }

                Picker("Multi-File Separator", selection: $separator) {
                    ForEach(WispMultiFileDropSeparator.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Dropped Files")
            } footer: {
                Text(
                    "Claude Code and other agent CLIs read a drop as prompt text and expect one "
                    + "path per line; shells expect a space. \"None\" inserts the path verbatim, "
                    + "which is what agents want but is ambiguous to a shell if the path "
                    + "contains a space."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.previewHeight,
                        alignment: .topLeading)
            } header: {
                Text("Preview — Two Files Dropped At Once")
            } footer: {
                Text("Paste (⌘V) is unaffected by these settings and always uses a space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Drag & Drop")
    }
}

struct DragDropSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        DragDropSettingsView()
    }
}
