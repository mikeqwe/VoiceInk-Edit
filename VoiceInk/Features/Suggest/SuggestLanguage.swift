import Foundation

/// Fork F16: the languages of Explain and Suggest, as settings (Settings → Suggest).
///
/// `explainAnswerLanguage`: the language Explain answers in, a language code. Unset: the Mac's first
/// preferred language (System Settings → General → Language & Region). Ask always answers in the
/// language of its spoken question, so it needs no setting.
///
/// `suggestWritingLanguage`: the language the user writes besides English. People who write such a
/// language often spell English terms and names in its letters, as they sound («Клод» for "Claude"), so
/// Suggest offers the English original of such a word, and its misspelling guard checks words of that
/// language's script with that language's spell checker. Unset: the first of the Mac's preferred
/// languages that is not English. `en` means English only: no such rule.
///
/// Codes are compared by their primary subtag, as `OutputLanguage` does ("ru-ES" is "ru").
enum SuggestLanguage {
    static let explainDefaultsKey = "explainAnswerLanguage"
    static let writingDefaultsKey = "suggestWritingLanguage"
    static let english = "en"

    /// The language Explain answers in.
    static func explainLanguage(in defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) -> String {
        OutputLanguage.primaryLanguage(defaults.string(forKey: explainDefaultsKey)) ?? defaultExplainLanguage(preferred: preferred)
    }

    static func defaultExplainLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.lazy.compactMap(OutputLanguage.primaryLanguage).first ?? english
    }

    /// The language the user writes besides English, or nil for English only.
    static func writingLanguage(in defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) -> String? {
        let code = OutputLanguage.primaryLanguage(defaults.string(forKey: writingDefaultsKey)) ?? defaultWritingLanguage(preferred: preferred)
        return code == english ? nil : code
    }

    /// The setting's value when nothing is stored: a code, `en` for English only.
    static func defaultWritingLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.lazy.compactMap(OutputLanguage.primaryLanguage).first { $0 != english } ?? english
    }

    /// The languages a picker offers: the current value, the Mac's preferred languages, the keyboard
    /// layouts' languages and English, each once, in that order.
    static func choices(current: String, preferred: [String], layouts: [String]) -> [String] {
        var seen = Set<String>()
        return ([current] + preferred + layouts + [english])
            .compactMap(OutputLanguage.primaryLanguage)
            .filter { seen.insert($0).inserted }
    }

    /// Whether a language is written in Cyrillic ("ru", "uk", "bg"; not "de" or "el").
    static func isCyrillic(_ code: String) -> Bool {
        Locale.Language(identifier: code).maximalIdentifier.split(separator: "-").contains("Cyrl")
    }
}
