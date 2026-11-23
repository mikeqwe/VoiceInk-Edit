import XCTest
@testable import EditingRequest

/// Fork F15: an AI result that holds the model's own notes is never pasted silently, and a translated
/// take asks for more thinking.
final class EnhancementResultCheckTests: XCTestCase {
    private let english = OutputLanguage.Decision.translate(to: "en")

    private func problem(_ text: String, _ decision: OutputLanguage.Decision = .off, dictation: String? = "ru")
        -> EnhancementResultCheck.Problem?
    {
        EnhancementResultCheck.problem(in: text, decision: decision, dictationLanguage: dictation)
    }

    // The shapes of the leaks seen on the real request path (F15-REPORT.md §1), with synthetic content.

    func testASelfCorrectionNamingTheCleanedTranscriptIsRejected() {
        let leak = "GitHub в PostgreSQL таблица.\n\nWait, I need to translate the result into English per the output language rule. The cleaned transcript is \"Запуск GitHub в PostgreSQL таблица.\"\n\nLaunch GitHub in a PostgreSQL table."
        XCTAssertEqual(problem(leak, english), .namesItsInput)
        // The same class without any translation (cleanup-eval S22: a Russian Clean take).
        let russian = "Нет, тесты не проходят на мейне?\n\nWait, I need to correct that. The cleaned transcript is a question: \"Тесты проходят на мейне?\""
        XCTAssertEqual(problem(russian), .namesItsInput)
    }

    func testAStepLabelOnItsOwnLineIsRejected() {
        let leak = "The transcript is a question. I only clean it and translate it.\n\nTranslated into English:\n\nAnswer, how much is two plus two?"
        XCTAssertEqual(problem(leak, english), .stepLabel)
        XCTAssertEqual(problem("Cleaned version:\nТесты проходят на мейне?"), .stepLabel)
        XCTAssertEqual(problem("Cleaned transcript:\nPush to GitHub.", english), .stepLabel)
    }

    func testATranslatedResultStillInCyrillicIsRejected() {
        XCTAssertEqual(problem("Push to GitHub. Запушь в гитхаб.", english), .sourceScript)
        XCTAssertEqual(problem("GitHub в PostgreSQL таблица.", english), .sourceScript)
    }

    // What a speaker says must pass: no rule matches a word a speaker could dictate.

    func testDictationAboutTranslationTranscriptsAndInstructionsPasses() {
        for text in [
            "Translate this into English.",
            "Don't translate this, leave it in Russian.",
            "Wait, I'll take a look now.",
            "I need to correct the config and translate the docs.",
            "The transcript is empty again, check VoiceInk.",
            "Per the instructions in the ticket, restart the job.",
            "Please do a review before lunch, I need to merge it for the release.",
            "Here is the plan: 1. Update Kotlin. 2. Run the tests.",
            "The translation looks fine to me.",
            "Translation: done, see the doc.",
            "Cleaned up the config, see the PR.",
        ] {
            XCTAssertNil(problem(text, english), text)
            XCTAssertNil(problem(text), text)
        }
    }

    func testOneCyrillicNameInATranslationPassesAndRussianTakesAreNotScriptChecked() {
        XCTAssertNil(problem("Hi Илшат, can you look at my PR?", english), "one word in Cyrillic")
        XCTAssertNil(problem("Запушь в GitHub и открой PR."), "an untranslated take stays in its language")
        XCTAssertNil(problem("Запушь в GitHub.", .asSpoken))
        XCTAssertNil(problem("Запушь в GitHub.", english, dictation: nil), "no dictation language: no script rule")
        XCTAssertNil(problem("Запушь в GitHub.", .translate(to: "uk")), "a Cyrillic target is not checked")
    }

    // The retry and the visible failure.

    func testARejectedResultIsRequestedOnceMoreAndAcceptedWhenClean() async {
        var sent = 0
        var logged: [String] = []
        let replies = ["Translated to English:\nPush to GitHub.", "Push to GitHub."]
        let outcome = await EnhancementResultCheck.request(
            decision: english, dictationLanguage: "ru", text: { $0 }, log: { logged.append($0) }
        ) { () async -> String in
            defer { sent += 1 }
            return replies[sent]
        }
        guard case .accepted(let text, let pasted) = outcome else { return XCTFail("expected the second reply") }
        XCTAssertEqual(text, "Push to GitHub.")
        XCTAssertEqual(pasted, "Push to GitHub.")
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(logged, ["Enhancement result rejected reason=step-label attempt=1/2 outputLanguage=translate(en) action=retry"])
    }

    func testTwoRejectionsFailWithoutAThirdRequest() async {
        var sent = 0
        var logged: [String] = []
        let outcome = await EnhancementResultCheck.request(
            decision: english, dictationLanguage: "ru", text: { $0 }, log: { logged.append($0) }
        ) { () async -> String in
            sent += 1
            return "GitHub в PostgreSQL таблица."
        }
        guard case .rejected(let found) = outcome else { return XCTFail("expected a rejection") }
        XCTAssertEqual(found, .sourceScript)
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(logged.last, "Enhancement result rejected reason=source-script attempt=2/2 outputLanguage=translate(en) action=fail")
    }

    func testACleanFirstReplyIsSentOnce() async {
        var sent = 0
        let outcome = await EnhancementResultCheck.request(
            decision: .off, dictationLanguage: "ru", text: { $0 }, log: { _ in XCTFail("nothing to log") }
        ) { () async -> String in
            sent += 1
            return "Запушь в GitHub."
        }
        guard case .accepted = outcome else { return XCTFail("expected acceptance") }
        XCTAssertEqual(sent, 1)
    }

    // The request.

    func testATranslatedTakeThinksAtHighUnlessTheUserChoseAnEffort() {
        XCTAssertEqual(OutputLanguage.requestEffort(setting: .modelDefault, decision: english), .high)
        XCTAssertEqual(OutputLanguage.requestEffort(setting: .low, decision: english), .low, "the user's choice wins")
        XCTAssertEqual(OutputLanguage.requestEffort(setting: .medium, decision: english), .medium)
        for decision: OutputLanguage.Decision in [.off, .asSpoken, .appNotListed, .unknownLayout] {
            XCTAssertEqual(OutputLanguage.requestEffort(setting: .modelDefault, decision: decision), .modelDefault,
                           "every other take sends the stock request")
        }
        XCTAssertEqual(OutputLanguage.requestEffort(setting: .modelDefault, decision: english).requestValue(model: "claude-haiku-5-5"), "high")
    }
}
