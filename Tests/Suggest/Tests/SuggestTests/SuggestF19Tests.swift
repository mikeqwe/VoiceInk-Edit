import XCTest
@testable import Suggest

/// F19 (the owner 23.11, 21:30): «Давай ответ покороче, без лишних деталей, которые не нужны получательно.» with
/// «получательно» selected. The request carried SPELLING with ten stem words, «получателю» among them, and the nine
/// options were «понятно, ясно, непонятно, …»: the model reads «…не нужны, понятно» as a fine sentence and drops a
/// word that only sounds right. The owner chose S2: for a word no checker knows, the list is the model's first
/// option, then the checker's stem words, then the model's other options, cut to the Number of Replacements.
final class SuggestF19Tests: XCTestCase {

    /// The stem words the installed build sent for «получательно» (NSSpellChecker, reproduced 23.11).
    static let hisStemWords = ["получательниц", "получатель", "получателя", "получатели", "получателем", "получателю",
                               "получателей", "получателях", "получателями", "получателям"]
    /// His nine options at 21:30 (screenshot), as the model's answer; «непонятно» was its opposite reading.
    static let hisAnswer = #"{"meaning": "m", "opposite": "непонятно", "replacements": ["понятно", "ясно", "непонятно", "договорились", "пожалуйста", "по существу", "вкратце", "получается", "короче"]}"#

    func testHisCaseShowsTheModelsFirstThenTheStemWords() {
        let answer = SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно", limit: 9,
                                        stemWords: Self.hisStemWords)
        XCTAssertEqual(answer.items, ["понятно", "получательниц", "получатель", "получателя", "получатели", "получателем",
                                      "получателю", "получателей", "непонятно"])
        XCTAssertEqual(answer.stemWords, 7)
        // F17: the opposite reading, cut by the stem words, takes the last place.
        XCTAssertEqual(answer.opposite, .added)
    }

    func testTheListIsCutAtTheNumberOfReplacements() {
        let answer = SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно", limit: 5,
                                        stemWords: Self.hisStemWords)
        XCTAssertEqual(answer.items, ["понятно", "получательниц", "получатель", "получателя", "непонятно"])
        XCTAssertEqual(answer.stemWords, 3)
    }

    func testModelsOtherOptionsFollowTheStemWords() {
        let output = #"{"replacements": ["получателю", "кратко", "понятно", "ясно"]}"#
        let answer = SuggestCore.answer(fromModelOutput: output, original: "получательно", limit: 9,
                                        stemWords: ["получатель", "получателю", "получателям"])
        // The model's first is kept first; a stem word equal to it is not repeated.
        XCTAssertEqual(answer.items, ["получателю", "получатель", "получателям", "кратко", "понятно", "ясно"])
        XCTAssertEqual(answer.stemWords, 2)
        XCTAssertEqual(answer.opposite, .none)
    }

    func testStemWordsDedupeAgainstModelOptionsByVariant() {
        let output = #"{"replacements": ["кратко", "Получателю.", "понятно"]}"#
        let answer = SuggestCore.answer(fromModelOutput: output, original: "получательно", limit: 9,
                                        stemWords: ["получателю"])
        XCTAssertEqual(answer.items, ["кратко", "получателю", "понятно"])
    }

    func testNoStemWordsLeaveTheAnswerAsBefore() {
        for limit in [3, 5, 9] {
            XCTAssertEqual(
                SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно", limit: limit, stemWords: []),
                SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно", limit: limit))
        }
        XCTAssertEqual(SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно").stemWords, 0)
    }

    func testANewSetSkipsStemWordsAlreadyShown() {
        let first = SuggestCore.answer(fromModelOutput: Self.hisAnswer, original: "получательно", limit: 9,
                                       stemWords: Self.hisStemWords)
        let next = #"{"replacements": ["кратко", "лаконично", "сжато"]}"#
        let answer = SuggestCore.answer(fromModelOutput: next, original: "получательно", excluding: first.items, limit: 9,
                                        stemWords: Self.hisStemWords)
        XCTAssertEqual(answer.items, ["кратко", "получателях", "получателями", "получателям", "лаконично", "сжато"])
        XCTAssertEqual(answer.stemWords, 3)
    }

    func testAnUnparsedAnswerStaysEmptySoTheRetryRuns() {
        let answer = SuggestCore.answer(fromModelOutput: "Sorry, I can't.", original: "получательно", limit: 9,
                                        stemWords: Self.hisStemWords)
        XCTAssertEqual(answer.items, [])
        XCTAssertEqual(answer.stemWords, 0)
    }

    func testAnAnswerWithNoUsableItemShowsTheStemWords() {
        let answer = SuggestCore.answer(fromModelOutput: #"{"replacements": ["получательно"]}"#, original: "получательно",
                                        limit: 3, stemWords: Self.hisStemWords)
        XCTAssertEqual(answer.items, ["получательниц", "получатель", "получателя"])
    }

    func testAnOppositeAlreadyInTheListStaysWhereItIs() {
        let output = #"{"opposite": "непонятно", "replacements": ["непонятно", "понятно"]}"#
        let answer = SuggestCore.answer(fromModelOutput: output, original: "получательно", limit: 4,
                                        stemWords: ["получатель", "получателю"])
        XCTAssertEqual(answer.items, ["непонятно", "получатель", "получателю", "понятно"])
        XCTAssertEqual(answer.opposite, .ranked)
    }

    func testStemWordsAreTrimmedAndNeverTheOriginal() {
        let answer = SuggestCore.answer(fromModelOutput: #"{"replacements": ["кратко"]}"#, original: "получательно",
                                        limit: 9, stemWords: [" получателю ", "получательно", ""])
        XCTAssertEqual(answer.items, ["кратко", "получателю"])
    }
}
