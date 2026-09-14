import Foundation

/// Git's C-style quoting is independent of core.quotepath for control characters.
enum GitPathCodec {
    static func decode(_ value: String) -> String? {
        guard value.hasPrefix("\"") else { return value }
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes.last == 34 else { return nil }
        var result: [UInt8] = []
        var index = 1
        while index < bytes.count - 1 {
            let byte = bytes[index]
            index += 1
            guard byte != 34 else { return nil }
            guard byte == 92 else { result.append(byte); continue }
            guard index < bytes.count - 1 else { return nil }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case 34, 92: result.append(escaped)
            case 97: result.append(7)
            case 98: result.append(8)
            case 116: result.append(9)
            case 110: result.append(10)
            case 118: result.append(11)
            case 102: result.append(12)
            case 114: result.append(13)
            case 48...55:
                var number = Int(escaped - 48)
                var digits = 1
                while digits < 3, index < bytes.count - 1, (48...55).contains(bytes[index]) {
                    number = number * 8 + Int(bytes[index] - 48)
                    index += 1
                    digits += 1
                }
                guard number <= 255 else { return nil }
                result.append(UInt8(number))
            default: return nil
            }
        }
        return String(bytes: result, encoding: .utf8)
    }

    static func encode(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.contains(where: { $0 <= 32 || $0 == 34 || $0 == 92 || $0 == 127 }) else { return path }
        // Build from bytes to avoid re-encoding each byte of a non-ASCII name.
        var encoded: [UInt8] = [34]
        for byte in bytes {
            switch byte {
            case 34: encoded += [92, 34]
            case 92: encoded += [92, 92]
            case 0...31, 127: encoded += Array(String(format: "\\%03o", byte).utf8)
            default: encoded.append(byte)
            }
        }
        encoded.append(34)
        return String(decoding: encoded, as: UTF8.self)
    }
}
