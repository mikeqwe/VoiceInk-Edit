import Foundation

/// Fork F15: the AI result is pasted as is, so it must be the result alone. Claude Haiku 5.5 sometimes
/// writes its reasoning into the reply when it skips thinking (Anthropic, "Prompting Claude Haiku 5.5",
/// "Keep reasoning out of user-facing text"): it quotes the transcript, labels a cleaned and a translated
/// version, and corrects itself ("Wait, … The cleaned transcript is …").
///
/// Every result of a mode's AI prompt (Clean, Rewrite, translated or not) passes this check in
/// `AIEnhancementService.makeRequest`. A rejected result is requested once more; a second rejection
/// fails the enhancement visibly (the transcript is pasted unchanged with a warning, as for any failed
/// enhancement), so model notes are never pasted silently.
///
/// The rules are only shapes that do not occur in dictated text: no rule matches a word a speaker
/// could say ("wait", "translate", "instructions"), so a dictation about transcripts or translation
/// passes.
enum EnhancementResultCheck {
    enum Problem: Equatable, Sendable {
        /// The reply talks about its own input: "the cleaned transcript", "the original transcript".
        case namesItsInput
        /// A line opens with a label of an intermediate step: "Cleaned:", "Translated to English:".
        case stepLabel
        /// A translated result still holds the dictation language's script: the original, or a quote of it.
        case sourceScript

        var logValue: String {
            switch self {
            case .namesItsInput: return "names-its-input"
            case .stepLabel: return "step-label"
            case .sourceScript: return "source-script"
            }
        }
    }

    private static let namesItsInput = try! NSRegularExpression(
        pattern: #"\bthe (?:cleaned|original|corrected) transcript\b"#, options: [.caseInsensitive])
    private static let stepLabel = try! NSRegularExpression(
        pattern: #"^\s*(?:cleaned(?: transcript| version)?|translated (?:to|into) [a-z]+)\s*:"#,
        options: [.caseInsensitive, .anchorsMatchLines])
    private static let cyrillicWord = try! NSRegularExpression(pattern: #"\p{Script=Cyrillic}+"#)

    /// Dictation languages written in Cyrillic, and translation targets written in Latin script.
    static let cyrillicLanguages: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "tg", "mn"]
    static let latinLanguages: Set<String> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "cs", "sk", "sv", "da", "no", "nb", "fi", "et", "lv", "lt",
        "tr", "ro", "hu", "hr", "sl", "id", "ms", "vi",
    ]

    /// The first problem found in `text`, or nil when it can be pasted. `decision` is the take's output
    /// language; `dictationLanguage` is the setting (a primary language code), used only for a translation.
    static func problem(in text: String, decision: OutputLanguage.Decision, dictationLanguage: String?) -> Problem? {
        let range = NSRange(text.startIndex..., in: text)
        if namesItsInput.firstMatch(in: text, range: range) != nil { return .namesItsInput }
        if stepLabel.firstMatch(in: text, range: range) != nil { return .stepLabel }
        if case .translate(let target) = decision,
            latinLanguages.contains(target),
            let source = OutputLanguage.primaryLanguage(dictationLanguage), cyrillicLanguages.contains(source),
            cyrillicWord.numberOfMatches(in: text, range: range) >= 2
        {
            return .sourceScript
        }
        return nil
    }

    /// A rejected result is requested once more: two attempts in all.
    static let attempts = 2

    enum Outcome<Result> {
        case accepted(Result)
        /// Every attempt was rejected; the last reason.
        case rejected(Problem)
    }

    /// Sends the request, checks its text, and sends it again while attempts remain. Each rejection is
    /// logged with `log`. Errors from `send` pass through unchanged.
    static func request<Result>(
        decision: OutputLanguage.Decision,
        dictationLanguage: String?,
        text: (Result) -> String,
        log: (String) -> Void,
        send: () async throws -> Result
    ) async rethrows -> Outcome<Result> {
        var attempt = 1
        while true {
            let result = try await send()
            guard let found = problem(in: text(result), decision: decision, dictationLanguage: dictationLanguage) else {
                return .accepted(result)
            }
            log(logLine(problem: found, attempt: attempt, decision: decision))
            guard attempt < attempts else { return .rejected(found) }
            attempt += 1
        }
    }

    static func logLine(problem: Problem, attempt: Int, decision: OutputLanguage.Decision) -> String {
        "Enhancement result rejected reason=\(problem.logValue) attempt=\(attempt)/\(attempts)"
            + " outputLanguage=\(decision.logValue)"
            + (attempt < attempts ? " action=retry" : " action=fail")
    }
}
