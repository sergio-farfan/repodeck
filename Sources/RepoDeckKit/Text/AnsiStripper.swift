import Foundation

/// Removes ANSI/VT escape sequences from text so command output renders as
/// clean plain text (the command runner does not interpret colors). Mirrors
/// the ColorHex/BinarySniffer pure-namespace pattern.
public enum AnsiStripper {
    private static let esc: Unicode.Scalar = "\u{1B}"
    private static let bel: Unicode.Scalar = "\u{07}"
    private static let backslash: Unicode.Scalar = "\\"
    private static let csiFinalByteRange: ClosedRange<UInt32> = 0x40...0x7E

    /// Strips CSI sequences (ESC[ … final-byte), OSC sequences (ESC] … BEL or
    /// ESC\), and standalone ESC-prefixed sequences. Leaves normal text,
    /// including tabs and newlines, intact.
    public static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)

        var i = 0
        while i < scalars.count {
            guard scalars[i] == esc else {
                result.append(scalars[i])
                i += 1
                continue
            }

            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            switch next {
            case "[":
                i = skipCSI(scalars, from: i)
            case "]":
                i = skipOSC(scalars, from: i)
            case nil:
                // Trailing lone ESC with nothing after it.
                i += 1
            default:
                // Standalone ESC-prefixed sequence: ESC + one byte.
                i += 2
            }
        }

        return String(result)
    }

    /// Returns the index just past a CSI sequence starting at `start`
    /// (`start` points at the ESC). Scans past `ESC[` for a final byte in
    /// `0x40...0x7E`; if the sequence is truncated (no final byte before the
    /// end of the string), consumes through the end.
    private static func skipCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var j = start + 2 // past ESC and '['
        while j < scalars.count, !csiFinalByteRange.contains(scalars[j].value) {
            j += 1
        }
        return j < scalars.count ? j + 1 : j
    }

    /// Returns the index just past an OSC sequence starting at `start`
    /// (`start` points at the ESC). Scans past `ESC]` for a BEL or an
    /// ESC-backslash string terminator; if unterminated, consumes through
    /// the end of the string.
    private static func skipOSC(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var j = start + 2 // past ESC and ']'
        while j < scalars.count {
            if scalars[j] == bel {
                return j + 1
            }
            if scalars[j] == esc, j + 1 < scalars.count, scalars[j + 1] == backslash {
                return j + 2
            }
            j += 1
        }
        return j
    }
}
