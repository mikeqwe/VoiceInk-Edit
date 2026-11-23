import AppKit
import Combine
import SwiftData
import os

/// Fork F13: Explain and Ask about the selection, in Suggest's panel at the selection. The decisions
/// live in `ExplainCore`; this type does the I/O: the selection and context reads (Suggest's own),
/// the model call, the panel, its keys, the copy, and the shown-answer file. It has no paste: the
/// panel's effects are copy and close only (`ExplainCore.Session.Effect`).
///
/// - Explain: its shortcut (`ShortcutAction.explainSelection`) reads the selection and asks what it means.
/// - Ask: its shortcut (`ShortcutAction.askAboutSelection`) reads the selection at once and starts a
///   take in the first enabled mode whose Output is Show; the same shortcut again ends the take. The
///   take's transcript (`TranscriptionDelivery`, Output Show) is the question. Pressed while an answer
///   shows, it asks a follow-up about the same selection.
@MainActor
final class ExplainController {
    static let shared = ExplainController()

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Explain")
    private let aiService = AIService()
    private let keyMonitor = ShortcutMonitor(owner: "explain-panel")
    private let model = SuggestPanelModel()
    private lazy var panel = SuggestPanel(model: model)
    private var session: ExplainCore.Session?
    private var request: Task<Void, Never>?
    /// The selection, context and model target read at the press, once ready.
    private var capture: Task<Captured?, Never>?
    /// Counts runs, so a late read, answer or take end never acts on a later run.
    private var run = 0
    private var outsideWatch: SuggestOutsideWatch?
    private var listenWatch: AnyCancellable?
    private var pressedAt = Date()
    /// Earlier exchanges about the same selection, for a spoken follow-up.
    private var earlier: [ExplainCore.Exchange] = []
    private var lastSelection: String?
    private var modelContext: ModelContext?

    private struct Captured {
        let selection: String
        let context: SuggestCore.Context
        let systemPrompt: String
        /// Fork F16, for the log: Explain's language code, or "question" for Ask.
        let answerLanguage: String
        let provider: AIProvider
        let model: String?
        let app: String?
    }

    /// The reason a capture gave no request, shown as the notice.
    private enum CaptureFailure: Error {
        case notice(String, reason: String)
    }

    private init() {
        model.onClick = { [weak self] target in self?.handleClick(target) }
    }

    // MARK: - Entrances

    /// The Explain shortcut: the panel opens at once in "Thinking…" with its keys taken.
    func explain(modelContext: ModelContext, isRecorderVisible: Bool) {
        guard !isRecorderVisible else {
            Self.logger.notice("Explain ignored reason=recording")
            notify("Explain: finish the recording first. Nothing was changed.")
            return
        }
        self.modelContext = modelContext
        open(kind: .explain, keepEarlier: false)
        startKeys()
        let current = run
        request = Task { [weak self] in await self?.answer(run: current) }
    }

    /// The Ask shortcut, once to start the question's take and once to end it.
    func ask(modelContext: ModelContext, recorder: RecorderUIManager) async {
        self.modelContext = modelContext
        if let session, session.isListening, recorder.isRecorderPanelVisible {
            Self.logger.notice("Ask take end requested")
            await recorder.toggleRecorderPanel(modeId: Self.showMode()?.id)
            return
        }
        guard !recorder.isRecorderPanelVisible else {
            Self.logger.notice("Ask ignored reason=recording")
            notify("Ask: finish the recording first. Nothing was changed.")
            return
        }
        guard let mode = Self.showMode() else {
            Self.logger.notice("Ask ignored reason=no-show-mode")
            notify("Ask: no enabled mode has Output set to Show. Nothing was changed.")
            return
        }
        let followUp = session?.answer != nil
        open(kind: .ask, keepEarlier: followUp)
        let current = run
        Self.logger.notice("Ask take start mode=\(mode.id.uuidString, privacy: .public) followUp=\(followUp, privacy: .public) earlier=\(self.earlier.count, privacy: .public)")
        var started = false
        listenWatch = recorder.recordingStatePublisher?.sink { [weak self] state in
            // The publisher replays the state at subscription (idle, before the take starts): only an idle that
            // follows this take's own start ends it.
            guard ExplainCore.takeEnded(by: state == .idle, started: &started) else { return }
            Task { @MainActor in
                // The transcript is delivered before the recorder goes idle; a take that ends with
                // none (cancelled, too short, empty) leaves the panel listening.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.run == current, self.session?.isListening == true else { return }
                self.fail("Ask: the recording ended without a question. Nothing was changed.", reason: "take-ended")
            }
        }
        await recorder.toggleRecorderPanel(modeId: mode.id)
    }

