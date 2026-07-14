import Foundation

/// Content-based binary detection mirroring git's own heuristic: data is
/// treated as binary when a NUL byte appears within its first 8000 bytes.
/// (UTF-16 text therefore classifies as binary — same call git makes.)
public enum BinarySniffer {
    public static let sniffLength = 8000

    public static func isLikelyBinary(_ data: Data) -> Bool {
        data.prefix(sniffLength).contains(0)
    }
}
