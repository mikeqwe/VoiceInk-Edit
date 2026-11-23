import AppKit
import SwiftUI

/// Fork: the Settings section for Suggest Replacement and for the apps that keep web
/// accessibility on (`WebAccessibilityKeepOn`).
struct SuggestSettingsSection: View {
    @AppStorage(WebAccessibilityKeepOn.defaultsKey) private var keepWebAccessibilityOn = true
    @AppStorage(SuggestCore.screenTextDefaultsKey) private var usesScreenText = true
    @AppStorage(EditingModelEffort.enhancement.defaultsKey) private var enhancementEffort = EditingModelEffort.enhancement.standard.rawValue
    @AppStorage(EditingModelEffort.suggest.defaultsKey) private var suggestEffort = EditingModelEffort.suggest.standard.rawValue
    @AppStorage(EditingModelEffort.explain.defaultsKey) private var explainEffort = EditingModelEffort.explain.standard.rawValue
    @State private var keepOnApps = WebAccessibilityKeepOn.bundleIdentifiers()
    @AppStorage(SuggestLanguage.explainDefaultsKey) private var explainLanguage = SuggestLanguage.defaultExplainLanguage()
    @AppStorage(SuggestLanguage.writingDefaultsKey) private var writingLanguage = SuggestLanguage.defaultWritingLanguage()
    @AppStorage(SuggestCore.replacementCountDefaultsKey) private var replacementCount = SuggestCore.defaultReplacementCount
    private let layoutLanguages = OutputLanguageMonitor.enabledLayoutLanguages()

    var body: some View {
        Section {
            LabeledContent {
                ShortcutRecorder(action: .suggestReplacement)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Suggest Replacement")
                    InfoTip("Select a word or a phrase in any app and press this shortcut. VoiceInk lists the replacements (Number of Replacements below): press 1–9 or click one to paste it, or Esc to close. Press the shortcut again for a new set.")
                }
            }

            LabeledContent {
                ShortcutRecorder(action: .explainSelection)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Explain Selection")
                    InfoTip("Select text in any app and press this shortcut. VoiceInk explains it in the Suggest panel, in the language set in Explain In below, with terms as written, using the same context as Suggest. The answer is never pasted: press 1 to copy it, Esc to close.")
                }
            }

            LabeledContent {
                ShortcutRecorder(action: .askAboutSelection)
                    .controlSize(.small)
            } label: {
                HStack(spacing: 4) {
                    Text("Ask About Selection")
                    InfoTip("Select text and press this shortcut, speak a question, then press it again. The take runs in the first mode whose Output is Show; the answer shows in the Suggest panel and is never pasted. Pressed while an answer shows, it asks a follow-up. The answer is in the language of the question. Questions about what an agent meant are better asked in that agent's own side chat.")
                }
            }

            Picker(selection: $explainLanguage) {
                ForEach(SuggestLanguage.choices(current: explainLanguage, preferred: Locale.preferredLanguages, layouts: layoutLanguages), id: \.self) { code in
                    Text(OutputLanguage.englishName(code)).tag(code)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Explain In")
                    InfoTip("The language Explain Selection answers in. Terms, names and code stay as written. Ask About Selection answers in the language of the question. The default is the Mac's first preferred language.")
                }
            }

            Picker(selection: $replacementCount) {
                ForEach(Array(SuggestCore.replacementCounts), id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Number of Replacements")
                    InfoTip("The most replacements Suggest lists, most likely first; keys 1–9 pick them. After the likely ones come other wordings, each a different choice: plainer, shorter, more formal, more casual or clearer. When fewer different choices exist, the list is shorter. When the selection can be read the other way round (with a negation added or removed), one of them is that reading. More replacements take a little longer to arrive. The default is 9.")
                }
            }

            Picker(selection: $writingLanguage) {
                ForEach(SuggestLanguage.choices(current: writingLanguage, preferred: Locale.preferredLanguages, layouts: layoutLanguages), id: \.self) { code in
                    Text(code == SuggestLanguage.english ? "English only" : "\(OutputLanguage.englishName(code)) and English").tag(code)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("I Write In")
                    InfoTip("Suggest assumes you write this language and English, and that you sometimes spell English terms and names in its letters, as they sound. For such a selection it offers the English original, and it checks spelling in both languages. English only offers no such originals. The default is the first of the Mac's preferred languages that is not English.")
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
            effortPicker("Claude Effort: Explain and Ask", selection: $explainEffort, levels: [.low, .medium, .high, .xhigh, .max],
                         tip: "How much a Claude model thinks before it explains the selection or answers a question about it. Model default (the default) sends no effort; Claude Haiku 5.5 then uses medium. Higher levels think longer: Max can take tens of seconds. A model that does not take the chosen level gets no effort.")
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

    private func effortPicker(
        _ title: String, selection: Binding<String>, levels: [EditingModelEffort] = [.low, .medium, .high], tip: String
    ) -> some View {
        Picker(selection: selection) {
            ForEach(levels, id: \.self) { level in
                Text(Self.effortName(level)).tag(level.rawValue)
            }
            Text("Model default").tag(EditingModelEffort.modelDefault.rawValue)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                InfoTip(tip)
            }
        }
    }

    private static func effortName(_ level: EditingModelEffort) -> String {
        switch level {
        case .modelDefault: return "Model default"
        case .low: return "Low (faster)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max (slowest)"
        }
    }

    private func save(_ list: [String]) {
        WebAccessibilityKeepOn.setBundleIdentifiers(list)
        keepOnApps = WebAccessibilityKeepOn.bundleIdentifiers()
        WebAccessibilityKeeper.shared.applyToRunningApps()
    }
}
