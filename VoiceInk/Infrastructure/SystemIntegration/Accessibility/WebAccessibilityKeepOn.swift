import AppKit
import ApplicationServices
import os

/// Fork F5: web accessibility stays on in the apps listed here.
///
/// Electron apps expose their full text to Accessibility only while `AXManualAccessibility` is on.
/// Electron turns it on two seconds after the last on or off request, and an off inside that window
/// cancels it (`enableScreenReaderCompleteModeAfterDelay:` in `shell/browser/mac/electron_application.mm`,
/// v43 and v44). VoiceInk's reader turns it on for a read and back off right after, so in these apps
/// every read flips the switch and the full tree never appears. For the apps here, VoiceInk turns it
/// on when VoiceInk starts and whenever one becomes active, and its readers never turn it back off.
///
/// Off switch, with no rebuild or restart: `defaults write com.prakashjoshipax.VoiceInk
/// keepWebAccessibilityOn -bool false`. Apps keep what they have until they restart or the
/// attribute is set off.
enum WebAccessibilityKeepOn {
    static let bundleIdentifiers: Set<String> = ["com.t3tools.t3code", "com.tinyspeck.slackmacgap"]
    static let defaultsKey = "keepWebAccessibilityOn"
    static let attribute = "AXManualAccessibility"

    /// On unless the defaults key is set to false.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func keepsOn(bundleIdentifier: String?, enabled: Bool) -> Bool {
        guard enabled, let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }

    /// What a reader writes back when it is done: the value the app had before (`previous`), as
    /// upstream does, or nil to write nothing, for an app on the list that had it off.
    static func valueAfterRead(previous: Bool, bundleIdentifier: String?, enabled: Bool) -> Bool? {
        !previous && keepsOn(bundleIdentifier: bundleIdentifier, enabled: enabled) ? nil : previous
    }

    /// `valueAfterRead` for a running process, with the defaults key read now.
    static func valueAfterRead(previous: Bool, processID: pid_t) -> Bool? {
        let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        return valueAfterRead(previous: previous, bundleIdentifier: bundleIdentifier, enabled: isEnabled)
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
        NSWorkspace.shared.runningApplications.forEach(keepOn)
    }

    private func keepOn(_ app: NSRunningApplication) {
        let bundleIdentifier = app.bundleIdentifier
        guard WebAccessibilityKeepOn.keepsOn(bundleIdentifier: bundleIdentifier, enabled: WebAccessibilityKeepOn.isEnabled) else { return }
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
