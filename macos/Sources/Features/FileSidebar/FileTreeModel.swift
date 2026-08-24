import Combine
import Foundation

/// Shared state and file mutations for the sidebar's tree.
///
/// The tree used to keep its expansion flag and cached children on each row's own `@State`,
/// which made it impossible to re-list a single folder after a rename or a delete: the only
/// way to see the change was to rebuild the tree, and that collapsed every folder the user
/// had open. Hoisting listings and expansion into one object lets a mutation re-list exactly
/// the affected directory while every *other* expanded folder keeps both its flag and its
/// cached listing.
///
/// To be precise about the win: this is expansion/listing **survival** across a targeted
/// re-list, not targeted view invalidation — any `@Published` write here still redraws every
/// observing row.
@MainActor
final class FileTreeModel: ObservableObject {
    /// Canonical cache key for any filesystem URL.
    ///
    /// `URL` is unusable as a key here: `contentsOfDirectory(at:)` hands back directory URLs
    /// with a trailing slash, while a URL built by `appendingPathComponent` for a path that
    /// does not exist yet has none — and the two compare unequal and hash differently. Keying
    /// by `standardizedFileURL.path` (which never carries a trailing slash) collapses both
    /// spellings onto one key, so a folder created or renamed through the context menu still
    /// matches the entry that comes back from the next directory listing.
    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    @Published private(set) var childrenByDirectory: [String: [FileEntry]] = [:]
    @Published private(set) var expandedDirectories: Set<String> = []
    @Published private(set) var loadingDirectories: Set<String> = []

    /// Path of the row currently showing its inline rename field, if any.
    @Published var editingPath: String?

    /// Last filesystem error, shown as an inline banner. Cleared by the next success.
    @Published var errorMessage: String?

    /// Name of the most recent undoable operation, or nil when there is nothing to undo.
    /// Drives the sidebar's Undo button.
    @Published private(set) var undoBannerAction: String?

    private(set) var root: URL?

    // MARK: - History
    //
    // Deliberately not an `UndoManager`. Two reasons, both load-bearing:
    //
    // * ⌘Z can never reach a private UndoManager in this app. The menu item targets First
    //   Responder, NSWindow supplies its own manager via
    //   `BaseTerminalController.windowWillReturnUndoManager`, and AppDelegate implements
    //   `undo(_:)` as a last resort — the app-wide manager always wins.
    // * Every inverse here is `async`. NSUndoManager only routes a registration onto the
    //   redo stack when it happens synchronously inside `undo()`, and an `await` always
    //   lands after that window has closed, so redo would silently never work.

    /// One reversible sidebar file operation.
    private struct FileHistoryStep {
        let name: String
        let apply: @MainActor (FileTreeModel) async -> Void
    }

    private var undoStack: [FileHistoryStep] = []
    /// True while replaying history, so an inverse operation does not push a new entry.
    private var isApplyingHistory = false

    private func pushHistory(
        named name: String,
        inverse: @escaping @MainActor (FileTreeModel) async -> Void
    ) {
        guard !isApplyingHistory else { return }
        undoStack.append(FileHistoryStep(name: name, apply: inverse))
        undoBannerAction = name
    }

    func undoLastOperation() async {
        guard !isApplyingHistory, let step = undoStack.popLast() else { return }
        isApplyingHistory = true
        await step.apply(self)
        isApplyingHistory = false
        undoBannerAction = undoStack.last?.name
    }

    // MARK: - Reads

    func children(of directory: URL) -> [FileEntry]? { childrenByDirectory[Self.key(directory)] }
    func isExpanded(_ directory: URL) -> Bool { expandedDirectories.contains(Self.key(directory)) }
    func isLoading(_ directory: URL) -> Bool { loadingDirectories.contains(Self.key(directory)) }
    func isEditing(_ url: URL) -> Bool { editingPath == Self.key(url) }

    func beginRename(_ url: URL) {
        errorMessage = nil
        editingPath = Self.key(url)
    }

    func cancelRename() { editingPath = nil }

    // MARK: - Expansion

    func setRoot(_ url: URL?) async {
        guard root.map(Self.key) != url.map(Self.key) else { return }
        root = url
        childrenByDirectory.removeAll()
        expandedDirectories.removeAll()
        loadingDirectories.removeAll()
        editingPath = nil
        errorMessage = nil
        undoStack.removeAll()
        undoBannerAction = nil
        guard let url else { return }
        await reload(directory: url)
    }

