import Foundation

/// Fork F1: a failed Rewrite pastes nothing.
///
/// A Rewrite take delivers text only when a selection was captured and the AI
/// enhancement returned a rewrite. Stock VoiceInk delivers the cleaned transcript
/// when the enhancement fails or is skipped, so the spoken instruction replaces the
/// selection; and an empty take "enhances" to an empty string without a model call,
/// which stock pastes over the selection. Every other take delivers exactly what
/// stock delivers.
///
/// Foundation only: `Tests/RewriteDeliveryGate` runs it with `swift test`.
enum RewriteDeliveryGate {
    enum Withheld: String, Equatable {
        /// The enhancement failed, did not run, or returned nothing.
        case noRewrite
        /// No selected text was captured, so there was nothing to rewrite.
        case noSelection

        var notice: String {
            switch self {
            case .noRewrite: return "Rewrite not applied: no rewrite came back from the AI. Nothing was pasted."
            case .noSelection: return "Rewrite not applied: no selected text. Nothing was pasted."
            }
        }
    }

    struct Decision: Equatable {
        let text: String?
        let withheld: Withheld?
    }

    /// - Parameters:
    ///   - stockText: what stock VoiceInk would deliver for this take.
    ///   - isRewrite: the take's mode uses the built-in Rewrite prompt.
    ///   - enhancedText: the enhancement's result, or nil when it failed or did not run.
    ///   - selectedText: the selection captured for the enhancement, if any.
    static func decide(
        stockText: String?,
        isRewrite: Bool,
        enhancedText: String?,
        selectedText: String?
    ) -> Decision {
        guard isRewrite else { return Decision(text: stockText, withheld: nil) }
        guard !isBlank(enhancedText) else { return Decision(text: nil, withheld: .noRewrite) }
        guard !isBlank(selectedText) else { return Decision(text: nil, withheld: .noSelection) }
        return Decision(text: stockText, withheld: nil)
    }

    private static func isBlank(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
