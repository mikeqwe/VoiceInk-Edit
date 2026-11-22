import XCTest
@testable import Suggest

/// Fork F11: the front window's OCR text goes into Suggest's context, labelled, inside F3's cap.
final class SuggestF11Tests: XCTestCase {
    private let around = SuggestCore.Context.Around(before: "I asked ", selected: "Клод", after: " to review it.")

    func testScreenTextIsSentLabelledAfterTheAccessibilityTexts() {
        let context = SuggestCore.adding(
            screenText: "  Active Window: Release notes\nWindow Content:\nClaude reviewed the patch.\n",
            to: SuggestCore.Context(around: around, other: ["page text"]))
        XCTAssertEqual(context.screen, "Active Window: Release notes\nWindow Content:\nClaude reviewed the patch.")
        let message = SuggestCore.userMessage(selection: "Клод", context: context, rejected: ["Клода"])
        XCTAssertEqual(message, """
            <TEXT_BEFORE>I asked </TEXT_BEFORE>
            <SELECTION>Клод</SELECTION>
            <TEXT_AFTER> to review it.</TEXT_AFTER>
            <OTHER_TEXT note="\(SuggestCore.otherTextNote)">page text</OTHER_TEXT>
            <SCREEN_TEXT note="\(SuggestCore.screenTextNote)">Active Window: Release notes
            Window Content:
            Claude reviewed the patch.</SCREEN_TEXT>
            <REJECTED><OPTION>Клода</OPTION></REJECTED>
            """)
        XCTAssertTrue(SuggestCore.screenTextNote.contains("OCR"))
        XCTAssertTrue(SuggestCore.screenTextNote.contains("may be unrelated"))
        XCTAssertTrue(SuggestCore.systemPrompt(writingLanguage: "ru").contains("SCREEN_TEXT, when present, is \(SuggestCore.screenTextNote)."),
                      "the model is told what SCREEN_TEXT is")
    }

    func testScreenTextTakesOnlyWhatTheCapLeaves() {
        // around: 8 + 14 = 22 units, other: 9; cap 40 leaves 9 for the screen.
        let base = SuggestCore.Context(around: around, other: ["page text"])
        XCTAssertEqual(SuggestCore.adding(screenText: "0123456789abc", to: base, cap: 40).screen, "012345678")
        XCTAssertNil(SuggestCore.adding(screenText: "0123456789", to: base, cap: 31).screen, "nothing left: no SCREEN_TEXT")
        XCTAssertEqual(SuggestCore.adding(screenText: "0123456789", to: base).screen, "0123456789",
                       "the real cap is F3's 200k")
    }

    func testNoScreenTextAddsNothing() {
        let base = SuggestCore.Context(around: around, other: [])
        XCTAssertEqual(SuggestCore.adding(screenText: nil, to: base), base)
        XCTAssertEqual(SuggestCore.adding(screenText: " \n ", to: base), base)
        XCTAssertFalse(SuggestCore.userMessage(selection: "Клод", context: base).contains("SCREEN_TEXT"))
    }

    func testTheScreenSwitchIsOnUnlessTurnedOff() {
        let name = "SuggestF11Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(SuggestCore.usesScreenText(in: defaults))
        defaults.set(false, forKey: SuggestCore.screenTextDefaultsKey)
        XCTAssertFalse(SuggestCore.usesScreenText(in: defaults))
        XCTAssertLessThanOrEqual(SuggestCore.screenTextWait, 1.0, "the wait for OCR stays short")
    }
}
