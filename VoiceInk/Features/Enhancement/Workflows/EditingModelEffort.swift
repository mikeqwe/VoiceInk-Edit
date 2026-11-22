import Foundation

/// Fork F11: the effort sent with the Anthropic requests of every mode's AI enhancement (cleanup,
/// Rewrite) and of Suggest, one setting per path.
///
/// Without `output_config.effort`, Claude Haiku 5.5 thinks at its default effort, `medium`, on every
/// request (https://platform.claude.com/docs/en/build-with-claude/effort). On F11's evaluation, `low`
/// made cleanup and Suggest about twice as fast at the median but measurably worse: cleanup invented
/// content more often, and Suggest listed other forms of a correct word. So both paths keep the stock
/// request by default, and `low` is a choice. Other requests (Assistant, Auto Learn) and other
/// providers are not affected.
enum EditingModelEffort: String, CaseIterable, Sendable {
    /// Send no effort: the model's own default, exactly the request stock VoiceInk sends.
    case modelDefault = "default"
    case low
    case medium
    case high

    /// One path's setting: where it is stored and what applies when nothing is.
    struct Setting: Sendable {
        let defaultsKey: String
        let standard: EditingModelEffort
    }

    static let enhancement = Setting(defaultsKey: "enhancementModelEffort", standard: .modelDefault)
    static let suggest = Setting(defaultsKey: "suggestModelEffort", standard: .modelDefault)

    /// The setting as stored. Unset means the path's standard; a value this build does not know is
    /// returned as `invalid`, so the caller can log it, and the standard applies.
    static func resolve(_ stored: String?, standard: EditingModelEffort) -> (effort: EditingModelEffort, invalid: String?) {
        guard let stored else { return (standard, nil) }
        guard let effort = EditingModelEffort(rawValue: stored) else { return (standard, stored) }
        return (effort, nil)
    }

    /// The stored setting; a stored value that is not a string is reported as invalid too.
    static func current(_ setting: Setting, in defaults: UserDefaults = .standard) -> (effort: EditingModelEffort, invalid: String?) {
        let stored = defaults.object(forKey: setting.defaultsKey)
        guard stored == nil || stored is String else { return (setting.standard, String(describing: stored!)) }
        return resolve(stored as? String, standard: setting.standard)
    }

    /// One log field for a request: what was sent, and why nothing was.
    func logValue(model: String, invalid: String?) -> String {
        let sent = requestValue(model: model) ?? (self == .modelDefault ? "none(setting=default)" : "none(model)")
        return invalid.map { "\(sent) invalid-setting=\($0)" } ?? sent
    }

    /// Model ID prefixes that accept `output_config.effort`, from the docs' availability table
    /// (effort page, 22.11.2026). A model outside the list gets no effort field, since the API
    /// may reject it.
    static let supportedModelPrefixes = [
        "claude-fable-5", "claude-mythos-5", "claude-mythos-preview",
        "claude-opus-5", "claude-sonnet-5", "claude-haiku-5-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-sonnet-4-6",
    ]

    static func modelAcceptsEffort(_ model: String) -> Bool {
        supportedModelPrefixes.contains { model.hasPrefix($0) }
    }

    /// The `output_config.effort` value to send for `model`, or nil to send the stock request.
    func requestValue(model: String) -> String? {
        guard self != .modelDefault, Self.modelAcceptsEffort(model) else { return nil }
        return rawValue
    }
}

/// The body of an Anthropic Messages request with an effort: the stock fields VoiceInk sends
/// (model, max_tokens, system, messages) plus `output_config`.
struct AnthropicEffortRequestBody: Encodable, Equatable, Sendable {
    struct Message: Encodable, Equatable, Sendable {
        let role: String
        let content: String
    }
    struct OutputConfig: Encodable, Equatable, Sendable {
        let effort: String
    }

    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [Message]
    let output_config: OutputConfig

    init(model: String, maxTokens: Int, system: String?, messages: [Message], effort: String) {
        self.model = model
        self.max_tokens = maxTokens
        self.system = system
        self.messages = messages
        self.output_config = OutputConfig(effort: effort)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(max_tokens, forKey: .max_tokens)
        if let system { try container.encode(system, forKey: .system) }
        try container.encode(messages, forKey: .messages)
        try container.encode(output_config, forKey: .output_config)
    }

    private enum CodingKeys: String, CodingKey {
        case model, max_tokens, system, messages, output_config
    }

    /// The reply's text: the first `text` block. Thinking blocks come first and are skipped.
    static func text(fromResponse data: Data) throws -> String {
        struct Block: Decodable { let type: String; let text: String? }
        struct Response: Decodable { let content: [Block] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.content.first { $0.type == "text" }?.text ?? ""
    }
}
