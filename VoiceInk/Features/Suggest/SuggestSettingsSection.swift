import AppKit
import SwiftUI

/// Fork: the Settings section for Suggest Replacement and for the apps that keep web
/// accessibility on (`WebAccessibilityKeepOn`).
struct SuggestSettingsSection: View {
    @AppStorage(WebAccessibilityKeepOn.defaultsKey) private var keepWebAccessibilityOn = true
    @AppStorage(SuggestCore.screenTextDefaultsKey) private var usesScreenText = true
    @AppStorage(EditingModelEffort.enhancement.defaultsKey) private var enhancementEffort = EditingModelEffort.enhancement.standard.rawValue
    @AppStorage(EditingModelEffort.suggest.defaultsKey) private var suggestEffort = EditingModelEffort.suggest.standard.rawValue
    @State private var keepOnApps = WebAccessibilityKeepOn.bundleIdentifiers()

    var body: some View {
        Section {
            LabeledContent {
                ShortcutRecorder(action: .suggestReplacement)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Suggest Replacement")
                    InfoTip("Select a word or a phrase in any app and press this shortcut. VoiceInk lists up to five replacements: press 1–5 or click one to paste it, or Esc to close. Press the shortcut again for a new set.")
                }
            }

            LabeledContent {
                ShortcutRecorder(action: .explainSelection)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Explain Selection")
                    InfoTip("Select text in any app and press this shortcut. VoiceInk explains it in the Suggest panel, in Russian with terms as written, using the same context as Suggest. The answer is never pasted: press 1 to copy it, Esc to close.")
                }
            }

            LabeledContent {
                ShortcutRecorder(action: .askAboutSelection)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Ask About Selection")
                    InfoTip("Select text and press this shortcut, speak a question, then press it again. The take runs in the first mode whose Output is Show; the answer shows in the Suggest panel and is never pasted. Pressed while an answer shows, it asks a follow-up. Questions about what an agent meant are better asked in that agent's own side chat.")
                }
            }

            Toggle(isOn: $usesScreenText) {
                HStack(spacing: 4) {
                    Text("Use Screen Text")
                    InfoTip("Suggest also sends the text recognized in the front window, as extra context. The screenshot stays on this Mac; only the recognized text is sent. Needs the Screen Recording permission; turning this on asks for it.")
                }
            }
            .onChange(of: usesScreenText) { _, isOn in
                guard isOn else { return }
                Task { _ = await ScreenCaptureService.requestScreenCapturePermissionRegistration() }
            }

            effortPicker("Claude Effort: Suggest", selection: $suggestEffort,
                         tip: "How much a Claude model thinks before it lists replacements. Model default (the default) sends no effort; Claude Haiku 5.5 then uses medium. Low is about twice as fast, but in a test it listed other forms of a correct word more often.")
            effortPicker("Claude Effort: Modes", selection: $enhancementEffort,
                         tip: "The same for every mode's AI enhancement (cleanup, Rewrite). Model default (the default) sends no effort; Claude Haiku 5.5 then uses medium. Low is about twice as fast, but in a test it added words that were not said more often. Other providers and models without effort are unaffected.")

            Toggle(isOn: $keepWebAccessibilityOn) {
                HStack(spacing: 4) {
                    Text("Keep Web Accessibility On")
                    InfoTip("Electron apps such as Slack show their full text to VoiceInk only while their web accessibility is on. VoiceInk turns it on in the apps below and leaves it on, so Suggest and selected-text context can read them. Other apps keep their own setting.")
                }
            }
            .onChange(of: keepWebAccessibilityOn) { _, isOn in
                if isOn { WebAccessibilityKeeper.shared.applyToRunningApps() }
            }

            if keepWebAccessibilityOn {
                AppListEditor(apps: keepOnApps, defaultApps: WebAccessibilityKeepOn.defaultBundleIdentifiers, save: save)
            }
        } header: {
            Text("Suggest")
        }
    }

    private func effortPicker(_ title: String, selection: Binding<String>, tip: String) -> some View {
        Picker(selection: selection) {
            Text("Low (faster)").tag(EditingModelEffort.low.rawValue)
            Text("Medium").tag(EditingModelEffort.medium.rawValue)
            Text("High").tag(EditingModelEffort.high.rawValue)
            Text("Model default").tag(EditingModelEffort.modelDefault.rawValue)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                InfoTip(tip)
            }
        }
    }

    private func save(_ list: [String]) {
        WebAccessibilityKeepOn.setBundleIdentifiers(list)
        keepOnApps = WebAccessibilityKeepOn.bundleIdentifiers()
        WebAccessibilityKeeper.shared.applyToRunningApps()
    }
}
