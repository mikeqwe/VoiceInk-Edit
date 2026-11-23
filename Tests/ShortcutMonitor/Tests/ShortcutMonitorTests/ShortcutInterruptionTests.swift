import AppKit
import CoreGraphics
import XCTest
@testable import ShortcutMonitor

/// A held recording shortcut is cancelled as an accidental start when another key goes down within
/// the interruption window. A key that was already held and only auto-repeats is not another key
/// pressed during the shortcut: its repeats must not cancel the take.
///
/// The case from a macro pad: its key sends F13; a remapper turns it into the held ⌃⌥F17 recording
/// shortcut. When VoiceInk's event tap is ahead of the remapper's (it was installed later), VoiceInk
/// also sees the pad's own F13 and, about 0.5 s into the hold, its first auto-repeat.
@MainActor
final class ShortcutInterruptionTests: XCTestCase {
    private final class FakeTap: ShortcutEventTap {
        var isValid: Bool { true }
        var isEnabled: Bool { true }
        func enable() {}
        func stop() {}
    }

    private final class Recorder {
        var transitions: [String] = []
    }

    private static let recordKey: UInt16 = 64                       // F17
    private static let recordFlags: CGEventFlags = [.maskControl, .maskAlternate]
    private static let padKey: UInt16 = 105                         // F13, the pad's own key

    private var monitor: ShortcutMonitor?
    private var handler: (@Sendable (CGEventType, CGEvent) -> Bool)?
    private var recorder = Recorder()

    override func setUp() async throws {
        let box = HandlerBox()
        let monitor = ShortcutMonitor(
            owner: "test",
            makeEventTap: { _, handler in
                box.set(handler)
                return FakeTap()
            },
            isKeyDown: { _ in false },
            isShortcutPressed: { _ in true },
            allowsInput: { true },
            allowsDispatch: { true }
        )
        let recorder = Recorder()
        monitor.start(
            shortcuts: [.primaryRecording: .key(keyCode: Self.recordKey, modifierFlags: [.control, .option])],
            interruptibleActions: [.primaryRecording],
            onShortcutDown: { _, _ in recorder.transitions.append("down") },
            onShortcutUp: { _, _ in recorder.transitions.append("up") },
            onShortcutInterrupted: { _, _ in recorder.transitions.append("interrupted") }
        )
        self.monitor = monitor
        self.handler = box.get()
        self.recorder = recorder
        XCTAssertNotNil(handler, "the monitor installed no tap")
    }

    override func tearDown() async throws {
        monitor?.stop()
        monitor = nil
    }

    func testThePadKeysAutoRepeatDoesNotCancelAHeldRecording() async throws {
        send(key: Self.padKey, down: true, at: 0.000)
        send(key: Self.recordKey, flags: Self.recordFlags, down: true, at: 0.006)
        send(key: Self.padKey, down: true, at: 0.500, autoRepeat: true)
        send(key: Self.padKey, down: true, at: 0.583, autoRepeat: true)
        send(key: Self.padKey, down: false, at: 1.800)
        send(key: Self.recordKey, flags: Self.recordFlags, down: false, at: 1.802)
        try await drainMain()
        XCTAssertEqual(recorder.transitions, ["down", "up"])
    }

    func testAnotherKeyPressedDuringTheShortcutStillCancelsAnAccidentalStart() async throws {
        send(key: Self.recordKey, flags: Self.recordFlags, down: true, at: 0.000)
        send(key: 0, down: true, at: 0.300)                          // A, pressed fresh
        send(key: 0, down: false, at: 0.350)
        send(key: Self.recordKey, flags: Self.recordFlags, down: false, at: 0.600)
        try await drainMain()
        XCTAssertEqual(recorder.transitions, ["down", "interrupted", "up"])
    }

    // MARK: - Helpers

    private final class HandlerBox: @unchecked Sendable {
        private var handler: (@Sendable (CGEventType, CGEvent) -> Bool)?
        private let lock = NSLock()
        func set(_ handler: @escaping @Sendable (CGEventType, CGEvent) -> Bool) {
            lock.lock(); self.handler = handler; lock.unlock()
        }
        func get() -> (@Sendable (CGEventType, CGEvent) -> Bool)? {
            lock.lock(); defer { lock.unlock() }; return handler
        }
    }

    /// Delivers one keyboard event through the installed tap, on the tap thread, as the system does.
    private func send(key: UInt16, flags: CGEventFlags = [], down: Bool, at seconds: TimeInterval, autoRepeat: Bool = false) {
        guard let handler, let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else {
            return XCTFail("no tap or event")
        }
        event.flags = flags
        event.timestamp = CGEventTimestamp((1_000 + seconds) * 1_000_000_000)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autoRepeat ? 1 : 0)
        let type: CGEventType = down ? .keyDown : .keyUp
        _ = ShortcutEventTapThread.shared.performAndWait { handler(type, event) }
    }

    /// Dispatch hops to the main queue and then a main-actor task; let both run.
    private func drainMain() async throws {
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}
