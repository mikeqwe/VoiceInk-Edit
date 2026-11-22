import XCTest
@testable import EditingRequest

/// Fork F14: the voice mark is set once, can differ per app, and is put in front by the app.
final class VoiceMarkTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let t3 = "com.t3tools.t3code"
    private let textEdit = "com.apple.TextEdit"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "VoiceMarkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// What a path's result is: `promptAddsMark` is its prompt's switch, `app` the take's app (nil for
    /// the History paths, which have no take app).
    private func result(_ text: String, promptAddsMark: Bool, app: String?) -> String {
        guard let (resolution, _) = VoiceMark.resolve(promptAddsMark: promptAddsMark, app: app, in: defaults)
        else { return text }
        return VoiceMark.applied(resolution.mark, to: text)
    }

    // MARK: - Resolution

    func testTheDefaultMarkIsTodaysPrefix() {
        XCTAssertEqual(VoiceMark.defaultMark, "[voice] ")
        XCTAssertEqual(VoiceMark.storedDefaultMark(in: defaults).mark, "[voice] ")
        XCTAssertEqual(VoiceMark.resolve(app: slack, defaultMark: "[voice] ", appMarks: [:]),
                       VoiceMark.Resolution(mark: "[voice] ", source: .default))
    }

    func testAnEditedDefaultMarkIsUsedExactlyWithItsSpace() {
        VoiceMark.setDefaultMark("🎙 ", in: defaults)
        XCTAssertEqual(result("Hello.", promptAddsMark: true, app: slack), "🎙 Hello.")
    }

    func testAnAppOverrideWinsForThatAppOnly() {
        let marks = [slack: "(voice) "]
        XCTAssertEqual(VoiceMark.resolve(app: slack, defaultMark: "[voice] ", appMarks: marks),
                       VoiceMark.Resolution(mark: "(voice) ", source: .app))
        XCTAssertEqual(VoiceMark.resolve(app: t3, defaultMark: "[voice] ", appMarks: marks),
                       VoiceMark.Resolution(mark: "[voice] ", source: .default))
    }

    func testAnUnlistedOrUnknownAppGetsTheDefault() {
        VoiceMark.setAppMarks([slack: ""], in: defaults)
        XCTAssertEqual(result("Hi.", promptAddsMark: true, app: t3), "[voice] Hi.")
        XCTAssertEqual(result("Hi.", promptAddsMark: true, app: nil), "[voice] Hi.")
    }

    func testAnEmptyMarkMeansNoPrefixAsDefaultAndPerApp() {
        VoiceMark.setAppMarks([slack: ""], in: defaults)
        XCTAssertEqual(result("Hi.", promptAddsMark: true, app: slack), "Hi.")
        VoiceMark.setDefaultMark("", in: defaults)
        XCTAssertEqual(result("Hi.", promptAddsMark: true, app: t3), "Hi.")
    }

    func testTheOverrideListShipsEmpty() {
        XCTAssertEqual(VoiceMark.appMarks(in: defaults).marks, [:])
        XCTAssertFalse(VoiceMark.appMarks(in: defaults).invalid)
    }

    func testWronglyTypedSettingsAreReportedAndFallBack() {
        defaults.set(42, forKey: VoiceMark.markDefaultsKey)
        defaults.set(["not", "a", "dictionary"], forKey: VoiceMark.appsDefaultsKey)
        let resolved = VoiceMark.resolve(promptAddsMark: true, app: slack, in: defaults)
        XCTAssertEqual(resolved?.resolution, VoiceMark.Resolution(mark: "[voice] ", source: .default))
        XCTAssertEqual(resolved?.invalidSettings, [VoiceMark.markDefaultsKey, VoiceMark.appsDefaultsKey])
    }

    func testStoredMarksKeepTheirSpacesAndBlankAppsAreDropped() {
        VoiceMark.setAppMarks([" \(slack) ": " [v] ", "  ": "x"], in: defaults)
        XCTAssertEqual(VoiceMark.appMarks(in: defaults).marks, [slack: " [v] "])
    }

    func testAnEmptyResultGetsNoMark() {
        XCTAssertEqual(VoiceMark.applied("[voice] ", to: ""), "")
        XCTAssertEqual(VoiceMark.applied("[voice] ", to: " \n"), " \n")
    }

    // MARK: - Paths

    func testCleanTakeGetsTheMarkOfTheAppItEndsIn() {
        VoiceMark.setAppMarks([slack: "(v) "], in: defaults)
        XCTAssertEqual(result("Привет.", promptAddsMark: true, app: textEdit), "[voice] Привет.")
        XCTAssertEqual(result("Привет.", promptAddsMark: true, app: slack), "(v) Привет.")
    }

    func testTranslatedCleanTakeGetsTheSameMark() {
        // F12 changes only the request; the mark goes on the translated result in the same way.
        XCTAssertNotNil(OutputLanguage.section(for: .translate(to: "en")))
        VoiceMark.setAppMarks([slack: "(v) "], in: defaults)
        XCTAssertEqual(result("Hello.", promptAddsMark: true, app: slack), "(v) Hello.")
    }

    func testRewriteAndOtherPromptsWithoutTheSwitchGetNoMark() {
        XCTAssertNil(VoiceMark.resolve(promptAddsMark: false, app: slack, in: defaults))
        XCTAssertEqual(result("Rewritten text.", promptAddsMark: false, app: slack), "Rewritten text.")
    }

    func testHistoryPathsWithoutATakeAppUseTheDefaultMark() {
        VoiceMark.setAppMarks([slack: ""], in: defaults)
        XCTAssertEqual(result("Again.", promptAddsMark: true, app: nil), "[voice] Again.")
    }

    // MARK: - Prompts stored before F14

    func testTheLegacySentenceBecomesTheSwitch() {
        let stored = "Clean the transcript.\n\nReturn only the cleaned transcript.\n\nBegin the result with \"[voice] \"."
        let converted = VoiceMark.legacyConversion(of: stored)
        XCTAssertTrue(converted.addsVoiceMark)
        XCTAssertEqual(converted.text, "Clean the transcript.\n\nReturn only the cleaned transcript.")
    }

    func testTheLegacySentenceInsideAParagraphIsRemovedToo() {
        let converted = VoiceMark.legacyConversion(of: "Return only the text. Begin the result with \"[voice] \".\n")
        XCTAssertTrue(converted.addsVoiceMark)
        XCTAssertEqual(converted.text, "Return only the text.")
    }

    func testAPromptWithoutTheSentenceIsUnchanged() {
        let rewrite = "Rewrite the selected text as the user asks.\n"
        let converted = VoiceMark.legacyConversion(of: rewrite)
        XCTAssertFalse(converted.addsVoiceMark)
        XCTAssertEqual(converted.text, rewrite)
    }

    // MARK: - Log

    func testTheLogLineQuotesTheMark() {
        XCTAssertEqual(
            VoiceMark.logLine(resolution: .init(mark: "[voice] ", source: .default), app: slack, invalidSettings: []),
            "Voice mark source=default mark=\"[voice] \" app=\(slack)")
        XCTAssertEqual(
            VoiceMark.logLine(resolution: .init(mark: "", source: .app), app: nil, invalidSettings: ["voiceMarkApps"]),
            "Voice mark source=app mark=\"\" app=none invalid-setting=voiceMarkApps")
    }
}
