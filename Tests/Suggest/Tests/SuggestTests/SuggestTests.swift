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
        // F5: "claude" is a case-only variant of "Claude", so it no longer counts as another option.
        let output = "[\"Claude\", \" Claude \", \"Клод\", \"  Клод\", \"Claud\", \"Claude\", \"claude\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "Клод"), ["Claude", "Claud"])
        // A case-only fix is a real replacement.
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: "[\"github\", \"GitHub\"]", original: "github"), ["GitHub"])
    }

    /// F5: an option that differs from another, or from an option already shown, only in letter
    /// case, punctuation or spacing is the same option. One fix of the selection's own case or
    /// punctuation stays. Splitting or joining words is a real difference.
    func testOptionsThatDifferOnlyInCaseOrPunctuationCountOnce() {
        // The F4 "tommorow" list: four spellings of one word.
        let tomorrow = "[\"tomorrow\", \"Tomorrow\", \"tomorrow,\", \"tomorrow.\", \"to-morrow\", \"tomorrow's\", \"to morrow\"]"
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: tomorrow, original: "tommorow"),
            ["tomorrow", "tomorrow's", "to morrow"])
        // The selection's own case or punctuation is the error: its first fix stays, a second is a repeat.
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: "[\"GitHub\", \"Github\", \"GitLab\"]", original: "github"),
            ["GitHub", "GitLab"])
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: "[\"it's done\", \"It’s done.\", \"it is done\"]", original: "its done"),
            ["it's done", "it is done"])
        // Spacing runs, and an option already shown in this run.
        XCTAssertEqual(
            SuggestCore.replacements(
                fromModelOutput: "[\"we were  going\", \"We were going!\", \"we are going\"]",
                original: "we was going", excluding: ["we were going"]),
            ["we are going"])
        // Letters in any script are compared case-insensitively.
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: "[\"Зонт\", \"зонт\", \"зонт,\", \"зонтик\"]", original: "сон"),
            ["Зонт", "зонтик"])
        XCTAssertEqual(SuggestCore.variantKey("  To-morrow,  please! "), "tomorrow please")
        XCTAssertEqual(SuggestCore.variantKey("…"), "…", "a punctuation-only text is its own key")
    }

    /// F5: web accessibility stays on only in the listed apps (by default T3 Code and Slack), and only
    /// while the switch allows it. Every other app gets back the value it had, as upstream does.
    func testOnlyListedAppsKeepWebAccessibilityOn() {
        let listed = WebAccessibilityKeepOn.defaultBundleIdentifiers
        for app in listed {
            XCTAssertTrue(WebAccessibilityKeepOn.keepsOn(bundleIdentifier: app, enabled: true, listed: listed), app)
            XCTAssertNil(WebAccessibilityKeepOn.valueAfterRead(previous: false, bundleIdentifier: app, enabled: true, listed: listed), app)
            // The off switch: back to today's restore.
            XCTAssertFalse(WebAccessibilityKeepOn.keepsOn(bundleIdentifier: app, enabled: false, listed: listed), app)
            XCTAssertEqual(WebAccessibilityKeepOn.valueAfterRead(previous: false, bundleIdentifier: app, enabled: false, listed: listed), false, app)
        }
        // Other Electron and Chromium apps are not on the list.
        for other in ["com.microsoft.VSCode", "com.hnc.Discord", "com.google.Chrome", "com.t3tools.t3code.helper", "", nil] as [String?] {
            XCTAssertFalse(WebAccessibilityKeepOn.keepsOn(bundleIdentifier: other, enabled: true, listed: listed), other ?? "nil")
            XCTAssertEqual(WebAccessibilityKeepOn.valueAfterRead(previous: false, bundleIdentifier: other, enabled: true, listed: listed), false, other ?? "nil")
        }
        // On before the read: it is put back on, listed or not.
        XCTAssertEqual(WebAccessibilityKeepOn.valueAfterRead(previous: true, bundleIdentifier: "com.microsoft.VSCode", enabled: true, listed: listed), true)
        XCTAssertEqual(WebAccessibilityKeepOn.valueAfterRead(previous: true, bundleIdentifier: "com.t3tools.t3code", enabled: true, listed: listed), true)
        XCTAssertEqual(WebAccessibilityKeepOn.defaultBundleIdentifiers, ["com.t3tools.t3code", "com.tinyspeck.slackmacgap"])
    }

    func testAtMostNineReplacements() {
        // F17: nine (was five).
        let output = "[\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\", \"h\", \"i\", \"j\", \"k\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "x"), ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        // The cap counts kept items, after drops.
        let withDrops = "[\"x\", \"a\", \"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\", \"h\", \"i\", \"j\"]"
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: withDrops, original: "x"), ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
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
        // One paste: the pick ends the list's picking (it only marks the line while it goes),
        // so a second digit does nothing.
        var session = readySession(["Claude", "Cloud"])
        XCTAssertEqual(session.handle(.pick(1)), .apply("Claude"))
        XCTAssertEqual(session.handle(.pick(2)), .none)
        XCTAssertEqual(session.phase, .picked(line: 1))
    }

    // MARK: Confirming a pick (UI polish)

    private func applies(_ effects: [SuggestCore.Session.Effect]) -> Int {
        effects.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    func testOnePastePerPickEvenWithTwoDigitsInsideTheAnimation() {
        var session = readySession(["Claude", "Cloud", "Clod"])
        // A pick, then more digits before the list is gone (the fade lasts 0.2 s).
        let effects = [session.handle(.pick(1)), session.handle(.pick(2)), session.handle(.pick(1)), session.handle(.pick(3))]
        XCTAssertEqual(effects, [.apply("Claude"), .none, .none, .none])
        XCTAssertEqual(applies(effects), 1)
    }

    func testDigitsDuringTheFadeAreIgnored() {
        var session = readySession(["Claude", "Cloud"])
        XCTAssertEqual(session.handle(.pick(2)), .apply("Cloud"))
        XCTAssertEqual(session.phase, .picked(line: 2), "the list stays to mark line 2")
        for key in [SuggestCore.Key.pick(1), .pick(2), .pick(9), .close] {
            XCTAssertEqual(session.handle(key), .none, "\(key) during the fade")
            XCTAssertEqual(session.phase, .picked(line: 2), "\(key) moved or ended the mark")
        }
        XCTAssertFalse(session.askForNewSet(), "no new set while the list goes")
        // The feedback over, the run closes; keys still do nothing.
        session.close()
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(session.handle(.pick(1)), .none)
    }

    func testEscPastesNothing() {
        // Esc closes at once from every phase, with no line marked and nothing pasted after.
        let thinking = SuggestCore.Session()
        let ready = readySession(["Claude", "Cloud"])
        var loading = readySession(["Claude"])
        XCTAssertTrue(loading.askForNewSet())
        for (name, start) in [("thinking", thinking), ("ready", ready), ("loading a new set", loading)] {
            var run = start
            var effects = [run.handle(.close)]
            XCTAssertEqual(effects, [.close], name)
            XCTAssertEqual(run.phase, .closed, "\(name): no mark after Esc")
            run.show(["Claude"])
            effects += [run.handle(.pick(1)), run.handle(.pick(2)), run.handle(.close)]
            XCTAssertEqual(applies(effects), 0, name)
        }
    }

    func testPickFeedbackIsShortAndRespectsReduceMotion() {
        let moving = SuggestCore.pickFeedback(reduceMotion: false)
        XCTAssertTrue(moving.fades)
        XCTAssertTrue((0.15...0.25).contains(moving.duration), "\(moving.duration) s")
        let still = SuggestCore.pickFeedback(reduceMotion: true)
        XCTAssertFalse(still.fades, "Reduce Motion: the mark only, no fade")
        XCTAssertEqual(still.duration, moving.duration, "the mark shows as long either way")
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
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        XCTAssertTrue(prompt.contains("The selected text is not right here."), prompt)
        for reason in ["speech", "recogni", "mistake", "misheard", "typo", "because", "Cyrillic"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(reason), "gives a reason: \(reason)")
        }
        XCTAssertTrue(prompt.contains("Never return the SELECTION unchanged."))
        // F5: a case-only replacement is allowed only when the selection's own error is its case or
        // punctuation (was: always allowed, which gave "tomorrow", "Tomorrow", "tomorrow.").
        XCTAssertTrue(prompt.contains("when the SELECTION's own error is its letter case or punctuation"), prompt)
        XCTAssertFalse(prompt.contains("differs from the SELECTION only in letter case is allowed"))
        // F8 asked for 7 so that 5 remained after the local filters; F17 asks for 5 to 9.
        XCTAssertTrue(prompt.contains("Return 5 to 9 replacements"))
        XCTAssertTrue(prompt.contains("with 5 to 9 distinct items"), prompt)
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
        // The model repeats shown options anyway: the code drops them, and (F5) their case-only
        // variants too.
        let output = "[\"Claude\", \"claude\", \"Cloud\", \"Clod\", \"Claude Code\"]"
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: output, original: "Клод", excluding: session.shown),
            ["Clod"])
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

    // MARK: A press while a run is open (F6)

    func testAPressWhileTheListShowsWorksOnTheSelectionAtThatPress() {
        let ready = readySession(["Claude", "Cloud"]).phase
        // The same selection: a new set, as before F6. The capture trims, so edges do not count.
        XCTAssertEqual(SuggestCore.pressDecision(phase: ready, runSelection: "Клод", current: "Клод"), .newSet)
        XCTAssertEqual(SuggestCore.pressDecision(phase: ready, runSelection: "Клод", current: " Клод\n"), .newSet)
        // Another word was selected while the list showed (the owner's 11:33:18 press): a fresh run.
        XCTAssertEqual(SuggestCore.pressDecision(phase: ready, runSelection: "Клод", current: "патч"), .freshRun)
        XCTAssertEqual(SuggestCore.pressDecision(phase: ready, runSelection: "Клод", current: "клод"), .freshRun,
                       "letter case is part of the selection")
        // Nothing selected now: a fresh run, which says so, rather than options for an old word.
        XCTAssertEqual(SuggestCore.pressDecision(phase: ready, runSelection: "Клод", current: nil), .freshRun)
        // While the first request still thinks: the same selection waits, another one restarts.
        let thinking = SuggestCore.Session().phase
        XCTAssertEqual(SuggestCore.pressDecision(phase: thinking, runSelection: "Клод", current: "Клод"),
                       .ignore(reason: "already-thinking"))
        XCTAssertEqual(SuggestCore.pressDecision(phase: thinking, runSelection: "Клод", current: "патч"), .freshRun)
        XCTAssertEqual(SuggestCore.pressDecision(phase: thinking, runSelection: nil, current: nil),
                       .ignore(reason: "already-thinking"))
        XCTAssertEqual(SuggestCore.pressDecision(phase: thinking, runSelection: nil, current: "патч"), .freshRun)
        // A new set loading for the same selection: a second press changes nothing.
        var loading = readySession(["Claude"])
        XCTAssertTrue(loading.askForNewSet())
        XCTAssertEqual(SuggestCore.pressDecision(phase: loading.phase, runSelection: "Клод", current: "Клод"),
                       .ignore(reason: "already-thinking"))
        // A pick being pasted replaces the selection: nothing, whatever is selected.
        var picked = readySession(["Claude"])
        _ = picked.handle(.pick(1))
        XCTAssertEqual(SuggestCore.pressDecision(phase: picked.phase, runSelection: "Клод", current: "патч"),
                       .ignore(reason: "closing"))
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

    // MARK: Where the list opens (F4)

    /// A 1440 × 900 screen with a 25 pt menu bar: visible frame y 0…875.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let list = CGSize(width: 300, height: 200)

    func testTheListOpensJustUnderTheSelection() {
        // A word on a line whose bottom is 600 pt up: the list's top sits panelGap under it.
        // F7 changed the horizontal rule (left edge → centre); `testTheListIsCentredOnTheSelectionOrItsLastLine`.
        let word = CGRect(x: 400, y: 600, width: 40, height: 18)
        let placed = SuggestCore.panelOrigin(size: list, anchor: word, visible: visible)
        XCTAssertEqual(placed.side, .below)
        // The mockup's gap: a 26 px top under a 22 px line.
        XCTAssertEqual(placed.origin.y + list.height, 596, "top 4 pt under the selection")
        // Three selected lines: the anchor spans them, so the list goes under the last one.
        let lines = CGRect(x: 120, y: 500, width: 700, height: 54)
        let underLines = SuggestCore.panelOrigin(size: list, anchor: lines, visible: visible)
        XCTAssertEqual(underLines.side, .below)
        XCTAssertEqual(underLines.origin.y + list.height, 496)
    }

    func testTheListFlipsAboveWhenThereIsNoRoomBelow() {
        let nearBottom = CGRect(x: 400, y: 120, width: 60, height: 18)
        let placed = SuggestCore.panelOrigin(size: list, anchor: nearBottom, visible: visible)
        XCTAssertEqual(placed.side, .above)
        XCTAssertEqual(placed.origin.y, 142, "bottom 4 pt over the selection")
        // Exactly enough room below still goes below.
        let justFits = CGRect(x: 400, y: 200 + SuggestCore.panelGap, width: 60, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: justFits, visible: visible).side, .below)
    }

    func testTheListStaysWholeOnTheVisibleFrame() {
        // Selection at the right edge: the list moves left to stay on screen.
        let right = CGRect(x: 1400, y: 600, width: 30, height: 18)
        let placedRight = SuggestCore.panelOrigin(size: list, anchor: right, visible: visible)
        XCTAssertEqual(placedRight.origin.x, 1440 - 300)
        // A tall selection with room on neither side: the side with more room, kept inside.
        let tall = CGRect(x: 10, y: 150, width: 600, height: 650)
        let placedTall = SuggestCore.panelOrigin(size: list, anchor: tall, visible: visible)
        XCTAssertEqual(placedTall.side, .below, "150 below against 75 above")
        XCTAssertEqual(placedTall.origin.y, 0, "clamped to the visible bottom")
        // Off the left edge of a second screen to the right of the first.
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let atLeft = CGRect(x: 1430, y: 700, width: 30, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: atLeft, visible: second).origin.x, 1440)
        // Every result lies inside the visible frame.
        for anchor in [right, tall, CGRect(x: -50, y: 870, width: 20, height: 18), CGRect(x: 700, y: 2, width: 20, height: 18)] {
            let origin = SuggestCore.panelOrigin(size: list, anchor: anchor, visible: visible).origin
            XCTAssertTrue(visible.contains(CGRect(origin: origin, size: list)), "\(anchor) → \(origin)")
        }
    }

    func testWithNoUsableBoundsTheListOpensWhereItAlwaysDid() {
        let placed = SuggestCore.panelOrigin(size: list, anchor: nil, visible: visible)
        XCTAssertEqual(placed.side, .fallback)
        XCTAssertEqual(placed.origin, CGPoint(x: 720 - 150, y: 875 - 875.0 / 4 - 200))
        // Rectangles an app reports when it has no text bounds are not anchors.
        let screens = [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertNil(SuggestCore.screenHolding(.zero, screenFrames: screens), "zero rectangle")
        XCTAssertNil(SuggestCore.screenHolding(CGRect(x: 10, y: 10, width: 40, height: 0), screenFrames: screens), "no height")
        XCTAssertNil(SuggestCore.screenHolding(CGRect(x: -900, y: 10, width: 40, height: 18), screenFrames: screens), "off every screen")
        XCTAssertNil(SuggestCore.screenHolding(CGRect(x: CGFloat.nan, y: 10, width: 40, height: 18), screenFrames: screens), "not finite")
        // A caret (zero width) is an anchor; the screen holding most of a rectangle wins.
        XCTAssertEqual(SuggestCore.screenHolding(CGRect(x: 300, y: 300, width: 0, height: 18), screenFrames: screens), 0)
        XCTAssertEqual(SuggestCore.screenHolding(CGRect(x: 1430, y: 300, width: 60, height: 18), screenFrames: screens), 1)
    }

    func testAccessibilityRectanglesFlipToAppKit() {
        // Top-left origin: a line 100 pt from the top of a 900 pt primary screen.
        let ax = CGRect(x: 400, y: 100, width: 40, height: 18)
        XCTAssertEqual(SuggestCore.appKitRect(fromAccessibility: ax, primaryScreenMaxY: 900), CGRect(x: 400, y: 782, width: 40, height: 18))
    }

    // MARK: No jump when the options arrive (F6)

    func testARunOpensOnTheSideItsFullListNeedsAndKeepsIt() {
        // A composer line 150 pt above the screen's bottom (the owner's Slack at 13:34:48).
        let composer = CGRect(x: 400, y: 150, width: 60, height: 18)
        let thinking = CGSize(width: 200, height: 60)
        let options = CGSize(width: 200, height: SuggestCore.plannedListHeight)
        XCTAssertEqual(SuggestCore.panelOrigin(size: thinking, anchor: composer, visible: visible).side, .below,
                       "before F6: Thinking… fits below…")
        XCTAssertEqual(SuggestCore.panelOrigin(size: options, anchor: composer, visible: visible).side, .above,
                       "…and the list then jumped above")
        // F6: the run takes the side a full list needs, and both sizes stay there, on one bottom edge.
        let side = SuggestCore.runSide(size: thinking, anchor: composer, visible: visible)
        XCTAssertEqual(side, .above)
        let first = SuggestCore.panelOrigin(size: thinking, anchor: composer, visible: visible, keeping: side)
        let second = SuggestCore.panelOrigin(size: options, anchor: composer, visible: visible, keeping: side)
        XCTAssertEqual(first.side, .above)
        XCTAssertEqual(second.side, .above)
        XCTAssertEqual(first.origin.y, 172, "bottom 4 pt over the selection")
        XCTAssertEqual(second.origin.y, first.origin.y, "the list grows up from the same edge")
        // With room for a full list below, it opens and stays below.
        let middle = CGRect(x: 400, y: 600, width: 60, height: 18)
        let belowSide = SuggestCore.runSide(size: thinking, anchor: middle, visible: visible)
        XCTAssertEqual(belowSide, .below)
        XCTAssertEqual(SuggestCore.panelOrigin(size: options, anchor: middle, visible: visible, keeping: belowSide).side, .below)
        // Only a list too tall for the kept side moves: there is no room above a line at the top.
        let top = CGRect(x: 400, y: 700, width: 60, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: options, anchor: top, visible: visible, keeping: .above).side, .below)
        // No anchor: the fallback, whatever was kept.
        XCTAssertEqual(SuggestCore.panelOrigin(size: options, anchor: nil, visible: visible, keeping: .above).side, .fallback)
    }

    // MARK: A backward selection's rectangle (F6)

    /// Chromium's answers for «Клод» in a contenteditable (`evidence/f6/params`): the range a
    /// backward selection reports gives 160,192 0×0; the same markers in document order give 249,229 44×23.
    private struct FakeMarkers: SuggestCore.MarkerQueries {
        enum Range: Equatable { case backward, forward, ordered }
        var orderedAvailable = true
        func bounds(_ range: Range) -> CGRect? {
            switch range {
            case .backward: return CGRect(x: 160, y: 192, width: 0, height: 0)
            case .forward, .ordered: return CGRect(x: 249, y: 229, width: 44, height: 23)
            }
        }
        func inDocumentOrder(_ range: Range) -> Range? { orderedAvailable ? .ordered : nil }
        func lastCharacter(_ range: Range) -> Range? { nil }
    }

    func testABackwardSelectionGetsItsOwnRectangle() {
        let word = CGRect(x: 249, y: 229, width: 44, height: 23)
        let backward = SuggestCore.markerSelectionGeometry(FakeMarkers.Range.backward, FakeMarkers())
        XCTAssertEqual(backward?.rect, word, "⌥⇧← selected: the markers in document order give the word")
        XCTAssertEqual(backward?.reordered, true)
        let forward = SuggestCore.markerSelectionGeometry(FakeMarkers.Range.forward, FakeMarkers())
        XCTAssertEqual(forward?.rect, word)
        XCTAssertEqual(forward?.reordered, false, "a forward selection is taken as reported")
        XCTAssertNil(SuggestCore.markerSelectionGeometry(FakeMarkers.Range.backward, FakeMarkers(orderedAvailable: false)),
                     "no ordered range: no rectangle, never the 0 × 0 one")
        XCTAssertNil(SuggestCore.usableTextRect(CGRect(x: 160, y: 192, width: 0, height: 0)))
        XCTAssertNil(SuggestCore.usableTextRect(CGRect(x: 160, y: 192, width: 40, height: CGFloat.infinity)))
        XCTAssertEqual(SuggestCore.usableTextRect(CGRect(x: 293, y: 229, width: 0, height: 23)),
                       CGRect(x: 293, y: 229, width: 0, height: 23), "a caret has no width but is usable")
    }

    // MARK: What an option changes (F4, 3b)

    private func lit(_ option: String, _ original: String) -> [String] {
        SuggestCore.segments(of: option, original: original).filter(\.changed).map(\.text)
    }

    func testChangedWordsAreLitForAMultiWordSelection() {
        let original = "The migration was finished yesterday but we still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it."
        let option = "The migration finished yesterday, but we are still seeing some errors on the old endpoints, mostly timeouts. I think we should keep the fallback for one more week before removing it."
        // Only what the option adds is lit: "finished" and "I" are in the original too, and the
        // dropped "was" and "and" have no text in the option to light.
        XCTAssertEqual(lit(option, original), [",", "are", "."])
        let segments = SuggestCore.segments(of: option, original: original)
        XCTAssertEqual(segments.map(\.text).joined(), option, "the runs give the option back unchanged")
        XCTAssertEqual(lit("we were going to ship it tomorrow", "we was going to ship it tomorrow"), ["were"])
        XCTAssertEqual(lit("we were gonna ship it tomorrow", "we was going to ship it tomorrow"), ["were gonna"],
                       "a space between two lit words is lit with them")
        XCTAssertEqual(lit("first line\nsecond line", "first lien\nsecond lien"), ["line", "line"],
                       "four words, two kept: half is enough to mark")
        XCTAssertEqual(lit("we're shipping it on Friday", "we are shipping it on Friday"), ["we're"],
                       "an apostrophe stays inside its word")
    }

    // MARK: Marks only where they help (F9)

    private func unmarked(_ option: String, _ original: String, _ message: String, line: UInt = #line) {
        XCTAssertEqual(SuggestCore.segments(of: option, original: original), [SuggestCore.Segment(text: option, changed: false)],
                       message, line: line)
    }

    /// The 231-character fragment of the long-fragment check (F4), with the three options a live
    /// list showed for it.
    private let f4Fragment = "The migration was finished yesterday but we still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it, so nobody get paged during the weekend again."

    func testTheOwnersRealTimeListShowsNoMarks() {
        // Reported on 21.11: «real-time» selected, and every option was lit end to end.
        for option in ["в реальном времени", "в режиме реального времени", "live", "в live-режиме", "онлайн"] {
            unmarked(option, "real-time", "«\(option)» for «real-time»")
        }
    }

    func testAShortPhraseShowsNoMarks() {
        for (option, original) in [("на лету", "on the fly"), ("meanwhile", "in the meantime"), ("rough draft", "first cut")] {
            unmarked(option, original, "an unrelated phrase for «\(original)»")
        }
        unmarked("send the summary", "send the report",
                 "three words are taken in at a glance: no marks even when the option keeps two of them")
    }

    func testFourWordsAreLongEnoughToMark() {
        XCTAssertEqual(lit("send the summary today", "send the report today"), ["summary"])
    }

    func testACompoundIsOneWord() {
        // As one word each, "real-time" and "end-to-end" make a two-word original: too short to
        // mark. Split at the hyphens it would be five words, four of them kept, with "world" lit.
        unmarked("real-world end-to-end", "real-time end-to-end", "hyphenated compounds count as one word each")
        unmarked("we're done", "we are done", "an apostrophe compound is one word: two words in the option, three in the original, none marked")
        XCTAssertEqual(lit("a real-world sync job", "a real-time sync job"), ["real-world"],
                       "a changed compound is lit whole")
    }

    func testTheF4FragmentIsMarkedAsBefore() {
        XCTAssertEqual(lit("The migration was finished yesterday, but we are still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it, so nobody gets paged during the weekend again.", f4Fragment),
                       [",", "are", "gets"])
        XCTAssertEqual(lit("The migration was finished yesterday, but we're still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it, so nobody gets paged during the weekend again.", f4Fragment),
                       [",", "we're", "gets"])
        XCTAssertEqual(lit("The migration was finished yesterday but we are still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it, so nobody gets paged over the weekend again.", f4Fragment),
                       ["are", "gets", "over"])
    }

    func testARewriteOfALongFragmentShowsNoMarks() {
        let rewrite = "Yesterday's cutover is done, yet legacy calls still time out now and then, so let's leave the safety net in place another seven days and spare the on-call rota a noisy weekend."
        unmarked(rewrite, f4Fragment, "an option that keeps almost none of the fragment's words is a rewrite")
        unmarked("Apples, pears, plums, cherries", "Bread, milk, eggs, cherries",
                 "only words count as kept: one word of four, though all three commas match")
        // Judged per option: a near-copy in the same list keeps its marks.
        XCTAssertEqual(lit("The migration was finished yesterday but we are still seeing some errors on the old endpoints, mostly timeouts, and I think we should keep the fallback for one more week before removing it, so nobody gets paged during the weekend again.", f4Fragment),
                       ["are", "gets"])
    }

    func testNoMarkingForASingleWordSelection() {
        XCTAssertEqual(SuggestCore.segments(of: "Claude Code", original: "Клод"), [SuggestCore.Segment(text: "Claude Code", changed: false)])
        XCTAssertEqual(SuggestCore.segments(of: "GitHub", original: " github. "), [SuggestCore.Segment(text: "GitHub", changed: false)])
        XCTAssertEqual(lit("Claude Code", "Клод"), [])
    }
}
