import XCTest
@testable import Suggest

/// F20: the list is built from editing directions, each used only when it applies, with a kind per item and up to
/// Number of Replacements items, instead of exactly that many (the owner chose the research's recommendation, 23.11).
final class SuggestF20Tests: XCTestCase {

    // MARK: - The prompt: F19's, with only these changes

    static func formatF20(count: Int = 9) -> String {
        #"{"meaning": "...", "opposite": "..." or null, "replacements": [{"t": "...", "k": "..."}]}: first "#
            + #""meaning", a few words on what the text says at the SELECTION's place and who says it to whom, "#
            + #"then "opposite", the opposite reading or null, then "replacements" with at most \#(count) "#
            + #"distinct items, each with "t", the replacement, and "k", its kind."#
    }

    static let directionsRule = "- After the likely ones, add other wordings that fit the text and keep its meaning, each in "
        + "a direction that applies here: plainer, shorter, more formal, more casual or clearer. Use a "
        + "direction only when it applies; there is no quota per direction. Two replacements with the "
        + "same meaning, register and length are one choice: return only the better one. Return fewer "
        + "rather than near-synonyms."

    static let kinds = #"Kinds: "repair", what the user likely meant: a word that sounds like the SELECTION, its "#
        + #"correct spelling, another form of its word or the English original; "opposite", the opposite "#
        + #"reading; "alternative", a different word or wording with a meaning that fits; "plain", "#
        + #"plainer; "short", shorter; "formal", more formal; "casual", more casual; "clearer", clearer."#

    /// F20's text changes to F19's prompt (each old text occurs once).
    static func changes(count: Int) -> [(old: String, new: String)] {
        [
            ("Return exactly \(count) replacements for the whole SELECTION, most likely first.",
             "Return up to \(count) replacements for the whole SELECTION, most likely first, each with its kind. "
                + "Fewer is fine, but always at least three that differ from the SELECTION, even when it looks right: "
                + "each one must give the user a choice the others do not."),
            ("- When fewer such replacements exist, add other words or wordings that fit the text and keep its meaning.\n\n",
             directionsRule + "\n\n" + kinds + "\n\n"),
            (SuggestF17Tests.formatF17(count: count), formatF20(count: count)),
        ]
    }

    static func withF20(_ before: String, count: Int = 9) -> String {
        var after = before
        for change in changes(count: count) {
            precondition(after.components(separatedBy: change.old).count == 2, "anchor: \(change.old)")
            after = after.replacingOccurrences(of: change.old, with: change.new)
        }
        return after
    }

    func testHisPromptIsF19sWithOnlyTheDirectionsKindsAndFlexibleCount() {
        for count in [5, 9] {
            let f19 = SuggestF18Tests.withF18(SuggestF17Tests.withF17(SuggestF16Tests.suggestPromptBeforeF16, count: count))
            XCTAssertEqual(SuggestCore.systemPrompt(writingLanguage: "ru", count: count), Self.withF20(f19, count: count))
        }
    }

    func testEveryLanguageAndCountGetsTheSameChanges() {
        for count in [3, 9] {
            for language in ["ru", "de", nil] as [String?] {
                let prompt = SuggestCore.systemPrompt(writingLanguage: language, count: count)
                XCTAssertTrue(prompt.contains("Return up to \(count) replacements for the whole SELECTION"), prompt)
                XCTAssertTrue(prompt.contains(Self.directionsRule + "\n\n" + Self.kinds + "\n\nNever return"), prompt)
                XCTAssertTrue(prompt.hasSuffix(Self.formatF20(count: count)), prompt)
                XCTAssertFalse(prompt.contains("exactly \(count)"), "no fixed count: \(prompt)")
            }
        }
    }

