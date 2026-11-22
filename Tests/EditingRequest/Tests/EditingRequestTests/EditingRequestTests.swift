import XCTest
@testable import EditingRequest

/// Fork F11: the effort sent on the Anthropic requests of cleanup, Rewrite and Suggest, and which
/// takes capture the screen.
final class EditingRequestTests: XCTestCase {
    private func json(_ body: AnthropicEffortRequestBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheSettingIsLowUnlessStoredAndAnUnknownValueIsReported() {
        XCTAssertEqual(EditingModelEffort.resolve(nil).effort, .low)
        XCTAssertNil(EditingModelEffort.resolve(nil).invalid)
        XCTAssertEqual(EditingModelEffort.resolve("default").effort, .modelDefault)
        XCTAssertEqual(EditingModelEffort.resolve("medium").effort, .medium)
        let unknown = EditingModelEffort.resolve("minimal")
        XCTAssertEqual(unknown.effort, .low)
        XCTAssertEqual(unknown.invalid, "minimal", "an unknown stored value is reported, not silently replaced")
    }

    func testEffortGoesOnlyToModelsThatAcceptIt() {
        XCTAssertEqual(EditingModelEffort.low.requestValue(model: "claude-haiku-5-5"), "low")
        XCTAssertEqual(EditingModelEffort.high.requestValue(model: "claude-sonnet-5-5"), "high")
        XCTAssertEqual(EditingModelEffort.low.requestValue(model: "claude-opus-4-5-20251101"), "low")
        XCTAssertNil(EditingModelEffort.low.requestValue(model: "claude-haiku-4-5"), "Haiku 4.5 is not in the docs' effort list")
        XCTAssertNil(EditingModelEffort.low.requestValue(model: "claude-sonnet-4-5"))
        XCTAssertNil(EditingModelEffort.modelDefault.requestValue(model: "claude-haiku-5-5"),
                     "\"default\" sends the stock request")
    }

    func testTheBodyIsTheStockRequestPlusOutputConfig() throws {
        let body = AnthropicEffortRequestBody(
            model: "claude-haiku-5-5", maxTokens: 8192, system: "SYS",
            messages: [.init(role: "user", content: "\n<TRANSCRIPT>\nhi\n</TRANSCRIPT>")], effort: "low")
        let object = try json(body)
        XCTAssertEqual(Set(object.keys), ["model", "max_tokens", "system", "messages", "output_config"])
        XCTAssertEqual(object["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(object["max_tokens"] as? Int, 8192)
        XCTAssertEqual(object["system"] as? String, "SYS")
        XCTAssertEqual((object["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(object["thinking"], "thinking stays adaptive: effort is the documented lever")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "\n<TRANSCRIPT>\nhi\n</TRANSCRIPT>"]])
    }

    func testNoSystemFieldWithoutASystemPrompt() throws {
        let body = AnthropicEffortRequestBody(
            model: "claude-haiku-5-5", maxTokens: 8192, system: nil, messages: [.init(role: "user", content: "x")], effort: "low")
        XCTAssertNil(try json(body)["system"])
    }

    func testTheReplyTextSkipsThinkingBlocks() throws {
        let reply = #"{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"[voice] Done."}]}"#
        XCTAssertEqual(try AnthropicEffortRequestBody.text(fromResponse: Data(reply.utf8)), "[voice] Done.")
        let empty = #"{"content":[{"type":"thinking","thinking":"..."}]}"#
        XCTAssertEqual(try AnthropicEffortRequestBody.text(fromResponse: Data(empty.utf8)), "")
    }

    func testOnlyAModeWithAIAndItsScreenSwitchCapturesTheScreen() {
        XCTAssertTrue(RecordingScreenContext.captures(aiEnhancementEnabled: true, usesVoiceInkRefine: false, useScreenCapture: true))
        XCTAssertFalse(RecordingScreenContext.captures(aiEnhancementEnabled: true, usesVoiceInkRefine: false, useScreenCapture: false),
                       "the switch off: no capture, so no screen names in the vocabulary either")
        XCTAssertFalse(RecordingScreenContext.captures(aiEnhancementEnabled: false, usesVoiceInkRefine: false, useScreenCapture: true),
                       "a mode without AI (Raw) sends nothing, so it captures nothing")
        XCTAssertFalse(RecordingScreenContext.captures(aiEnhancementEnabled: true, usesVoiceInkRefine: true, useScreenCapture: true),
                       "VoiceInk Refine takes no context")
    }
}
