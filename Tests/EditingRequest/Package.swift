// swift-tools-version:5.9
// Unit tests for fork F11: the effort on the Anthropic requests of cleanup, Rewrite and Suggest,
// and which takes capture the screen. Sources/EditingRequest/*.swift are symlinks to the files
// the app compiles, so these tests run the shipped decisions. Run: swift test
import PackageDescription

let package = Package(
    name: "EditingRequest",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EditingRequest"),
        .testTarget(name: "EditingRequestTests", dependencies: ["EditingRequest"]),
    ]
)
