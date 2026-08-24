import AppKit
import Foundation
import SwiftUI

/// A Warp-style collapsible file-explorer sidebar for the terminal's current working
/// directory. Shows a lazy, on-demand-expanding file tree by default; typing into the
/// filter field switches to a flat, recursively-searched file list instead.
///
/// The tree never recurses eagerly — each folder's children are only listed once the
/// user actually expands that folder — so large directories (e.g. `node_modules`) stay
/// cheap until opened. All filesystem access happens off the main thread.
struct FileSidebarView: View {
    let cwd: URL?
    let onOpenFile: (URL) -> Void

    /// Inserts a row's path into the focused terminal instead of opening it. Fired by
    /// ⌥-click and by the row's "Insert Path in Terminal" context-menu item. The sidebar
    /// hands over the raw `URL` and nothing else: deciding relative-vs-absolute and
    /// shell-escaping are terminal concerns, so `TerminalView` owns them — it is also the
    /// only place that knows which surface is focused.
    let onInsertPath: (URL) -> Void

    @State private var searchQuery = ""
    @State private var searchResults: [SearchResult] = []

    /// Listings, expansion and file mutations for the whole tree. Owned here rather than
    /// per-row so a rename or a delete can re-list just the affected folder without
    /// collapsing every other one the user has open.
    @StateObject private var model = FileTreeModel()

    /// Item awaiting delete confirmation. Non-nil puts the confirmation dialog on screen.
    @State private var pendingTrash: FileEntry?

    private static let maxSearchResults = 300
    private static let maxSearchDepth = 8
    private static let searchDebounceMilliseconds = 150

