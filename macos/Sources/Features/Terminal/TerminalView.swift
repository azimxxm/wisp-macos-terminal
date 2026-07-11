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

    /// User-adjustable width of the file sidebar (dragged via the divider, persisted).
    @AppStorage("com.azimxxm.wisp.sidebarWidth") private var sidebarWidth: Double = 260

    /// Allowed sidebar width range. Computed (not stored) because `TerminalView` is generic
    /// and Swift forbids static stored properties in generic types.
    private static var sidebarWidthRange: ClosedRange<CGFloat> { 180...600 }

    /// The persisted sidebar width, clamped into the allowed range so a stale/out-of-range
    /// stored value can never produce a broken layout.
    private var clampedSidebarWidth: CGFloat {
        min(max(CGFloat(sidebarWidth), Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
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

    /// Extensions opened in the in-window Markdown/text pane. Anything else (images,
    /// binaries, …) is revealed in Finder instead.
    private static var paneTextExtensions: Set<String> {
        [
            "md", "markdown", "txt", "text", "swift", "js", "jsx", "ts", "tsx", "json",
            "yaml", "yml", "toml", "sh", "zsh", "bash", "py", "go", "rs", "c", "h", "cpp",
            "cc", "hpp", "m", "mm", "css", "scss", "html", "xml", "zig", "conf", "cfg",
            "ini", "log", "rb", "java", "kt", "gradle", "lua", "php", "sql", "env",
        ]
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

        let ext = url.pathExtension.lowercased()
        if ext.isEmpty || Self.paneTextExtensions.contains(ext) {
            openMarkdownURL = url
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
                            cwd: pwdURL,
                            onCollapse: { withAnimation(.easeInOut(duration: 0.15)) { showSidebar = false } }
                        ) { openInPane($0) }
                            .frame(width: clampedSidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        SidebarResizeHandle(
                            width: Binding(
                                get: { clampedSidebarWidth },
                                set: { sidebarWidth = Double($0) }),
                            range: Self.sidebarWidthRange)
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
                            .onAppear { self.focused = true }
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
                            }
                            .onChange(of: cellSize) { newValue in
                                guard let size = newValue else { return }
                                self.delegate?.cellSizeDidChange(to: size)
                            }
                            .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                                   idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                    }
                    // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                    .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

                    // Warp-style Markdown read/edit pane (opened from the sidebar).
                    if let url = openMarkdownURL {
                        Divider()
                        MarkdownPaneView(url: url) { openMarkdownURL = nil }
                            .frame(minWidth: 320, idealWidth: 480, maxWidth: 760)
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
            .onReceive(NotificationCenter.default.publisher(for: .wispOpenPath)) { note in
                // Only the window whose focused surface fired this should open the file, so
                // a ⌘-click in one window doesn't pop a pane in every other window too.
                guard let posted = note.object as? Ghostty.SurfaceView,
                      posted === lastFocusedSurface?.value,
                      let url = note.userInfo?[wispOpenPathURLKey] as? URL else { return }
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
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = base }
                                width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStartWidth = nil })
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
