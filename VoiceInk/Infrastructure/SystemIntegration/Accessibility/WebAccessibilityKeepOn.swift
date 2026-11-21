import AppKit
import ApplicationServices
import os

/// Fork F5: web accessibility stays on in the apps the user lists (Settings → Suggest).
///
/// Electron apps expose their full text to Accessibility only while `AXManualAccessibility` is on.
/// Electron turns it on two seconds after the last on or off request, and an off inside that window
/// cancels it (`enableScreenReaderCompleteModeAfterDelay:` in `shell/browser/mac/electron_application.mm`,
/// v43 and v44). VoiceInk's reader turns it on for a read and back off right after, so in these apps
/// every read flips the switch and the full tree never appears. For the listed apps, VoiceInk turns it
/// on when VoiceInk starts and whenever one becomes active, and its readers never turn it back off.
///
/// Settings: the switch `keepWebAccessibilityOn` (on unless set to false) and the list
/// `webAccessibilityKeepOnApps` (bundle identifiers; absent means `defaultBundleIdentifiers`).
/// Both are read at each use, so a change needs no restart. Apps keep what they have until they
/// restart or the attribute is set off.
enum WebAccessibilityKeepOn {
    static let defaultBundleIdentifiers: [String] = ["com.t3tools.t3code", "com.tinyspeck.slackmacgap"]
    static let defaultsKey = "keepWebAccessibilityOn"
    static let appsDefaultsKey = "webAccessibilityKeepOnApps"
    static let attribute = "AXManualAccessibility"
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WebAccessibility")

    /// On unless the switch is set to false.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The listed apps, in the order the user added them. No stored list: the default list.
    /// A stored value that is not a list of strings lists no app (upstream behaviour), and is logged.
    static func bundleIdentifiers(in defaults: UserDefaults = .standard) -> [String] {
        guard let stored = defaults.object(forKey: appsDefaultsKey) else { return defaultBundleIdentifiers }
        guard let list = stored as? [String] else {
            logger.error("\(appsDefaultsKey, privacy: .public) is not a list of strings; no app keeps web accessibility on")
            return []
        }
        return normalized(list)
    }

    /// Stores the list, trimmed, without empty or repeated entries.
    static func setBundleIdentifiers(_ list: [String], in defaults: UserDefaults = .standard) {
        defaults.set(normalized(list), forKey: appsDefaultsKey)
    }

    static func normalized(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func keepsOn(bundleIdentifier: String?, enabled: Bool, listed: [String]) -> Bool {
        guard enabled, let bundleIdentifier else { return false }
        return listed.contains(bundleIdentifier)
    }

    /// What a reader writes back when it is done: the value the app had before (`previous`), as
    /// upstream does, or nil to write nothing, for a listed app that had it off.
    static func valueAfterRead(previous: Bool, bundleIdentifier: String?, enabled: Bool, listed: [String]) -> Bool? {
        !previous && keepsOn(bundleIdentifier: bundleIdentifier, enabled: enabled, listed: listed) ? nil : previous
    }

    /// `valueAfterRead` for a running process, with the settings read now.
    static func valueAfterRead(previous: Bool, processID: pid_t) -> Bool? {
        let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        return valueAfterRead(previous: previous, bundleIdentifier: bundleIdentifier, enabled: isEnabled(),
                              listed: bundleIdentifiers())
    }
}

/// Turns web accessibility on in the listed apps: once at launch for those already running, then
/// whenever one becomes active. It writes without reading first: Electron reports the attribute as
/// on only while its mode is exactly `kAXModeComplete`, and turning it on adds `kScreenReader` and
/// `kFromPlatform`, so the attribute reads false while it is on. A write while it is on changes nothing.
final class WebAccessibilityKeeper {
    static let shared = WebAccessibilityKeeper()
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WebAccessibility")
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.web-accessibility", qos: .utility)
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.keepOn(app)
        }
        applyToRunningApps()
    }

    /// Turns it on in every listed app that runs now: at launch, and after the list or the switch changes.
    func applyToRunningApps() {
        NSWorkspace.shared.runningApplications.forEach(keepOn)
    }

    private func keepOn(_ app: NSRunningApplication) {
        let bundleIdentifier = app.bundleIdentifier
        guard WebAccessibilityKeepOn.keepsOn(bundleIdentifier: bundleIdentifier, enabled: WebAccessibilityKeepOn.isEnabled(),
                                             listed: WebAccessibilityKeepOn.bundleIdentifiers()) else { return }
        let processID = app.processIdentifier
        queue.async {
            guard AXIsProcessTrusted() else { return }
            let element = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(element, 0.25)
            let started = ProcessInfo.processInfo.systemUptime
            let write = AXUIElementSetAttributeValue(element, WebAccessibilityKeepOn.attribute as CFString, kCFBooleanTrue)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            Self.logger.notice("Web accessibility kept on app=\(bundleIdentifier ?? "-", privacy: .public) pid=\(processID, privacy: .public) write=\(write.rawValue, privacy: .public) ms=\(milliseconds, format: .fixed(precision: 1), privacy: .public)")
        }
    }
}
