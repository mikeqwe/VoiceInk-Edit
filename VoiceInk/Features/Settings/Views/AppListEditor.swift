import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fork: rows for a list of apps by bundle identifier, with Remove, Add App… and Restore Defaults.
/// Used by Keep Web Accessibility On (F5) and Follow the Layout In (F12); its app chooser and names
/// also by the voice mark's per-app list (F14).
struct AppListEditor: View {
    let apps: [String]
    let defaultApps: [String]
    let save: ([String]) -> Void

    var body: some View {
        ForEach(apps, id: \.self) { bundleId in
            HStack(spacing: 8) {
                TriggerAppIcon(bundleId: bundleId, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.appName(for: bundleId) ?? bundleId)
                    Text(bundleId)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save(apps.filter { $0 != bundleId })
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel(Text("Remove \(Self.appName(for: bundleId) ?? bundleId)"))
            }
        }

        HStack(spacing: 8) {
            Button("Add App…") { save(apps + Self.chooseApps()) }
            Button("Restore Defaults") { save(defaultApps) }
                .disabled(apps == defaultApps)
        }
    }

    /// The bundle identifiers of the apps picked in an open panel; none when it is cancelled.
    static func chooseApps() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    static func appName(for bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