    /// The prompt names exactly the kinds the parser accepts.
    func testThePromptsKindsAreTheParsersKinds() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        let kindsLine = prompt.components(separatedBy: "\n").first { $0.hasPrefix("Kinds: ") } ?? ""
        let named = kindsLine.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertEqual(named, SuggestCore.ReplacementKind.allCases.map(\.rawValue))
        XCTAssertEqual(SuggestCore.ReplacementKind.allCases.map(\.rawValue),
                       ["repair", "opposite", "alternative", "plain", "short", "formal", "casual", "clearer"])
    }

    // MARK: - The answer

    private func typed(_ items: [[String: Any]], opposite: String? = nil) -> String {
        var object: [String: Any] = ["meaning": "m", "replacements": items]
        object["opposite"] = opposite ?? NSNull()
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testTypedItemsGiveTheirTextInOrder() {
        let output = typed([["t": "получателю", "k": "repair"], ["t": "адресату", "k": "alternative"],
                            ["t": "кому надо", "k": "casual"]])
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "получательно"),
                       ["получателю", "адресату", "кому надо"])
        XCTAssertEqual(SuggestCore.itemKinds(inModelOutput: output), "repair,alternative,casual")
    }

    func testAnItemWithAnUnknownOrMissingKindOrTextIsDropped() {
        let output = typed([["t": "a", "k": "repair"], ["t": "b", "k": "synonym"], ["t": "c"], ["k": "plain"],
                            ["t": 4, "k": "plain"], ["t": "d", "k": "short"]])
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "x"), ["a", "d"])
        XCTAssertEqual(SuggestCore.itemKinds(inModelOutput: output), "repair,?,?,?,?,short")
        XCTAssertEqual(SuggestCore.answerItemCount(output), 6, "the log still counts what the model sent")
    }

    func testBareStringsStillParse() {
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: #"{"replacements": ["a", "b"]}"#, original: "x"), ["a", "b"])
        XCTAssertEqual(SuggestCore.itemKinds(inModelOutput: #"["a", {"t": "b", "k": "plain"}]"#), "-,plain")
        XCTAssertNil(SuggestCore.itemKinds(inModelOutput: "no json"))
    }

    func testEmptyUnchangedAndNormalizedDuplicatesAreDropped() {
        let output = typed([["t": "  ", "k": "plain"], ["t": "понятно", "k": "repair"], ["t": "Ясно", "k": "plain"],
                            ["t": "ясно.", "k": "short"], ["t": "ясно", "k": "casual"], ["t": "кратко", "k": "short"]])
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "понятно"), ["Ясно", "кратко"])
    }

    func testFewerItemsAreShownAsTheyCameAndTheCountCaps() {
        let two = typed([["t": "a", "k": "repair"], ["t": "b", "k": "plain"]])
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: two, original: "x", limit: 9), ["a", "b"])
        let twelve = typed((1...12).map { ["t": "o\($0)", "k": "alternative"] })
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: twelve, original: "x", limit: 5), ["o1", "o2", "o3", "o4", "o5"])
    }

    func testTheOppositeAndStemWordsWorkWithTypedItems() {
        let output = typed([["t": "понятно", "k": "alternative"], ["t": "ясно", "k": "plain"], ["t": "непонятно", "k": "opposite"]],
                           opposite: "непонятно")
        let answer = SuggestCore.answer(fromModelOutput: output, original: "получательно", limit: 4,
                                        stemWords: ["получателю", "получателя"])
        XCTAssertEqual(answer.items, ["понятно", "получателю", "получателя", "непонятно"])
        XCTAssertEqual(answer.stemWords, 2)
        let few = typed([["t": "понятно", "k": "alternative"]], opposite: "непонятно")
        let added = SuggestCore.answer(fromModelOutput: few, original: "понятно", limit: 9)
        XCTAssertEqual(added.items, ["непонятно"], "the opposite is kept even when the model did not list it")
        XCTAssertEqual(added.opposite, .added)
    }

    func testTheMisspellingGuardSeesTypedItems() {
        let spelling = SuggestCore.Spelling(isWord: { ["быстро", "скоро"].contains($0) })
        let output = typed([["t": "бысто", "k": "repair"], ["t": "скоро", "k": "alternative"]])
        XCTAssertEqual(SuggestCore.replacements(fromModelOutput: output, original: "быстро", spelling: spelling), ["скоро"])
        XCTAssertEqual(SuggestCore.misspellingCount(inModelOutput: output, original: "быстро", spelling: spelling), 1)
    }
}
