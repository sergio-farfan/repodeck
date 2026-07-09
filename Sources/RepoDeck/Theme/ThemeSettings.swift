import AppKit
import Observation
import RepoDeckKit
import SwiftUI

/// User-configurable appearance settings: color scheme, accent color, UI and
/// monospace font families, and base font size.
///
/// Persists every property to `UserDefaults.standard` (`@AppStorage` doesn't
/// work inside `@Observable` classes) — read in `init`, written on each
/// property's `didSet`.
@MainActor
@Observable
final class ThemeSettings {
    enum Appearance: String, CaseIterable {
        case system, light, dark

        /// `nil` lets SwiftUI/AppKit follow the system setting.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    private static let appearanceKey = "theme.appearance"
    private static let accentHexKey = "theme.accentHex"
    private static let uiFontKey = "theme.uiFont"
    private static let monoFontKey = "theme.monoFont"
    private static let fontSizeKey = "theme.fontSize"

    // Plain constants — `nonisolated` so they're usable from contexts (like
    // `Theme`'s environment default) that aren't already on the main actor.
    nonisolated static let defaultAccentHex = "#7a5cffff"
    nonisolated static let defaultFontSize: Double = 13
    nonisolated static let fontSizeRange: ClosedRange<Double> = 10...20

    /// Sensible violet used only if `accentHex` is somehow malformed (e.g.
    /// corrupted `UserDefaults`) — matches `defaultAccentHex` (#7a5cffff).
    private nonisolated static let fallbackAccent = Color(red: 0x7a / 255.0, green: 0x5c / 255.0, blue: 0xff / 255.0)

    var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    var accentHex: String {
        didSet {
            UserDefaults.standard.set(accentHex, forKey: Self.accentHexKey)
        }
    }

    /// `nil` means "use the system UI font".
    var uiFontName: String? {
        didSet {
            UserDefaults.standard.set(uiFontName, forKey: Self.uiFontKey)
        }
    }

    /// `nil` means "use the system monospaced font".
    var monoFontName: String? {
        didSet {
            UserDefaults.standard.set(monoFontName, forKey: Self.monoFontKey)
        }
    }

    /// Clamped to `fontSizeRange` on every write. Out-of-range assignments
    /// correct themselves by re-assigning inside `didSet` — that nested
    /// assignment's own `didSet` call is the one that persists, so this
    /// terminates after at most one correction (the corrected value is
    /// already in range, so the nested call's clamp is a no-op).
    var baseFontSize: Double {
        didSet {
            guard baseFontSize != oldValue else { return }
            let clamped = min(max(baseFontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            if clamped != baseFontSize {
                baseFontSize = clamped
                return
            }
            UserDefaults.standard.set(baseFontSize, forKey: Self.fontSizeKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        accentHex = defaults.string(forKey: Self.accentHexKey) ?? Self.defaultAccentHex
        uiFontName = defaults.string(forKey: Self.uiFontKey)
        monoFontName = defaults.string(forKey: Self.monoFontKey)

        let storedSize = defaults.object(forKey: Self.fontSizeKey) as? Double
        let requestedSize = storedSize ?? Self.defaultFontSize
        baseFontSize = min(max(requestedSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    /// `accentHex` resolved to a `Color`, falling back to a sensible violet
    /// if it's somehow malformed.
    var accent: Color {
        guard let decoded = ColorHex.decode(accentHex) else { return Self.fallbackAccent }
        return Color(red: decoded.red, green: decoded.green, blue: decoded.blue, opacity: decoded.alpha)
    }

    /// `ColorPicker` binding target. Reading resolves through `accent`;
    /// writing extracts sRGB components from the new `Color` via `NSColor`
    /// and re-encodes `accentHex` — `Color` itself exposes no direct RGBA
    /// component accessors.
    var accentColor: Color {
        get { accent }
        set {
            let nsColor = NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue)
            accentHex = ColorHex.encode(
                red: Double(nsColor.redComponent),
                green: Double(nsColor.greenComponent),
                blue: Double(nsColor.blueComponent),
                alpha: Double(nsColor.alphaComponent)
            )
        }
    }

    func resetToDefaults() {
        appearance = .system
        accentHex = Self.defaultAccentHex
        uiFontName = nil
        monoFontName = nil
        baseFontSize = Self.defaultFontSize
    }
}
