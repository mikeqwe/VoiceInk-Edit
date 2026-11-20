import AppKit
import ApplicationServices
import LLMkit
import SwiftData
import SwiftUI
import os

/// Fork F2: Suggest. The decisions live in `SuggestCore`; this type does the I/O:
/// the list panel, its keys, the selection read, the model call and the paste.
@MainActor
final class SuggestController {
    static let shared = SuggestController()

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Suggest")
    private let aiService = AIService()
    private let keyMonitor = ShortcutMonitor(owner: "suggest-panel")
    private let model = SuggestPanelModel()
    private lazy var panel = SuggestPanel(model: model)
    private var session: SuggestCore.Session?
    private var request: Task<Void, Never>?
    /// The run's request, kept for a new set: the same selection, context and model.
    private var asked: Request?

    private struct Request {
        let selection: String
        let context: SuggestCore.Context
        let systemPrompt: String
        let provider: AIProvider
        let model: String?
    }

    /// Suggest waits at least this long for the model. The whole field text can be tens of
    /// thousands of tokens, and the list stays open in "Thinking…" with Esc to cancel.
    static let minimumRequestTimeout: TimeInterval = 30

    private init() {}

    /// The Suggest shortcut. Opens the list at once, in "thinking", and takes its keys
    /// before anything else happens, so a digit pressed early is consumed and ignored.
    /// Pressed again while the list shows, it asks for a new set that excludes every option
    /// shown in this run; the list keeps its keys meanwhile.
    func run(modelContext: ModelContext, isRecorderVisible: Bool) {
        if var session {
            guard session.askForNewSet(), let asked else {
                Self.logger.notice("Suggest ignored reason=already-thinking")
                return
            }
            self.session = session
            model.items = nil
            panel.fitToContent()
            Self.logger.notice("Suggest new set rejected=\(session.shown.count, privacy: .public)")
            request = Task { [weak self] in await self?.ask(asked, rejected: session.shown) }
            return
        }
        guard !isRecorderVisible else {
            Self.logger.notice("Suggest ignored reason=recording")
            notify("Suggest: finish the recording first. Nothing was changed.")
            return
        }
        session = SuggestCore.Session()
        asked = nil
        startKeys()
        model.items = nil
        showPanel()
        Self.logger.notice("Suggest open")
        request = Task { [weak self] in await self?.fetch(modelContext: modelContext) }
    }

    // MARK: - Keys

    private func startKeys() {
        var shortcuts: [ShortcutAction: Shortcut] = [:]
        for (index, binding) in SuggestCore.keyBindings.enumerated() {
            shortcuts[.suggestPanelKey(index)] = .key(
                keyCode: binding.keyCode,
                modifierFlags: binding.command ? [.command] : []
            )
        }
        // Synchronous: the tap matches these keys before this call returns.
        keyMonitor.start(
            shortcuts: shortcuts,
            onShortcutDown: { [weak self] action, _ in self?.handleKey(action) },
            onShortcutUp: { _, _ in },
            reason: "suggest-open"
        )
    }

    private func handleKey(_ action: ShortcutAction) {
        guard case .suggestPanelKey(let index) = action, SuggestCore.keyBindings.indices.contains(index),
            var session
        else { return }
        let key = SuggestCore.keyBindings[index].key
        let effect = session.handle(key)
        self.session = session
        switch effect {
        case .none:
            Self.logger.notice("Suggest key ignored key=\(String(describing: key), privacy: .public) phase=\(Self.phaseName(session.phase), privacy: .public)")
        case .close:
            Self.logger.notice("Suggest closed reason=esc")
            finish()
        case .withheld(let reason):
            Self.logger.notice("Suggest withheld reason=\(reason.rawValue, privacy: .public)")
            finish()
            notify("Suggest: no selected text. Nothing was pasted.")
        case .apply(let text):
            Self.logger.notice("Suggest apply key=\(String(describing: key), privacy: .public)")
            finish()
            Task { @MainActor in
                let outcome = await CursorPaster.startPasteAtCursor(text).value
                Self.logger.notice("Suggest pasted commandPosted=\(outcome.result.didPostPasteCommand, privacy: .public)")
                if !outcome.result.didPostPasteCommand {
                    self.notify("Suggest: the replacement could not be pasted. Nothing was changed.")
                }
            }
        }
    }