    func toggleExpansion(of directory: URL) async {
        let directoryKey = Self.key(directory)
        if expandedDirectories.contains(directoryKey) {
            expandedDirectories.remove(directoryKey)
            return
        }

        expandedDirectories.insert(directoryKey)
        guard childrenByDirectory[directoryKey] == nil else { return }
        await reload(directory: directory)
    }

    func expand(_ directory: URL) async {
        let directoryKey = Self.key(directory)
        expandedDirectories.insert(directoryKey)
        guard childrenByDirectory[directoryKey] == nil else { return }
        await reload(directory: directory)
    }

    /// Re-lists exactly one directory. Nothing above or beside it is touched, so every other
    /// expanded folder keeps both its expansion flag and its cached listing.
    func reload(directory: URL) async {
        let directoryKey = Self.key(directory)
        loadingDirectories.insert(directoryKey)
        defer { loadingDirectories.remove(directoryKey) }

        let entries = await FileSidebarScanner.children(of: directory)
        // A superseded listing must never clobber a newer one — same contract as the
        // sidebar's own root load.
        guard !Task.isCancelled else { return }

        let previous = childrenByDirectory[directoryKey] ?? []
        childrenByDirectory[directoryKey] = entries
        pruneCaches(removedFrom: previous, keeping: entries)
    }

    /// Drops cached listings and expansion flags for children that vanished from a fresh
    /// listing, plus everything beneath them. Purely in-memory: the new listing is already
    /// the source of truth, so no `fileExists` probe — and therefore no synchronous disk I/O
    /// on the main actor — is needed.
    private func pruneCaches(removedFrom previous: [FileEntry], keeping current: [FileEntry]) {
        let surviving = Set(current.map { Self.key($0.url) })
        let removed = previous.map { Self.key($0.url) }.filter { !surviving.contains($0) }
        guard !removed.isEmpty else { return }

        for goneKey in removed {
            let subtreePrefix = goneKey + "/"
            childrenByDirectory = childrenByDirectory.filter {
                $0.key != goneKey && !$0.key.hasPrefix(subtreePrefix)
            }
            expandedDirectories = expandedDirectories.filter {
                $0 != goneKey && !$0.hasPrefix(subtreePrefix)
            }
        }
    }

    /// Rewrites every cached key and entry URL that lived under `oldURL`, so renaming an
    /// *expanded* folder keeps its subtree open instead of collapsing it. Called before the
    /// parent reload so the new listing lands on already-correct keys.
    private func remapCaches(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.key(oldURL)
        let newKey = Self.key(newURL)
        let oldPrefix = oldKey + "/"

        func remapPath(_ path: String) -> String {
            if path == oldKey { return newKey }
            guard path.hasPrefix(oldPrefix) else { return path }
            return newKey + path.dropFirst(oldKey.count)
        }
        func remapURL(_ url: URL) -> URL {
            let path = Self.key(url)
            guard path == oldKey || path.hasPrefix(oldPrefix) else { return url }
            return URL(fileURLWithPath: remapPath(path))
        }

        childrenByDirectory = Dictionary(
            childrenByDirectory.map { key, value in
                (remapPath(key), value.map { FileEntry(url: remapURL($0.url), isDirectory: $0.isDirectory) })
            },
            uniquingKeysWith: { _, newest in newest })
        expandedDirectories = Set(expandedDirectories.map(remapPath))
        if let editingPath { self.editingPath = remapPath(editingPath) }
    }

    // MARK: - Mutations

