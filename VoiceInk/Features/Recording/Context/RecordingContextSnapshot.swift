import AppKit
import Foundation
import os

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
    /// Fork F12: decided at the release; `.off` until then.
    var outputLanguage: OutputLanguage.Decision = .off
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()
    let vocabularyPreparation: RecordingVocabularyPreparation

    init(savedVocabulary: RecordingVocabulary) {
        vocabularyPreparation = RecordingVocabularyPreparation(savedVocabulary: savedVocabulary)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateOutputLanguage(_ decision: OutputLanguage.Decision) {
        snapshot.outputLanguage = decision
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ScreenContext")

    static func startCapture(
        into store: RecordingContextSnapshotStore,
        language: String?,
        capturesScreen: Bool
    ) -> [Task<Void, Never>] {
        guard capturesScreen else {
            logger.notice("Screen context off for this take (mode)")
            return []
        }
        let screenCapture = Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                logger.notice("Screen context skipped reason=no-screen-recording-permission")
                return
            }
            guard !Task.isCancelled else { return }
            let started = Date()
            let screenCaptureService = ScreenCaptureService()
            let screenText = await screenCaptureService.captureAndExtractText()
            logger.notice(
                "Screen context captured chars=\(screenText?.count ?? 0, privacy: .public) seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)"
            )
            guard !Task.isCancelled else { return }
            store.updateScreenText(screenText)
            if let text = store.snapshot.screenText {
                store.vocabularyPreparation.prepareScreenNames(in: text, language: language)
            }
        }
        return [screenCapture]
    }
}
