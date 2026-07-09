import Foundation
import Testing
@testable import RepoDeckKit

@Test("1. Encode always produces lowercase #RRGGBBAA")
func encodeProducesLowercaseEightDigitHex() {
    let hex = ColorHex.encode(red: 1.0, green: 0.0, blue: 0.5, alpha: 1.0)
    #expect(hex.hasPrefix("#"))
    #expect(hex.count == 9)
    #expect(hex == hex.lowercased())
}

@Test("2. Encode known values maps to expected hex")
func encodeKnownValues() {
    #expect(ColorHex.encode(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0) == "#ffffffff")
    #expect(ColorHex.encode(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0) == "#00000000")
    #expect(ColorHex.encode(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0) == "#000000ff")
}

@Test("3. Round-trip encode then decode recovers original components")
func roundTripEncodeDecode() throws {
    let samples: [(Double, Double, Double, Double)] = [
        (1.0, 0.0, 0.0, 1.0),
        (0.0, 1.0, 0.0, 0.5),
        (0.0, 0.0, 1.0, 0.0),
        (48.0 / 255.0, 92.0 / 255.0, 255.0 / 255.0, 255.0 / 255.0),
    ]
    for (r, g, b, a) in samples {
        let hex = ColorHex.encode(red: r, green: g, blue: b, alpha: a)
        let decoded = try #require(ColorHex.decode(hex))
        #expect(abs(decoded.red - r) < 0.01)
        #expect(abs(decoded.green - g) < 0.01)
        #expect(abs(decoded.blue - b) < 0.01)
        #expect(abs(decoded.alpha - a) < 0.01)
    }
}

@Test("4. Decode #RRGGBBAA with leading #")
func decodeEightDigitWithHash() throws {
    let decoded = try #require(ColorHex.decode("#7a5cffcc"))
    #expect(abs(decoded.red - 0x7a.hexDouble) < 0.001)
    #expect(abs(decoded.green - 0x5c.hexDouble) < 0.001)
    #expect(abs(decoded.blue - 0xff.hexDouble) < 0.001)
    #expect(abs(decoded.alpha - 0xcc.hexDouble) < 0.001)
}

@Test("5. Decode #RRGGBBAA without leading #")
func decodeEightDigitWithoutHash() throws {
    let decoded = try #require(ColorHex.decode("7a5cffcc"))
    #expect(abs(decoded.red - 0x7a.hexDouble) < 0.001)
    #expect(abs(decoded.alpha - 0xcc.hexDouble) < 0.001)
}

@Test("6. Decode #RRGGBB defaults alpha to 1.0, with leading #")
func decodeSixDigitWithHash() throws {
    let decoded = try #require(ColorHex.decode("#336699"))
    #expect(abs(decoded.red - 0x33.hexDouble) < 0.001)
    #expect(abs(decoded.green - 0x66.hexDouble) < 0.001)
    #expect(abs(decoded.blue - 0x99.hexDouble) < 0.001)
    #expect(decoded.alpha == 1.0)
}

@Test("7. Decode #RRGGBB defaults alpha to 1.0, without leading #")
func decodeSixDigitWithoutHash() throws {
    let decoded = try #require(ColorHex.decode("336699"))
    #expect(decoded.alpha == 1.0)
}

@Test("8. Decode #RGB shorthand expands each nibble, defaults alpha to 1.0")
func decodeThreeDigitShorthand() throws {
    let decoded = try #require(ColorHex.decode("#f0a"))
    #expect(abs(decoded.red - 0xff.hexDouble) < 0.001)
    #expect(abs(decoded.green - 0x00.hexDouble) < 0.001)
    #expect(abs(decoded.blue - 0xaa.hexDouble) < 0.001)
    #expect(decoded.alpha == 1.0)
}

@Test("9. Decode #RGB shorthand without leading #")
func decodeThreeDigitShorthandWithoutHash() throws {
    let decoded = try #require(ColorHex.decode("f0a"))
    #expect(abs(decoded.red - 0xff.hexDouble) < 0.001)
}

@Test("10. Decode is case-insensitive for all accepted lengths")
func decodeCaseInsensitive() throws {
    let upperEight = try #require(ColorHex.decode("#7A5CFFCC"))
    let lowerEight = try #require(ColorHex.decode("#7a5cffcc"))
    #expect(upperEight == lowerEight)

    let upperSix = try #require(ColorHex.decode("#AABBCC"))
    let lowerSix = try #require(ColorHex.decode("#aabbcc"))
    #expect(upperSix == lowerSix)

    let upperThree = try #require(ColorHex.decode("#ABC"))
    let lowerThree = try #require(ColorHex.decode("#abc"))
    #expect(upperThree == lowerThree)
}

@Test("11. Decode rejects empty string")
func decodeRejectsEmptyString() {
    #expect(ColorHex.decode("") == nil)
    #expect(ColorHex.decode("#") == nil)
}

@Test("12. Decode rejects non-hex characters")
func decodeRejectsNonHexCharacters() {
    #expect(ColorHex.decode("xyz") == nil)
    #expect(ColorHex.decode("#gggggg") == nil)
    #expect(ColorHex.decode("#12345g") == nil)
}

@Test("13. Decode rejects malformed lengths")
func decodeRejectsMalformedLengths() {
    #expect(ColorHex.decode("#12") == nil)
    #expect(ColorHex.decode("#1234") == nil)
    #expect(ColorHex.decode("#12345") == nil)
    #expect(ColorHex.decode("#1234567") == nil)
    #expect(ColorHex.decode("#123456789") == nil)
}

private extension Int {
    /// Interprets `self` as a 0...255 hex byte and returns its 0...1 Double.
    var hexDouble: Double { Double(self) / 255.0 }
}
