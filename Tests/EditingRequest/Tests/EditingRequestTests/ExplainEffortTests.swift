import XCTest
@testable import EditingRequest

/// Fork F20: Explain and Ask have their own effort setting, with `xhigh` and `max`.
final class ExplainEffortTests: XCTestCase {
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "ExplainEffortTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testExplainHasItsOwnKeyAndSendsNoEffortByDefault() {
        XCTAssertEqual(EditingModelEffort.explain.defaultsKey, "explainModelEffort")
        XCTAssertEqual(EditingModelEffort.explain.standard, .modelDefault,
                       "unset, Explain sends what it sent before with the owner's settings: no effort")
        let keys = [EditingModelEffort.enhancement, EditingModelEffort.suggest, EditingModelEffort.explain].map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, 3)

        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(EditingModelEffort.current(EditingModelEffort.explain, in: defaults).effort, .modelDefault)
        XCTAssertNil(EditingModelEffort.modelDefault.requestValue(model: "claude-haiku-5-5"))
        defaults.set("high", forKey: EditingModelEffort.suggest.defaultsKey)
        XCTAssertEqual(EditingModelEffort.current(EditingModelEffort.explain, in: defaults).effort, .modelDefault,
                       "Suggest's setting no longer applies to Explain")
        defaults.set("max", forKey: EditingModelEffort.explain.defaultsKey)
        XCTAssertEqual(EditingModelEffort.current(EditingModelEffort.explain, in: defaults).effort, .max)
        XCTAssertEqual(EditingModelEffort.current(EditingModelEffort.suggest, in: defaults).effort, .high,
                       "and Explain's does not apply to Suggest")
        defaults.set("xhigh", forKey: EditingModelEffort.explain.defaultsKey)
        XCTAssertEqual(EditingModelEffort.current(EditingModelEffort.explain, in: defaults).effort, .xhigh)
    }

    func testTheNewLevelsAreTheAPIsValues() {
        XCTAssertEqual(EditingModelEffort.resolve("max", standard: .modelDefault).effort, .max)
        XCTAssertEqual(EditingModelEffort.resolve("xhigh", standard: .modelDefault).effort, .xhigh)
        XCTAssertEqual(EditingModelEffort.max.requestValue(model: "claude-haiku-5-5"), "max")
        XCTAssertEqual(EditingModelEffort.xhigh.requestValue(model: "claude-haiku-5-5"), "xhigh")
        XCTAssertEqual(EditingModelEffort.max.logValue(model: "claude-haiku-5-5", invalid: nil), "max")
    }

    func testEachLevelGoesOnlyToTheModelsTheDocsListForIt() {
        // Opus 4.5 takes low to high, but neither xhigh nor max.
        XCTAssertEqual(EditingModelEffort.high.requestValue(model: "claude-opus-4-5-20251101"), "high")
        XCTAssertNil(EditingModelEffort.max.requestValue(model: "claude-opus-4-5-20251101"))
        XCTAssertNil(EditingModelEffort.xhigh.requestValue(model: "claude-opus-4-5-20251101"))
        // Sonnet 4.6, Opus 4.6 and Mythos Preview take max but not xhigh.
        for model in ["claude-sonnet-4-6", "claude-opus-4-6", "claude-mythos-preview"] {
            XCTAssertEqual(EditingModelEffort.max.requestValue(model: model), "max", model)
            XCTAssertNil(EditingModelEffort.xhigh.requestValue(model: model), model)
        }
        for model in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-opus-4-7"] {
            XCTAssertEqual(EditingModelEffort.xhigh.requestValue(model: model), "xhigh", model)
            XCTAssertEqual(EditingModelEffort.max.requestValue(model: model), "max", model)
        }
        XCTAssertNil(EditingModelEffort.max.requestValue(model: "claude-haiku-4-5"))
        XCTAssertEqual(EditingModelEffort.max.logValue(model: "claude-opus-4-5", invalid: nil), "none(model)",
                       "a level the model does not take is logged, and the stock request goes")
    }

    func testTheHighLevelsGetRoomToThink() {
        for level in [EditingModelEffort.modelDefault, .low, .medium, .high] {
            XCTAssertEqual(level.outputTokenLimit, 8192, "\(level): LLMkit's stock limit")
            XCTAssertEqual(level.minimumTimeout, 0, "\(level): the caller's own timeout")
        }
        for level in [EditingModelEffort.xhigh, .max] {
            XCTAssertEqual(level.outputTokenLimit, 32_000, "\(level)")
            XCTAssertEqual(level.minimumTimeout, 120, "\(level)")
        }
    }
}
