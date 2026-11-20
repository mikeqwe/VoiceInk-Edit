import XCTest
@testable import Suggest

final class QuickAddPrefillTests: XCTestCase {
    func testAShortSelectionFillsTheVocabularyField() {
        XCTAssertEqual(QuickAddPrefill.word(from: "Claude"), "Claude")
        XCTAssertEqual(QuickAddPrefill.word(from: "  Claude Code \n"), "Claude Code")
    }

    func testNoUsableSelectionOpensItEmptyAsStock() {
        XCTAssertEqual(QuickAddPrefill.word(from: nil), "")
        XCTAssertEqual(QuickAddPrefill.word(from: "   "), "")
        XCTAssertEqual(QuickAddPrefill.word(from: "two\nlines"), "")
        XCTAssertEqual(QuickAddPrefill.word(from: String(repeating: "a", count: 65)), "")
        XCTAssertEqual(QuickAddPrefill.word(from: String(repeating: "a", count: 64)), String(repeating: "a", count: 64))
    }
}
