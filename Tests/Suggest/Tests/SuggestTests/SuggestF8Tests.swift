import XCTest
@testable import Suggest

/// Fork F8: no misspellings of a correct word; no unusable answers.
final class SuggestF8Tests: XCTestCase {
    /// A stand-in for the system spell checker: these words are real, every other word is not.
    private let spelling = SuggestCore.Spelling(
        isWord: { ["быстро", "быстр", "быстра", "быстрее", "сразу", "review", "reviews", "сон", "зонт", "кот", "код", "tomorrow", "Cabana", "ship", "it"].contains($0) },
        vocabulary: ["Kibana", "Kubectl"]
    )

    func testAMisspellingOfACorrectWordIsDropped() {
        // F7's live «быстро» list, then two real words.
        let output = #"{"meaning": "how fast it works", "replacements": ["быстр", "бысто", "выстро", "быстра", "сразу", "быстрее"]}"#
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: output, original: "быстро", spelling: spelling),
            ["быстр", "быстра", "сразу", "быстрее"])
        XCTAssertEqual(SuggestCore.misspellingCount(inModelOutput: output, original: "быстро", spelling: spelling), 2)
        // Without the check nothing changes (the tests and callers before F8).
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: output, original: "быстро"),
            ["быстр", "бысто", "выстро", "быстра", "сразу"])
    }

    func testTheGuardKeepsWhatIsNotAMisspellingOfTheOriginal() {
        let check = { (option: String, original: String) in
            SuggestCore.isMisspelling(option, of: original, spelling: self.spelling)
        }
        XCTAssertTrue(check("revew", "review"))       // one edit, not a word
        XCTAssertTrue(check("rewiev", "review"))      // two edits
        XCTAssertFalse(check("rvw", "review"))        // three edits: not near enough to count
        XCTAssertFalse(check("reviews", "review"))    // a real word
        XCTAssertFalse(check("код", "кот"))           // the homophone the user meant
        XCTAssertFalse(check("Kibana", "Cabana"))     // the vocabulary wins over the checker
        XCTAssertFalse(check("kibana", "Cabana"))     // in any case
        XCTAssertFalse(check("tomorow", "tommorow"))  // the original is not a real word: guard off
        XCTAssertFalse(check("Claude", "Клод"))       // far from the original
        XCTAssertTrue(check("ship itt", "ship it"))   // a phrase: every word of it real, one edit
        XCTAssertFalse(check("ship it!", "ship it"))  // only punctuation: zero letter edits
        XCTAssertFalse(check("быстро", ""))           // no words in the original
    }

    func testEditDistanceAndWords() {
        XCTAssertEqual(SuggestCore.editDistance("быстро", "бысто"), 1)
        XCTAssertEqual(SuggestCore.editDistance("быстро", "выстро"), 1)
        XCTAssertEqual(SuggestCore.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(SuggestCore.editDistance("", "abc"), 3)
        XCTAssertEqual(SuggestCore.editDistance("abc", ""), 3)
        XCTAssertEqual(SuggestCore.editDistance("ab", "ba"), 2)
        XCTAssertEqual(SuggestCore.words("pull-request, «Клод» v2"), ["pull", "request", "Клод", "v2"])
    }

    func testTheListIsFoundWhereverTheModelPutsIt() {
        let cases: [(String, [String])] = [
            // the F8 format: "meaning" first
            (#"{"meaning": "a tool", "replacements": ["Claude", "Cloud"]}"#, ["Claude", "Cloud"]),
            // a sentence with brackets before the JSON (was: no list, the first "[" did not parse)
            (#"The word [Клод] is a name. {"replacements": ["Claude", "Cloud"]}"#, ["Claude", "Cloud"]),
            // a note with braces after it (was: no list, the last "}" ended the span)
            (#"{"replacements": ["Claude"]} Note: {see above}"#, ["Claude"]),
            // two answers: the first list wins (was: no list, the span covered both)
            (#"{"replacements": ["Claude"]}\n{"replacements": ["Cloud"]}"#, ["Claude"]),
            // brackets inside a string do not end the value, in the object or in the list itself
            (#"{"meaning": "a } or ] here", "replacements": ["a [b]", "c"]}"#, ["a [b]", "c"]),
            (#"{"meaning": "x }", "replacements": ["a ]", "b"]}"#, ["a ]", "b"]),
            (#"{"meaning": "an \"escaped\" quote", "replacements": ["Claude"]}"#, ["Claude"]),
            // an object that is not the list is skipped whole: its nested array is not the list
            (#"{"other": ["Claude"]} ["Cloud"]"#, ["Cloud"]),
        ]
        for (output, expected) in cases {
            XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "Клод"), expected, output)
        }
        XCTAssertEqual(SuggestCore.answerItemCount(#"{"meaning": "x", "replacements": ["a", "b", "c"]}"#), 3)
    }

    func testANonJSONAnswerIsDescribedWithoutItsText() {
        XCTAssertEqual(SuggestCore.unparsedShape("«быстро» здесь уже верно, заменять не нужно."), "no-brackets")
        XCTAssertEqual(SuggestCore.unparsedShape(#"{"replacements": ["Claude", "Clo"#), "unbalanced")
        XCTAssertEqual(SuggestCore.unparsedShape(#"{"other": ["Claude"]}"#), "no-list")
    }

    func testSevenAreAskedForAndFiveShown() {
        XCTAssertEqual(SuggestCore.maxReplacements, 5)
        XCTAssertEqual(SuggestCore.requestedReplacements, 7)
        let output = #"{"replacements": ["быстро", "бысто", "сразу", "Сразу", "тут же", "моментально", "немедленно", "оперативно"]}"#
        // The original, a misspelling and a case repeat are dropped; five remain of seven asked.
        XCTAssertEqual(
            SuggestCore.replacements(fromModelOutput: output, original: "быстро", spelling: spelling),
            ["сразу", "тут же", "моментально", "немедленно", "оперативно"])
    }

    func testThePromptAsksForMeaningFirstAndSaysACorrectWordStillNeedsAlternatives() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        // F17 added "opposite" between the two.
        XCTAssertTrue(prompt.contains(#"{"meaning": "...", "opposite": "..." or null, "replacements": ["...", "..."]}"#), prompt)
        XCTAssertTrue(prompt.contains("even when the SELECTION is a correctly spelled word"), prompt)
        XCTAssertTrue(prompt.contains("even when the SELECTION looks right"), prompt)
        // F10 replaced F8's "Never another form of the SELECTION's own word …" with a bound: at most one
        // other form, and none when the SELECTION's own form fits (pinned in SuggestF10Tests).
        XCTAssertTrue(prompt.contains("Offer at most one other form of the SELECTION's own word"), prompt)
        XCTAssertTrue(prompt.contains("letters added, dropped, doubled or swapped"), prompt)
        // The evaluation's words are not the prompt's examples.
        for word in ["быстро", "review", "утром", "тесты", "настроек", "кот", "компакшн", "деплой", "tommorow", "Cabana"] {
            XCTAssertFalse(prompt.contains(word), "an evaluation word is in the prompt: \(word)")
        }
    }
}
