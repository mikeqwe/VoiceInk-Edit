import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                ForEach(keepOnApps, id: \.self) { bundleId in
                    HStack(spacing: 8) {
                        TriggerAppIcon(bundleId: bundleId, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.appName(for: bundleId) ?? bundleId)
                            Text(bundleId)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            save(keepOnApps.filter { $0 != bundleId })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                        .accessibilityLabel(Text("Remove \(Self.appName(for: bundleId) ?? bundleId)"))
                    }
                }

                HStack(spacing: 8) {
                    Button("Add App…") { chooseApp() }
                    Button("Restore Defaults") { save(WebAccessibilityKeepOn.defaultBundleIdentifiers) }
                        .disabled(keepOnApps == WebAccessibilityKeepOn.defaultBundleIdentifiers)
                }
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

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        save(keepOnApps + added)
    }

    private static func appName(for bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
