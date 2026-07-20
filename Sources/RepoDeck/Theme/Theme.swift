import SwiftUI

/// Resolved, immutable snapshot of the current theme — the accent color and
/// font values views render with. Rebuilt from `ThemeSettings` on every
/// change and injected via `\.theme` so views depend only on this
/// lightweight struct, not `ThemeSettings` itself.
///
/// Introduced by v1.1 Task 2; wiring it into existing leaf views is Task 3.
struct Theme {
    var accent: Color
    var baseSize: Double
    var uiFontName: String?
    var monoFontName: String?

    @MainActor
    init(settings: ThemeSettings) {
        accent = settings.accent
        baseSize = settings.baseFontSize
        uiFontName = settings.uiFontName
        monoFontName = settings.monoFontName
    }

    /// Direct-value initializer, used only for the environment's system
    /// default (see `ThemeKey` below) where there's no `ThemeSettings` yet.
    fileprivate init(accent: Color, baseSize: Double, uiFontName: String?, monoFontName: String?) {
        self.accent = accent
        self.baseSize = baseSize
        self.uiFontName = uiFontName
        self.monoFontName = monoFontName
    }

    /// Multiplier applied to every relative point size passed to `ui`/`mono`.
    private var scale: Double { baseSize / 13 }

    /// A UI-role font at `relativeToPointSize * scale`: `uiFontName` if set,
    /// else the system font. Custom fonts use `fixedSize` so the settings
    /// slider controls the rendered size, not Dynamic Type.
    func ui(_ relativeToPointSize: Double, weight: Font.Weight = .regular) -> Font {
        let size = relativeToPointSize * scale
        if let uiFontName {
            return .custom(uiFontName, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// A monospaced-role font at `relativeToPointSize * scale`: `monoFontName`
    /// if set, else the system monospaced font.
    func mono(_ relativeToPointSize: Double, weight: Font.Weight = .regular) -> Font {
        let size = relativeToPointSize * scale
        if let monoFontName {
            return .custom(monoFontName, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    // Convenience roles used by views (Task 3), mapped to point sizes then scaled.
    var body: Font { ui(13) }
    var callout: Font { ui(12) }
    var caption: Font { ui(11) }
    var caption2: Font { ui(10) }
    var title: Font { ui(15, weight: .semibold) }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(
        accent: Color(red: 0x7a / 255.0, green: 0x5c / 255.0, blue: 0xff / 255.0),
        baseSize: ThemeSettings.defaultFontSize,
        uiFontName: nil,
        monoFontName: nil
    )
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Theme {
    /// Flat sidebar pane color (ChatGPT-desktop look). Static + hardcoded on
    /// purpose — not a ThemeSettings knob; promote later if ever needed.
    static func sidebarBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x20 / 255.0, green: 0x21 / 255.0, blue: 0x23 / 255.0)  // #202123
            : Color(red: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEE / 255.0)  // #ECECEE
    }
}
