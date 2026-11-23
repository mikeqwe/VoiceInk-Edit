import XCTest
@testable import Suggest

/// F17: Suggest always offers the opposite reading. Speech recognition drops or adds a negation («недостаточно»
/// heard as «достаточно»), so the prompt asks for the SELECTION with its negation added or removed, ranked by
/// likelihood and returned also as "opposite", and the list keeps that item among the shown five.
final class SuggestF17Tests: XCTestCase {

    // MARK: - The prompt: F16's, plus the rule and the field

    /// The F17 rule as his settings ("ru") render it, copied verbatim.
    static let oppositeRuleRu = """
        - When the SELECTION says whether something is, can, must or happens (a verb, or a word \
        for an amount, an ability, a permission, a need, a state or a quality), one replacement must be its opposite reading: the SELECTION with its negation \
        added, or removed when it has one, in the form the language uses: a separate word, a \
        prefix or a contraction (for example «удобно» and «неудобно», «не успели» and «успели», \
        "did" and "didn't"). It is a real word or phrase, not a misspelling and not another form \
        of the SELECTION's own word. Return it also as "opposite". Rank it by how likely it is: \
        first when the text around the SELECTION says the opposite of the SELECTION, and after the \
        replacements that keep the meaning when the text supports the SELECTION. A noun, a name, a \
        term, code, a number or a date has no opposite reading: return null as "opposite" and \
        invent none.

        """

    static let formatBeforeF17 = """
        {"meaning": "...", "replacements": ["...", "..."]}: first "meaning", a few words on what the \
        text says at the SELECTION's place and who says it to whom, then "replacements" with exactly
        """

    static let formatF17 = """
        {"meaning": "...", "opposite": "..." or null, "replacements": ["...", "..."]}: first "meaning", \
        a few words on what the text says at the SELECTION's place and who says it to whom, then \
        "opposite", the opposite reading or null, then "replacements" with exactly
        """

    /// A pre-F17 Suggest prompt with exactly F17's two changes: the rule before the writing-language rule
    /// (or before "- Prefer" when there is none) and the field in the format. Each anchor must occur once.
    static func withF17(_ before: String, rule: String = oppositeRuleRu) -> String {
        let anchor = before.contains("\n- The user writes ") ? "\n- The user writes " : "\n- Prefer replacements"
        precondition(before.components(separatedBy: anchor).count == 2, "rule anchor")
        precondition(before.components(separatedBy: formatBeforeF17).count == 2, "format anchor")
        return before
            .replacingOccurrences(of: anchor, with: "\n" + rule + anchor.dropFirst())
            .replacingOccurrences(of: formatBeforeF17, with: formatF17)
    }

