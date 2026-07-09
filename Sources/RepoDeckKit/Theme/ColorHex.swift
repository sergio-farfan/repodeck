import Foundation

/// Hex-string codec for RGBA color components, used to persist the app's
/// accent color to `UserDefaults` (which can't store `Color`/`NSColor`
/// directly).
public enum ColorHex {
    /// Encodes RGBA components (each `0...1`) as a lowercase `"#RRGGBBAA"`
    /// string. Out-of-range inputs are clamped before conversion.
    public static func encode(red: Double, green: Double, blue: Double, alpha: Double) -> String {
        "#\(byteHex(red))\(byteHex(green))\(byteHex(blue))\(byteHex(alpha))"
    }

    /// Decodes `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (leading `#` optional,
    /// case-insensitive) into RGBA components (each `0...1`). `#RGB`/`#RRGGBB`
    /// default alpha to `1.0`. Returns `nil` for anything else — wrong
    /// length, empty, or containing non-hex-digit characters.
    public static func decode(_ string: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }

        switch digits.count {
        case 3:
            let chars = Array(digits)
            guard let r = component(String(repeating: chars[0], count: 2)),
                let g = component(String(repeating: chars[1], count: 2)),
                let b = component(String(repeating: chars[2], count: 2))
            else { return nil }
            return (r, g, b, 1.0)

        case 6:
            let chars = Array(digits)
            guard let r = component(String(chars[0...1])),
                let g = component(String(chars[2...3])),
                let b = component(String(chars[4...5]))
            else { return nil }
            return (r, g, b, 1.0)

        case 8:
            let chars = Array(digits)
            guard let r = component(String(chars[0...1])),
                let g = component(String(chars[2...3])),
                let b = component(String(chars[4...5])),
                let a = component(String(chars[6...7]))
            else { return nil }
            return (r, g, b, a)

        default:
            return nil
        }
    }

    /// Converts a `0...1` component to its two-digit lowercase hex byte.
    private static func byteHex(_ value: Double) -> String {
        let clamped = max(0, min(1, value))
        let byte = Int((clamped * 255).rounded())
        return String(format: "%02x", byte)
    }

    /// Parses a two-hex-digit string into a `0...1` component.
    private static func component(_ twoDigitHex: String) -> Double? {
        guard let byte = Int(twoDigitHex, radix: 16) else { return nil }
        return Double(byte) / 255.0
    }
}
