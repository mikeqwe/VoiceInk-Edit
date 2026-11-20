import Foundation

/// Fork: Quick Add to Dictionary opens with the selected word or short phrase already in its
/// vocabulary field, so adding a word is select, press, Return. Foundation only:
/// `Tests/Suggest` runs it with `swift test`.
enum QuickAddPrefill {
    static let maxLength = 64

    /// The vocabulary field's initial text: the selection when it is one short line,
    /// otherwise empty, as stock opens it.
    static func word(from selection: String?) -> String {
        guard let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            text.count <= maxLength, !text.contains(where: \.isNewline)
        else { return "" }
        return text
    }
}
