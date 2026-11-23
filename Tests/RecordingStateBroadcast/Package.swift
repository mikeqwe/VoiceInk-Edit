// swift-tools-version:5.9
// Unit tests for the recording-state broadcast the K0 pad's recording light follows.
// Sources/RecordingStateBroadcast/*.swift are symlinks to the files the app compiles. The tests use
// a prefix of their own, so a running router never sees them. Run: swift test
import PackageDescription

let package = Package(
    name: "RecordingStateBroadcast",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RecordingStateBroadcast"),
        .testTarget(name: "RecordingStateBroadcastTests", dependencies: ["RecordingStateBroadcast"]),
    ]
)
