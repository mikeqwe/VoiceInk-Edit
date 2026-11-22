import Foundation

/// Fork F14: the voice mark, the text that starts every cleaned take (by default "[voice] "), so a
/// reader can tell the text was dictated.
///
/// A prompt asks for the mark with its "Start with the voice mark" switch (`CustomPrompt.addsVoiceMark`).
/// The app, not the model, then puts the mark in front of the AI result (`AIEnhancementService.enhance`),
/// so every path that enhances with such a prompt marks its result the same way: live takes in any mode
/// (Clean, also when F12 translates it), and the re-enhance and audio-file paths of History. Paths with
/// no AI result (Raw, Note, Ask) and the ones with their own requests (Suggest, Explain, the assistant)
/// add no mark.
///
/// Settings: `voiceMark` (the default mark; absent is `defaultMark`, an empty string is no mark) and
/// `voiceMarkApps` (bundle identifier → that app's mark, an empty string is no mark there; absent is
/// no override). The app is the front app when the take ends; a path with no take app uses the default.
enum VoiceMark {
    static let markDefaultsKey = "voiceMark"
    static let appsDefaultsKey = "voiceMarkApps"
    static let defaultMark = "[voice] "

    /// Before F14 the mark was a sentence of the prompt itself. A prompt stored without the switch
    /// that still has this sentence is converted when it is decoded (`legacyConversion`).
    static let legacyPromptSentence = "Begin the result with \"[voice] \"."

    /// Where a take's mark came from, for the log.
    enum Source: String, Equatable, Sendable {
        case `default`
        case app
    }

    struct Resolution: Equatable, Sendable {
        let mark: String
        let source: Source
    }

    /// The mark for a take in `app`: the app's own mark when it has one, else the default.
    static func resolve(app: String?, defaultMark: String, appMarks: [String: String]) -> Resolution {
        if let app, let mark = appMarks[app] { return Resolution(mark: mark, source: .app) }
        return Resolution(mark: defaultMark, source: .default)
    }

    /// The text with the mark in front. An empty mark, or a result with no text, stays as it is.
    static func applied(_ mark: String, to text: String) -> String {
        guard !mark.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return mark + text
    }

    /// A prompt decoded without the switch: whether it asked for the legacy mark, and its text without
    /// that sentence. Text without the sentence is returned unchanged with `false`.
    static func legacyConversion(of promptText: String) -> (text: String, addsVoiceMark: Bool) {
        guard promptText.contains(legacyPromptSentence) else { return (promptText, false) }
        var text = promptText.replacingOccurrences(of: legacyPromptSentence, with: "")
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return (text, true)
    }

    // MARK: - Settings

    /// The default mark. A stored value that is not a string falls back to `defaultMark`; `invalid`
    /// says so, for the log.
    static func storedDefaultMark(in defaults: UserDefaults = .standard) -> (mark: String, invalid: Bool) {
        guard let stored = defaults.object(forKey: markDefaultsKey) else { return (defaultMark, false) }
        guard let mark = stored as? String else { return (defaultMark, true) }
        return (mark, false)
    }

    static func setDefaultMark(_ mark: String, in defaults: UserDefaults = .standard) {
        defaults.set(mark, forKey: markDefaultsKey)
    }

    /// The per-app marks. A stored value that is not a dictionary of strings gives no override;
    /// `invalid` says so, for the log.
    static func appMarks(in defaults: UserDefaults = .standard) -> (marks: [String: String], invalid: Bool) {
        guard let stored = defaults.object(forKey: appsDefaultsKey) else { return ([:], false) }
        guard let marks = stored as? [String: String] else { return ([:], true) }
        return (normalized(marks), false)
    }

    static func setAppMarks(_ marks: [String: String], in defaults: UserDefaults = .standard) {
        defaults.set(normalized(marks), forKey: appsDefaultsKey)
    }

    /// Bundle identifiers trimmed, blank ones dropped. Marks are kept exactly, spaces included.
    static func normalized(_ marks: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (app, mark) in marks {
            let key = app.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = mark }
        }
        return result
    }

    /// The mark for a result with the settings read now, or nil when its prompt does not ask for one.
    static func resolve(promptAddsMark: Bool, app: String?, in defaults: UserDefaults = .standard)
        -> (resolution: Resolution, invalidSettings: [String])?
    {
        guard promptAddsMark else { return nil }
        let stored = storedDefaultMark(in: defaults)
        let apps = appMarks(in: defaults)
        var invalid: [String] = []
        if stored.invalid { invalid.append(markDefaultsKey) }
        if apps.invalid { invalid.append(appsDefaultsKey) }
        return (resolve(app: app, defaultMark: stored.mark, appMarks: apps.marks), invalid)
    }

    /// The one log line per marked result. The mark itself is logged quoted, so a space shows.
    static func logLine(resolution: Resolution, app: String?, invalidSettings: [String]) -> String {
        var line = "Voice mark source=\(resolution.source.rawValue) mark=\"\(resolution.mark)\" app=\(app ?? "none")"
        for key in invalidSettings { line += " invalid-setting=\(key)" }
        return line
    }
}