    init(
        cwd: URL?,
        onOpenFile: @escaping (URL) -> Void,
        onInsertPath: @escaping (URL) -> Void
    ) {
        self.cwd = cwd
        self.onOpenFile = onOpenFile
        self.onInsertPath = onInsertPath
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let cwd {
                VStack(spacing: 0) {
                    header(for: cwd)
                    Divider()
                    searchField
                    Divider()

                    if let errorMessage = model.errorMessage {
                        errorBanner(errorMessage)
                        Divider()
                    }

                    if trimmedQuery.isEmpty {
                        treeContent(for: cwd)
                    } else {
                        searchContent
                    }
                }
                .task(id: cwd) {
                    await model.setRoot(cwd)
                }
                .confirmationDialog(
                    pendingTrash.map { "Move \"\($0.name)\" to the Trash?" } ?? "",
                    isPresented: Binding(
                        get: { pendingTrash != nil },
                        set: { if !$0 { pendingTrash = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Move to Trash", role: .destructive) {
                        guard let target = pendingTrash else { return }
                        pendingTrash = nil
                        Task {
                            await model.moveToTrash(
                                target.url, isDirectory: target.isDirectory, confirmed: true)
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingTrash = nil }
                } message: {
                    Text("You can put it back from the Trash, or undo here in the sidebar.")
                }
                .task(id: SearchKey(cwd: cwd, query: trimmedQuery)) {
                    await runSearch(cwd: cwd, query: trimmedQuery)
                }
            } else {
                emptyPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .wispGlassPanel()
    }

    // MARK: - Header, Search Field & Empty State

    private func header(for cwd: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(cwd.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(cwd.path)

            Spacer(minLength: 0)

            if let undoAction = model.undoBannerAction {
                Button {
                    Task { await model.undoLastOperation() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Undo \(undoAction)")
                .accessibilityLabel("Undo \(undoAction)")
            }

            Button {
                Task { await model.createFile(in: cwd) }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New File")

            Button {
                Task { await model.createFolder(in: cwd) }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Folder")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Filter files…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("Open a folder in the terminal to browse files here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Inline, non-blocking report of the last filesystem failure. Same shape as the
    /// Markdown pane's banner so the two panes read as one app.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Tree & Search Content

    @ViewBuilder
    private func treeContent(for cwd: URL) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                let rootEntries = model.children(of: cwd) ?? []
                if rootEntries.isEmpty {
                    if model.isLoading(cwd) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else {
                        Text("This folder is empty.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                } else {
                    ForEach(rootEntries) { entry in
                        FileTreeRow(
                            entry: entry,
                            depth: 0,
                            model: model,
                            onOpenFile: onOpenFile,
                            onInsertPath: onInsertPath,
                            onRequestTrash: { pendingTrash = $0 })
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if searchResults.isEmpty {
                    Text("No files match “\(trimmedQuery)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(searchResults) { result in
                        SearchResultRow(
                            result: result,
                            onOpenFile: onOpenFile,
                            onInsertPath: onInsertPath)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Async Loading

    /// Restarts whenever the directory or (trimmed) query changes. A short debounce
    /// avoids kicking off a new recursive scan on every single keystroke.
    @MainActor
    private func runSearch(cwd: URL, query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        try? await Task.sleep(for: .milliseconds(Self.searchDebounceMilliseconds))
        guard !Task.isCancelled else { return }

        searchResults = []
        let stream = FileSidebarScanner.searchStream(
            query: query,
            under: cwd,
            maxResults: Self.maxSearchResults,
            maxDepth: Self.maxSearchDepth
        )
        for await result in stream {
            guard !Task.isCancelled else { return }
            searchResults.append(result)
        }
    }
}

/// Combines the two inputs that should restart a search scan: the directory being
/// searched and the (trimmed) query text.
private struct SearchKey: Equatable {
    let cwd: URL
    let query: String
}

// MARK: - File Tree Row

/// A single row in the file tree. Owns its own expansion + lazily-loaded children
/// state, so opening a folder only ever lists that folder's immediate contents —
/// never the whole subtree — and only once the user actually expands it.
private struct FileTreeRow: View {
    let entry: FileEntry
    let depth: Int
    @ObservedObject var model: FileTreeModel
    let onOpenFile: (URL) -> Void
    let onInsertPath: (URL) -> Void
    let onRequestTrash: (FileEntry) -> Void

    @State private var isHovering = false

    private var isExpanded: Bool { model.isExpanded(entry.url) }
    private var children: [FileEntry]? { model.children(of: entry.url) }
    private var isLoadingChildren: Bool { model.isLoading(entry.url) }

    private static let indentWidth: CGFloat = 14
    private static let baseLeadingPadding: CGFloat = 6
    private static let rowCornerRadius: CGFloat = 4
    private static let dragPreviewHorizontalPadding: CGFloat = 8
    private static let dragPreviewVerticalPadding: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if entry.isDirectory, isExpanded {
                expandedChildren
            }
        }
    }

    private var row: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                if entry.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }

                Image(systemName: entry.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.iconColor)
                    .frame(width: 16)

                if model.isEditing(entry.url) {
                    InlineRenameField(
                        name: entry.name,
                        onCommit: { newName in
                            Task { await model.rename(entry.url, to: newName) }
                        },
                        onCancel: { model.cancelRename() })
                } else {
                    Text(entry.name)
                        .font(.system(size: 12, weight: entry.isMarkdown ? .medium : .regular))
                        .foregroundStyle(entry.isMarkdown ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if isLoadingChildren {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .padding(.leading, CGFloat(depth) * Self.indentWidth + Self.baseLeadingPadding)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Also the drag hit area: without it only the drawn glyphs would be draggable.
            .contentShape(Rectangle())
            .background(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Self.rowCornerRadius))
        }
        .buttonStyle(.plain)
        // Publishes the row as a file URL so dropping it on a terminal surface takes the
        // byte-for-byte same code path as dragging the file in from Finder.
        //
        // `NSItemProvider(object:)` on an `NSURL` registers exactly public.file-url and
        // public.url. That is what makes the drop work: `SurfaceView.dropTypes` contains
        // `.fileURL`, so `draggingEntered` accepts it and
        // `NSPasteboard.getOpinionatedStringContents()` finds
        // `item.propertyList(forType: .fileURL)` non-nil and runs it through
        // `Ghostty.Shell.escape`. `NSItemProvider(contentsOf:)` would additionally register
        // the file's own content UTI and eagerly load the whole file into the drag payload —
        // and for directories its primary representation fails to load at all.
        .onDrag {
            NSItemProvider(object: entry.url as NSURL)
        } preview: {
            dragPreview
        }
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        // ⌥-click has no visual affordance, so the tooltip is where it gets taught.
        .help("\(entry.url.path)\n⌥-click to insert this path into the terminal")
        .accessibilityLabel(entry.isDirectory ? "Folder, \(entry.name)" : "File, \(entry.name)")
    }

    /// Per-row file management. Single-item only: the tree has no multi-selection, so every
    /// action here operates on exactly this entry.
    ///
    /// "Move to Trash" is separated from the rest and routed through the host's confirmation
    /// dialog — on macOS a `.destructive` button does not render red inside a context menu,
    /// so position and the confirmation are what signal danger, not colour.
    @ViewBuilder
    private var contextMenu: some View {
        Button("Insert Path in Terminal") { onInsertPath(entry.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }

        Divider()

        if entry.isDirectory {
            Button("New File") { Task { await model.createFile(in: entry.url) } }
            Button("New Folder") { Task { await model.createFolder(in: entry.url) } }
            Divider()
        }

        Button("Rename") { model.beginRename(entry.url) }
        Button("Duplicate") {
            Task { await model.duplicate(entry.url, isDirectory: entry.isDirectory) }
        }

        Divider()

        Button("Copy Path") { copyToPasteboard(entry.url.path) }
        Button("Copy Relative Path") {
            copyToPasteboard(relativePath(of: entry.url, under: model.root) ?? entry.url.path)
        }

        Divider()

        Button("Move to Trash") { onRequestTrash(entry) }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// `url` written relative to the sidebar's root, or nil when it is not inside it.
    private func relativePath(of url: URL, under root: URL?) -> String? {
        guard let root else { return nil }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard rootPath != "/", filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// Compact chip shown under the cursor during a drag. Without an explicit preview
    /// SwiftUI snapshots the whole row, which is full sidebar width and reads as a smear.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.iconName)
                .font(.system(size: 12))
                .foregroundStyle(entry.iconColor)

            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, Self.dragPreviewHorizontalPadding)
        .padding(.vertical, Self.dragPreviewVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var expandedChildren: some View {
        if let children {
            if children.isEmpty {
                Text("No items")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth + 1) * Self.indentWidth + Self.baseLeadingPadding)
                    .padding(.vertical, 2)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(children) { child in
                        FileTreeRow(
                            entry: child,
                            depth: depth + 1,
                            model: model,
                            onOpenFile: onOpenFile,
                            onInsertPath: onInsertPath,
                            onRequestTrash: onRequestTrash)
                    }
                }
            }
        }
    }

    /// ⌥-click inserts the row's path into the focused terminal instead of opening it.
    ///
    /// Option was chosen because it is the only purely additive option: it needs no extra row
    /// chrome, and a plain click keeps its exact existing meaning. A hover-revealed button
    /// would have to live outside this `Button` (on macOS the outer button swallows clicks on
    /// nested ones), which means restructuring the row. Double-click is out because SwiftUI
    /// delivers it as two single clicks, so the first one would already have opened the pane.
    /// The context menu mirrors the action for discoverability.
    ///
    /// `NSEvent.modifierFlags` reports the *current* modifier state, which is accurate here:
    /// SwiftUI runs a `Button` action synchronously on mouse-up while the key is still held,
    /// and it exposes no way to read the event that triggered the button.
    @MainActor
    private func handleTap() {
        if NSEvent.modifierFlags.contains(.option) {
            onInsertPath(entry.url)
            return
        }

        guard entry.isDirectory else {
            onOpenFile(entry.url)
            return
        }

        Task { await model.toggleExpansion(of: entry.url) }
    }
}

// MARK: - Inline Rename Field

/// In-place rename editor for one row.
///
/// An `NSTextField` rather than SwiftUI's `TextField` for one reason: only the basename
/// should be selected when the editor opens, so typing a new name never silently eats the
/// extension — and SwiftUI still exposes no public API for a text field's selected range.
/// Dotfiles (`.gitignore`) select the whole name, matching VS Code.
private struct InlineRenameField: NSViewRepresentable {
    let name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.isAutomaticTextCompletionEnabled = false
        field.usesSingleLineMode = true

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            // `currentEditor()` only exists once the field is first responder, which is why
            // this cannot happen inline above.
            guard let editor = field.currentEditor() else { return }
            let stem = (name as NSString).deletingPathExtension
            // A leading dot means the whole thing is the name, not an extension.
            let selectable = (stem.isEmpty || name.hasPrefix(".")) ? name.count : stem.count
            editor.selectedRange = NSRange(location: 0, length: selectable)
        }

        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        /// Guards against the commit firing twice — Return triggers `doCommandBy` and then
        /// AppKit ends editing, which would otherwise commit the same name again.
        private var finished = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish { self.onCommit(textView.string) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish { self.onCancel() }
                return true
            default:
                return false
            }
        }

        /// Clicking away commits, the way Finder and VS Code both behave.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish { self.onCommit(field.stringValue) }
        }

        private func finish(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }
}

// MARK: - Search Result Row

/// A single flat search-result row: filename plus a dimmed path to the containing
/// folder, so same-named files from different folders stay distinguishable.
private struct SearchResultRow: View {
    let result: SearchResult
    let onOpenFile: (URL) -> Void
    let onInsertPath: (URL) -> Void

    @State private var isHovering = false

    private static let rowCornerRadius: CGFloat = 4
    private static let dragPreviewHorizontalPadding: CGFloat = 8
    private static let dragPreviewVerticalPadding: CGFloat = 4

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                Image(systemName: result.url.fileIconName)
                    .font(.system(size: 12))
                    .foregroundStyle(result.url.isMarkdownFile ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name)
                        .font(.system(size: 12, weight: result.url.isMarkdownFile ? .medium : .regular))
                        .foregroundStyle(result.url.isMarkdownFile ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !result.relativeDirectory.isEmpty {
                        Text(result.relativeDirectory)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Self.rowCornerRadius))
        }
        .buttonStyle(.plain)
        // Same payload as FileTreeRow — see the comment there for why NSURL is used and
        // not NSItemProvider(contentsOf:).
        .onDrag {
            NSItemProvider(object: result.url as NSURL)
        } preview: {
            dragPreview
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Insert Path in Terminal") { onInsertPath(result.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            }
        }
        .help("\(result.url.path)\n⌥-click to insert this path into the terminal")
        .accessibilityLabel(
            "File, \(result.name), in " +
            (result.relativeDirectory.isEmpty ? "current folder" : result.relativeDirectory)
        )
    }

    /// Compact chip shown under the cursor during a drag — see `FileTreeRow.dragPreview`
    /// for why an explicit preview beats the default full-width row snapshot.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: result.url.fileIconName)
                .font(.system(size: 12))
                .foregroundStyle(result.url.isMarkdownFile ? Color.accentColor : .secondary)

            Text(result.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, Self.dragPreviewHorizontalPadding)
        .padding(.vertical, Self.dragPreviewVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(Color.secondary.opacity(0.2)))
    }

    /// ⌥-click inserts the row's path into the terminal instead of opening the file — the
    /// same contract as `FileTreeRow.handleTap`, which documents why the modifier is read
    /// from `NSEvent`. Search results are always files, so there is no expand branch here.
    @MainActor
    private func handleTap() {
        if NSEvent.modifierFlags.contains(.option) {
            onInsertPath(result.url)
            return
        }

        onOpenFile(result.url)
    }
}

// MARK: - Models

/// One entry (file or directory) directly inside a listed folder.
struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isMarkdown: Bool { !isDirectory && url.isMarkdownFile }

    var iconName: String {
        isDirectory ? "folder" : url.fileIconName
    }

    var iconColor: Color {
        if isDirectory { return .secondary }
        return isMarkdown ? Color.accentColor : .secondary
    }
}

/// One match from a recursive filename search, flattened out of the tree with just
/// enough context — its containing folder, relative to the search root — to
/// disambiguate same-named files living in different folders.
private struct SearchResult: Identifiable, Hashable {
    let url: URL
    let relativeDirectory: String

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

// MARK: - Icon Mapping

private extension URL {
    /// Best-guess SF Symbol for this file's type, used as the row icon.
    var fileIconName: String {
        switch pathExtension.lowercased() {
        case "md", "markdown":
            return "doc.richtext"
        case "txt", "log", "csv", "rtf":
            return "doc.text"
        case "json", "yml", "yaml", "toml", "xml", "plist",
             "swift", "zig", "c", "h", "hpp", "cpp", "cc", "m", "mm",
             "go", "py", "js", "ts", "tsx", "jsx", "rs", "java", "kt", "rb", "sh":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp":
            return "photo"
        case "pdf":
            return "doc.fill"
        case "zip", "gz", "tar", "bz2", "xz", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    /// Markdown gets a distinct accent-colored look — it's the primary file type
    /// this sidebar is used to browse.
    var isMarkdownFile: Bool {
        let ext = pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }
}

// MARK: - Filesystem Scanning

/// Off-main-thread filesystem access for the sidebar. Nothing here touches
/// `@State`, so every function is safe to call from any actor context — the heavy
/// lifting always happens inside a detached task.
enum FileSidebarScanner {
    /// Directory and file names that are always skipped, regardless of the
    /// hidden-file check — the classic "huge and irrelevant" folders that would
    /// otherwise stall a recursive search.
    static let skippedNames: Set<String> = [
        "node_modules", ".git", ".zig-cache", ".build", "DerivedData",
        "dist", "build", ".next", "target",
    ]

    // `contentsOfDirectory` wants an Array of keys; `resourceValues(forKeys:)` on a
    // single URL wants a Set of the same keys. Keep both so neither call site needs
    // an inline conversion.
    private static let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
    private static let resourceKeySet: Set<URLResourceKey> = [.isDirectoryKey]

    /// Lists the immediate (non-recursive) children of `directory`, directories
    /// first then files, each alphabetically. Never throws — an unreadable
    /// directory just yields an empty list.
    static func children(of directory: URL) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            listChildren(of: directory)
        }.value
    }

    private static func listChildren(of directory: URL) -> [FileEntry] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let entries = items.compactMap { itemURL -> FileEntry? in
            let name = itemURL.lastPathComponent
            guard !name.hasPrefix("."), !skippedNames.contains(name) else { return nil }
            let isDirectory = (try? itemURL.resourceValues(forKeys: resourceKeySet))?.isDirectory ?? false
            return FileEntry(url: itemURL, isDirectory: isDirectory)
        }

        return sorted(entries)
    }

    private static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Recursively searches under `root` for files whose name contains `query`
    /// (case-insensitive), streaming each match as soon as it's found so the UI
    /// updates incrementally instead of waiting for the whole walk to finish.
    /// Stops after `maxResults` matches or `maxDepth` levels of nesting, and
    /// cancels the underlying scan as soon as the stream is abandoned.
    /// `fileprivate` rather than internal because `SearchResult` stays private to this
    /// file — only the tree's listing API needs to be reachable from `FileTreeModel`.
    fileprivate static func searchStream(
        query: String,
        under root: URL,
        maxResults: Int,
        maxDepth: Int
    ) -> AsyncStream<SearchResult> {
        AsyncStream { continuation in
            let context = SearchWalkContext(
                root: root,
                query: query.lowercased(),
                maxDepth: maxDepth,
                maxResults: maxResults,
                continuation: continuation
            )
            let task = Task.detached(priority: .userInitiated) {
                var emitted = 0
                walk(directory: root, depth: 0, emitted: &emitted, context: context)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func walk(directory: URL, depth: Int, emitted: inout Int, context: SearchWalkContext) {
        guard !Task.isCancelled, emitted < context.maxResults, depth <= context.maxDepth else { return }

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            guard !Task.isCancelled, emitted < context.maxResults else { return }

            let name = item.lastPathComponent
            guard !name.hasPrefix("."), !skippedNames.contains(name) else { continue }

            let isDirectory = (try? item.resourceValues(forKeys: resourceKeySet))?.isDirectory ?? false
            if isDirectory {
                walk(directory: item, depth: depth + 1, emitted: &emitted, context: context)
            } else if name.lowercased().contains(context.query) {
                context.continuation.yield(SearchResult(
                    url: item,
                    relativeDirectory: relativeDirectoryPath(of: item, under: context.root)
                ))
                emitted += 1
            }
        }
    }

    private static func relativeDirectoryPath(of fileURL: URL, under root: URL) -> String {
        let containingDirPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard containingDirPath.hasPrefix(rootPath) else { return "" }

        var relative = String(containingDirPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}

/// Bundles the values that stay constant across every recursive step of a single
/// search walk, so `walk(...)` doesn't need a long parameter list at each call site.
private struct SearchWalkContext {
    let root: URL
    let query: String
    let maxDepth: Int
    let maxResults: Int
    let continuation: AsyncStream<SearchResult>.Continuation
}

// MARK: - Previews

struct FileSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FileSidebarView(
                cwd: FileManager.default.homeDirectoryForCurrentUser,
                onOpenFile: { _ in },
                onInsertPath: { _ in })
                .frame(width: 260, height: 480)
                .previewDisplayName("With Directory")

            FileSidebarView(
                cwd: nil,
                onOpenFile: { _ in },
                onInsertPath: { _ in })
                .frame(width: 260, height: 480)
                .previewDisplayName("No Directory")
        }
    }
}
