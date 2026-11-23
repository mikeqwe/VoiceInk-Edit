import XCTest
@testable import Suggest

/// F18, option A: the owner's «мне нужны, получательно» meant «не нужны получателю». «которые мне нужны» is
/// grammatical, so all three sets kept «мне». For a selection of several words, the request also carries the
/// selection with «мне» read as «не» (SOUNDS_LIKE). One pair, the one his data shows.
final class SuggestF18SoundsTests: XCTestCase {

    func testHisPhraseIsSentWithNeInPlaceOfMne() {
        XCTAssertEqual(SuggestCore.soundsLike("мне нужны, получательно", writingLanguage: "ru"), "не нужны, получательно")
        XCTAssertEqual(SuggestCore.soundsLike("которые мне нужны для сборки", writingLanguage: "ru"), "которые не нужны для сборки")
    }

    func testOnlyAWholeLowerCaseWordFollowedByASpaceIsReplaced() {
        XCTAssertNil(SuggestCore.soundsLike("Мне нужно", writingLanguage: "ru"), "capital: not measured, not replaced")
        XCTAssertNil(SuggestCore.soundsLike("пришли мне", writingLanguage: "ru"), "at the end")
        XCTAssertNil(SuggestCore.soundsLike("мне, кажется", writingLanguage: "ru"), "followed by a comma")
        XCTAssertNil(SuggestCore.soundsLike("тебе мнение важно", writingLanguage: "ru"), "inside another word")
        XCTAssertNil(SuggestCore.soundsLike("омне нужны", writingLanguage: "ru"), "the end of another word")
        XCTAssertEqual(SuggestCore.soundsLike("мне мне нужны", writingLanguage: "ru"), "не не нужны", "each one")
    }

    func testOneWordAnotherLanguageOrNoneGetNothing() {
        XCTAssertNil(SuggestCore.soundsLike("мне", writingLanguage: "ru"))
        XCTAssertNil(SuggestCore.soundsLike("мне ", writingLanguage: "ru"), "one word with the space a double-click takes")
        XCTAssertNil(SuggestCore.soundsLike("мне нужны", writingLanguage: "de"))
        XCTAssertNil(SuggestCore.soundsLike("мне нужны", writingLanguage: nil))
        XCTAssertNil(SuggestCore.soundsLike("тебе нужны", writingLanguage: "ru"))
    }

    func testTheMessageCarriesItLast() {
        let context = SuggestCore.Context(around: nil, other: [], screen: nil)
        XCTAssertEqual(SuggestCore.userMessage(selection: "мне нужны", context: context, soundsLike: "не нужны"),
                       "<SELECTION>мне нужны</SELECTION>\n<SOUNDS_LIKE>не нужны</SOUNDS_LIKE>")
        XCTAssertEqual(SuggestCore.userMessage(selection: "x y", context: context), "<SELECTION>x y</SELECTION>")
    }
}