    /// A take in a Show mode ended with this transcript (`TranscriptionDelivery`). With an Ask
    /// listening it is that Ask's question; otherwise (the mode's own shortcut) it asks about the
    /// selection now.
    func heard(_ text: String?) {
        if session?.isListening != true {
            Self.logger.notice("Ask transcript without a listening panel; reading the selection now")
            open(kind: .ask, keepEarlier: false)
        }
        guard var session, session.heard(text) else {
            fail("Ask: no question was heard. Nothing was changed.", reason: "empty-question")
            return
        }
        self.session = session
        listenWatch = nil
        Self.logger.notice("Ask heard questionChars=\(session.question?.count ?? 0, privacy: .public) afterPressSeconds=\(Date().timeIntervalSince(self.pressedAt), format: .fixed(precision: 2), privacy: .public)")
        model.answer = SuggestPanelModel.Answer(title: ExplainCore.title(kind: .ask), question: session.question, text: nil, status: "Thinking…", footer: nil)
        panel.fitToContent()
        startKeys()
        let current = run
        request = Task { [weak self] in await self?.answer(run: current) }
    }

    /// Another panel or a take takes over: close without a notice.
    func dismiss(reason: String) {
        guard session != nil else { return }
        Self.logger.notice("Explain closed reason=\(reason, privacy: .public)")
        finish()
    }

    // MARK: - The run

    private func open(kind: ExplainCore.Kind, keepEarlier: Bool) {
        SuggestController.shared.dismiss(reason: "explain-opened")
        let carried = keepEarlier ? carriedEarlier() : []
        let selection = keepEarlier ? lastSelection : nil
        finish()
        earlier = carried
        lastSelection = selection
        pressedAt = Date()
        session = ExplainCore.Session(kind: kind)
        model.original = nil
        model.items = nil
        model.answer = SuggestPanelModel.Answer(
            title: ExplainCore.title(kind: kind), question: nil, text: nil,
            status: kind == .ask ? "Listening… speak your question" : "Thinking…", footer: nil)
        showPanel()
        Self.logger.notice("Explain open kind=\(kind.rawValue, privacy: .public)")
        let current = run
        let started = pressedAt
        capture = Task { [weak self] in
            guard let self else { return nil }
            return await self.read(run: current, started: started)
        }
    }

    /// The selection, its field text and the window's OCR, read as Suggest reads them (F3, F11).
    private func read(run current: Int, started: Date) async -> Captured? {
        let screen = SuggestScreenText(started: started)
        let selection = await SelectedTextService.fetchSelectedText(isEnabled: true)
        guard run == current else { return nil }
        guard let selection else {
            fail("\(title): select some text first. Nothing was changed.", reason: "no-selection")
            return nil
        }
        guard ExplainCore.acceptsSelection(selection) else {
            fail("\(title): select at most \(ExplainCore.maxSelectionLength) characters. Nothing was changed.", reason: "selection-too-long")
            return nil
        }
        if let lastSelection, !SuggestCore.sameSelection(lastSelection, selection) { earlier = [] }
        lastSelection = selection
        model.original = selection
        panel.fitToContent()
        guard let target = SuggestController.providerAndModel() else {
            fail("\(title): the default mode has no AI provider. Nothing was changed.", reason: "no-provider")
            return nil
        }
        let app = NSWorkspace.shared.frontmostApplication
        let accessibility = await SuggestContextReader.read(processID: app?.processIdentifier, selection: selection)
        guard run == current else { return nil }
        let screenText = await screen.value(by: screen.started.addingTimeInterval(SuggestCore.screenTextWait))
        guard run == current else { return nil }
        Self.logger.notice("Explain screen \(screen.logFields, privacy: .public)")
        let kind = session?.kind ?? .explain
        let vocabulary = modelContext.map { CustomVocabularyService.shared.loadSavedVocabulary(from: $0) }
        let explainLanguage = SuggestLanguage.explainLanguage()
        return Captured(
            selection: selection,
            context: SuggestCore.adding(screenText: screenText, to: accessibility),
            systemPrompt: [ExplainCore.systemPrompt(kind: kind, explainLanguage: explainLanguage), vocabulary?.enhancementSection ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "\n\n"),
            answerLanguage: kind == .explain ? explainLanguage : "question",
            provider: target.provider,
            model: target.model,
            app: app?.bundleIdentifier
        )
    }

