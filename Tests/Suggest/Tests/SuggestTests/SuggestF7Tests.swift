import AppKit
import XCTest
@testable import Suggest

/// Fork F7: the list centred on the selection, and the mouse.
final class SuggestF7Tests: XCTestCase {
    /// A 1440 × 900 screen with a 25 pt menu bar: visible frame y 0…875.
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let list = CGSize(width: 300, height: 200)

    // MARK: Placement

    func testTheListIsCentredOnTheSelectionOrItsLastLine() {
        // One word, «быстро» in the owner's screenshot: the list's middle on the word's middle.
        let word = CGRect(x: 400, y: 600, width: 40, height: 18)
        let placed = SuggestCore.panelOrigin(size: list, anchor: word, visible: visible)
        XCTAssertEqual(placed.origin.x + list.width / 2, 420, "centred on the word, not on its left edge")
        XCTAssertEqual(placed.origin.y + list.height, 596, "vertical placement as in F6")
        // An explicit centre wins over the anchor's own middle.
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: word, visible: visible, centreX: 700).origin.x, 550)

        // Accessibility coordinates (top-left origin). A selection over two lines: the first from
        // x 300 to the line's end at 820, the second from the column's left at 120 to x 260.
        let twoLines = CGRect(x: 120, y: 100, width: 700, height: 44)
        let lastCharacter = CGRect(x: 250, y: 122, width: 10, height: 22)
        let centre = SuggestCore.centreRect(selection: twoLines, lastCharacter: lastCharacter)
        XCTAssertEqual(centre, CGRect(x: 120, y: 122, width: 140, height: 22), "the last line's selected part")
        XCTAssertEqual(centre.midX, 190)
        // One line: the last character is on the selection's own line, so the whole selection.
        let oneLine = CGRect(x: 400, y: 100, width: 60, height: 22)
        XCTAssertEqual(SuggestCore.centreRect(selection: oneLine, lastCharacter: CGRect(x: 450, y: 100, width: 10, height: 22)), oneLine)
        // A last character that is missing, unusable, or outside the selection: the whole selection.
        XCTAssertEqual(SuggestCore.centreRect(selection: twoLines, lastCharacter: nil), twoLines)
        XCTAssertEqual(SuggestCore.centreRect(selection: twoLines, lastCharacter: .zero), twoLines)
        XCTAssertEqual(SuggestCore.centreRect(selection: twoLines, lastCharacter: CGRect(x: 0, y: 0, width: 900, height: 288)), twoLines,
                       "a whole-field frame is not a character")
        XCTAssertEqual(SuggestCore.centreRect(selection: twoLines, lastCharacter: CGRect(x: 250, y: 300, width: 10, height: 22)), twoLines)

        // The last visible character skips a selected line's break and trailing spaces, whole.
        XCTAssertEqual(SuggestCore.lastVisibleCharacter(of: "first line\n"), NSRange(location: 9, length: 1))
        XCTAssertEqual(SuggestCore.lastVisibleCharacter(of: "быстро "), NSRange(location: 5, length: 1))
        XCTAssertEqual(SuggestCore.lastVisibleCharacter(of: "ok 👍\n"), NSRange(location: 3, length: 2), "a surrogate pair is one character")
        XCTAssertNil(SuggestCore.lastVisibleCharacter(of: " \n "))
    }

    /// Chromium-like markers for a selection over two lines (the backward case of F6).
    private struct TwoLineMarkers: SuggestCore.MarkerQueries {
        enum Range: Equatable { case backward, ordered, last }
        func bounds(_ range: Range) -> CGRect? {
            switch range {
            case .backward: return .zero
            case .ordered: return CGRect(x: 120, y: 100, width: 700, height: 44)
            case .last: return CGRect(x: 250, y: 122, width: 10, height: 22)
            }
        }
        func inDocumentOrder(_ range: Range) -> Range? { .ordered }
        func lastCharacter(_ range: Range) -> Range? { range == .ordered ? .last : nil }
    }

    func testAMarkerSelectionIsCentredOnItsLastLine() {
        let geometry = SuggestCore.markerSelectionGeometry(TwoLineMarkers.Range.backward, TwoLineMarkers())
        XCTAssertEqual(geometry?.rect, CGRect(x: 120, y: 100, width: 700, height: 44))
        XCTAssertEqual(geometry?.centre, CGRect(x: 120, y: 122, width: 140, height: 22), "the last line of the ordered range")
        XCTAssertEqual(geometry?.reordered, true)
    }

    func testCentringIsClampedToTheVisibleFrameOnEveryScreen() {
        // Near the left edge: the centred list would start off screen, so it starts at the edge.
        let left = CGRect(x: 10, y: 600, width: 30, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: left, visible: visible).origin.x, 0)
        // Near the right edge.
        let right = CGRect(x: 1400, y: 600, width: 30, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: right, visible: visible).origin.x, 1140)
        // A second screen to the right, and one to the left at negative x: clamped to that screen.
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let atSecondsLeft = CGRect(x: 1450, y: 700, width: 30, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: atSecondsLeft, visible: second).origin.x, 1440)
        let leftScreen = CGRect(x: -1280, y: 0, width: 1280, height: 775)
        let atLeftScreensRight = CGRect(x: -20, y: 300, width: 15, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: atLeftScreensRight, visible: leftScreen).origin.x, -300)
        // In the middle of a screen it is centred exactly.
        let middle = CGRect(x: -700, y: 300, width: 80, height: 18)
        XCTAssertEqual(SuggestCore.panelOrigin(size: list, anchor: middle, visible: leftScreen).origin.x, -810)
        // Every result lies inside its visible frame.
        for (anchor, frame) in [(left, visible), (right, visible), (atSecondsLeft, second), (atLeftScreensRight, leftScreen), (middle, leftScreen)] {
            let origin = SuggestCore.panelOrigin(size: list, anchor: anchor, visible: frame).origin
            XCTAssertTrue(frame.contains(CGRect(origin: origin, size: list)), "\(anchor) → \(origin)")
        }
    }

    // MARK: Clicks

    private func readySession(_ items: [String]) -> SuggestCore.Session {
        var session = SuggestCore.Session()
        session.selectionCaptured("быстро")
        session.show(items)
        return session
    }

    private func applies(_ effects: [SuggestCore.Session.Effect]) -> Int {
        effects.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    func testAClickPicksThroughTheSamePasteAsADigit() {
        var clicked = readySession(["точно", "корректно"])
        var typed = readySession(["точно", "корректно"])
        XCTAssertEqual(clicked.click(.row(2)), typed.handle(.pick(2)), "a click on row 2 is a digit 2")
        XCTAssertEqual(clicked.phase, .picked(line: 2), "the same pick mark and fade")

        // A click and a digit together, either first: one paste.
        var clickFirst = readySession(["точно", "корректно"])
        let a = [clickFirst.click(.row(1)), clickFirst.handle(.pick(2)), clickFirst.click(.row(2))]
        XCTAssertEqual(applies(a), 1)
        XCTAssertEqual(a.first, .apply("точно"))
        var digitFirst = readySession(["точно", "корректно"])
        let b = [digitFirst.handle(.pick(2)), digitFirst.click(.row(1)), digitFirst.click(.row(1))]
        XCTAssertEqual(applies(b), 1)
        XCTAssertEqual(b.first, .apply("корректно"))

        // While thinking, on a missing row, or on "more": nothing is pasted.
        var thinking = SuggestCore.Session()
        XCTAssertEqual(thinking.click(.row(1)), .none)
        var two = readySession(["точно", "корректно"])
        XCTAssertEqual(two.click(.row(3)), .none)
        XCTAssertEqual(two.click(.more), .none)
        XCTAssertEqual(two.click(.original), .none)
        XCTAssertEqual(two.phase, .ready(["точно", "корректно"]), "nothing changed")
        // The esc chip is Esc: it closes and nothing is pasted after.
        XCTAssertEqual(two.click(.close), .close)
        XCTAssertEqual(applies([two.click(.row(1)), two.handle(.pick(1))]), 0)
    }

    func testThePointerHighlightsWhatItIsOverAndClicksOnRelease() {
        var pointer = SuggestCore.Pointer()
        XCTAssertNil(pointer.highlighted, "nothing is highlighted until the pointer moves")
        pointer.moved(over: .row(2))
        XCTAssertEqual(pointer.highlighted, .row(2))
        XCTAssertNil(pointer.pressed)
        pointer.moved(over: .row(3))
        XCTAssertEqual(pointer.highlighted, .row(3))
        // Pressed: held on row 3; dragged off it shows nothing; released elsewhere picks nothing.
        pointer.down(on: .row(3))
        XCTAssertEqual(pointer.highlighted, .row(3))
        XCTAssertEqual(pointer.pressed, .row(3))
        pointer.moved(over: .row(4))
        XCTAssertNil(pointer.highlighted, "a held press shows only over its own row")
        XCTAssertNil(pointer.up(on: .row(4)), "down on 3, up on 4: no pick")
        XCTAssertEqual(pointer.highlighted, .row(4), "after the release, hover again")
        // Down and up on the same row: that row is clicked.
        pointer.down(on: .row(1))
        XCTAssertEqual(pointer.up(on: .row(1)), .row(1))
        XCTAssertNil(pointer.pressed)
        XCTAssertNil(pointer.up(on: .row(1)), "a release with no press is no click")
        // Leaving the list, or new content under it: nothing highlighted.
        pointer.exited()
        XCTAssertNil(pointer.highlighted)
        pointer.moved(over: .close)
        pointer.down(on: .close)
        pointer.reset()
        XCTAssertEqual(pointer, SuggestCore.Pointer())

        // Hit testing over rows laid edge to edge: every point between them belongs to one row.
        let frames: [SuggestCore.Target: CGRect] = [
            .close: CGRect(x: 260, y: 6, width: 30, height: 16),
            .row(1): CGRect(x: 0, y: 30, width: 300, height: 28),
            .row(2): CGRect(x: 0, y: 58, width: 300, height: 28),
        ]
        XCTAssertEqual(SuggestCore.target(at: CGPoint(x: 150, y: 57.9), in: frames), .row(1))
        XCTAssertEqual(SuggestCore.target(at: CGPoint(x: 150, y: 58), in: frames), .row(2))
        XCTAssertEqual(SuggestCore.target(at: CGPoint(x: 270, y: 10), in: frames), .close)
        XCTAssertNil(SuggestCore.target(at: CGPoint(x: 150, y: 10), in: frames), "the top line's empty space")
    }

    // MARK: Closing when the user moves on

    func testTheListClosesWhenTheUserMovesOn() {
        let ready = readySession(["точно"]).phase
        for phase in [SuggestCore.Session.Phase.thinking, ready] {
            XCTAssertEqual(SuggestCore.closeReason(for: .mouseDown, phase: phase), "click-outside")
            XCTAssertEqual(SuggestCore.closeReason(for: .appActivated(isTarget: false), phase: phase), "app-switch")
            XCTAssertEqual(SuggestCore.closeReason(for: .focusChanged(isSame: false), phase: phase), "focus-changed")
            XCTAssertNil(SuggestCore.closeReason(for: .appActivated(isTarget: true), phase: phase), "the app itself again")
            XCTAssertNil(SuggestCore.closeReason(for: .focusChanged(isSame: true), phase: phase), "the same field")
        }
        // A pick being pasted is never cut short.
        for event in [SuggestCore.OutsideEvent.mouseDown, .appActivated(isTarget: false), .focusChanged(isSame: false)] {
            XCTAssertNil(SuggestCore.closeReason(for: event, phase: .picked(line: 1)), "\(event) during a pick")
            XCTAssertNil(SuggestCore.closeReason(for: event, phase: .closed))
        }
        // Closed that way, as Esc: a later digit or click pastes nothing.
        var session = readySession(["точно"])
        session.close()
        XCTAssertEqual(applies([session.handle(.pick(1)), session.click(.row(1))]), 0)
    }

    // MARK: No activation

    /// A click on the list must not activate VoiceInk or take keyboard focus: the pick is pasted
    /// into the app that has it. The panel never becomes key or main, does not activate its app, and
    /// the pointer layer takes the first click itself, in its own top-left coordinates.
    @MainActor
    func testAClickNeverActivatesVoiceInkOrTakesFocus() throws {
        _ = NSApplication.shared
        let panel = SuggestNonActivatingPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "a click must not activate VoiceInk")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate, "it shows over another app while VoiceInk is inactive")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let below = NSView(frame: content.bounds)
        let pointer = SuggestPointerView(frame: content.bounds)
        content.addSubview(below)
        content.addSubview(pointer)
        panel.contentView = content
        XCTAssertTrue(pointer.acceptsFirstMouse(for: nil), "the first click acts")
        XCTAssertTrue(content.hitTest(NSPoint(x: 150, y: 100)) === pointer, "the layer takes every click on the list")
        pointer.updateTrackingAreas()
        XCTAssertTrue(pointer.trackingAreas.contains { $0.options.isSuperset(of: [.activeAlways, .mouseMoved]) },
                      "hover works while VoiceInk is inactive")

        var events: [SuggestPointerView.Event] = []
        pointer.onEvent = { events.append($0) }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 150, y: 150), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            panel.sendEvent(event)
        }
        XCTAssertEqual(events, [.down(CGPoint(x: 150, y: 50)), .up(CGPoint(x: 150, y: 50))],
                       "both halves of the click reach the layer, y from the top")
        XCTAssertFalse(panel.isKeyWindow, "the click did not take keyboard focus")
        XCTAssertFalse(NSApp.keyWindow === panel)

        // A pointer that jumps onto the list from outside gets only "entered" until it moves again:
        // that is a move, so the row under it lights at once.
        events = []
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: NSPoint(x: 40, y: 30), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        pointer.mouseEntered(with: entered)
        guard case .moved(let point, _)? = events.first, events.count == 1 else {
            return XCTFail("entering is not reported as a move: \(events)")
        }
        XCTAssertEqual(point, CGPoint(x: 40, y: 170))
    }
}
