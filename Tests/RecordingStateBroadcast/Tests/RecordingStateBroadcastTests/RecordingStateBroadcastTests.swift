import Foundation
import XCTest
@testable import RecordingStateBroadcast

@MainActor
final class RecordingStateBroadcastTests: XCTestCase {
    private let center = DistributedNotificationCenter.default()
    private var prefix = ""
    private var heard: [String] = []
    private var token: NSObjectProtocol?

    override func setUp() async throws {
        prefix = "test.k0pad.\(UUID().uuidString)"
        heard = []
        token = center.addObserver(forName: Notification.Name(prefix + ".recordingState"), object: nil, queue: .main) { [weak self] note in
            let state = note.userInfo?["state"] as? String ?? "<none>"
            MainActor.assumeIsolated { self?.heard.append(state) }
        }
    }

    override func tearDown() async throws {
        if let token { center.removeObserver(token) }
    }

    private func waitFor(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while heard.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(heard.count, count, "notifications heard: \(heard)", file: file, line: line)
    }

    /// Every change reaches another process with the state's name: a take that VoiceInk itself ends
    /// (its Cancel, Esc, no speech) is seen like one the pad ends.
    func testEveryChangeIsPostedWithItsName() {
        let broadcast = RecordingStateBroadcast(prefix: prefix, center: center)
        for state in [RecordingState.starting, .recording, .idle, .starting, .recording, .transcribing, .enhancing, .idle] {
            broadcast.post(state)
        }
        waitFor(8)
        XCTAssertEqual(heard, ["starting", "recording", "idle", "starting", "recording", "transcribing", "enhancing", "idle"])
    }

    /// A router that starts (or reloads) during a take asks, and hears the current state.
    func testARequestIsAnsweredWithTheCurrentState() {
        let broadcast = RecordingStateBroadcast(prefix: prefix, center: center)
        broadcast.post(.recording)
        waitFor(1)
        center.postNotificationName(Notification.Name(prefix + ".recordingStateRequest"), object: nil, userInfo: nil, deliverImmediately: true)
        waitFor(2)
        XCTAssertEqual(heard, ["recording", "recording"])
    }
}
