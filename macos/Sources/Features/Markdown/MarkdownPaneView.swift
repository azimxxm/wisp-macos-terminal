import SwiftUI
import AppKit
import WebKit

/// Warp-style Markdown side pane: previews a `.md` file as rendered HTML and lets the
/// user edit its raw text in place. Owns its own disk I/O — the host window only needs
/// to present this view and react to `onClose`.
///
/// Rendering uses a small, self-contained CommonMark-subset converter (see
/// ``MarkdownRenderer`` below) instead of a third-party package, since `swift-markdown`
/// isn't available to this target.
struct MarkdownPaneView: View {
    let url: URL
    let onClose: () -> Void

    /// Which half of the pane is currently visible.
    private enum ViewMode: String, CaseIterable, Hashable {
        case rendered = "Rendered"
        case raw = "Raw"
    }

    /// Named layout constants for the header chrome (avoids magic numbers scattered
    /// through the view body below).
    private enum Layout {
        static let modeSwitcherWidth: CGFloat = 200
        static let modifiedDotSize: CGFloat = 6
        static let headerIconSize: CGFloat = 22
        static let headerIconCornerRadius: CGFloat = 5
        static let headerHorizontalPadding: CGFloat = 12
        static let headerVerticalPadding: CGFloat = 8
    }

