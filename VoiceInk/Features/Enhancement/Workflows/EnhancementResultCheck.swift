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
        /// Fork F19: the reply has no single, non-empty <RESULT>…</RESULT> pair (`pasted`).
        case resultTag

        var logValue: String {
            switch self {
            case .namesItsInput: return "names-its-input"
            case .stepLabel: return "step-label"
            case .sourceScript: return "source-script"
            case .resultTag: return "result-tag"
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

    // MARK: - The result envelope (F19)

    /// Fork F19: the owner's «разницу вариант не понял» (23.11, 21:44, prompt "T3 | Clean", Haiku without thinking) was
    /// pasted with the model's own notes around it: «Фиксирую: … — это очистка без изменения смысла. … Ответ: …». The
    /// rules above know only English shapes, and no list of phrases covers every language. So every AI prompt's
    /// result now comes inside <RESULT>…</RESULT> (`envelopeInstruction`, last in the system message), and only what is
    /// inside is pasted. Replayed isolated: his take leaked notes 3/30 without it and 0/30 with it; 40 Clean and 19
    /// Rewrite takes from his history lost no result and gained no note. Rewrite is included because it leaked the
    /// same way (a pasted «Вот варианты: …»).
    static let envelopeInstruction = "Return the result inside <RESULT> and </RESULT>, with nothing before or after the tags. "
        + "Inside the tags put only the result itself: no notes, labels, explanations or comments."
    static let resultOpen = "<RESULT>"
    static let resultClose = "</RESULT>"

    /// What is pasted: with the envelope, the text inside exactly one <RESULT>…</RESULT> pair, trimmed, and nil when
    /// the reply has no pair, more than one, the tags out of order, or nothing inside; text outside the pair is
    /// dropped. Without it, the reply itself.
    static func pasted(from reply: String, envelope: Bool) -> String? {
        guard envelope else { return reply }
        guard reply.components(separatedBy: resultOpen).count == 2, reply.components(separatedBy: resultClose).count == 2,
            let open = reply.range(of: resultOpen), let close = reply.range(of: resultClose), open.upperBound <= close.lowerBound
        else { return nil }
        let inside = reply[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inside.isEmpty ? nil : inside
    }

    /// The first problem found in a reply: no usable envelope (with `envelope`), then the rules below on what would
    /// be pasted.
    static func problem(inReply reply: String, envelope: Bool, decision: OutputLanguage.Decision, dictationLanguage: String?)
        -> Problem?
    {
        guard let text = pasted(from: reply, envelope: envelope) else { return .resultTag }
        return problem(in: text, decision: decision, dictationLanguage: dictationLanguage)
    }

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
        envelope: Bool = false,
        text: (Result) -> String,
        log: (String) -> Void,
        send: () async throws -> Result
    ) async rethrows -> Outcome<Result> {
        var attempt = 1
        while true {
            let result = try await send()
            guard let found = problem(inReply: text(result), envelope: envelope, decision: decision, dictationLanguage: dictationLanguage) else {
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
