// swift-tools-version:5.9
// Unit tests for fork F2 (Suggest: numbered replacements for the selected word) and the
// Quick Add prefill. Sources/Suggest/*.swift are symlinks to the files the app compiles
// (SuggestCore, F1's RewriteDeliveryGate, which gates the paste, and QuickAddPrefill), so
// these tests run the shipped decisions. Run: swift test
import PackageDescription

let package = Package(
    name: "Suggest",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Suggest"),
        .testTarget(name: "SuggestTests", dependencies: ["Suggest"]),
    ]
)
