import XCTest
@testable import Suggest

/// F17: Suggest always offers the opposite reading. Speech recognition drops or adds a negation («недостаточно»
/// heard as «достаточно»), so the prompt asks for the SELECTION with its negation added or removed, ranked by
/// likelihood and returned also as "opposite", and the list keeps that item among the shown ones.
/// F17 (scope addition, the owner 23.11): up to nine replacements instead of five, with no padding; keys 1–9;
/// a list too tall for the side of the selection gets shorter options instead of covering it.
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

    static func formatF17(count: Int = 9) -> String {
        #"{"meaning": "...", "opposite": "..." or null, "replacements": ["...", "..."]}: first "meaning", "#
            + #"a few words on what the text says at the SELECTION's place and who says it to whom, then "#
            + #""opposite", the opposite reading or null, then "replacements" with exactly \#(count) distinct items."#
    }

    /// F17's text changes to a pre-F17 prompt, besides the rule: the count (the setting's; F16's padding rule
    /// stays) and the format. Each old text must occur once.
    static func changes(count: Int) -> [(old: String, new: String)] {
        [
            ("Return exactly 7 replacements", "Return exactly \(count) replacements"),
            (#"{"meaning": "...", "replacements": ["...", "..."]}: first "meaning", a few words on what the text says at "#
                + #"the SELECTION's place and who says it to whom, then "replacements" with exactly 7 distinct items."#,
             formatF17(count: count)),
        ]
    }

    /// A pre-F17 Suggest prompt with exactly F17's changes: the rule before the writing-language rule (or
    /// before "- Prefer" when there is none), and `changes`.
    static func withF17(_ before: String, rule: String = oppositeRuleRu, count: Int = 9) -> String {
        let anchor = before.contains("\n- The user writes ") ? "\n- The user writes " : "\n- Prefer replacements"
        precondition(before.components(separatedBy: anchor).count == 2, "rule anchor")
        var after = before.replacingOccurrences(of: anchor, with: "\n" + rule + anchor.dropFirst())
        for change in changes(count: count) {
            precondition(after.components(separatedBy: change.old).count == 2, "anchor: \(change.old)")
            after = after.replacingOccurrences(of: change.old, with: change.new)
        }
        return after
    }

    func testHisPromptIsF16sWithOnlyTheOppositeRuleAndField() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        XCTAssertTrue(prompt.contains(Self.oppositeRuleRu + "- The user writes Russian and English"), prompt)
        XCTAssertTrue(prompt.hasSuffix(Self.formatF17()), prompt)
        // The full equality with F16's verbatim copy is SuggestF16Tests.testHisWritingLanguageGivesTheSuggestPromptAsBefore.
    }

    /// Golden at 5: his prompt with Number of Replacements set to 5 is F16's with the same F17 changes, at 5.
    func testHisPromptAtFiveIsF16sWithTheRuleFieldAndCountFive() {
        XCTAssertEqual(SuggestCore.systemPrompt(writingLanguage: "ru", count: 5),
                       SuggestF18Tests.withF18(Self.withF17(SuggestF16Tests.suggestPromptBeforeF16, count: 5)))
    }

    /// Number of Replacements (Settings → Suggest): 3 to 9, nine by default. The prompt asks for exactly that many,
    /// with F16's rule to fill them ("up to nine, fewer when fewer fit" gave fewer than five in 37 of 86 live lists),
    /// and the list shows at most that many.
    func testTheCountIsTheSettingAndThePromptAsksForExactlyIt() {
        XCTAssertEqual(SuggestCore.maxReplacements, 9)
        XCTAssertEqual(SuggestCore.replacementCounts, 3...9)
        let suite = "SuggestF17Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SuggestCore.replacementCount(in: defaults), 9, "unset: the default")
        for count in [3, 5, 9] {
            defaults.set(count, forKey: SuggestCore.replacementCountDefaultsKey)
            XCTAssertEqual(SuggestCore.replacementCount(in: defaults), count)
        }
        for invalid in [2, 10, 0] {
            defaults.set(invalid, forKey: SuggestCore.replacementCountDefaultsKey)
            XCTAssertEqual(SuggestCore.replacementCount(in: defaults), 9, "\(invalid) is not a choice")
        }
        for count in [3, 5, 9] {
            for language in ["ru", "de", nil] as [String?] {
                let prompt = SuggestCore.systemPrompt(writingLanguage: language, count: count)
                XCTAssertTrue(prompt.contains("Return exactly \(count) replacements for the whole SELECTION, most likely first."), prompt)
                XCTAssertTrue(prompt.contains("- When fewer such replacements exist, add other words or wordings that fit "
                    + "the text and keep its meaning."), "the padding rule: \(prompt)")
                XCTAssertTrue(prompt.hasSuffix("with exactly \(count) distinct items."), prompt)
            }
        }
        XCTAssertEqual(SuggestCore.systemPrompt(writingLanguage: "ru"), SuggestCore.systemPrompt(writingLanguage: "ru", count: 9))
        let twelve = (1...12).map { "option \($0)" }
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["replacements": twelve]), encoding: .utf8)!
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: json, original: "x"), Array(twelve.prefix(9)))
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: json, original: "x", limit: 5), Array(twelve.prefix(5)))
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: #"["a", "b"]"#, original: "x", limit: 5), ["a", "b"])
        // The opposite keeps its place within the setting's count.
        let withOpposite = #"{"opposite": "not 9", "replacements": ["# + twelve.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
        let three = SuggestCore.answer(fromModelOutput: withOpposite, original: "x", limit: 3)
        XCTAssertEqual(three.items, ["option 1", "option 2", "not 9"])
        XCTAssertEqual(three.opposite, .added)
    }

    func testAllNineArePickedByTheTopRowAndByCommandKeypad() {
        for line in 1...9 {
            let bindings = SuggestCore.keyBindings.filter { $0.key == .pick(line) }
            XCTAssertEqual(bindings.filter(\.command).count, 1, "⌘ + keypad \(line)")
            XCTAssertEqual(bindings.filter { !$0.command }.count, 1, "top-row \(line)")
        }
        XCTAssertEqual(SuggestCore.FooterHints.pick(count: 9, keyLabel: "Fn"), "Fn + 1–9 paste")
        XCTAssertEqual(SuggestCore.FooterHints.pick(count: 7, keyLabel: nil), "1–7 paste")
    }

    // MARK: - Nine beside the selection

    func testTheRunPlansForTheRowsItAsksFor() {
        XCTAssertEqual(SuggestCore.plannedListHeight(rows: 9), 54 + 9 * 27)
        XCTAssertEqual(SuggestCore.plannedListHeight(rows: 5), 189, "F5's measured five-row list")
        // A selection 250 pt above the bottom of a 875 pt screen: a 189 pt list (five) fits below, nine do not.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = CGRect(x: 600, y: 250, width: 80, height: 18)
        let thinking = CGSize(width: 220, height: 40)
        XCTAssertEqual(SuggestCore.runSide(size: thinking, anchor: anchor, visible: visible, rows: 9), .above)
        XCTAssertEqual(SuggestCore.runSide(size: thinking, anchor: anchor, visible: visible, rows: 5), .below)
    }

    func testTheRoomIsTheRoomierSideOfTheSelection() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        XCTAssertEqual(SuggestCore.listRoom(anchor: CGRect(x: 10, y: 300, width: 50, height: 20), visible: visible), 875 - 320 - 4)
        XCTAssertEqual(SuggestCore.listRoom(anchor: CGRect(x: 10, y: 700, width: 50, height: 20), visible: visible), 700 - 4 - 25)
        XCTAssertEqual(SuggestCore.listRoom(anchor: nil, visible: visible), 850)
    }

    func testOptionsGetShorterOnlyWhileTheListDoesNotFit() {
        XCTAssertNil(SuggestCore.smallerOptionLineLimit(current: 8, height: 400, room: 400), "fits: options stay whole")
        XCTAssertEqual(SuggestCore.smallerOptionLineLimit(current: 8, height: 401, room: 400), 7)
        XCTAssertEqual(SuggestCore.smallerOptionLineLimit(current: 2, height: 900, room: 400), 1)
        XCTAssertNil(SuggestCore.smallerOptionLineLimit(current: 1, height: 900, room: 400), "one line is the least")
        XCTAssertEqual(SuggestCore.maxOptionLines, 8)
    }

    func testOtherSettingsGetTheRuleWithEnglishExamplesOnly() {
        let englishOnlyRule = Self.oppositeRuleRu.replacingOccurrences(
            of: "«удобно» and «неудобно», «не успели» and «успели», \"did\"", with: "\"did\"")
        for language in ["de", "uk", nil] as [String?] {
            let prompt = SuggestCore.systemPrompt(writingLanguage: language)
            XCTAssertTrue(prompt.contains(englishOnlyRule), "\(language ?? "en-only"): \(prompt)")
            XCTAssertFalse(prompt.contains("«"), "Russian examples for \(language ?? "en-only")")
            XCTAssertTrue(prompt.hasSuffix(Self.formatF17()))
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

    private let nine = ["хватает", "мало", "вполне", "с запасом", "предостаточно", "много", "избыточно", "в достатке", "вдоволь"]

    func testAnOppositeRankedInTheListStaysWhereTheModelPutIt() {
        let a = answer("Недостаточно.", ["хватает", "недостаточно"] + nine.dropFirst())
        XCTAssertEqual(a.items, ["хватает", "недостаточно"] + nine[1..<8])
        XCTAssertEqual(a.opposite, .ranked)
    }

    func testAnOppositeRankedBelowTheListTakesTheLastPlace() {
        let a = answer("недостаточно", nine + ["слишком много", "недостаточно"])
        XCTAssertEqual(a.items, Array(nine.prefix(8)) + ["недостаточно"], "the top eight keep their order")
        XCTAssertEqual(a.opposite, .added)
    }

    func testAnOppositeLeftOutOfTheListIsAddedAfterAShortList() {
        let a = answer("недостаточно", ["хватает", "мало", "достаточно"])
        XCTAssertEqual(a.items, ["хватает", "мало", "недостаточно"])
        XCTAssertEqual(a.opposite, .added)
    }

    func testNoOppositeLeavesTheListAsBefore() {
        let items = ["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша", "Катька", "Катенька", "Катрин", "Кэт"]
        let list = #"["Katya", "Kate", "Катерина", "Катюша", "Таня", "Маша", "Катька", "Катенька", "Катрин", "Кэт"]"#
        for json in [
            #"{"meaning": "m", "opposite": null, "replacements": "# + list + "}",
            #"{"meaning": "m", "replacements": "# + list + "}",
            #"{"meaning": "m", "opposite": "  ", "replacements": "# + list + "}",
            #"{"meaning": "m", "opposite": ["не Катя"], "replacements": "# + list + "}",
            list,
        ] {
            let a = SuggestCore.answer(fromModelOutput: json, original: "Катя")
            XCTAssertEqual(a.items, Array(items.prefix(9)), json)
            XCTAssertEqual(a.opposite, SuggestCore.OppositePlacement.none, json)
            XCTAssertEqual(SuggestCore.replacements(fromModelOutput: json, original: "Катя"), a.items, json)
        }
    }

    func testAnOppositeTheFiltersWouldDropIsNotAdded() {
        let full = nine
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
        let a = answer("недостаточно", nine, shown: ["Недостаточно", "чересчур"])
        XCTAssertEqual(a.items, nine)
        XCTAssertEqual(a.opposite, .shownBefore)
    }

    func testTheOppositeComesFromTheObjectThatHoldsTheList() {
        let output = #"note {"opposite": "чужое"} then {"meaning": "m", "opposite": "не работает", "replacements": ["функционирует", "отвечает"]}"#
        let a = SuggestCore.answer(fromModelOutput: output, original: "работает")
        XCTAssertEqual(a.items, ["функционирует", "отвечает", "не работает"])
        XCTAssertEqual(a.opposite, .added)
    }

    /// Live (after-r1c, 23.11 12:49): "shouldn't merge" for «should merge» was dropped as a misspelling, list item and
    /// opposite alike, because the guard checked "shouldn" alone. macOS's checker knows "shouldn't" whole.
    func testAContractionIsCheckedWholeSoANegationIsNotAMisspelling() {
        XCTAssertEqual(SuggestCore.words("shouldn't merge, it's “quoted” 'x' rock’n’roll"),
                       ["shouldn't", "merge", "it's", "quoted", "x", "rock’n’roll"])
        XCTAssertEqual(SuggestCore.words("don' t 'tis"), ["don", "t", "tis"], "an apostrophe not between letters splits")
        let known: Set<String> = ["should", "merge", "shouldn't", "t"]
        let spelling = SuggestCore.Spelling(isWord: { known.contains($0) })
        XCTAssertFalse(SuggestCore.isMisspelling("shouldn't merge", of: "should merge", spelling: spelling))
        let a = answer("shouldn't merge", ["will merge", "shouldn't merge"], original: "should merge", spelling: spelling)
        XCTAssertEqual(a.items, ["will merge", "shouldn't merge"])
        XCTAssertEqual(a.opposite, .ranked)
        XCTAssertTrue(SuggestCore.isMisspelling("shuld merge", of: "should merge", spelling: spelling), "the guard still works")
    }

    func testNotJSONGivesNothing() {
        let a = SuggestCore.answer(fromModelOutput: "недостаточно", original: "достаточно")
        XCTAssertEqual(a, SuggestCore.Answer(items: [], opposite: .none))
    }
}
