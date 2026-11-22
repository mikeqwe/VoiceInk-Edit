import Foundation

/// Fork F12: the output language follows the keyboard layout, in the apps the user lists.
///
/// The user names the language they dictate in. When a take ends (the release) with a keyboard layout
/// of another language active, in a listed app, the AI request gets one more system-message section,
/// "Output language": clean as the mode's prompt says, then translate into the layout's language. The
/// prompts themselves are not changed, and every other take is exactly as before. The section is added
/// where the vocabulary and context sections are (`AIEnhancementService.getSystemMessage`), so it
/// reaches every mode with an AI prompt (Clean, Rewrite) and no other path: modes without AI
/// enhancement (Raw, Note) have no request, and Suggest builds its own.
///
/// Settings: `outputLanguageDictationLanguage` (a language code; unset or empty is off, the default)
/// and `outputLanguageApps` (bundle identifiers; absent means `defaultBundleIdentifiers`).
enum OutputLanguage {
    static let dictationLanguageDefaultsKey = "outputLanguageDictationLanguage"
    static let appsDefaultsKey = "outputLanguageApps"
    static let defaultBundleIdentifiers: [String] = ["com.tinyspeck.slackmacgap", "company.thebrowser.dia"]

    /// The keyboard layout as read: its input source ID and the first of its languages.
    struct Layout: Equatable, Sendable {
        let sourceID: String?
        let language: String?
    }

    /// What a take does with its output language.
    enum Decision: Equatable, Sendable {
        /// No dictation language is set: the feature is off.
        case off
        /// The front app is not on the list.
        case appNotListed
        /// The layout has no language, or it could not be read: nothing is translated.
        case unknownLayout
        /// The layout's language is the dictation language: the output stays as spoken.
        case asSpoken
        /// The output is written in this language (a primary language code such as "en").
        case translate(to: String)

        var logValue: String {
            switch self {
            case .off: return "off"
            case .appNotListed: return "app-not-listed"
            case .unknownLayout: return "unknown-layout"
            case .asSpoken: return "as-spoken"
            case .translate(let code): return "translate(\(code))"
            }
        }
    }

    /// The decision for one take. The layout is the one active at the release.
    static func decide(dictationLanguage: String?, layout: Layout, app: String?, listedApps: [String]) -> Decision {
        guard let dictation = primaryLanguage(dictationLanguage) else { return .off }
        guard let app, listedApps.contains(app) else { return .appNotListed }
        guard let layoutLanguage = primaryLanguage(layout.language) else { return .unknownLayout }
        return layoutLanguage == dictation ? .asSpoken : .translate(to: layoutLanguage)
    }

    /// "en-GB", "en_US" and "EN" are all "en". Nil or blank is no language.
    static func primaryLanguage(_ code: String?) -> String? {
        guard let code else { return nil }
        let primary = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() }
        guard let primary, !primary.isEmpty else { return nil }
        return primary
    }

    /// The language's English name, as the section names it ("en" → "English").
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code) ?? code
    }

    /// The recorder badge while recording: the target language when the take would be translated,
    /// "?" when the app is listed but the layout has no readable language, otherwise none.
    static func badge(for decision: Decision) -> String? {
        switch decision {
        case .translate(let code): return code.uppercased()
        case .unknownLayout: return "?"
        case .off, .appNotListed, .asSpoken: return nil
        }
    }

    /// The system-message section for a take, or nil when the take keeps its language.
    /// Translation style from the user's superwhisper mode "EN | Default".
    static func section(for decision: Decision) -> String? {
        guard case .translate(let code) = decision else { return nil }
        let name = englishName(code)
        return """
            # Output language
            The user's keyboard layout is set to \(name), so write the result in \(name). First do everything the instructions above ask, then translate the result into \(name). Return only the \(name) text, without the original. This replaces any instruction to keep, preserve or not translate the original language.
            Translate naturally, as a native speaker would say the same thing, in simple, clear language suitable for B1-level readers, and keep the speaker's tone. Keep technical terms, product and tool names, file names, code and commands in their standard spelling.
            If the instructions above require the result to begin with a fixed prefix such as "[voice] ", keep that prefix unchanged at the very start.
            """
    }

    /// Fork F15: the effort a take's request is sent with. A translated take thinks at `high` unless the
    /// user chose an effort: without thinking, Claude Haiku 5.5 wrote its clean-then-translate steps into
    /// the pasted text (F15-REPORT.md), and Anthropic recommends `high` "when instruction following matters
    /// most" (Prompting Claude Haiku 5.5). Every other take keeps the setting as it is.
    static func requestEffort(setting: EditingModelEffort, decision: Decision) -> EditingModelEffort {
        guard case .translate = decision, setting == .modelDefault else { return setting }
        return .high
    }

    // MARK: - Settings

    /// The dictation language, or nil when the feature is off.
    static func dictationLanguage(in defaults: UserDefaults = .standard) -> String? {
        primaryLanguage(defaults.string(forKey: dictationLanguageDefaultsKey))
    }

    /// The listed apps. No stored list: the default list. A stored value that is not a list of strings
    /// lists no app; `invalid` says so, for the log.
    static func bundleIdentifiers(in defaults: UserDefaults = .standard) -> (apps: [String], invalid: Bool) {
        guard let stored = defaults.object(forKey: appsDefaultsKey) else { return (defaultBundleIdentifiers, false) }
        guard let list = stored as? [String] else { return ([], true) }
        return (normalized(list), false)
    }

    static func setBundleIdentifiers(_ list: [String], in defaults: UserDefaults = .standard) {
        defaults.set(normalized(list), forKey: appsDefaultsKey)
    }

    static func normalized(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The decision with the settings read now.
    static func decide(layout: Layout, app: String?, in defaults: UserDefaults = .standard) -> Decision {
        decide(dictationLanguage: dictationLanguage(in: defaults), layout: layout, app: app,
               listedApps: bundleIdentifiers(in: defaults).apps)
    }

    /// Whether a mode's takes can follow the layout: only a mode whose AI request carries a system
    /// message (AI enhancement on, a provider other than VoiceInk Refine).
    static func modeFollows(aiEnhancementEnabled: Bool, usesVoiceInkRefine: Bool) -> Bool {
        aiEnhancementEnabled && !usesVoiceInkRefine
    }

    /// The one log line per take, written at the release.
    static func takeLogLine(decision: Decision, layout: Layout, app: String?, dictationLanguage: String?,
                            modeFollows: Bool, appsInvalid: Bool) -> String {
        var line = "Output language take decision=\(decision.logValue)"
            + " applies=\(modeFollows && section(for: decision) != nil)"
            + " mode=\(modeFollows ? "ai" : "no-ai")"
            + " layout=\(layout.sourceID ?? "unreadable") layoutLanguage=\(layout.language.map { $0.isEmpty ? "none" : $0 } ?? "unreadable")"
            + " app=\(app ?? "unknown") dictation=\(dictationLanguage ?? "off")"
        if appsInvalid { line += " invalid-setting=\(appsDefaultsKey)" }
        return line
    }
}
