import Foundation

/// Fork F11: which takes capture the front window's text. Stock VoiceInk captures it on every take
/// once Screen Recording is granted, and its names then reach the vocabulary of every mode, even with
/// the mode's screen switch off. Here only a take whose mode sends it captures it: AI enhancement on,
/// a provider that takes context, and the mode's "Use Screen Context" switch on.
enum RecordingScreenContext {
    static func captures(aiEnhancementEnabled: Bool, usesVoiceInkRefine: Bool, useScreenCapture: Bool) -> Bool {
        aiEnhancementEnabled && !usesVoiceInkRefine && useScreenCapture
    }
}