    func testHisPromptIsF16sWithOnlyTheOppositeRuleAndField() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        XCTAssertTrue(prompt.contains(Self.oppositeRuleRu + "- The user writes Russian and English"), prompt)
        XCTAssertTrue(prompt.hasSuffix(Self.formatF17 + " 7 distinct items."), prompt)
        // The full equality with F16's verbatim copy is SuggestF16Tests.testHisWritingLanguageGivesTheSuggestPromptAsBefore.
    }

    func testOtherSettingsGetTheRuleWithEnglishExamplesOnly() {
        let englishOnlyRule = Self.oppositeRuleRu.replacingOccurrences(
            of: "«удобно» and «неудобно», «не успели» and «успели», \"did\"", with: "\"did\"")
        for language in ["de", "uk", nil] as [String?] {
            let prompt = SuggestCore.systemPrompt(writingLanguage: language)
            XCTAssertTrue(prompt.contains(englishOnlyRule), "\(language ?? "en-only"): \(prompt)")
            XCTAssertFalse(prompt.contains("«"), "Russian examples for \(language ?? "en-only")")
            XCTAssertTrue(prompt.hasSuffix(Self.formatF17 + " 7 distinct items."))
        }
        XCTAssertTrue(SuggestCore.systemPrompt(writingLanguage: nil).contains("invent none.\n- Prefer replacements"))
    }

    /// None of the evaluation's selections is a prompt example (F8's rule), so the evaluation measures the rule.
    func testNoEvaluationWordIsAnExample() {
        let examples = SuggestCore.oppositeExamples.values.joined(separator: " ") + " \"did\" and \"didn't\""
        let evaluation = ["достаточно", "можно", "работает", "нужно", "понятно", "важно", "согласен", "проходят",
                          "смог", "мержить", "прошла", "подходит", "enough", "can", "working", "need", "should",
                          "possible", "passed", "works"]
        let words = Set(SuggestCore.words(examples.lowercased()))
        for word in evaluation {
            XCTAssertFalse(words.contains(word) || words.contains("не" + word), "evaluation word as an example: \(word)")
        }
    }

    // MARK: - The list keeps the opposite

    private func answer(_ opposite: String?, _ items: [String], original: String = "достаточно",
                        shown: [String] = [], spelling: SuggestCore.Spelling? = nil) -> SuggestCore.Answer {
        var object: [String: Any] = ["meaning": "m", "replacements": items]
        object["opposite"] = opposite ?? NSNull()
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return SuggestCore.answer(fromModelOutput: json, original: original, excluding: shown, spelling: spelling)
    }

    func testAnOppositeRankedInTheListStaysWhereTheModelPutIt() {
        let a = answer("Недостаточно.", ["хватает", "недостаточно", "мало", "вполне", "с запасом", "много", "избыточно"])
        XCTAssertEqual(a.items, ["хватает", "недостаточно", "мало", "вполне", "с запасом"])
        XCTAssertEqual(a.opposite, .ranked)
    }

    func testAnOppositeRankedBelowTheListTakesTheLastPlace() {
        let a = answer("недостаточно", ["хватает", "мало", "вполне", "с запасом", "предостаточно", "много", "недостаточно"])
        XCTAssertEqual(a.items, ["хватает", "мало", "вполне", "с запасом", "недостаточно"], "the top four keep their order")
        XCTAssertEqual(a.opposite, .added)
    }

    func testAnOppositeLeftOutOfTheListIsAddedAfterAShortList() {
        let a = answer("недостаточно", ["хватает", "мало", "достаточно"])
        XCTAssertEqual(a.items, ["хватает", "мало", "недостаточно"])
        XCTAssertEqual(a.opposite, .added)
    }

    func testNoOppositeLeavesTheListAsBefore() {
        let items = ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]
        for json in [
            #"{"meaning": "m", "opposite": null, "replacements": ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]}"#,
            #"{"meaning": "m", "replacements": ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]}"#,
            #"{"meaning": "m", "opposite": "  ", "replacements": ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]}"#,
            #"{"meaning": "m", "opposite": ["не Катя"], "replacements": ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]}"#,
            #"["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша"]"#,
        ] {
            let a = SuggestCore.answer(fromModelOutput: json, original: "Катя")
            XCTAssertEqual(a.items, Array(items.prefix(5)), json)
            XCTAssertEqual(a.opposite, SuggestCore.OppositePlacement.none, json)
            XCTAssertEqual(SuggestCore.replacements(fromModelOutput: json, original: "Катя"), a.items, json)
        }
    }

    func testAnOppositeTheFiltersWouldDropIsNotAdded() {
        let full = ["хватает", "мало", "вполне", "с запасом", "предостаточно"]
        let same = answer(" достаточно ", full)
        XCTAssertEqual(same.items, full)
        XCTAssertEqual(same.opposite, .dropped, "the original itself")

        let spelling = SuggestCore.Spelling(isWord: { $0 != "нидостаточно" })
        let misspelled = answer("нидостаточно", full, spelling: spelling)
        XCTAssertEqual(misspelled.items, full)
        XCTAssertEqual(misspelled.opposite, .dropped, "a misspelling of the original")

        let real = answer("недостаточно", full, spelling: spelling)
        XCTAssertEqual(real.items.last, "недостаточно", "a real word one prefix away is not a misspelling")
        XCTAssertEqual(real.opposite, .added)
    }

    func testAnOppositeShownInAnEarlierSetIsNotShownAgain() {
        let a = answer("недостаточно", ["хватает", "мало", "вполне", "с запасом", "предостаточно"],
                       shown: ["Недостаточно", "много"])
        XCTAssertEqual(a.items, ["хватает", "мало", "вполне", "с запасом", "предостаточно"])
        XCTAssertEqual(a.opposite, .shownBefore)
    }

    func testTheOppositeComesFromTheObjectThatHoldsTheList() {
        let output = #"note {"opposite": "чужое"} then {"meaning": "m", "opposite": "не работает", "replacements": ["функционирует", "отвечает"]}"#
        let a = SuggestCore.answer(fromModelOutput: output, original: "работает")
        XCTAssertEqual(a.items, ["функционирует", "отвечает", "не работает"])
        XCTAssertEqual(a.opposite, .added)
    }

    func testNotJSONGivesNothing() {
        let a = SuggestCore.answer(fromModelOutput: "недостаточно", original: "достаточно")
        XCTAssertEqual(a, SuggestCore.Answer(items: [], opposite: .none))
    }
}