    // MARK: - Selection and model

    private func fetch(modelContext: ModelContext) async {
        let selection = await SelectedTextService.fetchSelectedText(isEnabled: true)
        guard isCurrent else { return }
        session?.selectionCaptured(selection)
        guard let selection else {
            fail("Suggest: select some text first. Nothing was changed.", reason: "no-selection")
            return
        }
        guard SuggestCore.acceptsSelection(selection) else {
            fail("Suggest: select at most \(SuggestCore.maxSelectionLength) characters. Nothing was changed.", reason: "selection-too-long")
            return
        }
        guard let target = Self.providerAndModel() else {
            fail("Suggest: the default mode has no AI provider. Nothing was changed.", reason: "no-provider")
            return
        }
        let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let context = await SuggestContextReader.read(processID: processID, selection: selection)
        guard isCurrent else { return }
        session?.rawSelectionRead(context.around?.selected)
        let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext).enhancementSection
        let request = Request(
            selection: selection,
            context: context,
            systemPrompt: [SuggestCore.systemPrompt, vocabulary].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            provider: target.provider,
            model: target.model
        )
        asked = request
        await ask(request, rejected: [])
    }

    private func ask(_ request: Request, rejected: [String]) async {
        let message = SuggestCore.userMessage(selection: request.selection, context: request.context, rejected: rejected)
        let context = request.context
        let aroundChars = context.around.map { $0.before.utf16.count + $0.after.utf16.count } ?? 0
        let otherChars = context.other.reduce(0) { $0 + $1.utf16.count }
        Self.logger.notice("Suggest request provider=\(request.provider.rawValue, privacy: .public) model=\(request.model ?? "default", privacy: .public) selectionChars=\(request.selection.count, privacy: .public) context=\(context.around != nil, privacy: .public) aroundChars=\(aroundChars, privacy: .public) otherTexts=\(context.other.count, privacy: .public) otherChars=\(otherChars, privacy: .public) rejected=\(rejected.count, privacy: .public)")
        let started = Date()
        do {
            let completion = try await aiService.performChatCompletion(
                provider: request.provider,
                modelName: request.model,
                messages: [.user(message)],
                systemPrompt: request.systemPrompt,
                localUserPrompt: message,
                timeout: max(EnhancementRequestSettings.timeout, Self.minimumRequestTimeout),
                retryOnTimeout: false
            )
            guard isCurrent else { return }
            let items = SuggestCore.replacements(
                fromModelOutput: completion.text, original: request.selection, excluding: rejected)
            guard !items.isEmpty else {
                fail("Suggest: no \(rejected.isEmpty ? "" : "new ")replacements came back. Nothing was changed.", reason: "empty-answer")
                return
            }
            session?.show(items)
            model.items = items
            panel.fitToContent()
            Self.logger.notice("Suggest ready count=\(items.count, privacy: .public) seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)")
        } catch {
            guard isCurrent else { return }
            fail("Suggest failed: \(error.localizedDescription) Nothing was changed.", reason: "request-error")
        }
    }

    private var isCurrent: Bool {
        !Task.isCancelled && session?.phase == .thinking
    }

    private static func providerAndModel() -> (provider: AIProvider, model: String?)? {
        guard let mode = ModeManager.shared.getDefaultConfiguration(),
            let name = mode.selectedAIProvider, let provider = AIProvider(rawValue: name),
            provider.supportsEnhancement, provider != .voiceInkRefine
        else { return nil }
        let model = mode.selectedAIModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (provider, model?.isEmpty == false ? model : nil)
    }

    // MARK: - Panel and notices

    private func showPanel() {
        panel.fitToContent()
        panel.placeOnActiveScreen()
        panel.orderFrontRegardless()
    }

    /// A first request that fails closes the list. A new set that fails shows the previous
    /// list again, so the options already offered stay pickable.
    private func fail(_ notice: String, reason: String) {
        if var session, session.restorePrevious(), case .ready(let items) = session.phase {
            self.session = session
            request = nil
            model.items = items
            panel.fitToContent()
            Self.logger.notice("Suggest new set failed reason=\(reason, privacy: .public) restored=\(items.count, privacy: .public)")
            notify(notice)
            return
        }
        Self.logger.notice("Suggest closed reason=\(reason, privacy: .public)")
        finish()
        notify(notice)
    }

    private func finish() {
        request?.cancel()
        request = nil
        keyMonitor.stop(reason: "suggest-closed")
        panel.orderOut(nil)
        model.items = nil
        session = nil
        asked = nil
    }

    private func notify(_ title: String) {
        NotificationManager.shared.showNotification(title: title, type: .warning)
    }

    private static func phaseName(_ phase: SuggestCore.Session.Phase) -> String {
        switch phase {
        case .thinking: return "thinking"
        case .ready: return "ready"
        case .closed: return "closed"
        }
    }
}