    private func answer(run current: Int) async {
        guard let captured = await capture?.value, run == current, let session, session.phase == .thinking else { return }
        let message = ExplainCore.userMessage(
            selection: captured.selection, context: captured.context, question: session.question, earlier: earlier)
        let effort = EditingModelEffort.current(EditingModelEffort.explain)
        let context = captured.context
        let aroundChars = context.around.map { $0.before.utf16.count + $0.after.utf16.count } ?? 0
        Self.logger.notice("Explain request kind=\(session.kind.rawValue, privacy: .public) provider=\(captured.provider.rawValue, privacy: .public) model=\(captured.model ?? "default", privacy: .public) selectionChars=\(captured.selection.count, privacy: .public) aroundChars=\(aroundChars, privacy: .public) otherTexts=\(context.other.count, privacy: .public) screenChars=\(context.screen?.utf16.count ?? 0, privacy: .public) earlier=\(self.earlier.count, privacy: .public) answerLanguage=\(captured.answerLanguage, privacy: .public) effort=\(captured.provider == .anthropic ? effort.effort.logValue(model: captured.model ?? "default", invalid: effort.invalid) : "n/a", privacy: .public) afterPressSeconds=\(Date().timeIntervalSince(self.pressedAt), format: .fixed(precision: 2), privacy: .public)")
        let started = Date()
        do {
            let completion = try await aiService.performChatCompletion(
                provider: captured.provider,
                modelName: captured.model,
                messages: [.user(message)],
                systemPrompt: captured.systemPrompt,
                localUserPrompt: message,
                timeout: max(EnhancementRequestSettings.timeout, SuggestController.minimumRequestTimeout, effort.effort.minimumTimeout),
                retryOnTimeout: false,
                anthropicEffort: effort.effort
            )
            guard run == current, var session = self.session else { return }
            guard let text = ExplainCore.answer(fromModelOutput: completion.text) else {
                fail("\(title): no answer came back. Nothing was changed.", reason: "empty-answer")
                return
            }
            guard session.show(text) else { return }
            self.session = session
            model.answer = SuggestPanelModel.Answer(
                title: ExplainCore.title(kind: session.kind), question: session.question, text: text, status: nil,
                footer: ExplainCore.footer(
                    pickKeyLabel: UserDefaults.standard.string(forKey: SuggestCore.FooterHints.pickKeyLabelDefaultsKey),
                    extra: UserDefaults.standard.string(forKey: ExplainCore.footerExtraDefaultsKey)))
            let side = panel.fitToContent()
            Self.logger.notice("Explain ready kind=\(session.kind.rawValue, privacy: .public) chars=\(text.count, privacy: .public) seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) afterPressSeconds=\(Date().timeIntervalSince(self.pressedAt), format: .fixed(precision: 2), privacy: .public) side=\(side.rawValue, privacy: .public)")
            publishShown(captured: captured, session: session, answer: text)
        } catch {
            guard run == current else { return }
            fail("\(title) failed: \(error.localizedDescription) Nothing was changed.", reason: "request-error")
        }
    }

    private var title: String { ExplainCore.title(kind: session?.kind ?? .explain) }

    private func carriedEarlier() -> [ExplainCore.Exchange] {
        guard let session, let answer = session.answer else { return earlier }
        return earlier + [ExplainCore.Exchange(question: session.question, answer: answer)]
    }

    private static func showMode() -> ModeConfig? {
        ModeManager.shared.configurations.first { $0.isEnabled && $0.outputMode == .show }
    }

    // MARK: - Keys and clicks

    private func startKeys() {
        var shortcuts: [ShortcutAction: Shortcut] = [:]
        for (index, binding) in SuggestCore.keyBindings.enumerated() {
            shortcuts[.suggestPanelKey(index)] = .key(keyCode: binding.keyCode, modifierFlags: binding.command ? [.command] : [])
        }
        keyMonitor.start(
            shortcuts: shortcuts,
            onShortcutDown: { [weak self] action, _ in self?.handleKey(action) },
            onShortcutUp: { _, _ in },
            reason: "explain-open"
        )
    }

    private func handleKey(_ action: ShortcutAction) {
        guard case .suggestPanelKey(let index) = action, SuggestCore.keyBindings.indices.contains(index), var session
        else { return }
        let key = ExplainCore.key(for: SuggestCore.keyBindings[index].key)
        let effect = session.handle(key)
        self.session = session
        deliver(effect, input: "key=\(key)")
    }

    private func handleClick(_ target: SuggestCore.Target) {
        guard var session else { return }
        let effect = session.click(target)
        self.session = session
        deliver(effect, input: "click=\(target)")
    }

