import Foundation
import Testing
@testable import RepoDeckKit

@Suite struct AnsiStripperTests {
    @Test func plainTextIsUnchanged() {
        #expect(AnsiStripper.strip("hello world") == "hello world")
    }

    @Test func stripsRedColoredWord() {
        let input = "\u{1B}[31mERROR\u{1B}[0m"
        #expect(AnsiStripper.strip(input) == "ERROR")
    }

    @Test func stripsCursorMoveAndClearLine() {
        let input = "\u{1B}[2K\u{1B}[1G"
        #expect(AnsiStripper.strip(input) == "")
    }

    @Test func stripsOscTitleTerminatedByBel() {
        let input = "\u{1B}]0;title\u{07}"
        #expect(AnsiStripper.strip(input) == "")
    }

    @Test func stripsOscTitleTerminatedByStringTerminator() {
        let input = "\u{1B}]0;title\u{1B}\\after"
        #expect(AnsiStripper.strip(input) == "after")
    }

    @Test func stripsCombinedBoldAndColor() {
        let input = "\u{1B}[1m\u{1B}[32mOK\u{1B}[0m"
        #expect(AnsiStripper.strip(input) == "OK")
    }

    @Test func stripsBareEscapeAtEndOfString() {
        #expect(AnsiStripper.strip("\u{1B}") == "")
    }

    @Test func stripsStandaloneEscapePlusOneByte() {
        // A lone ESC not followed by `[` or `]` consumes ESC + one byte.
        #expect(AnsiStripper.strip("before\u{1B}Xafter") == "beforeafter")
    }

    @Test func preservesTabsAndNewlines() {
        let input = "col1\tcol2\nline2\r\n"
        #expect(AnsiStripper.strip(input) == input)
    }

    @Test func emptyStringIsUnchanged() {
        #expect(AnsiStripper.strip("") == "")
    }

    @Test func mixedPlainAndEscapedTextKeepsOnlyPlainParts() {
        let input = "plain \u{1B}[33mwarn\u{1B}[0m tail"
        #expect(AnsiStripper.strip(input) == "plain warn tail")
    }
}
