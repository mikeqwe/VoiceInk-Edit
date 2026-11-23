import XCTest
@testable import Suggest

/// The model's answer is parsed once (`SuggestCore.reply(in:)`); the list and the answer's log line read that one
/// value. These pin what each reads from it: the list, and the log's raw item count, kinds and misspelling count,
/// for a malformed answer, an empty list, and a list with items the parser refuses.
final class SuggestReplyTests: XCTestCase {

    private let spelling = SuggestCore.Spelling(isWord: { ["быстро", "быстр", "быстрее", "небыстро"].contains($0) })

    func testAMalformedAnswerIsNoReplyAndNoList() {
        for output in ["Sorry, I can't.", #"{"replacements": ["a""#, #"{"meaning": "m"}"#] {
            let reply = SuggestCore.reply(in: output)
            XCTAssertNil(reply, output)
            XCTAssertEqual(SuggestCore.answer(from: reply, original: "x", stemWords: ["y"]).items, [], output)
            XCTAssertNil(SuggestCore.itemKinds(in: reply), output)
            XCTAssertEqual(SuggestCore.misspellingCount(in: reply, original: "быстро", spelling: spelling), 0, output)
        }
    }

    func testAnEmptyListIsAReplyWithNoItems() {
        let reply = SuggestCore.reply(in: #"{"replacements": []}"#)
        XCTAssertEqual(reply?.items.count, 0)
        XCTAssertEqual(SuggestCore.itemKinds(in: reply), "")
        // A parsed answer with no items still takes the stem words; an unparsed one does not (F19).
        XCTAssertEqual(SuggestCore.answer(from: reply, original: "x", stemWords: ["y"]).items, ["y"])
    }

    func testTheLogCountsTheRawItemsWhileTheListKeepsTheUsableOnes() {
        let output = #"{"opposite": "небыстро", "replacements": [{"t": "быстро", "k": "repair"}, 7, {"t": "бысто", "k": "plain"}, {"t": "скоро", "k": "odd"}, "быстрее"]}"#
        let reply = SuggestCore.reply(in: output)
        XCTAssertEqual(reply?.items.count, 5)
        XCTAssertEqual(reply?.opposite, "небыстро")
        XCTAssertEqual(SuggestCore.itemKinds(in: reply), "repair,?,plain,?,-")
        XCTAssertEqual(SuggestCore.misspellingCount(in: reply, original: "быстро", spelling: spelling), 1)
        XCTAssertEqual(SuggestCore.answer(from: reply, original: "быстро", spelling: spelling).items, ["быстрее", "небыстро"])
    }

    func testTheTextAndTheParsedEntryPointsAgree() {
        let outputs = [
            SuggestF19Tests.hisAnswer, "Sorry.", #"["a", "b"]"#, #"{"replacements": []}"#,
            #"{"replacements": [{"t": "a", "k": "short"}, 3, "b"], "opposite": "c"}"#,
        ]
        for output in outputs {
            let reply = SuggestCore.reply(in: output)
            XCTAssertEqual(SuggestCore.answer(fromModelOutput: output, original: "получательно", limit: 9,
                                              stemWords: SuggestF19Tests.hisStemWords),
                           SuggestCore.answer(from: reply, original: "получательно", limit: 9,
                                              stemWords: SuggestF19Tests.hisStemWords), output)
            XCTAssertEqual(SuggestCore.answerItemCount(output), reply?.items.count, output)
            XCTAssertEqual(SuggestCore.itemKinds(inModelOutput: output), SuggestCore.itemKinds(in: reply), output)
            XCTAssertEqual(SuggestCore.misspellingCount(inModelOutput: output, original: "быстро", spelling: spelling),
                           SuggestCore.misspellingCount(in: reply, original: "быстро", spelling: spelling), output)
        }
    }
}
