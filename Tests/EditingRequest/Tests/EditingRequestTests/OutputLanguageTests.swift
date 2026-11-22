import XCTest
@testable import EditingRequest

/// Fork F12: the output language follows the keyboard layout, in the listed apps.
final class OutputLanguageTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let dia = "company.thebrowser.dia"
    private let t3 = "com.t3tools.t3code"
    private let abc = OutputLanguage.Layout(sourceID: "com.apple.keylayout.ABC", language: "en")
    private let russian = OutputLanguage.Layout(sourceID: "com.apple.keylayout.Russian", language: "ru")

    private func decide(_ layout: OutputLanguage.Layout, app: String?, dictation: String? = "ru",
                        listed: [String]? = nil) -> OutputLanguage.Decision {
        OutputLanguage.decide(dictationLanguage: dictation, layout: layout, app: app,
                              listedApps: listed ?? [slack, dia])
    }

    func testAnEnglishLayoutInAListedAppTranslatesIntoEnglish() {
        XCTAssertEqual(decide(abc, app: slack), .translate(to: "en"))
        XCTAssertEqual(decide(abc, app: dia), .translate(to: "en"))
        XCTAssertEqual(OutputLanguage.badge(for: decide(abc, app: slack)), "EN")
    }

    func testTheDictationLanguagesLayoutKeepsTheTakeAsToday() {
        let decision = decide(russian, app: slack)
        XCTAssertEqual(decision, .asSpoken)
        XCTAssertNil(OutputLanguage.section(for: decision), "the Russian layout adds nothing")
        XCTAssertNil(OutputLanguage.badge(for: decision))
    }

    func testAnAppNotOnTheListKeepsTheTakeAsToday() {
        let decision = decide(abc, app: t3)
        XCTAssertEqual(decision, .appNotListed)
        XCTAssertNil(OutputLanguage.section(for: decision))
        XCTAssertNil(OutputLanguage.badge(for: decision))
        XCTAssertEqual(decide(abc, app: nil), .appNotListed, "an unknown front app is not listed")
    }

    func testOffByDefault() {
        XCTAssertEqual(decide(abc, app: slack, dictation: nil), .off)
        XCTAssertEqual(decide(abc, app: slack, dictation: "  "), .off)
        let name = "OutputLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(OutputLanguage.dictationLanguage(in: defaults))
        XCTAssertEqual(OutputLanguage.decide(layout: abc, app: slack, in: defaults), .off)
        defaults.set("ru", forKey: OutputLanguage.dictationLanguageDefaultsKey)
        XCTAssertEqual(OutputLanguage.decide(layout: abc, app: slack, in: defaults), .translate(to: "en"))
    }

    func testTheAppListDefaultsToSlackAndDiaAndAStoredListReplacesIt() {
        let name = "OutputLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(OutputLanguage.bundleIdentifiers(in: defaults).apps, [slack, dia])
        XCTAssertFalse(OutputLanguage.defaultBundleIdentifiers.contains(t3), "T3 Code is off by default")
        OutputLanguage.setBundleIdentifiers([" \(t3) ", t3, ""], in: defaults)
        XCTAssertEqual(OutputLanguage.bundleIdentifiers(in: defaults).apps, [t3])
        defaults.set("ru", forKey: OutputLanguage.dictationLanguageDefaultsKey)
        XCTAssertEqual(OutputLanguage.decide(layout: abc, app: slack, in: defaults), .appNotListed)
        defaults.set(3, forKey: OutputLanguage.appsDefaultsKey)
        let wrongType = OutputLanguage.bundleIdentifiers(in: defaults)
        XCTAssertEqual(wrongType.apps, [])
        XCTAssertTrue(wrongType.invalid, "a stored value of the wrong type is reported")
    }

    func testAThirdLayoutGivesItsOwnLanguage() {
        let german = OutputLanguage.Layout(sourceID: "com.apple.keylayout.German", language: "de")
        XCTAssertEqual(decide(german, app: slack), .translate(to: "de"))
        XCTAssertEqual(OutputLanguage.badge(for: .translate(to: "de")), "DE")
        XCTAssertTrue(OutputLanguage.section(for: .translate(to: "de"))!.contains("write the result in German"))
        let british = OutputLanguage.Layout(sourceID: "com.apple.keylayout.British", language: "en-GB")
        XCTAssertEqual(decide(british, app: slack), .translate(to: "en"))
        XCTAssertEqual(decide(russian, app: slack, dictation: "ru-RU"), .asSpoken)
    }

    func testALayoutWithoutALanguageTranslatesNothingAndShowsAQuestionMark() {
        let hex = OutputLanguage.Layout(sourceID: "com.apple.keylayout.UnicodeHexInput", language: "")
        XCTAssertEqual(decide(hex, app: slack), .unknownLayout)
        XCTAssertEqual(decide(OutputLanguage.Layout(sourceID: nil, language: nil), app: slack), .unknownLayout)
        XCTAssertNil(OutputLanguage.section(for: .unknownLayout))
        XCTAssertEqual(OutputLanguage.badge(for: .unknownLayout), "?")
        XCTAssertEqual(decide(hex, app: t3), .appNotListed, "no badge outside the listed apps")
    }

    func testTheSectionTranslatesAfterTheCleanupAndKeepsTermsAndThePrefix() throws {
        let section = try XCTUnwrap(OutputLanguage.section(for: .translate(to: "en")))
        XCTAssertTrue(section.hasPrefix("# Output language\n"))
        XCTAssertTrue(section.contains("write the result in English"))
        XCTAssertTrue(section.contains("First do everything the instructions above ask, then translate the result into English"))
        XCTAssertTrue(section.contains("This replaces any instruction to keep, preserve or not translate the original language"))
        XCTAssertTrue(section.contains("simple, clear language suitable for B1-level readers"))
        XCTAssertTrue(section.contains("standard spelling"))
        XCTAssertTrue(section.contains("\"[voice] \""))
        XCTAssertNil(OutputLanguage.section(for: .off))
        XCTAssertNil(OutputLanguage.section(for: .asSpoken))
    }

    func testOnlyModesWithAnAIPromptFollow() {
        XCTAssertTrue(OutputLanguage.modeFollows(aiEnhancementEnabled: true, usesVoiceInkRefine: false), "Clean, Rewrite")
        XCTAssertFalse(OutputLanguage.modeFollows(aiEnhancementEnabled: false, usesVoiceInkRefine: false), "Raw, Note")
        XCTAssertFalse(OutputLanguage.modeFollows(aiEnhancementEnabled: true, usesVoiceInkRefine: true), "Refine has no prompt")
    }

    func testTheTakeLogLineNamesTheDecisionAndItsInputs() {
        let line = OutputLanguage.takeLogLine(decision: .translate(to: "en"), layout: abc, app: slack,
                                              dictationLanguage: "ru", modeFollows: true, appsInvalid: false)
        XCTAssertEqual(line, "Output language take decision=translate(en) applies=true mode=ai layout=com.apple.keylayout.ABC layoutLanguage=en app=com.tinyspeck.slackmacgap dictation=ru")
        let raw = OutputLanguage.takeLogLine(decision: .translate(to: "en"), layout: abc, app: slack,
                                             dictationLanguage: "ru", modeFollows: false, appsInvalid: true)
        XCTAssertTrue(raw.contains("applies=false mode=no-ai"))
        XCTAssertTrue(raw.hasSuffix(" invalid-setting=outputLanguageApps"))
        let unreadable = OutputLanguage.takeLogLine(decision: .unknownLayout, layout: .init(sourceID: nil, language: nil),
                                                    app: nil, dictationLanguage: nil, modeFollows: true, appsInvalid: false)
        XCTAssertTrue(unreadable.contains("layout=unreadable layoutLanguage=unreadable app=unknown dictation=off"))
    }
}
