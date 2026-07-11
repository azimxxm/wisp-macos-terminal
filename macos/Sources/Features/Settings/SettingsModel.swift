import SwiftUI

/// Drives the "Appearance" settings UI and applies changes to the running Ghostty app
/// in real time the moment a value changes — there is no "Apply" or "Save" step.
///
/// Every property is seeded from whichever override the user chose in a previous session
/// (persisted in `UserDefaults`), falling back to the terminal's real, currently-active
/// configuration when there is no override yet. This means an untouched control always
/// reflects the terminal's actual current appearance instead of some arbitrary hardcoded
/// default, so re-applying it as part of a live override is always a no-op until the user
/// actually changes something.
///
/// This intentionally never writes to the user's on-disk `config` file. All changes are
/// applied through `Ghostty.App.applySettings(overrides:)`, which layers overrides on top
/// of the real configuration in memory only.
final class SettingsModel: ObservableObject {
    private enum DefaultsKey {
        static let backgroundOpacity = "Settings.Appearance.BackgroundOpacity"
        static let backgroundBlur = "Settings.Appearance.BackgroundBlur"
        static let backgroundColorHex = "Settings.Appearance.BackgroundColorHex"
        static let fontSize = "Settings.Appearance.FontSize"
        static let theme = "Settings.Appearance.Theme"
        static let cursorStyle = "Settings.Appearance.CursorStyle"
        static let cursorBlink = "Settings.Appearance.CursorBlink"
        static let windowPadding = "Settings.Appearance.WindowPadding"
    }

    /// Background opacity, 0 (fully transparent) ... 1 (fully opaque). Ghostty config key:
    /// `background-opacity`.
    @Published var backgroundOpacity: Double {
        didSet { settingDidChange() }
    }

    /// Background blur radius, in points. 0 disables blur. Only visible where the window is
    /// translucent (opacity < 1). Ghostty config key: `background-blur`. Together with a
    /// sub-1 opacity this gives Warp's frosted-glass look.
    @Published var backgroundBlur: Double {
        didSet { settingDidChange() }
    }

    /// Background color. Ghostty config key: `background`, serialized as `#RRGGBB`.
    @Published var backgroundColor: Color {
        didSet { settingDidChange() }
    }

    /// Font size, in points. Ghostty config key: `font-size`.
    @Published var fontSize: Double {
        didSet { settingDidChange() }
    }

    /// The color theme name, e.g. "Dracula" or "Builtin Dark". Ghostty config key:
    /// `theme`. Empty means "no override" — the terminal keeps using whatever its real
    /// configuration file specifies.
    @Published var theme: String {
        didSet { settingDidChange() }
    }

    /// Cursor shape: "block", "bar", or "underline". Ghostty config key: `cursor-style`.
    @Published var cursorStyle: String {
        didSet { settingDidChange() }
    }

    /// Whether the cursor blinks. Ghostty config key: `cursor-style-blink`.
    @Published var cursorBlink: Bool {
        didSet { settingDidChange() }
    }

    /// Uniform window padding, in points, applied to both axes. Ghostty config keys:
    /// `window-padding-x` / `window-padding-y`.
    @Published var windowPadding: Double {
        didSet { settingDidChange() }
    }

    /// The Ghostty app we apply live changes to. Weak because `AppDelegate` (which owns
    /// both `ghostty` and this model) outlives us and we must never extend its lifetime.
    private weak var ghostty: Ghostty.App?

    /// Guards against firing side effects (persisting + applying) while we're still
    /// hydrating our initial state from UserDefaults/the live config below.
    private var isHydrating = true

    init(ghostty: Ghostty.App?) {
        self.ghostty = ghostty

        let defaults = UserDefaults.ghostty
        let liveConfig = ghostty?.config

        backgroundOpacity = defaults.object(forKey: DefaultsKey.backgroundOpacity) as? Double
            ?? liveConfig?.backgroundOpacity
            ?? 1.0

        backgroundBlur = defaults.object(forKey: DefaultsKey.backgroundBlur) as? Double
            ?? liveConfig?.backgroundBlurRadius
            ?? 0

        if let hex = defaults.string(forKey: DefaultsKey.backgroundColorHex),
           let color = OSColor(hex: hex) {
            backgroundColor = Color(color)
        } else {
            backgroundColor = liveConfig?.backgroundColor ?? Color(NSColor.windowBackgroundColor)
        }

        fontSize = defaults.object(forKey: DefaultsKey.fontSize) as? Double
            ?? liveConfig?.fontSize
            ?? 13

        theme = defaults.string(forKey: DefaultsKey.theme) ?? ""

        cursorStyle = defaults.string(forKey: DefaultsKey.cursorStyle) ?? "block"
        cursorBlink = defaults.object(forKey: DefaultsKey.cursorBlink) as? Bool ?? true
        windowPadding = defaults.object(forKey: DefaultsKey.windowPadding) as? Double ?? 2

        isHydrating = false
    }

    /// Applies every currently-stored setting live. Call this once at launch so overrides
    /// from a previous session take effect immediately instead of waiting for the user to
    /// open the Settings window and nudge a control.
    func applyAll() {
        apply()
    }

    private func settingDidChange() {
        guard !isHydrating else { return }
        persist()
        apply()
    }

    private func persist() {
        let defaults = UserDefaults.ghostty
        defaults.set(backgroundOpacity, forKey: DefaultsKey.backgroundOpacity)
        defaults.set(backgroundBlur, forKey: DefaultsKey.backgroundBlur)
        defaults.set(OSColor(backgroundColor).hexString, forKey: DefaultsKey.backgroundColorHex)
        defaults.set(fontSize, forKey: DefaultsKey.fontSize)
        defaults.set(theme, forKey: DefaultsKey.theme)
        defaults.set(cursorStyle, forKey: DefaultsKey.cursorStyle)
        defaults.set(cursorBlink, forKey: DefaultsKey.cursorBlink)
        defaults.set(windowPadding, forKey: DefaultsKey.windowPadding)
    }

    private func apply() {
        var overrides: [String: String] = [
            "background-opacity": String(format: "%.2f", backgroundOpacity),
            "background-blur": String(Int(backgroundBlur.rounded())),
            "font-size": String(format: "%.0f", fontSize),
            "cursor-style": cursorStyle,
            "cursor-style-blink": cursorBlink ? "true" : "false",
            "window-padding-x": String(Int(windowPadding.rounded())),
            "window-padding-y": String(Int(windowPadding.rounded())),
        ]

        if let hex = OSColor(backgroundColor).hexString {
            overrides["background"] = hex
        }

        let trimmedTheme = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTheme.isEmpty {
            overrides["theme"] = trimmedTheme
        }

        ghostty?.applySettings(overrides: overrides)
    }
}
