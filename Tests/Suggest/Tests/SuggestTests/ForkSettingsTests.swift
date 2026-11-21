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

/// Typing while the list shows closes it, nothing pasted; the key still reaches the app.
final class SuggestTypingClosesTests: XCTestCase {
    private func key(_ code: UInt16, _ characters: String, command: Bool = false, control: Bool = false) -> SuggestCore.TypedKey {
        SuggestCore.TypedKey(keyCode: code, characters: characters, command: command, control: control)
    }

    func testTextChangingKeysCloseTheList() {
        let closing: [(String, SuggestCore.TypedKey)] = [
            ("a", key(0, "a")), ("⇧A", key(0, "A")), ("ф", key(3, "ф")), ("space", key(49, " ")),
            ("⌥e then é", key(14, "é")), ("comma", key(43, ",")),
            ("Delete", key(51, "\u{7F}")), ("⌥Delete", key(51, "\u{7F}")), ("⌘Delete", key(51, "\u{7F}", command: true)),
            ("Forward Delete", key(117, "\u{F728}")),
            ("keypad 5 without ⌘", key(87, "5")),
        ]
        for (name, typed) in closing {
            XCTAssertTrue(SuggestCore.changesText(typed), name)
            for phase in [SuggestCore.Session.Phase.thinking, .ready(["x"])] {
                XCTAssertEqual(SuggestCore.closeReason(for: .keyDown(typed), phase: phase), "typing", name)
            }
            XCTAssertNil(SuggestCore.closeReason(for: .keyDown(typed), phase: .picked(line: 1)), "a pick being pasted is never cut short: \(name)")
        }
    }

    func testNavigationModifierChordsReturnAndOwnedKeysKeepTheList() {
        let keeping: [(String, SuggestCore.TypedKey)] = [
            ("←", key(123, "\u{F702}")), ("→", key(124, "\u{F703}")), ("↑", key(126, "\u{F700}")), ("↓", key(125, "\u{F701}")),
            ("⌥⇧←", key(123, "\u{F702}")), ("Home", key(115, "\u{F729}")), ("Page Down", key(121, "\u{F72D}")),
            ("F16", key(106, "\u{F713}")), ("⌃⌥F16", key(106, "\u{F713}", control: true)),
            ("⏎", key(36, "\r")), ("keypad Enter", key(76, "\u{3}")), ("Tab", key(48, "\t")), ("Esc", key(53, "\u{1B}")),
            ("⌘C", key(8, "c", command: true)), ("⌘V", key(9, "v", command: true)), ("⌃A", key(0, "\u{1}", control: true)),
            ("dead key", key(14, "")),
            ("top-row 3, owned", key(20, "3")), ("⌘ keypad 2, owned", key(84, "2", command: true)),
        ]
        for (name, typed) in keeping {
            XCTAssertFalse(SuggestCore.changesText(typed), name)
            XCTAssertNil(SuggestCore.closeReason(for: .keyDown(typed), phase: .ready(["x"])), name)
        }
    }
}