/// Everything VoiceInk's Accessibility reader returns for the focused element, editable or
/// read-only, up to `SuggestCore.contextCap`. No promise for apps whose elements it cannot
/// read (Electron editors among them).
enum SuggestContextReader {
    private static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.suggest-context", qos: .userInitiated)

    static func read(processID: pid_t?, selection: String) async -> SuggestCore.Context {
        guard let processID else { return .none }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else {
                    continuation.resume(returning: .none)
                    return
                }
                let reader = AccessibilityTextReader(
                    messagingTimeout: 0.05,
                    fieldMessagingTimeout: 0.25,
                    readBudget: 0.6,
                    maximumFieldLength: SuggestCore.contextCap
                )
                let app = AXUIElementCreateApplication(processID)
                defer { reader.restoreWebAccessibility(processID: processID, appElement: app) }
                let readings = reader.focusedReadings(processID: processID, includeSystemFocus: false, includeReadOnly: true)
                let context = SuggestCore.context(
                    readings: readings.map { SuggestCore.TextReading(text: $0.fieldText, selection: $0.selection) },
                    selectedText: selection
                )
                continuation.resume(returning: context)
            }
        }
    }
}

@MainActor
final class SuggestPanelModel: ObservableObject {
    /// nil while thinking.
    @Published var items: [String]?
}

/// Floats over the app and never takes keyboard focus, so the draft keeps its focus and
/// its selection. Its keys come from `SuggestController`'s key monitor.
@MainActor
final class SuggestPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let hostingView: NSHostingView<SuggestPanelView>

    init(model: SuggestPanelModel) {
        hostingView = NSHostingView(rootView: SuggestPanelView(model: model))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = hostingView
        setAccessibilityIdentifier("voiceink-suggest-panel")
    }

    func fitToContent() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - visible.height / 4 - frame.height)
        setFrameOrigin(origin)
    }
}

struct SuggestPanelView: View {
    @ObservedObject var model: SuggestPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Suggest")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let items = model.items {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if item.count > 60 || item.contains("\n") {
                            // A phrase or a few lines: wrap at a fixed width.
                            Text(verbatim: item)
                                .font(.body)
                                .lineLimit(8)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 560, alignment: .leading)
                        } else {
                            Text(verbatim: item)
                                .font(.body)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(index + 1) \(item)"))
                    .accessibilityIdentifier("suggest-item-\(index + 1)")
                }
                Text(verbatim: "Fn + digit picks · Suggest again for others · Esc closes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Thinking…")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Thinking"))
                .accessibilityIdentifier("suggest-thinking")
                Text(verbatim: "Esc closes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 240, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
