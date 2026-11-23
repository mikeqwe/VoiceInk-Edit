import XCTest
@testable import Suggest

/// F18 (the owner 23.11): for «получательно» (meant «получателю») the model read the word by its ending as an
/// adverb and filled the list with «кратко», «понятно»; «получателю» came eighth. For a single word the spell
/// checker does not know, the request now carries the checker's real words that share its stem, and the prompt
/// says what they are. Rule-only prompt changes gave no gain on the same evaluation and were not kept.
final class SuggestF18Tests: XCTestCase {

    static let spellingSentence = "SPELLING, when present, lists real words a spell checker offers for the "
        + "SELECTION; may be unrelated. SOUNDS_LIKE, when present, is the SELECTION with a short word replaced by one "
        + "that sounds like it; may be unrelated. "

    /// An F17 Suggest prompt with exactly F18's change: the SPELLING sentence before the REJECTED one.
    static func withF18(_ before: String) -> String {
        let anchor = "REJECTED, when present, lists"
        precondition(before.components(separatedBy: anchor).count == 2, "anchor")
        return before.replacingOccurrences(of: anchor, with: spellingSentence + anchor)
    }

    // MARK: - The prompt

    /// His prompt is F16's verbatim copy with exactly F17's changes and then F18's one sentence.
    func testHisPromptIsF17sWithOnlyTheSpellingSentence() {
        let f17 = SuggestF17Tests.withF17(SuggestF16Tests.suggestPromptBeforeF16)
        XCTAssertEqual(SuggestCore.systemPrompt(writingLanguage: "ru"), SuggestF20Tests.withF20(Self.withF18(f17))) // + F20's changes
        let f17AtFive = SuggestF17Tests.withF17(SuggestF16Tests.suggestPromptBeforeF16, count: 5)
        XCTAssertEqual(SuggestCore.systemPrompt(writingLanguage: "ru", count: 5), SuggestF20Tests.withF20(Self.withF18(f17AtFive), count: 5))
    }

    func testEverySettingGetsTheSentenceAndItGivesNoReason() {
        for language in ["ru", "de", nil] as [String?] {
            for count in [3, 9] {
                let prompt = SuggestCore.systemPrompt(writingLanguage: language, count: count)
                XCTAssertTrue(prompt.contains(Self.spellingSentence + "REJECTED, when present"), prompt)
            }
        }
        // F3: the prompt gives no reason why the SELECTION is wrong.
        for reason in ["speech", "recogni", "mistake", "misheard", "typo", "because", "Cyrillic", "dictat"] {
            XCTAssertFalse(Self.spellingSentence.localizedCaseInsensitiveContains(reason), reason)
        }
    }

    // MARK: - The hints

    /// macOS's checker for «получательно» (Russian, 23.11): two guesses, then completions of «получате».
    static let checkerForHisWord = ["получательниц", "получатель", "получатель", "получателя", "получатели", "получателем",
                                    "получателю", "получателей", "получателях", "получателями", "получателям"]

    func testHisWordGetsItsStemWords() {
        XCTAssertEqual(SuggestCore.spellingHints(for: "получательно", candidates: Self.checkerForHisWord),
                       ["получательниц", "получатель", "получателя", "получатели", "получателем", "получателю",
                        "получателей", "получателях", "получателями", "получателям"])
    }

    /// The checker's unrelated guesses share no stem and are not sent (they put "Griffin" and «компания» in lists).
    func testUnrelatedGuessesAreDropped() {
        XCTAssertEqual(SuggestCore.spellingHints(for: "Grafana", candidates: ["Griffin", "Griffon", "Grandma", "Graphics"]), [])
        XCTAssertEqual(SuggestCore.spellingHints(for: "компакшн", candidates: ["компания", "компьютер", "комплект"]), [])
        XCTAssertEqual(SuggestCore.spellingHints(for: "заполнительно", candidates: ["заполнитель", "заполните", "заполните-ка"]),
                       ["заполнитель", "заполните", "заполните-ка"])
    }

    /// The stem is the first max(6, length − 4) letters, case aside; the word itself is not a hint.
    func testTheStemIsTheWordWithoutItsLastFourLettersAndAtLeastSix() {
        XCTAssertEqual(SuggestCore.spellingHints(for: "Customerly", candidates: ["customarily", "customer", "Customerly", "custom"]),
                       ["customarily", "customer", "custom"], "stem «custom», 6 letters")
        XCTAssertEqual(SuggestCore.spellingHints(for: "reviewerly", candidates: ["review", "reviewer", "revie"]),
                       ["review", "reviewer"])
        XCTAssertEqual(SuggestCore.spellingHints(for: "читательно", candidates: ["читабельно", "читатель"]), ["читатель"])
        XCTAssertEqual(SuggestCore.spellingHints(for: "Reviewerly", candidates: ["Reviewer", "REVIEWERS"]), ["Reviewer", "REVIEWERS"],
                       "a capital in the word or in a candidate does not matter")
    }

    func testOnlyTheFirstTenDistinctCandidatesCount() {
        let candidates = ["a1", "a1"] + (2...10).map { "a\($0)" } + ["получателю"]
        XCTAssertEqual(candidates.count, 12)
        XCTAssertEqual(SuggestCore.spellingHints(for: "получательно", candidates: candidates), [],
                       "the 11th distinct candidate is not considered")
    }

    func testSeveralWordsOrNothingGetNone() {
        XCTAssertEqual(SuggestCore.spellingHints(for: "мне нужны", candidates: ["мне нужны всем"]), [])
        XCTAssertEqual(SuggestCore.spellingHints(for: "  ", candidates: ["x"]), [])
        XCTAssertEqual(SuggestCore.spellingHints(for: " получательно\n", candidates: ["получателю"]), ["получателю"])
    }

    // MARK: - The message

    func testTheMessageCarriesTheHintsLastAndOnlyWhenThereAreAny() {
        let context = SuggestCore.Context(around: nil, other: [], screen: nil)
        XCTAssertEqual(SuggestCore.userMessage(selection: "получательно", context: context, rejected: ["кратко"],
                                               spelling: ["получатель", "получателю"]),
                       "<SELECTION>получательно</SELECTION>\n<REJECTED><OPTION>кратко</OPTION></REJECTED>\n"
                       + "<SPELLING>получатель, получателю</SPELLING>")
        XCTAssertEqual(SuggestCore.userMessage(selection: "x", context: context, spelling: []), "<SELECTION>x</SELECTION>")
        XCTAssertEqual(SuggestCore.userMessage(selection: "x", context: context), "<SELECTION>x</SELECTION>")
    }
}
