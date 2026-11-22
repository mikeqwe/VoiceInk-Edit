import Foundation
import SwiftData

enum BackupImporter {
    private static let keyIsTextFormattingEnabled = "IsTextFormattingEnabled"

    @MainActor
    static func apply(
        _ backup: BackupFile, categories: Set<BackupCategory>, enhancementService: AIEnhancementService,
        recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager,
        mediaController: MediaController, playbackController: PlaybackController, recorderUIManager: RecorderUIManager,
        modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager
    ) async throws {
        var shouldRepairModePromptSelections = false

        if categories.contains(.dictionary) {
            try await importDictionary(from: backup, modelContext: modelContext)
        }

        if categories.contains(.general) {
            importGeneral(
                backup.generalSettings,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: mediaController,
                playbackController: playbackController,
                recorderUIManager: recorderUIManager
            )
        }

        if categories.contains(.prompts) {
            enhancementService.customPrompts = backup.customPrompts
            shouldRepairModePromptSelections = true
            print("Successfully imported \(backup.customPrompts.count) prompts.")
        }

        if categories.contains(.modes) {
            let modeManager = ModeManager.shared
            for config in modeManager.configurations {
                ShortcutStore.removeShortcutStorage(for: .mode(config.id))
            }

            modeManager.configurations = backup.modeConfigs
            let importedModeIds = Set(backup.modeConfigs.map(\.id))

            if let shortcuts = backup.modeShortcuts {
                for (idString, shortcutBackup) in shortcuts {
                    guard
                        let id = UUID(uuidString: idString),
                        importedModeIds.contains(id)
                    else {
                        continue
                    }

                    ShortcutStore.setShortcut(shortcutBackup.shortcut, for: .mode(id))
                }
            }

            modeManager.saveConfigurations()
            shouldRepairModePromptSelections = true

            if let customEmojis = backup.customEmojis {
                let emojiManager = EmojiManager.shared
                for emoji in customEmojis {
                    _ = emojiManager.addCustomEmoji(emoji)
                }
            }
            print("Successfully imported \(backup.modeConfigs.count) Mode configurations.")
        }

        if shouldRepairModePromptSelections {
            enhancementService.repairModePromptSelections()
        }

        if categories.contains(.customModels) {
            importCustomModels(backup.customCloudModels, transcriptionModelManager: transcriptionModelManager)
        }
    }