    @State private var mode: ViewMode = .rendered
    /// The document's current text. This is the single source of truth for both the
    /// raw editor and the rendered preview — switching modes never re-reads the file,
    /// it just re-renders (or re-edits) whatever is already in memory.
    @State private var text = ""
    @State private var isModified = false
    /// Set when a load or save fails. Shown as a small inline banner; never crashes.
    @State private var ioErrorMessage: String?
    @State private var isSaveHovered = false
    @State private var isCloseHovered = false
    @State private var isFindHovered = false
    /// Bridges the header's Find button to the raw editor's native AppKit find/replace bar.
    @State private var findController = RawEditorFindController()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let ioErrorMessage {
                errorBanner(ioErrorMessage)
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .wispGlassPanel()
        .task(id: url) {
            // `.task(id:)` fires on first appearance and again whenever `url` changes,
            // cancelling any in-flight load from the previous file automatically.
            await load()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isModified {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: Layout.modifiedDotSize, height: Layout.modifiedDotSize)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            Picker("View mode", selection: $mode) {
                ForEach(ViewMode.allCases, id: \.self) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("View mode")
            .frame(width: Layout.modeSwitcherWidth)

            Spacer(minLength: 12)

            Button {
                showFindReplace()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .frame(width: Layout.headerIconSize, height: Layout.headerIconSize)
                    .background(
                        RoundedRectangle(cornerRadius: Layout.headerIconCornerRadius, style: .continuous)
                            .fill(isFindHovered ? Color.primary.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Find & Replace")
            .accessibilityLabel("Find and Replace")
            .onHover { isFindHovered = $0 }

            Button {
                save()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: Layout.headerIconSize, height: Layout.headerIconSize)
                    .background(
                        RoundedRectangle(cornerRadius: Layout.headerIconCornerRadius, style: .continuous)
                            .fill(isSaveHovered && isModified ? Color.primary.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isModified)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save (⌘S)")
            .accessibilityLabel("Save")
            .onHover { isSaveHovered = $0 }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: Layout.headerIconSize, height: Layout.headerIconSize)
                    .background(
                        RoundedRectangle(cornerRadius: Layout.headerIconCornerRadius, style: .continuous)
                            .fill(isCloseHovered ? Color.primary.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .onHover { isCloseHovered = $0 }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isModified)
        .padding(.horizontal, Layout.headerHorizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.headerHorizontalPadding)
        .padding(.vertical, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .rendered:
            // Re-rendered from the live `text` state every time this branch is drawn, so
            // it always reflects whatever was last typed in Raw mode.
            MarkdownHTMLView(html: MarkdownRenderer.renderHTML(from: text))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .raw:
            MarkdownRawEditor(text: $text, findController: findController) {
                isModified = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Shows the native find/replace bar over the raw editor. Switches to Raw mode first
    /// (find/replace only makes sense on editable text), deferring the call one runloop tick
    /// so the editor exists in the view hierarchy before we message it.
    private func showFindReplace() {
        if mode != .raw { mode = .raw }
        DispatchQueue.main.async {
            findController.showFindReplace()
        }
    }

    // MARK: File I/O

    @MainActor
    private func load() async {
        do {
            text = try await Self.readFile(at: url)
            isModified = false
            ioErrorMessage = nil
        } catch {
            ioErrorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @MainActor
    private func save() {
        let snapshot = text
        Task {
            do {
                try await Self.writeFile(snapshot, to: url)
                isModified = false
                ioErrorMessage = nil
            } catch {
                ioErrorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Reads are pushed onto a detached background task so a large file never blocks
    /// the main actor, even though `.md` notes are typically tiny.
    private static func readFile(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    private static func writeFile(_ contents: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }
}

// MARK: - MarkdownHTMLView

/// Renders a fully-formed, self-contained HTML document (see ``MarkdownRenderer``) inside
/// a `WKWebView`. Never loads remote content: `loadHTMLString` is always called with a
/// `nil` base URL, JavaScript execution is disabled, and any link click is intercepted so
/// it opens in the user's default browser instead of navigating the pane away.
private struct MarkdownHTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Guard against redundant reloads: SwiftUI calls `updateNSView` on every render
        // pass of the parent, not just when `html` actually changes, and reloading an
        // unchanged document would flash the page and reset scroll position.
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedHTML: String?

        /// Cancels any navigation triggered by clicking a link inside the rendered
        /// preview and opens it in the user's default browser instead — the preview
        /// itself must never navigate away from the markdown it was given.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - RawEditorFindController

/// Bridges the SwiftUI header's "Find & Replace" button to the AppKit find bar built into
/// the raw editor's `NSTextView`. Holds a weak reference to the live text view (set when the
/// editor is created) and triggers the standard text-finder actions on it.
final class RawEditorFindController {
    weak var textView: NSTextView?

    /// Shows the find bar in find-and-replace mode.
    func showFindReplace() {
        perform(.showReplaceInterface)
    }

    private func perform(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        // `performTextFinderAction(_:)` reads the requested action from the sender's tag.
        let sender = NSMenuItem()
        sender.tag = Int(action.rawValue)
        textView.performTextFinderAction(sender)
    }
}

// MARK: - MarkdownRawEditor

/// Editable monospaced raw-text view backed by `NSTextView`, wrapped in a scroll view.
/// Plain `NSTextView` (rather than SwiftUI's `TextEditor`) gives control over font,
/// smart-substitution behavior, and undo — all of which matter when editing source text
/// like Markdown, where curly quotes or auto-dashes would silently corrupt syntax.
private struct MarkdownRawEditor: NSViewRepresentable {
    @Binding var text: String
    let findController: RawEditorFindController
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.drawsBackground = false
        textView.textColor = .textColor

        // Native macOS find/replace bar (find field, replace field, match count, next/prev,
        // Replace / Replace All) — the same interface VS Code's find widget imitates.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        findController.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only push `text` into the view when it changed from *outside* an edit (e.g. a
        // fresh file load) — otherwise every keystroke would round-trip through SwiftUI
        // state and reset the cursor position.
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let onEdit: () -> Void

        init(text: Binding<String>, onEdit: @escaping () -> Void) {
            self.text = text
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            onEdit()
        }
    }
}

// MARK: - MarkdownRenderer

/// Converts a small, common subset of CommonMark (plus GitHub-Flavored tables) to a
/// complete, self-contained HTML document (inline `<style>`, no external resources, no
/// JavaScript). There is no dependency on `swift-markdown` or any other package — this is
/// a deliberately small, line-oriented parser covering headings, emphasis, code (inline +
/// fenced), lists, blockquotes, rules, links, GFM tables, and paragraphs. It is not a full
/// CommonMark implementation (no nested lists, no Setext headings, no reference-style
/// links) but is robust for everyday notes, READMEs, and agent docs like `CLAUDE.md`.
///
/// All text content is HTML-escaped before any markdown syntax is interpreted, so the
/// renderer is safe to point at an untrusted `.md` file: it can never inject a live
/// `<script>`, and link `href`s are scheme-checked (see `sanitizedHref`).
private enum MarkdownRenderer {
    static func renderHTML(from markdown: String) -> String {
        wrapDocument(body: renderBody(markdown))
    }

    // MARK: Block-level parsing

    /// Walks the document line by line. Each branch consumes one or more lines that make
    /// up a single block (a fenced code block, a run of list items, a paragraph, etc.)
    /// and advances `index` past them.
    private static func renderBody(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [String] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
            } else if trimmed.hasPrefix("```") {
                let (html, next) = consumeFencedCodeBlock(lines, from: index)
                blocks.append(html)
                index = next
            } else if isHorizontalRule(trimmed) {
                blocks.append("<hr>")
                index += 1
            } else if let heading = parseHeading(trimmed) {
                blocks.append(renderHeading(heading))
                index += 1
            } else if trimmed.hasPrefix(">") {
                let (html, next) = consumeBlockquote(lines, from: index)
                blocks.append(html)
                index = next
            } else if unorderedListItemText(trimmed) != nil {
                let (html, next) = consumeList(lines, from: index, ordered: false)
                blocks.append(html)
                index = next
            } else if orderedListItemText(trimmed) != nil {
                let (html, next) = consumeList(lines, from: index, ordered: true)
                blocks.append(html)
                index = next
            } else if isTableStart(lines, at: index) {
                let (html, next) = consumeTable(lines, from: index)
                blocks.append(html)
                index = next
            } else {
                let (html, next) = consumeParagraph(lines, from: index)
                blocks.append(html)
                index = next
            }
        }

        return blocks.joined(separator: "\n")
    }

    private static func renderHeading(_ heading: (level: Int, text: String)) -> String {
        let inline = renderInline(escapeHTML(heading.text))
        return "<h\(heading.level)>\(inline)</h\(heading.level)>"
    }

    private static func consumeFencedCodeBlock(_ lines: [String], from start: Int) -> (html: String, next: Int) {
        var index = start + 1
        var codeLines: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        let escaped = codeLines.map(escapeHTML).joined(separator: "\n")
        return ("<pre><code>\(escaped)</code></pre>", index)
    }

    private static func consumeBlockquote(_ lines: [String], from start: Int) -> (html: String, next: Int) {
        var index = start
        var quoteLines: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var stripped = String(trimmed.dropFirst())
            if stripped.hasPrefix(" ") { stripped.removeFirst() }
            quoteLines.append(stripped)
            index += 1
        }
        let inline = quoteLines.map { renderInline(escapeHTML($0)) }.joined(separator: "<br>")
        return ("<blockquote><p>\(inline)</p></blockquote>", index)
    }

    private static func consumeList(_ lines: [String], from start: Int, ordered: Bool) -> (html: String, next: Int) {
        var index = start
        var items: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let itemText = ordered ? orderedListItemText(trimmed) : unorderedListItemText(trimmed)
            guard let itemText else { break }
            items.append(itemText)
            index += 1
        }
        let itemsHTML = items.map { "<li>\(renderInline(escapeHTML($0)))</li>" }.joined()
        let tag = ordered ? "ol" : "ul"
        return ("<\(tag)>\(itemsHTML)</\(tag)>", index)
    }

    private static func consumeParagraph(_ lines: [String], from start: Int) -> (html: String, next: Int) {
        var index = start
        var paragraphLines: [String] = []
        while index < lines.count {
            // A GFM table can immediately follow a paragraph line with no blank line
            // between them; stop the paragraph here so the table parses as a table
            // rather than being swallowed as more paragraph text.
            if isTableStart(lines, at: index) { break }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard isParagraphContinuation(trimmed) else { break }
            paragraphLines.append(trimmed)
            index += 1
        }
        // A single newline inside a paragraph renders as a visible line break rather
        // than being collapsed into a space: for a live editor/preview pane, users
        // expect their line breaks to stay visible, unlike strict CommonMark reflow.
        let inline = paragraphLines.map { renderInline(escapeHTML($0)) }.joined(separator: "<br>")
        return ("<p>\(inline)</p>", index)
    }

    /// A line continues the current paragraph as long as it's non-blank and doesn't
    /// start a different kind of block (heading, quote, list, rule, or fence).
    private static func isParagraphContinuation(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") { return false }
        if isHorizontalRule(trimmed) { return false }
        if parseHeading(trimmed) != nil { return false }
        if unorderedListItemText(trimmed) != nil || orderedListItemText(trimmed) != nil { return false }
        return true
    }

    // MARK: Block matchers

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let characters = Set(trimmed)
        guard characters.count == 1, let marker = characters.first else { return false }
        return marker == "-" || marker == "*" || marker == "_"
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*#*\s*$"#) else { return nil }
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: full),
              let levelRange = Range(match.range(at: 1), in: trimmed),
              let textRange = Range(match.range(at: 2), in: trimmed)
        else { return nil }
        return (trimmed[levelRange].count, String(trimmed[textRange]))
    }

    private static func unorderedListItemText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedListItemText(_ trimmed: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^\d+[.)]\s+(.*)$"#) else { return nil }
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: full),
              let textRange = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[textRange])
    }

    // MARK: Tables (GFM)

    private enum ColumnAlignment {
        case none, left, center, right
    }

    /// A table starts where the current line is a pipe row *and* the next line is a
    /// delimiter row (`|---|:--:|`). Requiring the delimiter to contain a pipe keeps a
    /// Setext heading (`Title` / `-----`) from being misread as a single-column table.
    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let delimiter = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"), delimiter.contains("|") else { return false }
        return isTableDelimiterRow(delimiter)
    }

    /// True when every cell of `line` is a run of dashes with optional leading/trailing
    /// colons (the alignment markers) — i.e. the row that separates a table header from
    /// its body.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: #"^:?-+:?$"#) else { return false }
        return cells.allSatisfy { cell in
            let range = NSRange(cell.startIndex..., in: cell)
            return regex.firstMatch(in: cell, range: range) != nil
        }
    }

    private static func consumeTable(_ lines: [String], from start: Int) -> (html: String, next: Int) {
        let headerCells = splitTableRow(lines[start])
        let alignments = parseTableAlignments(lines[start + 1])
        let columnCount = headerCells.count

        var index = start + 2
        var bodyRows: [[String]] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            bodyRows.append(splitTableRow(lines[index]))
            index += 1
        }

        var html = "<table>\n<thead>\n<tr>"
        for (column, cell) in headerCells.enumerated() {
            html += "<th\(alignAttribute(alignments, at: column))>\(renderInline(escapeHTML(cell)))</th>"
        }
        html += "</tr>\n</thead>\n"

        if !bodyRows.isEmpty {
            html += "<tbody>\n"
            for row in bodyRows {
                html += "<tr>"
                // Pad short rows and drop overflowing cells so every body row matches the
                // header's column count — GFM treats missing trailing cells as empty.
                for column in 0..<columnCount {
                    let cell = column < row.count ? row[column] : ""
                    html += "<td\(alignAttribute(alignments, at: column))>\(renderInline(escapeHTML(cell)))</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        html += "</table>"
        return (html, index)
    }

    private static func parseTableAlignments(_ line: String) -> [ColumnAlignment] {
        splitTableRow(line).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return .none
            }
        }
    }

    private static func alignAttribute(_ alignments: [ColumnAlignment], at index: Int) -> String {
        guard index < alignments.count else { return "" }
        switch alignments[index] {
        case .none: return ""
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    /// Splits one table row into trimmed cell strings, dropping the optional outer pipes
    /// and honoring `\|` as a literal pipe inside a cell.
    private static func splitTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") && !content.hasSuffix("\\|") { content.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in content {
            if escaped {
                // Keep the backslash for anything except an escaped pipe, so other inline
                // escapes survive to the inline renderer untouched.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Inline rendering

    /// Applies inline formatting to text that has already been HTML-escaped. Code spans
    /// are protected first (highest precedence, matching CommonMark) so the bold/italic/
    /// link passes below never look inside them.
    private static func renderInline(_ escaped: String) -> String {
        let (protectedText, codeSpans) = extractCodeSpans(escaped)
        var result = protectedText
        result = replacing(result, pattern: #"\*\*(.+?)\*\*"#, template: "<strong>$1</strong>")
        result = replacing(result, pattern: #"__(.+?)__"#, template: "<strong>$1</strong>")
        // Italics require non-whitespace immediately inside the markers, so a stray
        // `* 3 * 4 *` (literal asterisks used as multiplication) doesn't get emphasized.
        result = replacing(result, pattern: #"\*([^\s*](?:[^*]*[^\s*])?)\*"#, template: "<em>$1</em>")
        result = replacing(result, pattern: #"\b_([^\s_](?:[^_]*[^\s_])?)_\b"#, template: "<em>$1</em>")
        result = applyLinks(result)
        return restoreCodeSpans(result, codeSpans)
    }

    /// Extracts `` `code` `` spans into an array and leaves a control-character
    /// placeholder (`\u{2}<index>\u{3}`) in their place — characters real markdown text
    /// will never contain, so restoring them later can't collide with user content.
    private static func extractCodeSpans(_ text: String) -> (text: String, spans: [String]) {
        guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return (text, []) }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return (text, []) }

        var spans: [String] = []
        var result = ""
        var lastEnd = 0
        for match in matches {
            guard match.range(at: 1).location != NSNotFound else { continue }
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            spans.append("<code>\(nsText.substring(with: match.range(at: 1)))</code>")
            result += "\u{2}\(spans.count - 1)\u{3}"
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastEnd)
        return (result, spans)
    }

    private static func restoreCodeSpans(_ text: String, _ spans: [String]) -> String {
        guard !spans.isEmpty else { return text }
        var result = text
        for (index, span) in spans.enumerated() {
            result = result.replacingOccurrences(of: "\u{2}\(index)\u{3}", with: span)
        }
        return result
    }

    /// Replaces `[text](href)` with an anchor tag. Handled separately from the other
    /// inline regexes because `href` needs scheme validation, which a plain
    /// template-based regex replace can't do.
    private static func applyLinks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^()\s]+)\)"#) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            guard match.range(at: 1).location != NSNotFound, match.range(at: 2).location != NSNotFound else { continue }
            let linkText = nsText.substring(with: match.range(at: 1))
            let rawHref = nsText.substring(with: match.range(at: 2))
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            if let href = sanitizedHref(rawHref) {
                result += "<a href=\"\(href)\">\(linkText)</a>"
            } else {
                // Unsafe/unsupported scheme (e.g. `javascript:`): fall back to the
                // original escaped text instead of silently dropping the content.
                result += nsText.substring(with: match.range)
            }
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// Only `http`, `https`, `mailto`, `file`, and scheme-less (relative/anchor) links
    /// are rendered as real `<a>` tags — this keeps a maliciously crafted `.md` file
    /// from producing a `javascript:` or similarly executable href.
    private static func sanitizedHref(_ raw: String) -> String? {
        let allowedSchemes: Set<String> = ["http", "https", "mailto", "file"]
        let attributeSafe = raw.replacingOccurrences(of: "\"", with: "&quot;")
        guard let scheme = URL(string: raw)?.scheme?.lowercased() else {
            // No scheme at all (e.g. "#section" or "./notes.md") — safe relative link.
            return attributeSafe
        }
        return allowedSchemes.contains(scheme) ? attributeSafe : nil
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func escapeHTML(_ text: String) -> String {
        // Order matters: `&` must be escaped first, otherwise the `&` introduced by the
        // `<`/`>` replacements below would themselves get escaped a second time.
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Document wrapper

    private static func wrapDocument(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// GitHub/Warp-like styling. `color-scheme` plus the `prefers-color-scheme` media
    /// query below give correct contrast in both light and dark without any Swift-side
    /// involvement — the page repaints itself when the system appearance changes.
    private static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        font-size: 14px;
        line-height: 1.65;
        padding: 20px 24px 40px;
        background-color: #ffffff;
        color: #1f2328;
        word-wrap: break-word;
    }
    h1, h2, h3, h4, h5, h6 {
        font-weight: 600;
        line-height: 1.3;
        margin: 1.4em 0 0.6em;
    }
    h1 { font-size: 1.75em; border-bottom: 1px solid rgba(31,35,40,0.12); padding-bottom: 0.3em; }
    h2 { font-size: 1.4em; border-bottom: 1px solid rgba(31,35,40,0.12); padding-bottom: 0.3em; }
    h3 { font-size: 1.2em; }
    h4 { font-size: 1.05em; }
    h5, h6 { font-size: 1em; color: #59636e; }
    p { margin: 0 0 1em; }
    a { color: #0969da; text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 600; }
    em { font-style: italic; }
    code {
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 0.9em;
        background-color: rgba(175, 184, 193, 0.2);
        padding: 0.15em 0.4em;
        border-radius: 4px;
    }
    pre {
        background-color: rgba(175, 184, 193, 0.15);
        border-radius: 8px;
        padding: 14px 16px;
        overflow-x: auto;
    }
    pre code { background-color: transparent; padding: 0; font-size: 0.88em; line-height: 1.5; }
    blockquote {
        margin: 0 0 1em;
        padding: 0.1em 1em;
        color: #59636e;
        border-left: 4px solid #d1d9e0;
    }
    blockquote p { margin: 0; }
    ul, ol { padding-left: 1.6em; margin: 0 0 1em; }
    li { margin: 0.25em 0; }
    hr { border: none; border-top: 1px solid rgba(31,35,40,0.16); margin: 1.6em 0; }
    table {
        display: block;
        width: max-content;
        max-width: 100%;
        overflow-x: auto;
        border-collapse: collapse;
        margin: 0 0 1em;
        font-size: 0.95em;
    }
    th, td { border: 1px solid #d1d9e0; padding: 6px 13px; }
    th { font-weight: 600; background-color: rgba(175, 184, 193, 0.16); }
    tbody tr:nth-child(2n) td { background-color: rgba(175, 184, 193, 0.08); }

    @media (prefers-color-scheme: dark) {
        body { background-color: #0d1117; color: #e6edf3; }
        h1, h2 { border-bottom-color: rgba(230,237,243,0.14); }
        h5, h6 { color: #9198a1; }
        a { color: #4493f8; }
        code { background-color: rgba(110,118,129,0.3); }
        pre { background-color: rgba(110,118,129,0.15); }
        blockquote { color: #9198a1; border-left-color: #3d444d; }
        hr { border-top-color: rgba(230,237,243,0.16); }
        th, td { border-color: #3d444d; }
        th { background-color: rgba(110, 118, 129, 0.18); }
        tbody tr:nth-child(2n) td { background-color: rgba(110, 118, 129, 0.08); }
    }
    """
}

// MARK: - Previews

struct MarkdownPaneView_Previews: PreviewProvider {
    static var previews: some View {
        MarkdownPaneView(url: previewFileURL, onClose: {})
            .frame(width: 420, height: 560)
    }

    /// Writes a small sample document to a scratch file so the preview has real content
    /// to render instead of an empty/error state. If the write fails, the pane itself
    /// still handles a missing file gracefully via its error banner.
    private static let previewFileURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownPaneView-Preview.md")
        let sample = """
        # Wisp Notes

        A **quick** look at what this pane can render, including `inline code`, a [link](https://ghostty.org), and:

        - Bullet one
        - Bullet two

        > Warp-style side panes are pretty handy.

        ```
        echo "fenced code block"
        ```
        """
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()
}
