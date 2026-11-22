import SwiftUI

/// Fork F14: the Settings section for `VoiceMark`: the default mark and a different mark per app.
struct VoiceMarkSettingsSection: View {
    @State private var mark = VoiceMark.storedDefaultMark().mark
    @State private var appMarks = VoiceMark.appMarks().marks

    var body: some View {
        Section {
            LabeledContent {
                TextField("No mark", text: $mark)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 180)
                    .onChange(of: mark) { _, newValue in VoiceMark.setDefaultMark(newValue) }
            } label: {
                HStack(spacing: 4) {
                    Text("Voice Mark")
                    InfoTip("Prompts with \"Start with the Voice Mark\" on, such as the cleanup prompt, begin their result with this text, so readers can tell it was dictated. Include the space after it. Leave it empty for no mark. Modes without AI, Suggest and Explain add no mark.")
                }
            }
            MarkPreview(mark: mark)

            LabeledContent {
                EmptyView()
            } label: {
                HStack(spacing: 4) {
                    Text("Different Mark In")
                    InfoTip("Takes that end in one of these apps use the app's mark instead. Leave it empty for no mark in that app.")
                }
            }
            ForEach(sortedApps, id: \.self) { bundleId in
                HStack(spacing: 8) {
                    TriggerAppIcon(bundleId: bundleId, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppListEditor.appName(for: bundleId) ?? bundleId)
                        Text(bundleId)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("No mark", text: binding(for: bundleId))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 140)
                        .accessibilityLabel(Text("Mark in \(AppListEditor.appName(for: bundleId) ?? bundleId)"))
                    Button {
                        save(appMarks.filter { $0.key != bundleId })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel(Text("Remove \(AppListEditor.appName(for: bundleId) ?? bundleId)"))
                }
            }
            Button("Add App…") {
                var marks = appMarks
                for bundleId in AppListEditor.chooseApps() where marks[bundleId] == nil {
                    marks[bundleId] = mark  // starts as the default, so nothing changes until edited
                }
                save(marks)
            }
        } header: {
            Text("Voice Mark")
        }
    }

    private var sortedApps: [String] {
        appMarks.keys.sorted {
            (AppListEditor.appName(for: $0) ?? $0).localizedCaseInsensitiveCompare(AppListEditor.appName(for: $1) ?? $1)
                == .orderedAscending
        }
    }

    private func binding(for bundleId: String) -> Binding<String> {
        Binding(
            get: { appMarks[bundleId] ?? "" },
            set: { newValue in
                var marks = appMarks
                marks[bundleId] = newValue
                save(marks)
            })
    }

    private func save(_ marks: [String: String]) {
        VoiceMark.setAppMarks(marks)
        appMarks = VoiceMark.appMarks().marks
    }
}

/// How a result starts with this mark, so a missing or extra space shows.
private struct MarkPreview: View {
    let mark: String

    var body: some View {
        Text(mark.isEmpty ? "Results start without a mark." : "Results start as: \(VoiceMark.applied(mark, to: "Hello"))")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