    @MainActor
    private static func importGeneral(
        _ general: GeneralBackup?, recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager,
        mediaController: MediaController, playbackController: PlaybackController, recorderUIManager: RecorderUIManager
    ) {
        guard let general else {
            print("No general settings found in the imported file.")
            return
        }

        if let shortcut = general.primaryRecordingShortcut {
            ShortcutStore.setShortcut(shortcut.shortcut, for: .primaryRecording)
            recordingShortcutManager.primaryRecordingShortcut = .custom
        }
        if let shortcut2 = general.secondaryRecordingShortcut {
            ShortcutStore.setShortcut(shortcut2.shortcut, for: .secondaryRecording)
            recordingShortcutManager.secondaryRecordingShortcut = .custom
        }
        if let pasteShortcut = general.pasteLastTranscriptionShortcut {
            ShortcutStore.setShortcut(pasteShortcut.shortcut, for: .pasteLastTranscription)
        }
        if let pasteEnhancementShortcut = general.pasteLastEnhancementShortcut {
            ShortcutStore.setShortcut(pasteEnhancementShortcut.shortcut, for: .pasteLastEnhancement)
        }
        if let retryShortcut = general.retryLastTranscriptionShortcut {
            ShortcutStore.setShortcut(retryShortcut.shortcut, for: .retryLastTranscription)
        }
        if let cancelShortcut = general.cancelRecorderShortcut {
            ShortcutStore.setShortcut(cancelShortcut.shortcut, for: .cancelRecorder)
        }
        if let historyShortcut = general.openHistoryWindowShortcut {
            ShortcutStore.setShortcut(historyShortcut.shortcut, for: .openQuickHistory)
        }
        if let dictionaryShortcut = general.quickAddToDictionaryShortcut {
            ShortcutStore.setShortcut(dictionaryShortcut.shortcut, for: .quickAddToDictionary)
        }

        if let shortcutRawValue = general.primaryRecordingShortcutRawValue,
            let shortcut = RecordingShortcutManager.ShortcutSelection(rawValue: shortcutRawValue)
        {
            recordingShortcutManager.primaryRecordingShortcut = shortcut
        }
        if let secondaryShortcutRawValue = general.secondaryRecordingShortcutRawValue,
            let secondaryShortcut = RecordingShortcutManager.ShortcutSelection(rawValue: secondaryShortcutRawValue)
        {
            recordingShortcutManager.secondaryRecordingShortcut = secondaryShortcut
        }
        if let modeRawValue = general.primaryRecordingShortcutModeRawValue,
            let mode = RecordingShortcutManager.Mode(rawValue: modeRawValue)
        {
            recordingShortcutManager.primaryRecordingShortcutMode = mode
        }
        if let secondaryModeRawValue = general.secondaryRecordingShortcutModeRawValue,
            let secondaryMode = RecordingShortcutManager.Mode(rawValue: secondaryModeRawValue)
        {
            recordingShortcutManager.secondaryRecordingShortcutMode = secondaryMode
        }
        if let launch = general.launchAtLoginEnabled {
            LaunchAtLoginManager.shared.setEnabled(launch)
        }
        if let menuOnly = general.isMenuBarOnly {
            menuBarManager.isMenuBarOnly = menuOnly
        }
        if let recType = general.recorderType {
            recorderUIManager.recorderType = recType
        }
        if let rawAppearancePreference = general.appAppearancePreference,
            let appearancePreference = AppAppearancePreference(rawValue: rawAppearancePreference)
        {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
            appearancePreference.apply()
        }
        if let rawLanguagePreference = general.appLanguagePreference {
            let languagePreference = AppLanguagePreference.normalizedRawValue(rawLanguagePreference)
            UserDefaults.standard.set(languagePreference, forKey: AppLanguagePreference.userDefaultsKey)
            AppLanguagePreference.apply(rawValue: languagePreference)
        }

        if let transcriptionCleanup = general.isTranscriptionCleanupEnabled {
            UserDefaults.standard.set(transcriptionCleanup, forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        }
        if let transcriptionMinutes = general.transcriptionRetentionMinutes {
            UserDefaults.standard.set(transcriptionMinutes, forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        }
        if let audioCleanup = general.isAudioCleanupEnabled {
            UserDefaults.standard.set(audioCleanup, forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        }
        if let audioRetention = general.audioRetentionPeriod {
            UserDefaults.standard.set(audioRetention, forKey: CleanupSettingsKeys.audioRetentionPeriod)
        }

        if let muteSystem = general.isSystemMuteEnabled {
            mediaController.isSystemMuteEnabled = muteSystem
        }
        if let pauseMedia = general.isPauseMediaEnabled {
            playbackController.isPauseMediaEnabled = pauseMedia
        }
        if let audioDelay = general.audioResumptionDelay {
            mediaController.audioResumptionDelay = audioDelay
        }
        if let experimentalEnabled = general.isExperimentalFeaturesEnabled {
            UserDefaults.standard.set(experimentalEnabled, forKey: "isExperimentalFeaturesEnabled")
            if experimentalEnabled == false {
                playbackController.isPauseMediaEnabled = false
            }
        }
        if let textFormattingEnabled = general.isTextFormattingEnabled {
            UserDefaults.standard.set(textFormattingEnabled, forKey: keyIsTextFormattingEnabled)
        }
        if let restoreClipboard = general.restoreClipboardAfterPaste {
            UserDefaults.standard.set(restoreClipboard, forKey: "restoreClipboardAfterPaste")
        }
        if let clipboardDelay = general.clipboardRestoreDelay {
            UserDefaults.standard.set(clipboardDelay, forKey: "clipboardRestoreDelay")
        }
        if let method = general.pasteMethod.flatMap(PasteMethod.init(rawValue:)) {
            PasteMethod.setCurrent(method)
        }
        if let enabled = general.smartPunctuationEnabled {
            UserDefaults.standard.set(enabled, forKey: SmartPunctuation.settingsKey)
        }
        if let finishAndSendKey = general.finishAndSendKey.flatMap(FinishAndSendKey.init(rawValue:)) {
            UserDefaults.standard.set(finishAndSendKey.rawValue, forKey: FinishAndSendSettings.key)
        }
        if let autoLearnEnabled = general.isAutoLearnDictionaryEnabled {
            UserDefaults.standard.set(autoLearnEnabled, forKey: AutoLearnSettings.isEnabledKey)
        }
        if let minimumCorrections = general.autoLearnMinimumCorrections {
            UserDefaults.standard.set(AutoLearnSettings.clampedMinimumCorrections(minimumCorrections),
                forKey: AutoLearnSettings.minimumCorrectionsKey)
        }
        let reviewMode = general.autoLearnAIReviewMode.flatMap(AutoLearnSettings.AIReviewMode.init(rawValue:))
        if let reviewMode {
            UserDefaults.standard.set(reviewMode.rawValue, forKey: AutoLearnSettings.aiReviewModeKey)
        }
        if general.isAutoLearnDictionaryEnabled != nil || general.autoLearnMinimumCorrections != nil || reviewMode != nil {
            Task {
                if let autoLearnEnabled = general.isAutoLearnDictionaryEnabled {
                    await AutoLearnService.shared.settingDidChange(isEnabled: autoLearnEnabled)
                } else {
                    await AutoLearnService.shared.suggestionThresholdDidChange()
                }
            }
        }

        importForkSettings(general)

        print("Successfully imported general settings.")
    }

    /// Fork settings from a backup: the Suggest shortcut, the Hybrid hold threshold (one of the
    /// offered values), web accessibility, and the Suggest footer's key names (blank clears one).
    @MainActor
    private static func importForkSettings(_ general: GeneralBackup) {
        if let shortcut = general.suggestReplacementShortcut {
            ShortcutStore.setShortcut(shortcut.shortcut, for: .suggestReplacement)
        }
        if let threshold = general.hybridHoldThreshold {
            if RecordingShortcutManager.HybridHoldThreshold.options.contains(threshold) {
                UserDefaults.standard.set(threshold, forKey: RecordingShortcutManager.HybridHoldThreshold.userDefaultsKey)
            } else {
                print("Skipped hybridHoldThreshold \(threshold): not one of the offered values.")
            }
        }
        if let keepOn = general.keepWebAccessibilityOn {
            UserDefaults.standard.set(keepOn, forKey: WebAccessibilityKeepOn.defaultsKey)
        }
        if let apps = general.webAccessibilityKeepOnApps {
            WebAccessibilityKeepOn.setBundleIdentifiers(apps)
        }
        if let language = general.outputDictationLanguage {
            if let code = OutputLanguage.primaryLanguage(language) {
                UserDefaults.standard.set(code, forKey: OutputLanguage.dictationLanguageDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: OutputLanguage.dictationLanguageDefaultsKey)
            }
        }
        if let apps = general.outputLanguageApps {
            OutputLanguage.setBundleIdentifiers(apps)
        }
        if let mark = general.voiceMark {
            VoiceMark.setDefaultMark(mark)
        }
        if let marks = general.voiceMarkApps {
            VoiceMark.setAppMarks(marks)
        }
        for (language, key) in [
            (general.explainAnswerLanguage, SuggestLanguage.explainDefaultsKey),
            (general.suggestWritingLanguage, SuggestLanguage.writingDefaultsKey),
        ] {
            guard let language else { continue }
            if let code = OutputLanguage.primaryLanguage(language) {
                UserDefaults.standard.set(code, forKey: key)
            } else {
                print("Skipped \(key) \"\(language)\": not a language code.")
            }
        }
        if let usesScreenText = general.suggestUsesScreenText {
            UserDefaults.standard.set(usesScreenText, forKey: SuggestCore.screenTextDefaultsKey)
        }
        for (effort, setting) in [
            (general.enhancementModelEffort, EditingModelEffort.enhancement),
            (general.suggestModelEffort, EditingModelEffort.suggest),
        ] {
            guard let effort else { continue }
            if EditingModelEffort(rawValue: effort) != nil {
                UserDefaults.standard.set(effort, forKey: setting.defaultsKey)
            } else {
                print("Skipped \(setting.defaultsKey) \(effort): not a known value.")
            }
        }
        for (label, key) in [
            (general.suggestPickKeyLabel, SuggestCore.FooterHints.pickKeyLabelDefaultsKey),
            (general.suggestMoreKeyLabel, SuggestCore.FooterHints.moreKeyLabelDefaultsKey),
        ] {
            guard let label else { continue }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(trimmed, forKey: key)
            }
        }
        if general.keepWebAccessibilityOn != nil || general.webAccessibilityKeepOnApps != nil {
            WebAccessibilityKeeper.shared.applyToRunningApps()
        }
    }

    @MainActor
    private static func importDictionary(from backup: BackupFile, modelContext: ModelContext) async throws {
        guard backup.vocabularyWords != nil || backup.wordReplacements != nil else {
            print("No new dictionary entries were imported.")
            DictionaryService.cleanUpDictionaryContent(context: modelContext, source: "settings import")
            return
        }

        let replacementEntries = (backup.wordReplacements ?? [:])
            .sorted { $0.key < $1.key }
            .map { original, replacement in
                DictionaryReplacementEntry(
                    sources: WordReplacementVariants.parse(original),
                    replacement: replacement,
                    createdAt: nil
                )
            }

        let archive = DictionaryArchive(
            vocabulary: (backup.vocabularyWords ?? []).map {
                DictionaryVocabularyEntry(term: $0.word, createdAt: nil)
            },
            replacements: replacementEntries
        )

        let result = try await DictionaryImportExportService.apply(
            archive: archive,
            mode: .merge,
            modelContext: modelContext
        )
        DictionaryService.cleanUpDictionaryContent(context: modelContext, source: "settings import")
        print(
            "Successfully imported \(result.summary.vocabularyToImport) vocabulary entries and "
                + "\(result.summary.replacementRulesToImport) word replacement rules."
        )
        if result.summary.skippedEntryCount > 0 {
            print("Skipped \(result.summary.skippedEntryCount) dictionary entries.")
        }
    }

    @MainActor
    private static func importCustomModels(
        _ models: [CustomModelBackup]?, transcriptionModelManager: TranscriptionModelManager
    ) {
        guard let models else {
            print("No custom models found in the imported file.")
            return
        }

        let customModelManager = CustomCloudModelManager.shared
        customModelManager.customModels = models.map { $0.makeModel() }
        customModelManager.saveCustomModels()
        transcriptionModelManager.refreshAllAvailableModels()
        print("Successfully imported \(models.count) custom model definitions.")
    }

}
