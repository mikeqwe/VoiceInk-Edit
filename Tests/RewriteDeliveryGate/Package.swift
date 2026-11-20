// swift-tools-version:5.9
// Unit tests for fork F1 (a failed Rewrite pastes nothing).
// Sources/RewriteDeliveryGate/RewriteDeliveryGate.swift is a symlink to the file the
// app compiles, so these tests run the shipped decision. Run: swift test
import PackageDescription

let package = Package(
    name: "RewriteDeliveryGate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RewriteDeliveryGate"),
        .testTarget(name: "RewriteDeliveryGateTests", dependencies: ["RewriteDeliveryGate"]),
    ]
)
