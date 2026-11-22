import AppKit
import Carbon
import SwiftUI
import os

/// Fork F12: reads the keyboard layout and the front app for `OutputLanguage`, at the release of a take
/// and live for the recorder badge.
@MainActor
final class OutputLanguageMonitor: ObservableObject {
    static let shared = OutputLanguageMonitor()
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OutputLanguage")

    /// The decision with the layout, front app and settings of now. Kept current by the system's
    /// layout-change and app-activation notifications and by settings changes.
    @Published private(set) var decision: OutputLanguage.Decision = .off
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in Task { @MainActor in OutputLanguageMonitor.shared.refresh() } }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in OutputLanguageMonitor.shared.refresh() } }))
        let local = NotificationCenter.default
        observers.append((local, local.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in OutputLanguageMonitor.shared.refresh() } }))
        refresh()
    }

    func refresh() {
        let now = OutputLanguage.decide(layout: Self.currentLayout(), app: Self.frontAppBundleIdentifier())
        if now != decision { decision = now }
    }

    /// The decision for a take that ends now, logged once. The layout at the release wins.
    func decisionForTakeEndingNow(mode: ModeConfig?) -> OutputLanguage.Decision {
        let layout = Self.currentLayout()
        let app = Self.frontAppBundleIdentifier()
        let apps = OutputLanguage.bundleIdentifiers()
        let dictation = OutputLanguage.dictationLanguage()
        let decision = OutputLanguage.decide(dictationLanguage: dictation, layout: layout, app: app, listedApps: apps.apps)
        let line = OutputLanguage.takeLogLine(
            decision: decision, layout: layout, app: app, dictationLanguage: dictation,
            modeFollows: Self.modeFollows(mode), appsInvalid: apps.invalid)
        Self.logger.notice("\(line, privacy: .public)")
        self.decision = decision
        return decision
    }

    static func modeFollows(_ mode: ModeConfig?) -> Bool {
        guard let mode else { return false }
        return OutputLanguage.modeFollows(
            aiEnhancementEnabled: mode.isAIEnhancementEnabled,
            usesVoiceInkRefine: mode.selectedAIProvider == AIProvider.voiceInkRefine.rawValue)
    }

    static func frontAppBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The selected keyboard layout. Source ID nil: it could not be read. Language "": the source
    /// names no language (`kTISPropertyInputSourceLanguages` empty, as for Unicode Hex Input).
    static func currentLayout() -> OutputLanguage.Layout {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return OutputLanguage.Layout(sourceID: nil, language: nil)
        }
        let sourceID = property(source, kTISPropertyInputSourceID) as? String
        let languages = property(source, kTISPropertyInputSourceLanguages) as? [String]
        return OutputLanguage.Layout(sourceID: sourceID, language: languages?.first ?? "")
    }

    /// Languages of the enabled keyboard layouts, for the settings picker.
    static func enabledLayoutLanguages() -> [String] {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        var seen = Set<String>()
        return list.compactMap { source in
            (property(source, kTISPropertyInputSourceLanguages) as? [String])?.first
                .flatMap(OutputLanguage.primaryLanguage)
        }.filter { seen.insert($0).inserted }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

/// The recorder's output-language badge: "EN" when this take would come out in English, "?" when the
/// layout has no readable language. Shown only for a mode that follows the layout.
struct OutputLanguageBadge: View {
    @ObservedObject private var monitor = OutputLanguageMonitor.shared
    @ObservedObject private var modeManager = ModeManager.shared

    var body: some View {
        if OutputLanguageMonitor.modeFollows(modeManager.currentEffectiveConfiguration),
           let text = OutputLanguage.badge(for: monitor.decision) {
            Text(text)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.9)))
                .fixedSize()
                .accessibilityLabel(Text("Output language \(text)"))
                .help(text == "?" ? "The keyboard layout has no language: the output keeps the spoken language."
                                  : "This take comes out in the keyboard layout's language.")
        }
    }
}
