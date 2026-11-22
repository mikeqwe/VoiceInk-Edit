import XCTest
@testable import Suggest

/// F10: Suggest offers the grammatical form that was meant. A dictated word often comes back with the wrong
/// ending («расскажу» for a requested «расскажи»), so the prompt asks for that one form when the words around
/// the selection call for it, and for none when the selection's own form fits.
final class SuggestF10Tests: XCTestCase {
    func testThePromptAsksForTheFormTheTextNeeds() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        XCTAssertTrue(prompt.contains(
            "When another form of the SELECTION's own word fits the text around it better, that form is a likely replacement; rank it by how likely it is."),
            prompt)
        // The form is judged from the words around the selection, not from its own ending, which would
        // otherwise anchor the reading («I will tell» instead of a request).
        XCTAssertTrue(prompt.contains("Judge the form from the words around it, as if the SELECTION's own ending were unknown"), prompt)
        // What the form is judged from: agreement, a request (the owner's case), English verb forms and plurals.
        XCTAssertTrue(prompt.contains("agreement with its subject or neighbours in person, number, gender and case"), prompt)
        XCTAssertTrue(prompt.contains("a request or instruction to someone, which needs the imperative, rather than a statement"), prompt)
        XCTAssertTrue(prompt.contains("an English verb form or plural"), prompt)
        // F8's gain: no list of forms for a word that is already right.
        XCTAssertTrue(prompt.contains(
            "Offer at most one other form of the SELECTION's own word, the one that fits best, and none when the SELECTION's own form fits the text best."),
            prompt)
        // The meaning step names who speaks to whom, which tells a request from a statement.
        XCTAssertTrue(prompt.contains("a few words on what the text says at the SELECTION's place and who says it to whom"), prompt)
    }

    func testTheF10EvaluationWordsAreNotPromptExamples() {
        let prompt = SuggestCore.systemPrompt(writingLanguage: "ru")
        for word in ["расскажу", "расскажи", "рассказал", "дизайнер", "стала", "коротко", "runs the test", "run the test"] {
            XCTAssertFalse(prompt.contains(word), "an evaluation word is in the prompt: \(word)")
        }
    }
}
