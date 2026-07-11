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
    /// Called when the user taps the collapse button in the header. Optional so the
    /// sidebar can still be used without a host that manages its visibility.
    let onCollapse: (() -> Void)?

    @State private var searchQuery = ""
    @State private var rootEntries: [FileEntry] = []
    @State private var isLoadingRoot = false
    @State private var searchResults: [SearchResult] = []

    private static let maxSearchResults = 300
    private static let maxSearchDepth = 8
    private static let searchDebounceMilliseconds = 150

    init(cwd: URL?, onCollapse: (() -> Void)? = nil, onOpenFile: @escaping (URL) -> Void) {
        self.cwd = cwd
        self.onCollapse = onCollapse
        self.onOpenFile = onOpenFile
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

                    if trimmedQuery.isEmpty {
                        treeContent
                    } else {
                        searchContent
                    }
                }
                .task(id: cwd) {
                    await loadRoot(cwd: cwd)
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
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide sidebar (⌘⌥B)")
                .accessibilityLabel("Hide sidebar")
            }

            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(cwd.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(cwd.path)

            Spacer(minLength: 0)
        }
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

    // MARK: - Tree & Search Content

    @ViewBuilder
    private var treeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rootEntries.isEmpty {
                    if isLoadingRoot {
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
                        FileTreeRow(entry: entry, depth: 0, onOpenFile: onOpenFile)
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
                        SearchResultRow(result: result, onOpenFile: onOpenFile)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Async Loading

    /// Re-reads the top-level listing whenever `cwd` changes — `.task(id:)` cancels
    /// any in-flight listing for the previous directory automatically.
    @MainActor
    private func loadRoot(cwd: URL) async {
        isLoadingRoot = true
        defer { isLoadingRoot = false }

        let entries = await FileSidebarScanner.children(of: cwd)
        guard !Task.isCancelled else { return }
        rootEntries = entries
    }

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
    let onOpenFile: (URL) -> Void

    @State private var isExpanded = false
    @State private var children: [FileEntry]?
    @State private var isLoadingChildren = false
    @State private var isHovering = false

    private static let indentWidth: CGFloat = 14
    private static let baseLeadingPadding: CGFloat = 6

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

                Text(entry.name)
                    .font(.system(size: 12, weight: entry.isMarkdown ? .medium : .regular))
                    .foregroundStyle(entry.isMarkdown ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
            .contentShape(Rectangle())
            .background(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.url.path)
        .accessibilityLabel(entry.isDirectory ? "Folder, \(entry.name)" : "File, \(entry.name)")
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
                        FileTreeRow(entry: child, depth: depth + 1, onOpenFile: onOpenFile)
                    }
                }
            }
        }
    }

    @MainActor
    private func handleTap() {
        guard entry.isDirectory else {
            onOpenFile(entry.url)
            return
        }

        isExpanded.toggle()
        guard isExpanded, children == nil, !isLoadingChildren else { return }

        isLoadingChildren = true
        Task {
            let loaded = await FileSidebarScanner.children(of: entry.url)
            isLoadingChildren = false
            children = loaded
        }
    }
}

// MARK: - Search Result Row

/// A single flat search-result row: filename plus a dimmed path to the containing
/// folder, so same-named files from different folders stay distinguishable.
private struct SearchResultRow: View {
    let result: SearchResult
    let onOpenFile: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onOpenFile(result.url)
        } label: {
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(result.url.path)
        .accessibilityLabel(
            "File, \(result.name), in " +
            (result.relativeDirectory.isEmpty ? "current folder" : result.relativeDirectory)
        )
    }
}

// MARK: - Models

/// One entry (file or directory) directly inside a listed folder.
private struct FileEntry: Identifiable, Hashable {
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
private enum FileSidebarScanner {
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
    static func searchStream(
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
            FileSidebarView(cwd: FileManager.default.homeDirectoryForCurrentUser) { _ in }
                .frame(width: 260, height: 480)
                .previewDisplayName("With Directory")

            FileSidebarView(cwd: nil) { _ in }
                .frame(width: 260, height: 480)
                .previewDisplayName("No Directory")
        }
    }
}
