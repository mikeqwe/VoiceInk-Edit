import Foundation

// Test-only stand-ins for app types the symlinked shortcut files name but the monitor never
// uses: the legacy shortcut (ShortcutMigration.swift, kept equal to the app's declaration) and
// the mode lookups behind ShortcutAction's display name.
struct LegacyKeyboardShortcut: Codable {
    let carbonKeyCode: Int
    let carbonModifiers: Int
}

struct ModeStub {
    let id: UUID
    let name: String
}

final class ModeManager {
    static let shared = ModeManager()
    func getConfiguration(with id: UUID) -> ModeStub? { nil }
}

enum StarterModeCatalog {
    static let templates: [ModeStub] = []
}
