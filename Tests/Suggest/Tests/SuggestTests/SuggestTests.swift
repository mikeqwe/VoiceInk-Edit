import XCTest
@testable import Suggest

final class SuggestTests: XCTestCase {
    // MARK: Parsing the model's answer

    func testMalformedOrEmptyOutputGivesNoReplacements() {
        let outputs = [
            "",
            "   \n",
            "Sure! The word is probably Claude.",
            "1. Claude\n2. Cloud",
            "[",
            "{\"replacements\": \"Claude\"}",
            "{\"other\": [\"Claude\"]}",
            "[1, 2, null]",
            "null",
            "[\"\", \"   \"]",
        ]
        for output in outputs {
            XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "Клод"), [], "output: \(output)")
        }
    }

    func testParsesArrayObjectAndFencedAnswers() {
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: "[\"Claude\", \"Cloud\"]", original: "Клод"), ["Claude", "Cloud"])
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: "{\"replacements\": [\"Claude\", 7, \"Cloud\"]}", original: "Клод"),
            ["Claude", "Cloud"])
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: "```json\n{\"replacements\": [\"Claude\"]}\n```", original: "Клод"),
            ["Claude"])
    }

    func testDedupeAndDropTheOriginal() {
        let output = "[\"Claude\", \" Claude \", \"Клод\", \"  Клод\", \"Claud\", \"Claude\", \"claude\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "Клод"), ["Claude", "Claud", "claude"])
        // A case-only fix is a real replacement.
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: "[\"github\", \"GitHub\"]", original: "github"), ["GitHub"])
    }

    func testAtMostFiveReplacements() {
        let output = "[\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\", \"h\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "x"), ["a", "b", "c", "d", "e"])
        // The cap counts kept items, after drops.
        let withDrops = "[\"x\", \"a\", \"a\", \"b\", \"c\", \"d\", \"e\", \"f\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: withDrops, original: "x"), ["a", "b", "c", "d", "e"])
    }

    // MARK: Keys

    private func key(_ keyCode: UInt16, command: Bool) -> SuggestCore.Key? {
        SuggestCore.keyBindings.first { $0.keyCode == keyCode && $0.command == command }?.key
    }

    func testTheListOwnsPadDigitsTopRowDigitsAndEsc() {
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (index, code) in keypad.enumerated() {
            XCTAssertEqual(key(code, command: true), .pick(index + 1), "⌘ + keypad \(index + 1)")
        }
        let topRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, code) in topRow.enumerated() {
            XCTAssertEqual(key(code, command: false), .pick(index + 1), "top-row \(index + 1)")
        }
        XCTAssertEqual(key(53, command: false), .close)
        XCTAssertEqual(Set(SuggestCore.keyBindings.map { "\($0.keyCode):\($0.command)" }).count, SuggestCore.keyBindings.count)
    }

    func testReturnIsNotConsumed() {
        // kVK_Return 36, kVK_ANSI_KeypadEnter 76, with or without ⌘ (". + ⏎" is Send now).
        for code: UInt16 in [36, 76] {
            XCTAssertNil(key(code, command: false))
            XCTAssertNil(key(code, command: true))
        }
        XCTAssertFalse(SuggestCore.keyBindings.contains { $0.keyCode == 36 || $0.keyCode == 76 })
    }

    // MARK: A run

    private func readySession(_ items: [String], selection: String? = "Клод") -> SuggestCore.Session {
        var session = SuggestCore.Session()
        session.selectionCaptured(selection)
        session.show(items)
        return session
    }

    func testAnEarlyDigitIsIgnored() {
        var session = SuggestCore.Session()
        XCTAssertEqual(session.handle(.pick(1)), .none)
        session.selectionCaptured("Клод")
        XCTAssertEqual(session.handle(.pick(1)), .none)
        XCTAssertEqual(session.phase, .thinking)
        // The early digit left nothing pending: the list still needs its own pick.
        session.show(["Claude", "Cloud"])
        XCTAssertEqual(session.phase, .ready(["Claude", "Cloud"]))
        XCTAssertEqual(session.handle(.pick(2)), .apply("Cloud"))
    }

    func testADigitWithNoSuchLineDoesNothing() {
        var session = readySession(["Claude", "Cloud"])
        XCTAssertEqual(session.handle(.pick(3)), .none)
        XCTAssertEqual(session.handle(.pick(10)), .none)
        XCTAssertEqual(session.phase, .ready(["Claude", "Cloud"]))
        XCTAssertEqual(session.handle(.pick(1)), .apply("Claude"))
    }

    func testEscClosesWithNoWrite() {
        var thinking = SuggestCore.Session()
        XCTAssertEqual(thinking.handle(.close), .close)
        XCTAssertEqual(thinking.phase, .closed)
        thinking.show(["Claude"])
        XCTAssertEqual(thinking.handle(.pick(1)), .none, "a list arriving after Esc never applies")

        var ready = readySession(["Claude"])
        XCTAssertEqual(ready.handle(.close), .close)
        XCTAssertEqual(ready.handle(.pick(1)), .none)
        XCTAssertEqual(ready.phase, .closed)
    }

    func testApplyIsGated() {
        for selection in [nil, "", "  \n"] as [String?] {
            var session = readySession(["Claude"], selection: selection)
            XCTAssertEqual(session.handle(.pick(1)), .withheld(.noSelection), "selection: \(String(describing: selection))")
            XCTAssertEqual(session.phase, .closed)
        }
        // One paste: the pick closes the list, so a second digit does nothing.
        var session = readySession(["Claude", "Cloud"])
        XCTAssertEqual(session.handle(.pick(1)), .apply("Claude"))
        XCTAssertEqual(session.handle(.pick(2)), .none)
        XCTAssertEqual(session.phase, .closed)
    }

    // MARK: Context

    func testContextIsTheTextAroundTheSelectionOnly() {
        let text = "I asked Клод to review the patch."
        let range = (text as NSString).range(of: "Клод")
        XCTAssertEqual(
            SuggestCore.context(fieldText: text, selection: range, selectedText: "Клод"),
            SuggestCore.Context(before: "I asked ", after: " to review the patch."))
        XCTAssertEqual(
            SuggestCore.context(fieldText: text, selection: range, selectedText: "Клод", radius: 3),
            SuggestCore.Context(before: "ed ", after: " to"))
        // Another element's text, or a stale range, sends no context.
        XCTAssertNil(SuggestCore.context(fieldText: text, selection: range, selectedText: "patch"))
        XCTAssertNil(SuggestCore.context(fieldText: "short", selection: range, selectedText: "Клод"))
        let message = SuggestCore.userMessage(selection: "Клод", context: nil)
        XCTAssertEqual(message, "<SELECTION>Клод</SELECTION>")
    }
}
