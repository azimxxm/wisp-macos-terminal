import SwiftUI

/// The main Settings window content. Structured as a sidebar + detail split so more
/// sections (e.g. "Keybindings", "Shell Integration") can be added later without
/// reworking the navigation.
struct SettingsView: View {
    @StateObject private var model: SettingsModel
    @State private var selectedSection: SettingsSection? = .appearance

    init(ghostty: Ghostty.App?) {
        _model = StateObject(wrappedValue: SettingsModel(ghostty: ghostty))
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                SettingsSidebarRow(section: section)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch selectedSection ?? .appearance {
                case .appearance:
                    // A grouped Form scrolls itself on macOS — an outer ScrollView would flatten
                    // the inset-grouped "cards" that give it the System Settings look.
                    AppearanceSettingsView(model: model)
                case .themes:
                    // The gallery manages its own scrolling + pinned search field.
                    ThemeGalleryView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
        }
        .frame(minWidth: 700, idealWidth: 740, minHeight: 480, idealHeight: 560)
        .navigationTitle("Wisp Settings")
    }
}

/// A System Settings-style sidebar row: the section's SF Symbol in a tinted rounded square,
/// followed by its title.
private struct SettingsSidebarRow: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(section.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(section.title)
                .font(.system(size: 13))
        }
        .padding(.vertical, 2)
    }
}

/// The sections available in the sidebar. Add new cases here as more settings ship.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case themes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .themes: return "Themes"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .themes: return "paintpalette.fill"
        }
    }

    /// Tint for the sidebar icon square (System Settings signature look).
    var tint: Color {
        switch self {
        case .appearance: return .blue
        case .themes: return .pink
        }
    }
}

/// The "Appearance" settings pane. Every control here applies to every live terminal
/// window the moment it changes — there is no separate "Apply" or "Save" step, and
/// nothing here is ever written to the user's configuration file.
private struct AppearanceSettingsView: View {
    @ObservedObject var model: SettingsModel

    private static let fontSizeRange: ClosedRange<Double> = 8...32
    /// Blur radius range. 0 = off; ~60 matches Warp's default frosted-glass look.
    private static let blurRange: ClosedRange<Double> = 0...100
    /// Window padding range, in points, applied uniformly to both axes.
    private static let paddingRange: ClosedRange<Double> = 0...40
    private static let presetThemes = [
        "Builtin Dark", "Builtin Light", "Dracula", "Nord",
        "Gruvbox Dark", "Gruvbox Light", "Catppuccin Mocha", "Solarized Dark",
    ]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Background Opacity")
                        Spacer()
                        Text(model.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.backgroundOpacity, in: 0...1) {
                        Text("Background Opacity")
                    }
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Background Blur")
                        Spacer()
                        Text("\(Int(model.backgroundBlur))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.backgroundBlur, in: Self.blurRange, step: 1) {
                        Text("Background Blur")
                    }
                    .labelsHidden()
                }
                .accessibilityElement(children: .combine)

                ColorPicker("Background Color", selection: $model.backgroundColor, supportsOpacity: false)

                Stepper(value: $model.fontSize, in: Self.fontSizeRange, step: 1) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(model.fontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Menu("Presets") {
                            ForEach(Self.presetThemes, id: \.self) { name in
                                Button(name) { model.theme = name }
                            }
                        }
                        .fixedSize()
                    }
                    TextField("Inherit from configuration file", text: $model.theme)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Theme name override")
                }
            } header: {
                Text("Live Preview")
            } footer: {
                Text(
                    "Changes here apply to every terminal window immediately and are " +
                    "remembered across launches. They never modify your configuration file."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Cursor Style", selection: $model.cursorStyle) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)

                Toggle("Blinking Cursor", isOn: $model.cursorBlink)

                Stepper(value: $model.windowPadding, in: Self.paddingRange, step: 1) {
                    HStack {
                        Text("Window Padding")
                        Spacer()
                        Text("\(Int(model.windowPadding)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Cursor & Window")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(ghostty: nil)
    }
}
