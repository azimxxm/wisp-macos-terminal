import SwiftUI
import AppKit

/// A rich "Welcome to Wisp" screen shown on first launch (and re-openable from
/// Help ▸ Welcome to Wisp). It introduces the terminal, the technology it is built on,
/// its features, and the author.
struct WispWelcomeView: View {
    /// Called when the user dismisses the screen ("Get Started" or the close button).
    var onDismiss: () -> Void = {}

    private var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Wisp accent — a soft luminous blue that reads well on both light and dark backgrounds.
    private let accent = Color(red: 0.42, green: 0.56, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                builtWithSection
                featuresSection
                authorSection
                getStartedButton
            }
            .padding(.horizontal, 46)
            .padding(.top, 42)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(width: 780, height: 720)
        .tint(accent)
        .background(WelcomeBackground().ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 100, height: 100)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            Text("Welcome to Wisp")
                .font(.system(size: 32, weight: .bold))

            Text("A fast, native macOS terminal that never freezes —\nbuilt as a rock-solid host for AI coding CLIs.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let version {
                Text("Version \(version) · Apple Silicon")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Built with

    private var builtWithSection: some View {
        WelcomeSection(title: "Built With", systemImage: "hammer.fill") {
            VStack(alignment: .leading, spacing: 14) {
                TechRow(symbol: "cpu", title: "Ghostty core (Zig)",
                        detail: "SIMD VT parser via the libghostty C ABI")
                TechRow(symbol: "square.stack.3d.up.fill", title: "Metal GPU renderer",
                        detail: "Native Apple Silicon acceleration")
                TechRow(symbol: "swift", title: "Swift · AppKit · SwiftUI",
                        detail: "Native macOS application layer")
                TechRow(symbol: "textformat", title: "CoreText",
                        detail: "Ligatures and high-quality glyph shaping")
            }
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        WelcomeSection(title: "Features", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "bolt.fill",
                           text: "Never-freeze under heavy AI streaming (1M–3M+ tokens)")
                FeatureRow(symbol: "slider.horizontal.3",
                           text: "Live Warp-style settings — opacity, blur, color, font, cursor, padding")
                FeatureRow(symbol: "sidebar.left",
                           text: "File sidebar with live search and drag-to-resize")
                FeatureRow(symbol: "doc.richtext",
                           text: "Markdown read/edit pane — GFM tables and Find & Replace")
                FeatureRow(symbol: "cursorarrow.click",
                           text: "Clickable file paths — ⌘-click terminal output to open")
                FeatureRow(symbol: "rectangle.split.2x1",
                           text: "Splits, tabs, and Liquid Glass (macOS 26)")
                FeatureRow(symbol: "paintpalette",
                           text: "Theme gallery with live visual previews")
            }
        }
    }

    // MARK: - Author

    private var authorSection: some View {
        WelcomeSection(title: "Author", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Azimjon Abdurasulov")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Coding Tech LLC")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    LinkChip(title: "Website", symbol: "globe",
                             url: "https://azimjondev.uz/")
                    LinkChip(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                             url: "https://github.com/azimxxm")
                    LinkChip(title: "LinkedIn", symbol: "briefcase.fill",
                             url: "https://linkedin.com/in/azimjon-abdurasulov")
                    LinkChip(title: "Instagram", symbol: "camera.fill",
                             url: "http://instagram.com/azimjondevuz")
                    LinkChip(title: "Telegram", symbol: "paperplane.fill",
                             url: "http://t.me/azimjondevuz")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var getStartedButton: some View {
        Button(action: onDismiss) {
            Text("Get Started")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .padding(.top, 4)
    }
}

// MARK: - Building blocks

/// A titled, material-backed card grouping related welcome content.
private struct WelcomeSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 18, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A two-line row: technology name + short detail, led by an accent-tinted symbol.
private struct TechRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A single feature bullet led by an accent-tinted symbol.
private struct FeatureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 16))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A capsule button linking to one of the author's profiles.
private struct LinkChip: View {
    let title: String
    let symbol: String
    let url: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let link = URL(string: url) else { return }
            openURL(link)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.vertical, 9)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(url)
    }
}

/// The Apple "About This Mac"-style translucent window background.
private struct WelcomeBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Window controller

/// Hosts ``WispWelcomeView`` in a borderless-titlebar window. Built programmatically (no xib)
/// and kept alive as a shared instance so it can be reopened from the Help menu.
final class WispWelcomeController: NSWindowController {
    static let shared = WispWelcomeController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: WispWelcomeView(onDismiss: { [weak window] in window?.performClose(nil) }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
