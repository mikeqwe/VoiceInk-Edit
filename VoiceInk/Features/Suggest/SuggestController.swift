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
                Self.logger.notice("Suggest ignored reason=\(session.phase == .thinking ? "already-thinking" : "closing", privacy: .public)")
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
        model.original = nil
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
            // The paste starts now; the list confirms the pick alongside it.
            let paste = CursorPaster.startPasteAtCursor(text)
            Task { @MainActor in
                let outcome = await paste.value
                Self.logger.notice("Suggest pasted commandPosted=\(outcome.result.didPostPasteCommand, privacy: .public)")
                if !outcome.result.didPostPasteCommand {
                    self.notify("Suggest: the replacement could not be pasted. Nothing was changed.")
                }
            }
            if case .picked(let line) = session.phase { confirmPick(line: line) }
        }
    }

    /// Marks the picked line, then the list goes: VoiceInk's 0.2 s ease-in fade, or under Reduce
    /// Motion the mark alone for the same time. The list keeps its keys until it is gone, and
    /// `SuggestCore.Session` ignores them, so a digit in that time neither pastes nor types.
    private func confirmPick(line: Int) {
        model.picked = line
        let feedback = SuggestCore.pickFeedback(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let done: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, case .picked = self.session?.phase else { return }
                Self.logger.notice("Suggest closed reason=picked")
                self.finish()
            }
        }
        if feedback.fades {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = feedback.duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                },
                completionHandler: done)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + feedback.duration, execute: done)
        }
    }

    // MARK: - Selection and model

    private func fetch(modelContext: ModelContext) async {
        let selection = await SelectedTextService.fetchSelectedText(isEnabled: true)
        guard isCurrent else { return }
        session?.selectionCaptured(selection)
        model.original = selection
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
        panel.alphaValue = 1
        model.items = nil
        model.original = nil
        model.picked = nil
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
        case .picked: return "picked"
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
    /// The selected text, once captured.
    @Published var original: String?
    /// nil while thinking.
    @Published var items: [String]?
    /// The picked line (1-based) while the list confirms it.
    @Published var picked: Int?
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
        appearance = nil  // follows VoiceInk's appearance, as the AutoLearn panel does
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

/// Styled after VoiceInk's own non-activating suggestion panel, AutoLearn's "Learn this
/// correction?" (`AutoLearnSuggestionContent.swift`: 400 pt wide, 16 pt padding, 15 pt
/// semibold title, 13 pt secondary original, `AutoLearnSuggestionSurface`), with the key
/// chips of the Quick Add panel (`DictionaryQuickAddPanel.swift`, `QuickPanelControls.swift`).
///
/// Two columns: the title, the original, the line badges and the footer start at the content
/// edge; each option's text, wrapped lines included, starts one badge and one gap further in.
/// A badge is centred on the middle of its option's first line, and so is the "esc" chip on
/// the title's. A picked line takes VoiceInk's selected-row look (`AppTheme.Selection`, the
/// green check of `ModePopover` and `EnhancementPromptPopover`).
struct SuggestPanelView: View {
    @ObservedObject var model: SuggestPanelModel

    /// The AppKit twins of the title and option fonts below, for their cap heights.
    private static let titleMetrics = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let optionMetrics = NSFont.systemFont(ofSize: 15, weight: .medium)
    private static let badgeWidth: CGFloat = 22
    private static let badgeGap: CGFloat = 10
    private static let checkWidth: CGFloat = 14
    /// How far a line's highlight reaches past the columns, sideways and up and down.
    private static let rowInset = CGSize(width: 8, height: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .suggestFirstLine) {
                Text(verbatim: "Suggestions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .firstLineMiddle(Self.titleMetrics)
                Spacer(minLength: 12)
                SuggestKeyChip(text: "esc")
            }
            if let original = model.original {
                Text(verbatim: original)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let items = model.items {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        row(line: index + 1, text: item)
                    }
                }
                .padding(.horizontal, -Self.rowInset.width)
                .padding(.vertical, -Self.rowInset.height)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "Paste")
                    SuggestKeyChip(text: items.count == 1 ? "1" : "1–\(items.count)")
                    Text(verbatim: "·")
                    Text(verbatim: "Suggest again for other options")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: "Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Thinking"))
                .accessibilityIdentifier("suggest-thinking")
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .modifier(AutoLearnSuggestionSurface())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(line: Int, text: String) -> some View {
        let isPicked = model.picked == line
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .suggestFirstLine, spacing: Self.badgeGap) {
            SuggestKeyChip(text: "\(line)", width: Self.badgeWidth)
            Text(verbatim: text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .firstLineMiddle(Self.optionMetrics)
            // Always laid out, so marking a line never reflows its text.
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Status.positive)
                .frame(width: Self.checkWidth)
                .opacity(isPicked ? 1 : 0)
        }
        .padding(.horizontal, Self.rowInset.width)
        .padding(.vertical, Self.rowInset.height)
        .background {
            if isPicked {
                shape.fill(AppTheme.Selection.fill)
                    .overlay(shape.strokeBorder(AppTheme.Selection.border, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(line) \(text)"))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("suggest-item-\(line)")
    }
}

private extension VerticalAlignment {
    private enum SuggestFirstLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// The middle of a text's first line (`firstLineMiddle`); any other view meets it with its centre.
    static let suggestFirstLine = VerticalAlignment(SuggestFirstLine.self)
}

private extension View {
    /// Puts `suggestFirstLine` half a cap height above the first baseline: the optical middle of
    /// the first line, whatever the line height or the number of lines.
    func firstLineMiddle(_ font: NSFont) -> some View {
        alignmentGuide(.suggestFirstLine) { $0[.firstTextBaseline] - font.capHeight / 2 }
    }
}

/// The key hint of the Quick Add panel's "↵" and "esc" chips. A line badge has a fixed width,
/// so 1 to 9 are all the same size.
private struct SuggestKeyChip: View {
    let text: String
    var width: CGFloat?

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondary)
            .padding(.horizontal, width == nil ? 6 : 0)
            .padding(.vertical, 3)
            .frame(minWidth: width == nil ? 22 : nil)
            .frame(width: width)
            .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: 5))
    }
}
