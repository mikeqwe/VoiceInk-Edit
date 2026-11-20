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

    // MARK: Context (F3: everything the reader returns, up to the cap)

    private func reading(_ text: String, selecting part: String?) -> SuggestCore.TextReading {
        SuggestCore.TextReading(text: text, selection: part.map { (text as NSString).range(of: $0) })
    }

    func testWholeFocusedTextIsSent() {
        let before = String(repeating: "Earlier sentence about the patch. ", count: 300)  // 10,200 chars
        let after = String(repeating: " Later sentence about the review.", count: 300)
        let text = before + "Клод" + after
        let context = SuggestCore.context(readings: [reading(text, selecting: "Клод")], selectedText: "Клод")
        XCTAssertEqual(context.around, SuggestCore.Context.Around(before: before, selected: "Клод", after: after))
        XCTAssertEqual(context.other, [])
        let message = SuggestCore.userMessage(selection: "Клод", context: context)
        XCTAssertEqual(message, "<TEXT_BEFORE>\(before)</TEXT_BEFORE>\n<SELECTION>Клод</SELECTION>\n<TEXT_AFTER>\(after)</TEXT_AFTER>")
    }

    func testTextWithoutTheSelectionIsSentLabelled() {
        // A read-only page or another element: no selection range, or the range holds other text.
        let page = "A paragraph the user is reading."
        let field = "I asked Клод to review the patch."
        let stale = SuggestCore.TextReading(text: field, selection: (field as NSString).range(of: "review"))
        let context = SuggestCore.context(
            readings: [SuggestCore.TextReading(text: page, selection: nil), stale], selectedText: "Клод")
        XCTAssertNil(context.around)
        XCTAssertEqual(context.other, [page, field])
        XCTAssertEqual(
            SuggestCore.userMessage(selection: "Клод", context: context),
            "<SELECTION>Клод</SELECTION>\n"
                + "<OTHER_TEXT note=\"other text visible in the same window; may be unrelated\">\(page)</OTHER_TEXT>\n"
                + "<OTHER_TEXT note=\"other text visible in the same window; may be unrelated\">\(field)</OTHER_TEXT>")
        // With the selection found, other distinct texts still follow; blank and repeated ones do not.
        let both = SuggestCore.context(
            readings: [reading(field, selecting: "Клод"), SuggestCore.TextReading(text: page, selection: nil),
                SuggestCore.TextReading(text: field, selection: nil), SuggestCore.TextReading(text: "  \n", selection: nil)],
            selectedText: "Клод")
        XCTAssertEqual(both.around, SuggestCore.Context.Around(before: "I asked ", selected: "Клод", after: " to review the patch."))
        XCTAssertEqual(both.other, [page])
        XCTAssertEqual(SuggestCore.userMessage(selection: "Клод", context: .none), "<SELECTION>Клод</SELECTION>")
    }

    func testContextStaysWithinTheCap() {
        XCTAssertEqual(SuggestCore.contextCap, 200_000)
        let text = String(repeating: "a", count: 80) + "Клод" + String(repeating: "b", count: 80)
        // An even split around the selection when both sides are long.
        let even = SuggestCore.context(readings: [reading(text, selecting: "Клод")], selectedText: "Клод", cap: 100)
        XCTAssertEqual(even.around, SuggestCore.Context.Around(
            before: String(repeating: "a", count: 50), selected: "Клод", after: String(repeating: "b", count: 50)))
        // Near the start, the unused share goes to the other side.
        let early = "ab" + "Клод" + String(repeating: "c", count: 300)
        let shifted = SuggestCore.context(readings: [reading(early, selecting: "Клод")], selectedText: "Клод", cap: 100)
        XCTAssertEqual(shifted.around, SuggestCore.Context.Around(
            before: "ab", selected: "Клод", after: String(repeating: "c", count: 98)))
        // Other text takes what is left, and a cut never splits a composed character.
        let other = "xyz" + String(repeating: "😀", count: 20)
        let capped = SuggestCore.context(
            readings: [reading("12345Клод12345", selecting: "Клод"), SuggestCore.TextReading(text: other, selection: nil)],
            selectedText: "Клод", cap: 16)
        // 16 - 10 = 6 units left: "xyz" (3) and one emoji (2); the next emoji (5..<7) would be split at 6.
        XCTAssertEqual(capped.other, ["xyz😀"])
        let total = (capped.around.map { $0.before.utf16.count + $0.after.utf16.count } ?? 0)
            + capped.other.reduce(0) { $0 + $1.utf16.count }
        XCTAssertLessThanOrEqual(total, 16)
        // Nothing left: no other text at all.
        let full = SuggestCore.context(
            readings: [reading(text, selecting: "Клод"), SuggestCore.TextReading(text: "page", selection: nil)],
            selectedText: "Клод", cap: 100)
        XCTAssertEqual(full.other, [])
    }

    // MARK: The prompt (F3)

    func testPromptSaysTheSelectionIsNotRightWithoutAReason() {
        let prompt = SuggestCore.systemPrompt
        XCTAssertTrue(prompt.contains("The selected text is not right here."), prompt)
        for reason in ["speech", "recogni", "mistake", "misheard", "typo", "because", "Cyrillic"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(reason), "gives a reason: \(reason)")
        }
        XCTAssertTrue(prompt.contains("Never return the SELECTION unchanged."))
        XCTAssertTrue(prompt.contains("differs from the SELECTION only in letter case is allowed"))
        XCTAssertTrue(prompt.contains("OTHER_TEXT, when present, is other text visible in the same window; may be unrelated."))
        XCTAssertTrue(prompt.contains("REJECTED, when present, lists replacements already offered"))
        XCTAssertTrue(prompt.contains("a word, a phrase or a few lines"))
    }

    // MARK: A new set (F3)

    func testANewSetExcludesEveryOptionShown() {
        var session = readySession(["Claude", "Claude Code"])
        XCTAssertTrue(session.askForNewSet())
        XCTAssertEqual(session.phase, .thinking)
        session.show(["Cloud"])
        XCTAssertEqual(session.shown, ["Claude", "Claude Code", "Cloud"])
        XCTAssertTrue(session.askForNewSet())
        // The model repeats shown options anyway: the code drops them.
        let output = "[\"Claude\", \"claude\", \"Cloud\", \"Clod\", \"Claude Code\"]"
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: output, original: "Клод", excluding: session.shown),
            ["claude", "Clod"])
        XCTAssertEqual(
            SuggestCore.userMessage(selection: "Клод", context: .none, rejected: ["Claude", "Cloud"]),
            "<SELECTION>Клод</SELECTION>\n<REJECTED><OPTION>Claude</OPTION><OPTION>Cloud</OPTION></REJECTED>")
    }

    func testTheListKeepsItsKeysWhileANewSetLoads() {
        var thinking = SuggestCore.Session()
        XCTAssertFalse(thinking.askForNewSet(), "no new set before the first list")
        var session = readySession(["Claude", "Cloud"])
        XCTAssertTrue(session.askForNewSet())
        XCTAssertFalse(session.askForNewSet(), "a second press while loading changes nothing")
        XCTAssertEqual(session.handle(.pick(1)), .none, "a digit while loading does nothing")
        XCTAssertEqual(session.phase, .thinking)
        // A failed new set shows the previous list again, and it still picks.
        XCTAssertTrue(session.restorePrevious())
        XCTAssertEqual(session.phase, .ready(["Claude", "Cloud"]))
        XCTAssertEqual(session.handle(.pick(2)), .apply("Cloud"))
        // A failed first request has nothing to restore: the run closes.
        XCTAssertFalse(thinking.restorePrevious())
        // Esc while loading closes with no write.
        var loading = readySession(["Claude"])
        XCTAssertTrue(loading.askForNewSet())
        XCTAssertEqual(loading.handle(.close), .close)
        XCTAssertFalse(loading.restorePrevious())
        XCTAssertEqual(loading.handle(.pick(1)), .none)
    }

    // MARK: Phrases and lines (F3)

    func testSelectionCap() {
        XCTAssertEqual(SuggestCore.maxSelectionLength, 500)
        XCTAssertTrue(SuggestCore.acceptsSelection(String(repeating: "й", count: 500)))
        XCTAssertFalse(SuggestCore.acceptsSelection(String(repeating: "й", count: 501)))
        XCTAssertTrue(SuggestCore.acceptsSelection("first line\nsecond line"))
    }

    func testAPickKeepsTheSelectionsOwnEdges() {
        // The capture trims; the reader's raw selection keeps a selected line's break.
        let text = "Intro.\nfirst lien\nsecond lien\nOutro."
        let selected = "first lien\nsecond lien\n"
        let context = SuggestCore.context(readings: [reading(text, selecting: selected)], selectedText: "first lien\nsecond lien")
        XCTAssertEqual(context.around, SuggestCore.Context.Around(before: "Intro.\n", selected: selected, after: "Outro."))
        var session = SuggestCore.Session()
        session.selectionCaptured("first lien\nsecond lien")
        session.rawSelectionRead(context.around?.selected)
        let output = "{\"replacements\": [\"first line\\nsecond line\", \" first lien\\nsecond lien \"]}"
        let items = SuggestCore.replacements(fromModelOutput: output, original: "first lien\nsecond lien")
        XCTAssertEqual(items, ["first line\nsecond line"])
        session.show(items)
        XCTAssertEqual(session.handle(.pick(1)), .apply("first line\nsecond line\n"))
        XCTAssertEqual(SuggestCore.pasteText("Claude", rawSelection: " Клод "), " Claude ")
        XCTAssertEqual(SuggestCore.pasteText("Claude", rawSelection: nil), "Claude")
    }
}
