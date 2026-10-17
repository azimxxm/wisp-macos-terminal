import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    /// Warp-style file sidebar visibility (toggled from View ▸ Toggle File Sidebar / ⌘⌥B).
    @State private var showSidebar = false

    /// The file currently open in the Markdown read/edit pane, if any.
    @State private var openMarkdownURL: URL?

    /// User-adjustable width of the markdown preview/edit pane (dragged via the divider, persisted).
    @AppStorage("com.azimxxm.wisp.markdownPaneWidth") private var markdownPaneWidth: Double = 480

    /// Allowed markdown pane width range.
    private static var markdownPaneWidthRange: ClosedRange<CGFloat> { 320...960 }

    /// Clamped persisted markdown pane width.
    private var clampedMarkdownPaneWidth: CGFloat {
        min(max(CGFloat(markdownPaneWidth), Self.markdownPaneWidthRange.lowerBound), Self.markdownPaneWidthRange.upperBound)
    }

    /// Live width while the markdown pane divider is being dragged.
    @State private var liveMarkdownPaneWidth: CGFloat?

    /// Width the markdown pane actually renders at.
    private var effectiveMarkdownPaneWidth: CGFloat {
        liveMarkdownPaneWidth ?? clampedMarkdownPaneWidth
    }

    /// The most recent non-empty working directory. The sidebar reads this instead of the live
    /// focused pwd so that clicking into the sidebar's search field — which moves focus off the
    /// terminal and makes the focused `pwd` go nil — does not blank the file list.
    @State private var lastKnownPwd: URL?

    /// User-adjustable width of the file sidebar (dragged via the divider, persisted).
    @AppStorage("com.azimxxm.wisp.sidebarWidth") private var sidebarWidth: Double = 260

    /// Warp-style git status bar visibility. It only renders when the cwd is a repo; this lets the
    /// user hide it even then (toggled via the titlebar branch button / View ▸ Toggle Git Bar / ⌘⌥G).
    @AppStorage("com.azimxxm.wisp.showGitBar") private var showGitBar = true

    /// Reads the focused terminal's working directory and publishes its git state for the bottom bar.
    @StateObject private var gitMonitor = GitRepositoryMonitor()

    /// Allowed sidebar width range. Computed (not stored) because `TerminalView` is generic
    /// and Swift forbids static stored properties in generic types.
    private static var sidebarWidthRange: ClosedRange<CGFloat> { 180...600 }

    /// The persisted sidebar width, clamped into the allowed range so a stale/out-of-range
    /// stored value can never produce a broken layout.
    private var clampedSidebarWidth: CGFloat {
        min(max(CGFloat(sidebarWidth), Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
    }

    /// Live width while the divider is being dragged. Kept in memory (not `@AppStorage`) so a
    /// drag updates only the layout and never touches UserDefaults per frame; the final value is
    /// persisted once on drag end. `nil` whenever no drag is in progress.
    @State private var liveSidebarWidth: CGFloat?

    /// Width the sidebar actually renders at: the live drag value while dragging, otherwise the
    /// persisted (clamped) value.
    private var effectiveSidebarWidth: CGFloat {
        liveSidebarWidth ?? clampedSidebarWidth
    }

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    /// Opens a file picked in the sidebar or ⌘-clicked in the terminal: directories reveal
    /// in Finder; text-like files (and extension-less files such as LICENSE/Makefile) go to
    /// the Markdown pane; everything else reveals in Finder.
    private func openInPane(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        if TerminalFilePath.isTextOrMarkdownFile(url: url) {
            openMarkdownURL = url
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Types a git command into the focused terminal (run via a trailing return) so it executes in
    /// the user's own shell, then schedules a status refresh once it has had a moment to run.
    private func runGitCommand(_ command: String) {
        guard let surface = lastFocusedSurface?.value else { return }
        surface.surfaceModel?.sendText(command + "\r")
        gitMonitor.refreshSoon()
    }

    /// Types a filesystem path picked in the sidebar into the focused terminal at the cursor
    /// and stops there — no return is sent, so the user still composes the command around it.
    /// Paths living under the current working directory go in relative to it (shorter, and
    /// what a person would actually have typed); anything else goes in absolute.
    ///
    /// Escaping goes through `Ghostty.Shell.escape`, the same escaper the Finder-drag drop
    /// path uses in `NSPasteboard.getOpinionatedStringContents()`, so a row that is dragged
    /// onto the surface and a row that is ⌥-clicked are escaped identically.
    private func insertPathInTerminal(_ url: URL) {
        guard let surfaceView = lastFocusedSurface?.value ?? focusedSurface else { return }

        let path = Self.terminalPath(for: url, relativeTo: lastKnownPwd ?? pwdURL)
        surfaceView.surfaceModel?.sendText(Ghostty.Shell.escape(path) + " ")

        // Text sent to a surface that isn't first responder lands correctly but leaves the
        // caret in the sidebar, so the next keystroke would go to the filter field. Same
        // restore trick — and same reason it has to be deferred — as the command palette:
        // we're on a user-interactive thread here and AppKit wants this on the main queue.
        DispatchQueue.main.async {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    /// The literal text to type for `url`: relative to `base` when it sits underneath it,
    /// absolute otherwise.
    ///
    /// A relative path starting with `-` or `~` gets an explicit `./` prefix.
    /// `Ghostty.Shell.escape` escapes `\ ()[]{}<>"'`!#$&;|*?` and tab but deliberately not
    /// those two, so without the prefix the shell would read the path as an option flag or
    /// as a home-directory expansion.
    private static func terminalPath(for url: URL, relativeTo base: URL?) -> String {
        let absolute = url.standardizedFileURL.path
        guard let base else { return absolute }

        // A cwd of "/" would make the prefix test "//" and isn't worth relativizing anyway.
        let basePath = base.standardizedFileURL.path
        guard basePath != "/", absolute.hasPrefix(basePath + "/") else { return absolute }

        let relative = String(absolute.dropFirst(basePath.count + 1))
        guard !relative.isEmpty else { return absolute }
        guard relative.hasPrefix("-") || relative.hasPrefix("~") else { return relative }
        return "./" + relative
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                HStack(spacing: 0) {
                    // Warp-style file-explorer sidebar for the focused terminal's cwd.
                    if showSidebar {
                        FileSidebarView(
                            cwd: lastKnownPwd ?? pwdURL,
                            onOpenFile: { openInPane($0) },
                            onInsertPath: { insertPathInTerminal($0) })
                            .frame(width: effectiveSidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        SidebarResizeHandle(
                            width: Binding(
                                get: { effectiveSidebarWidth },
                                set: { liveSidebarWidth = $0 }),
                            range: Self.sidebarWidthRange,
                            onCommit: {
                                if let dragged = liveSidebarWidth { sidebarWidth = Double(dragged) }
                                liveSidebarWidth = nil
                            })
                    }

                    VStack(spacing: 0) {
                        // If we're running in debug mode we show a warning so that users
                        // know that performance will be degraded.
                        if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                            DebugBuildWarningView()
                        }

                        TerminalSplitTreeView(
                            tree: viewModel.surfaceTree,
                            action: { delegate?.performSplitAction($0) })
                            .environmentObject(ghostty)
                            .ghosttyLastFocusedSurface(lastFocusedSurface)
                            .focused($focused)
                            .onAppear {
                                self.focused = true
                                // Seed the sidebar cwd with the initial pwd (single-param onChange
                                // above doesn't fire for the initial value on our deploy target).
                                if lastKnownPwd == nil { lastKnownPwd = pwdURL }
                                gitMonitor.activate(cwd: pwdURL)
                            }
                            .onChange(of: focusedSurface) { newValue in
                                // We want to keep track of our last focused surface so even if
                                // we lose focus we keep this set to the last non-nil value.
                                if newValue != nil {
                                    lastFocusedSurface = .init(newValue)
                                    self.delegate?.focusedSurfaceDidChange(to: newValue)
                                }
                            }
                            .onChange(of: pwdURL) { newValue in
                                self.delegate?.pwdDidChange(to: newValue)
                                // Remember the last real cwd so focus leaving the terminal (e.g.
                                // clicking the sidebar search field, which nils the focused pwd)
                                // doesn't blank the file list.
                                if let newValue { lastKnownPwd = newValue }
                                // Drive the git bar off the same stable cwd; a nil pwd (focus left the
                                // terminal) keeps the last repo instead of clearing it.
                                gitMonitor.activate(cwd: newValue ?? lastKnownPwd)
                            }
                            .onChange(of: cellSize) { newValue in
                                guard let size = newValue else { return }
                                self.delegate?.cellSizeDidChange(to: size)
                            }
                            .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                                   idealHeight: lastFocusedSurface?.value?.initialSize?.height)

                        // Warp-style git status bar, shown at the bottom of the terminal column
                        // whenever the focused cwd is a git repo.
                        if showGitBar, let gitStatus = gitMonitor.status {
                            GitStatusBarView(
                                status: gitStatus,
                                run: runGitCommand,
                                onRefresh: { gitMonitor.refresh(force: true) },
                                onHide: { showGitBar = false }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                    .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

                    // Warp-style Markdown read/edit pane (opened from the sidebar or terminal link).
                    if let url = openMarkdownURL {
                        SidebarResizeHandle(
                            width: Binding(
                                get: { effectiveMarkdownPaneWidth },
                                set: { liveMarkdownPaneWidth = $0 }
                            ),
                            range: Self.markdownPaneWidthRange,
                            isTrailing: true,
                            onCommit: {
                                if let live = liveMarkdownPaneWidth {
                                    markdownPaneWidth = Double(live)
                                    liveMarkdownPaneWidth = nil
                                }
                            }
                        )
                        MarkdownPaneView(url: url) { openMarkdownURL = nil }
                            .frame(width: effectiveMarkdownPaneWidth)
                    }
                }

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
            .onReceive(NotificationCenter.default.publisher(for: .wispToggleFileSidebar)) { _ in
                withAnimation(.easeInOut(duration: 0.15)) { showSidebar.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .wispToggleGitBar)) { _ in
                withAnimation(.easeInOut(duration: 0.15)) { showGitBar.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .wispOpenPath)) { note in
                // Only the window whose focused surface fired this should open the file
                if let posted = note.object as? Ghostty.SurfaceView {
                    guard posted === lastFocusedSurface?.value || posted === focusedSurface || lastFocusedSurface == nil else { return }
                }
                guard let url = note.userInfo?[wispOpenPathURLKey] as? URL else { return }
                openInPane(url)
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the View ▸ Toggle File Sidebar menu item to show/hide the file sidebar.
    static let wispToggleFileSidebar = Notification.Name("com.azimxxm.wisp.toggleFileSidebar")
}

/// A thin, draggable divider between the sidebar and the terminal that lets the user resize
/// the sidebar (VS Code / Warp-style). The visible line stays 1pt wide; a wider transparent
/// hit area makes it easy to grab, and the cursor becomes a horizontal resize arrow on hover.
private struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var isTrailing: Bool = false

    /// Called once when the drag ends so the caller can persist the final width, instead of
    /// writing it on every frame.
    var onCommit: () -> Void = {}

    /// Width at the moment the drag began, so the delta is applied to a stable base instead
    /// of accumulating across `onChanged` callbacks.
    @State private var dragStartWidth: CGFloat?

    private static let hitWidth: CGFloat = 10

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: Self.hitWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // `.global` coordinate space is essential here: the handle lives in the HStack
                    // and is pushed sideways as the sidebar it controls grows/shrinks. In the
                    // default `.local` space that motion corrupts `translation` every frame, so the
                    // width oscillates and the UI flickers. Global space is a stable reference.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = base }
                                let delta = isTrailing ? -value.translation.width : value.translation.width
                                width = min(max(base + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                onCommit()
                            })
            )
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Wisp! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Wisp are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Wisp are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