    /// Runs a blocking filesystem mutation off the main actor and funnels any failure into
    /// `errorMessage`. Returns nil iff the body threw — every caller keys its follow-up work
    /// off that. The sidebar promises that no filesystem call blocks the main thread, so the
    /// work is always detached.
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async -> T? {
        do {
            let value = try await Task.detached(priority: .userInitiated) { try body() }.value
            errorMessage = nil
            return value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ url: URL, to newName: String) async {
        // Committing or abandoning an inline edit always closes the editor, whatever the
        // outcome — otherwise a no-op Return leaves the row stuck in edit mode.
        editingPath = nil

        let parent = url.deletingLastPathComponent()
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            errorMessage = "\"\(trimmed)\" isn't a valid name."
            return
        }

        let destination = parent.appendingPathComponent(trimmed)
        let sameNameDifferentCase = trimmed.lowercased() == url.lastPathComponent.lowercased()

        let moved = await perform {
            let manager = FileManager.default
            // A case-only rename on a case-insensitive volume looks like a collision with
            // itself, so it goes via a staging name instead of being rejected.
            if sameNameDifferentCase {
                let staging = parent.appendingPathComponent(".wisp-rename-\(UUID().uuidString)")
                try manager.moveItem(at: url, to: staging)
                try manager.moveItem(at: staging, to: destination)
                return true
            }
            if manager.fileExists(atPath: destination.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try manager.moveItem(at: url, to: destination)
            return true
        }
        guard moved == true else { return }

        remapCaches(from: url, to: destination)
        await reload(directory: parent)
        pushHistory(named: "Rename") { model in
            await model.rename(destination, to: url.lastPathComponent)
        }
    }

    func createFile(in directory: URL) async {
        await create(in: directory, baseName: "untitled.txt", isDirectory: false)
    }

    func createFolder(in directory: URL) async {
        await create(in: directory, baseName: "untitled folder", isDirectory: true)
    }

    private func create(in directory: URL, baseName: String, isDirectory: Bool) async {
        let destination = await perform { () -> URL in
            let manager = FileManager.default
            let target = Self.uniqueDestination(for: directory.appendingPathComponent(baseName))
            if isDirectory {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                guard manager.createFile(atPath: target.path, contents: Data()) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return target
        }
        guard let destination else { return }

        await expand(directory)
        await reload(directory: directory)
        // Open the inline editor straight away so the new item can be named in place, the
        // way Finder and VS Code both do.
        editingPath = Self.key(destination)
        pushHistory(named: isDirectory ? "New Folder" : "New File") { model in
            await model.moveToTrash(destination, isDirectory: isDirectory, confirmed: true)
        }
    }

    func duplicate(_ url: URL, isDirectory: Bool) async {
        let parent = url.deletingLastPathComponent()
        let destination = await perform { () -> URL in
            let target = Self.uniqueDestination(for: Self.copyName(for: url))
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }
        guard let destination else { return }

        await reload(directory: parent)
        pushHistory(named: "Duplicate") { model in
            await model.moveToTrash(destination, isDirectory: isDirectory, confirmed: true)
        }
    }

    /// Moves an item to the Trash. Never `removeItem`: everything the sidebar deletes has to
    /// stay recoverable from the Finder even after Wisp quits.
    ///
    /// `confirmed` is decided by the view, which owns the alert.
    func moveToTrash(_ url: URL, isDirectory: Bool, confirmed: Bool) async {
        guard confirmed else { return }
        let parent = url.deletingLastPathComponent()

        // `resultingItemURL` is what makes undo possible: it is where the item actually
        // landed inside the Trash, which is not derivable from the original path.
        let trashed = await perform { () -> URL in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            guard let landed = resulting as URL? else {
                // Documented as always populated on macOS, but undo depends on it, so a nil
                // is treated as a failure rather than silently costing the user their undo.
                throw CocoaError(.fileWriteUnknown)
            }
            return landed
        }
        guard let trashed else { return }

        await reload(directory: parent)
        pushHistory(named: "Move to Trash") { model in
            await model.restore(trashed, to: url)
        }
    }

    /// Puts an item back where it was before it went to the Trash. Deliberately ours rather
    /// than Finder's "Put Back", which only restores the first item of a multi-item delete.
    private func restore(_ trashed: URL, to original: URL) async {
        let parent = original.deletingLastPathComponent()
        let restored = await perform {
            try FileManager.default.moveItem(at: trashed, to: original)
            return true
        }
        guard restored == true else { return }
        await reload(directory: parent)
    }

    // MARK: - Naming helpers

    /// `name.txt` -> `name copy.txt`, matching Finder.
    private nonisolated static func copyName(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
        return parent.appendingPathComponent(name)
    }

    /// First free name in the `name`, `name 2`, `name 3`… series. Called inside a detached
    /// body, so the `fileExists` probes never touch the main thread.
    private nonisolated static func uniqueDestination(for proposed: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: proposed.path) else { return proposed }

        let parent = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let stem = proposed.deletingPathExtension().lastPathComponent
        for suffix in 2...999 {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent("\(stem)-\(UUID().uuidString)")
    }
}
