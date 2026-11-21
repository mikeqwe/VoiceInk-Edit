import XCTest
@testable import Suggest

/// The fork's settings: the keep-on app list (Settings → Suggest) and the Suggest footer's key names.
final class ForkSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ForkSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheKeepOnListIsAStoredSettingWithADefault() {
        // Nothing stored: the default list, and the switch is on.
        XCTAssertEqual(WebAccessibilityKeepOn.bundleIdentifiers(in: defaults), WebAccessibilityKeepOn.defaultBundleIdentifiers)
        XCTAssertTrue(WebAccessibilityKeepOn.isEnabled(in: defaults))

        // A stored list replaces the default one: trimmed, in order, without blanks or repeats.
        WebAccessibilityKeepOn.setBundleIdentifiers(
            [" com.microsoft.VSCode ", "com.hnc.Discord", "", "com.microsoft.VSCode"], in: defaults)
        let listed = WebAccessibilityKeepOn.bundleIdentifiers(in: defaults)
        XCTAssertEqual(listed, ["com.microsoft.VSCode", "com.hnc.Discord"])
        XCTAssertTrue(WebAccessibilityKeepOn.keepsOn(bundleIdentifier: "com.microsoft.VSCode", enabled: true, listed: listed))
        XCTAssertFalse(WebAccessibilityKeepOn.keepsOn(bundleIdentifier: "com.tinyspeck.slackmacgap", enabled: true, listed: listed),
                       "a default app the user removed is no longer kept on")
        XCTAssertNil(WebAccessibilityKeepOn.valueAfterRead(previous: false, bundleIdentifier: "com.hnc.Discord", enabled: true, listed: listed))

        // An empty list keeps no app on, unlike a missing one.
        WebAccessibilityKeepOn.setBundleIdentifiers([], in: defaults)
        XCTAssertEqual(WebAccessibilityKeepOn.bundleIdentifiers(in: defaults), [])

        // A stored value of the wrong type lists no app instead of a guessed default.
        defaults.set("com.tinyspeck.slackmacgap", forKey: WebAccessibilityKeepOn.appsDefaultsKey)
        XCTAssertEqual(WebAccessibilityKeepOn.bundleIdentifiers(in: defaults), [])

        // The switch.
        defaults.set(false, forKey: WebAccessibilityKeepOn.defaultsKey)
        XCTAssertFalse(WebAccessibilityKeepOn.isEnabled(in: defaults))
    }

    func testTheFooterNamesTheBoundShortcutOrNoKey() {
        typealias Hints = SuggestCore.FooterHints
        // No key names set: digits alone, and the bound shortcut, or just "more".
        XCTAssertEqual(Hints.pick(count: 5, keyLabel: nil), "1–5 paste")
        XCTAssertEqual(Hints.pick(count: 1, keyLabel: "  "), "1 paste")
        XCTAssertEqual(Hints.more(keyLabel: nil, boundShortcut: "⌃⌥S"), "⌃⌥S more")
        XCTAssertEqual(Hints.more(keyLabel: "", boundShortcut: nil), "more")
        // Key names from the settings, as a macro pad sets them.
        XCTAssertEqual(Hints.pick(count: 3, keyLabel: "Fn"), "Fn + 1–3 paste")
        XCTAssertEqual(Hints.more(keyLabel: "△", boundShortcut: "⌃⌥F16"), "△ more")
    }
}
