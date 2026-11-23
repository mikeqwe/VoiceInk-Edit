import XCTest
@testable import EditingRequest

/// F19 (the owner 23.11, 21:44): «разницу вариант не понял» was pasted with the model's notes around it («Фиксирую: …
/// Ответ: …»). Every AI prompt's result now comes inside <RESULT>…</RESULT>, and only what is inside is pasted; a
/// reply without one usable pair is requested once more, then fails visibly (F15).
final class EnhancementResultEnvelopeTests: XCTestCase {

    static let hisLeak = "разницу вариант не понял\nФиксирую: \"разницу вариант не понял\" — это очистка без изменения смысла. "
        + "Возможно, речь о \"разницу вариантов не понял\", но менять слова не буду.\n\nОтвет: разницу вариант не понял"

    func testOnlyTheInsideOfThePairIsPasted() {
        XCTAssertEqual(EnhancementResultCheck.pasted(from: "<RESULT>Разницу вариант не понял.</RESULT>", envelope: true),
                       "Разницу вариант не понял.")
        XCTAssertEqual(EnhancementResultCheck.pasted(from: "Фиксирую: очистка.\n<RESULT>\n Разницу вариант не понял. \n</RESULT>\nОтвет: готово",
                                                     envelope: true), "Разницу вариант не понял.")
    }

    func testHisLeakWithoutTheTagsIsNotPasted() {
        XCTAssertNil(EnhancementResultCheck.pasted(from: Self.hisLeak, envelope: true))
        XCTAssertEqual(EnhancementResultCheck.verdict(onReply: Self.hisLeak, envelope: true, decision: .off, dictationLanguage: "ru"),
                       .reject(.resultTag))
    }

    func testABrokenEnvelopeIsNotPasted() {
        for reply in ["<RESULT>текст", "текст</RESULT>", "</RESULT>текст<RESULT>", "<RESULT>  \n</RESULT>",
                      "<RESULT>один</RESULT> <RESULT>два</RESULT>", "<RESULT>один <RESULT>два</RESULT>", "<RESULT>один</RESULT> два</RESULT>", "<result>текст</result>"] {
            XCTAssertNil(EnhancementResultCheck.pasted(from: reply, envelope: true), reply)
        }
    }

    func testWithoutTheEnvelopeTheReplyIsPastedAsBefore() {
        XCTAssertEqual(EnhancementResultCheck.pasted(from: "Запушь в GitHub.", envelope: false), "Запушь в GitHub.")
        XCTAssertEqual(EnhancementResultCheck.verdict(onReply: "Запушь в GitHub.", envelope: false, decision: .off, dictationLanguage: "ru"),
                       .paste("Запушь в GitHub."))
    }

    func testTheRulesStillCheckWhatIsInside() {
        XCTAssertEqual(EnhancementResultCheck.verdict(onReply: "<RESULT>Cleaned: push it.</RESULT>", envelope: true,
                                                      decision: .off, dictationLanguage: "ru"), .reject(.stepLabel))
        XCTAssertEqual(EnhancementResultCheck.verdict(onReply: "Cleaned: <RESULT>Push it.</RESULT>", envelope: true,
                                                      decision: .off, dictationLanguage: "ru"), .paste("Push it."), "a label outside is dropped")
    }

    func testTheInstructionNamesTheTagsTheParserReads() {
        XCTAssertTrue(EnhancementResultCheck.envelopeInstruction.contains(EnhancementResultCheck.resultOpen))
        XCTAssertTrue(EnhancementResultCheck.envelopeInstruction.contains(EnhancementResultCheck.resultClose))
        XCTAssertEqual(EnhancementResultCheck.resultOpen, "<RESULT>")
        XCTAssertEqual(EnhancementResultCheck.resultClose, "</RESULT>")
    }

    func testAMissingEnvelopeIsRequestedOnceMoreThenAccepted() async {
        var sent = 0
        var logged: [String] = []
        let replies = [Self.hisLeak, "<RESULT>Разницу вариант не понял.</RESULT>"]
        let outcome = await EnhancementResultCheck.request(
            decision: .off, dictationLanguage: "ru", envelope: true, text: { $0 }, log: { logged.append($0) }
        ) { () async -> String in
            defer { sent += 1 }
            return replies[sent]
        }
        guard case .accepted(let reply, let pasted) = outcome else { return XCTFail("expected the second reply") }
        XCTAssertEqual(reply, "<RESULT>Разницу вариант не понял.</RESULT>")
        XCTAssertEqual(pasted, "Разницу вариант не понял.")
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(logged, ["Enhancement result rejected reason=result-tag attempt=1/2 outputLanguage=off action=retry"])
    }

    func testTwoMissingEnvelopesFailVisibly() async {
        var sent = 0
        var logged: [String] = []
        let outcome = await EnhancementResultCheck.request(
            decision: .off, dictationLanguage: "ru", envelope: true, text: { $0 }, log: { logged.append($0) }
        ) { () async -> String in
            sent += 1
            return Self.hisLeak
        }
        guard case .rejected(let found) = outcome else { return XCTFail("expected a rejection") }
        XCTAssertEqual(found, .resultTag)
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(logged.last, "Enhancement result rejected reason=result-tag attempt=2/2 outputLanguage=off action=fail")
    }
}
