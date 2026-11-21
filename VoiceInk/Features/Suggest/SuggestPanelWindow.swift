import AppKit

/// Fork F7: the Suggest list's window and the layer that takes its mouse events. AppKit only, so
/// `Tests/Suggest` can check that a click on the list never activates VoiceInk or takes keyboard
/// focus from the app the list serves: the pick is pasted there.

/// Floats over the app and never takes keyboard focus or activates VoiceInk, so the draft keeps
/// its focus and its selection while the list is clicked.
@MainActor
class SuggestNonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

/// A transparent layer over the list's content that takes every mouse event inside it, from the
/// first click and whether or not VoiceInk is active, and reports it in top-left coordinates.
/// It draws nothing and is not an accessibility element; VoiceOver reaches the content under it.
@MainActor
final class SuggestPointerView: NSView {
    enum Event: Equatable {
        /// The pointer moved, or was dragged, to this point; `screen`: where it is on screen.
        case moved(CGPoint, screen: CGPoint)
        case exited
        case down(CGPoint)
        case up(CGPoint)
    }

    var onEvent: ((Event) -> Void)?

    override var isFlipped: Bool { true }

    /// The first click on the list acts at once: the panel never becomes key, so without this the
    /// click would only try to focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        superview?.subviews.first { $0 !== self }?.accessibilityHitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    /// Entering is a move too: a pointer that jumps onto a row gets only this event until it moves again.
    override func mouseEntered(with event: NSEvent) { onEvent?(.moved(location(event), screen: NSEvent.mouseLocation)) }
    override func mouseMoved(with event: NSEvent) { onEvent?(.moved(location(event), screen: NSEvent.mouseLocation)) }
    override func mouseDragged(with event: NSEvent) { onEvent?(.moved(location(event), screen: NSEvent.mouseLocation)) }
    override func mouseExited(with event: NSEvent) { onEvent?(.exited) }
    override func mouseDown(with event: NSEvent) { onEvent?(.down(location(event))) }
    override func mouseUp(with event: NSEvent) { onEvent?(.up(location(event))) }
    /// Other buttons do nothing on the list, and do not reach the window under it.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