    private func deliver(_ effect: ExplainCore.Session.Effect, input: String) {
        switch effect {
        case .none:
            Self.logger.notice("Explain input ignored \(input, privacy: .public)")
        case .close:
            Self.logger.notice("Explain closed reason=esc \(input, privacy: .public)")
            finish()
        case .copy(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = pasteboard.setString(text, forType: .string)
            Self.logger.notice("Explain copied chars=\(text.count, privacy: .public) ok=\(copied, privacy: .public)")
            finish()
            if !copied { notify("Explain: the answer could not be copied.") }
        }
    }

    // MARK: - Panel

    private func showPanel() {
        run &+= 1
        let current = run
        let started = ProcessInfo.processInfo.systemUptime
        panel.setAnchor(nil)
        panel.fitToContent()
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let processID = target, processID != ProcessInfo.processInfo.processIdentifier else {
            reveal(run: current, reading: .none(reason: "no-frontmost-app"), started: started, target: nil)
            return
        }
        SuggestAnchorReader.queue.async { [weak self] in
            let reading = SuggestAnchorReader.read(processID: processID)
            Task { @MainActor in self?.reveal(run: current, reading: reading, started: started, target: processID) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SuggestAnchorReader.budget * 1_000_000_000))
            self?.reveal(run: current, reading: .none(reason: "budget"), started: started, target: processID)
        }
    }

    private func reveal(run current: Int, reading: SuggestAnchorReader.Reading, started: TimeInterval, target: pid_t?) {
        guard current == run, session != nil, !panel.isVisible else { return }
        if case .rect(let rect, let centre) = reading.result {
            panel.setAnchor(rect, centre: centre)
        }
        let side = panel.fitToContent()
        panel.orderFrontRegardless()
        outsideWatch?.stop()
        outsideWatch = SuggestOutsideWatch(target: target, focused: reading.focused?.element) { [weak self] event in
            self?.outside(event)
        }
        let waited = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Self.logger.notice("Explain anchor source=\(reading.source, privacy: .public) shownAfterMs=\(waited, privacy: .public) side=\(side.rawValue, privacy: .public)")
    }

    /// The panel closes as Suggest's list does (F7): a click outside, an app switch, a focus change, or
    /// a key that changes the text; and on ⏎, which still reaches the app (`ExplainCore.closesOnKey`). While the question is
    /// recorded, only an app switch closes it; the take's own keys belong to the recorder.
    private func outside(_ event: SuggestCore.OutsideEvent) {
        guard let session else { return }
        if session.isListening {
            guard case .appActivated(let isTarget) = event, !isTarget else { return }
        }
        let reason: String
        if case .keyDown(let key) = event {
            guard ExplainCore.closesOnKey(key) else { return }
            reason = "typing"
        } else {
            guard let other = SuggestCore.closeReason(for: event, phase: .thinking) else { return }
            reason = other
        }
        Self.logger.notice("Explain closed reason=\(reason, privacy: .public)")
        finish()
    }

    private func fail(_ notice: String, reason: String) {
        Self.logger.notice("Explain closed reason=\(reason, privacy: .public)")
        finish()
        notify(notice)
    }

    private func finish() {
        let wasOpen = session != nil
        run &+= 1
        request?.cancel()
        request = nil
        capture?.cancel()
        capture = nil
        listenWatch = nil
        keyMonitor.stop(reason: "explain-closed")
        outsideWatch?.stop()
        outsideWatch = nil
        panel.orderOut(nil)
        model.answer = nil
        model.original = nil
        model.items = nil
        session = nil
        if wasOpen { publishClosed() }
    }

    private func notify(_ title: String) {
        NotificationManager.shared.showNotification(title: title, type: .warning)
    }

    // MARK: - The shown-answer file

    private static var shownURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent(ExplainCore.shownFileName)
    }

    private func publishShown(captured: Captured, session: ExplainCore.Session, answer: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        write(ExplainCore.Shown(
            open: true, pid: ProcessInfo.processInfo.processIdentifier, run: run, kind: session.kind.rawValue,
            app: captured.app, selection: captured.selection, question: session.question, answer: answer,
            model: captured.model, shownAt: formatter.string(from: Date())))
    }

    private func publishClosed() {
        write(ExplainCore.closed(pid: ProcessInfo.processInfo.processIdentifier, run: run))
    }

    private func write(_ shown: ExplainCore.Shown) {
        guard let url = Self.shownURL, let data = ExplainCore.shownData(shown) else { return }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            Self.logger.error("Explain shown-file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
