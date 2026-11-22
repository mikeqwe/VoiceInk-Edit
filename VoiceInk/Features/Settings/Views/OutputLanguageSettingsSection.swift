import SwiftUI

/// Fork F12: the Settings section for `OutputLanguage`.
struct OutputLanguageSettingsSection: View {
    @AppStorage(OutputLanguage.dictationLanguageDefaultsKey) private var dictationLanguage = ""
    @State private var apps = OutputLanguage.bundleIdentifiers().apps
    private let layoutLanguages = OutputLanguageMonitor.enabledLayoutLanguages()

    var body: some View {
        Section {
            Picker(selection: $dictationLanguage) {
                Text("Off").tag("")
                ForEach(languageChoices, id: \.self) { code in
                    Text(OutputLanguage.englishName(code)).tag(code)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("I Dictate In")
                    InfoTip("When a take ends with a keyboard layout of another language, in one of the apps below, modes with AI enhancement (such as cleanup and Rewrite) write the result in the layout's language: they clean it as usual, then translate it. The recorder shows the language, for example EN, while you speak. Other apps, the layout of this language, and modes without AI keep the spoken language. Suggest is not affected.")
                }
            }

            if !dictationLanguage.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    HStack(spacing: 4) {
                        Text("Follow the Layout In")
                        InfoTip("Only takes in these apps follow the keyboard layout.")
                    }
                }
                AppListEditor(apps: apps, defaultApps: OutputLanguage.defaultBundleIdentifiers) { list in
                    OutputLanguage.setBundleIdentifiers(list)
                    apps = OutputLanguage.bundleIdentifiers().apps
                }
            }
        } header: {
            Text("Output Language")
        }
    }

    /// The languages of the enabled keyboard layouts, plus the stored one if it is not among them.
    private var languageChoices: [String] {
        var choices = layoutLanguages
        if !dictationLanguage.isEmpty, !choices.contains(dictationLanguage) { choices.append(dictationLanguage) }
        return choices
    }
}
