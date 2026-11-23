// swift-tools-version:5.9
// Unit tests for the shortcut monitor's press, release and interruption decisions.
// Sources/ShortcutMonitor/*.swift are symlinks to the files the app compiles, so these
// tests run the shipped monitor with an injected event tap. Run: swift test
import PackageDescription

let package = Package(
    name: "ShortcutMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShortcutMonitor"),
        .testTarget(name: "ShortcutMonitorTests", dependencies: ["ShortcutMonitor"]),
    ]
)
