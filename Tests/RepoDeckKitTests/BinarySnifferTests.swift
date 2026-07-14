import Foundation
import Testing
@testable import RepoDeckKit

@Test("1. Empty data is text")
func emptyDataIsText() {
    let data = Data()
    #expect(!BinarySniffer.isLikelyBinary(data))
}

@Test("2. Plain UTF-8 text is not binary")
func plainUTF8IsText() {
    let data = "Hello, world! This is plain text.".data(using: .utf8)!
    #expect(!BinarySniffer.isLikelyBinary(data))
}

@Test("3. NUL byte at offset 0 is binary")
func nulAtOffsetZeroIsBinary() {
    var data = Data()
    data.append(0)
    data.append(contentsOf: "text".data(using: .utf8)!)
    #expect(BinarySniffer.isLikelyBinary(data))
}

@Test("4. NUL byte mid-buffer is binary")
func nulMidBufferIsBinary() {
    var data = Data()
    data.append(contentsOf: "Hello".data(using: .utf8)!)
    data.append(0)
    data.append(contentsOf: "World".data(using: .utf8)!)
    #expect(BinarySniffer.isLikelyBinary(data))
}

@Test("5. PNG header with NULs in IHDR length is binary")
func pngHeaderWithNulsIsBinary() {
    // PNG signature + IHDR chunk length (big-endian: 0x0000000D)
    let pngHeader: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG signature
        0x00, 0x00, 0x00, 0x0D,  // IHDR chunk length (contains NUL bytes)
        0x49, 0x48, 0x44, 0x52   // "IHDR"
    ]
    let data = Data(pngHeader)
    #expect(BinarySniffer.isLikelyBinary(data))
}

@Test("6. NUL byte only beyond 8000-byte boundary is text")
func nulBeyondBoundaryIsText() {
    var data = Data(repeating: 0x41, count: 8500)  // 'A' repeated
    data[8001] = 0  // Place NUL beyond sniffLength
    #expect(!BinarySniffer.isLikelyBinary(data))
}

@Test("7. UTF-16 encoded text is binary")
func utf16EncodedIsBinary() {
    let text = "Hello, world!"
    let utf16Data = text.data(using: .utf16)!
    #expect(BinarySniffer.isLikelyBinary(utf16Data))
}

@Test("8. sniffLength constant is 8000")
func sniffLengthIs8000() {
    #expect(BinarySniffer.sniffLength == 8000)
}
