import SwiftUI

// MARK: - ThemePreview

/// A parsed terminal theme reduced to just the colors the gallery needs to draw a swatch.
/// `Sendable` so it can be produced off the main actor by ``ThemeCatalog`` and handed back.
struct ThemePreview: Identifiable, Hashable, Sendable {
    let name: String
    let background: Color
    let foreground: Color
    /// ANSI palette colors in index order (0...15). May be short if the theme omitted some.
    let palette: [Color]
    let isDark: Bool

    var id: String { name }
}

// MARK: - ThemeCatalog

/// Loads and parses the terminal themes bundled under `Contents/Resources/ghostty/themes`.
/// Each theme file is a flat `key = value` list (Ghostty config syntax); we read only the
/// color keys needed to render a preview. All work is pure file I/O + color math, so it is
/// safe to call from a background task.
enum ThemeCatalog {
    /// The bundled themes directory, or nil if it isn't present (e.g. running unbundled).
    static var themesDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    /// Reads and parses every theme file, sorted case-insensitively by name.
    static func loadAll() -> [ThemePreview] {
        guard let directory = themesDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }

        return names
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(name: name, contents: contents)
            }
    }

    /// Parses one theme file body. Returns nil only if it defines no background color.
    static func parse(name: String, contents: String) -> ThemePreview? {
        var background: OSColor?
        var foreground: OSColor?
        var palette: [Int: OSColor] = [:]

        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background": background = OSColor(hex: value)
            case "foreground": foreground = OSColor(hex: value)
            case "palette":
                // The value looks like "N=#rrggbb".
                guard let inner = value.firstIndex(of: "=") else { continue }
                let indexText = value[..<inner].trimmingCharacters(in: .whitespaces)
                let hexText = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexText), let color = OSColor(hex: hexText) {
                    palette[index] = color
                }
            default:
                break
            }
        }

        guard let background else { return nil }
        let resolvedForeground = foreground ?? (background.isLightColor ? .black : .white)
        let orderedPalette = (0..<16).compactMap { palette[$0] }.map { Color($0) }

        return ThemePreview(
            name: name,
            background: Color(background),
            foreground: Color(resolvedForeground),
            palette: orderedPalette,
            isDark: !background.isLightColor)
    }
}

// MARK: - ThemeGalleryView

/// A searchable grid of live-preview theme swatches. Selecting one sets `model.theme`, which
/// applies to every terminal window immediately (and persists) via ``SettingsModel``.
struct ThemeGalleryView: View {
    @ObservedObject var model: SettingsModel

    @State private var themes: [ThemePreview] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)]

    private var filtered: [ThemePreview] {
        guard !searchText.isEmpty else { return themes }
        return themes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            content
        }
        .task { await loadThemesIfNeeded() }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search \(themes.count) themes…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("Loading themes…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filtered) { theme in
                        ThemeSwatchCard(
                            theme: theme,
                            isSelected: theme.name == model.theme
                        ) {
                            // Tapping the active theme clears the override (back to config).
                            model.theme = (model.theme == theme.name) ? "" : theme.name
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    @MainActor
    private func loadThemesIfNeeded() async {
        guard themes.isEmpty else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            ThemeCatalog.loadAll()
        }.value
        themes = loaded
        isLoading = false
    }
}

// MARK: - ThemeSwatchCard

/// A single theme swatch: a miniature terminal rendered in the theme's own colors, with the
/// theme name and a selection check.
private struct ThemeSwatchCard: View {
    let theme: ThemePreview
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    /// ANSI colors used for the little swatch strip (red/green/yellow/blue/magenta/cyan).
    private var swatchColors: [Color] {
        let indices = [1, 2, 3, 4, 5, 6]
        let picked = indices.compactMap { theme.palette.indices.contains($0) ? theme.palette[$0] : nil }
        return picked.isEmpty ? [theme.foreground] : picked
    }

    /// Green from the palette makes a convincing shell prompt; fall back to the foreground.
    private var promptColor: Color {
        theme.palette.indices.contains(2) ? theme.palette[2] : theme.foreground
    }

    var body: some View {
        VStack(spacing: 8) {
            preview
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                }
                Text(theme.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16)
                      : (isHovered ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.background)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("wisp").foregroundStyle(promptColor)
                    Text("~").foregroundStyle(theme.foreground.opacity(0.7))
                    Text("%").foregroundStyle(theme.foreground.opacity(0.5))
                }
                Text("git status")
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 3) {
                    ForEach(Array(swatchColors.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 1)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
