import Foundation

/// Tells other processes VoiceInk's recording state, so an indicator outside the app (the K0 pad's
/// recording light) shows what VoiceInk really does, however a take started or ended.
///
/// Posts the distributed notification `<prefix>.recordingState` with `userInfo["state"]` = the state's
/// name (`idle`, `starting`, `recording`, `transcribing`, `enhancing`, `busy`) on every change, once at
/// launch, and again whenever another process posts `<prefix>.recordingStateRequest`.
@MainActor
final class RecordingStateBroadcast {
    static let shared = RecordingStateBroadcast()

    let changed: Notification.Name
    let request: Notification.Name
    private let center: DistributedNotificationCenter
    private var observer: NSObjectProtocol?
    private(set) var state: RecordingState = .idle

    init(prefix: String = "com.prakashjoshipax.VoiceInk", center: DistributedNotificationCenter = .default()) {
        changed = Notification.Name(prefix + ".recordingState")
        request = Notification.Name(prefix + ".recordingStateRequest")
        self.center = center
        observer = center.addObserver(forName: request, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func post(_ state: RecordingState) {
        self.state = state
        send()
    }

    private func send() {
        // Delivered at once even to a process whose notifications are suspended (Hammerspoon in the background).
        center.postNotificationName(changed, object: nil, userInfo: ["state": "\(state)"], deliverImmediately: true)
    }
}
