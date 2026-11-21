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
    /// Counts runs, so a selection rectangle read for an earlier run is never applied to this one.
    private var openGeneration = 0
    /// The selection read for a press while a run is open (F6), until it decides that press.
    private var pressCheck: Task<Void, Never>?
    /// The last press's arguments (F7), so a click on "more" acts as another press.
    private var lastPress: (modelContext: ModelContext, isRecorderVisible: Bool)?
    /// Watches for a click outside the list, an app switch and a focus change while it shows (F7).
    private var outsideWatch: SuggestOutsideWatch?

    private struct Request {
        let selection: String
        let context: SuggestCore.Context
        let systemPrompt: String
        let provider: AIProvider
        let model: String?
        /// The user's vocabulary terms: the misspelling guard never drops them.
        let vocabulary: [String]
    }

    /// Suggest waits at least this long for the model. The whole field text can be tens of
    /// thousands of tokens, and the list stays open in "Thinking…" with Esc to cancel.
    static let minimumRequestTimeout: TimeInterval = 30

    private init() {
        model.onClick = { [weak self] target in self?.handleClick(target) }
    }

    /// The Suggest shortcut. Opens the list at once, in "thinking", and takes its keys
    /// before anything else happens, so a digit pressed early is consumed and ignored.
    /// Pressed again while a run is open (F6), it first reads the selection at that moment
    /// (`SuggestCore.pressDecision`): the same selection with the list showing asks for a new set
    /// that excludes every option shown in this run, and the list keeps its keys meanwhile;
    /// another selection closes this run and starts a fresh one for it.
    func run(modelContext: ModelContext, isRecorderVisible: Bool) {
        lastPress = (modelContext, isRecorderVisible)
        if let session {
            // A pick is being pasted: its text is on the clipboard, so no selection read (whose
            // Copy fallback uses the clipboard) may run now.
            if case .picked = session.phase {
                Self.logger.notice("Suggest ignored reason=closing")
                return
            }
            guard pressCheck == nil else {
                Self.logger.notice("Suggest ignored reason=reading-selection")
                return
            }
            let generation = openGeneration
            pressCheck = Task { [weak self] in
                let current = await SelectedTextService.fetchSelectedText(isEnabled: true)
                guard !Task.isCancelled else { return }
                self?.decidePress(current: current, generation: generation, modelContext: modelContext, isRecorderVisible: isRecorderVisible)
            }
            return
        }
        start(modelContext: modelContext, isRecorderVisible: isRecorderVisible, selection: .readNow)
    }

    /// Where a run's selection comes from: read when the run starts, or already read at the press
    /// that started it (a press while another run was open).
    private enum SelectionSource {
        case readNow
        case read(String?)
    }

    private func start(modelContext: ModelContext, isRecorderVisible: Bool, selection: SelectionSource) {
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
        request = Task { [weak self] in await self?.fetch(modelContext: modelContext, selection: selection) }
    }

    /// The second half of a press while a run is open, once the selection at that press is read.
    private func decidePress(current: String?, generation: Int, modelContext: ModelContext, isRecorderVisible: Bool) {
        pressCheck = nil
        guard generation == openGeneration, var session else {
            Self.logger.notice("Suggest ignored reason=closed-meanwhile")
            return
        }
        switch SuggestCore.pressDecision(phase: session.phase, runSelection: session.selection, current: current) {
        case .ignore(let reason):
            Self.logger.notice("Suggest ignored reason=\(reason, privacy: .public)")
        case .newSet:
            guard session.askForNewSet(), let asked else {
                Self.logger.notice("Suggest ignored reason=no-request")
                return
            }
            self.session = session
            model.items = nil
            panel.fitToContent()
            Self.logger.notice("Suggest new set rejected=\(session.shown.count, privacy: .public)")
            request = Task { [weak self] in await self?.ask(asked, rejected: session.shown) }
        case .freshRun:
            Self.logger.notice("Suggest fresh run reason=selection-changed selectionChars=\(current?.count ?? 0, privacy: .public) previousChars=\(session.selection?.count ?? 0, privacy: .public)")
            finish()
            start(modelContext: modelContext, isRecorderVisible: isRecorderVisible, selection: .read(current))
        }
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
        deliver(effect, input: "key=\(key)")
    }

    /// A click on the list (F7): a row or the esc chip through the same session as the keys, so a
    /// click picks through the same single paste as a digit; "more" as another press.
    private func handleClick(_ target: SuggestCore.Target) {
        guard var session else { return }
        if target == .more {
            guard let lastPress else { return }
            Self.logger.notice("Suggest click target=more")
            run(modelContext: lastPress.modelContext, isRecorderVisible: lastPress.isRecorderVisible)
            return
        }
        let effect = session.click(target)
        self.session = session
        deliver(effect, input: "click=\(target)")
    }

    private func deliver(_ effect: SuggestCore.Session.Effect, input: String) {
        guard let session else { return }
        switch effect {
        case .none:
            Self.logger.notice("Suggest input ignored \(input, privacy: .public) phase=\(Self.phaseName(session.phase), privacy: .public)")
        case .close:
            Self.logger.notice("Suggest closed reason=esc \(input, privacy: .public)")
            finish()
        case .withheld(let reason):
            Self.logger.notice("Suggest withheld reason=\(reason.rawValue, privacy: .public)")
            finish()
            notify("Suggest: no selected text. Nothing was pasted.")
        case .apply(let text):
            Self.logger.notice("Suggest apply \(input, privacy: .public)")
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

    private func fetch(modelContext: ModelContext, selection source: SelectionSource) async {
        let selection: String?
        switch source {
        case .readNow: selection = await SelectedTextService.fetchSelectedText(isEnabled: true)
        case .read(let text): selection = text
        }
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
        let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        let request = Request(
            selection: selection,
            context: context,
            systemPrompt: [SuggestCore.systemPrompt, vocabulary.enhancementSection].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            provider: target.provider,
            model: target.model,
            vocabulary: vocabulary.terms
        )
        asked = request
        await ask(request, rejected: [])
    }

    /// Fork F8: an answer with no usable option (not JSON, or every item dropped) is asked once
    /// more before the notice; F7 saw 5 such answers in 41.
    private func ask(_ request: Request, rejected: [String], attempt: Int = 1) async {
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
            let spelling = SuggestCore.Spelling(isWord: SuggestSpelling.isWord, vocabulary: request.vocabulary)
            let items = SuggestCore.replacements(
                fromModelOutput: completion.text, original: request.selection, excluding: rejected, spelling: spelling)
            let answered = SuggestCore.answerItemCount(completion.text).map(String.init)
                ?? "not-json shape=\(SuggestCore.unparsedShape(completion.text))"
            Self.logger.notice("Suggest answer items=\(answered, privacy: .public) kept=\(items.count, privacy: .public) misspelled=\(SuggestCore.misspellingCount(inModelOutput: completion.text, original: request.selection, spelling: spelling), privacy: .public) chars=\(completion.text.count, privacy: .public) attempt=\(attempt, privacy: .public)")
            if items.isEmpty, attempt == 1 {
                Self.logger.notice("Suggest retry reason=no-usable-option")
                await ask(request, rejected: rejected, attempt: 2)
                return
            }
            guard !items.isEmpty else {
                fail("Suggest: no \(rejected.isEmpty ? "" : "new ")replacements came back. Nothing was changed.", reason: "empty-answer")
                return
            }
            session?.show(items)
            model.items = items
            let side = panel.fitToContent()
            Self.logger.notice("Suggest ready count=\(items.count, privacy: .public) seconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) side=\(side.rawValue, privacy: .public)")
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

    /// The list shows at the selected text (F4). Its keys are already taken; the selection's
    /// rectangle is read off the main thread, and the list shows as soon as it arrives or the budget
    /// (`SuggestAnchorReader.budget`) ends, whichever is first. Past the budget it shows where it
    /// always did, and a late rectangle is dropped.
    private func showPanel() {
        openGeneration &+= 1
        let generation = openGeneration
        let started = ProcessInfo.processInfo.systemUptime
        panel.setAnchor(nil)
        panel.fitToContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let processID = target, processID != ownPID else {
            reveal(generation: generation, reading: .none(reason: "no-frontmost-app"), started: started, target: nil)
            return
        }
        SuggestAnchorReader.queue.async { [weak self] in
            let reading = SuggestAnchorReader.read(processID: processID)
            Task { @MainActor in self?.reveal(generation: generation, reading: reading, started: started, target: processID) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SuggestAnchorReader.budget * 1_000_000_000))
            self?.reveal(generation: generation, reading: .none(reason: "budget"), started: started, target: processID)
        }
    }

    /// The first of the reading and the budget for this run shows the list; the other does nothing.
    /// From then on the list closes on a click outside it, an app switch, or a change of the
    /// focused element the reading found (F7, `SuggestCore.closeReason`).
    private func reveal(generation: Int, reading: SuggestAnchorReader.Reading, started: TimeInterval, target: pid_t?) {
        guard generation == openGeneration, session != nil, !panel.isVisible else {
            if generation == openGeneration, reading.source != "none:budget" {
                Self.logger.notice("Suggest anchor late source=\(reading.source, privacy: .public) readMs=\(reading.milliseconds, privacy: .public)")
            }
            return
        }
        var anchor: CGRect?
        var centre: CGRect?
        if case .rect(let rect, let centreRect) = reading.result {
            anchor = rect
            centre = centreRect
        }
        panel.setAnchor(anchor, centre: centre)
        let side = panel.fitToContent()
        panel.orderFrontRegardless()
        outsideWatch?.stop()
        outsideWatch = SuggestOutsideWatch(target: target, focused: reading.focused?.element) { [weak self] event in
            self?.outside(event)
        }
        let waited = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        let geometry = anchor.map { rect in
            let middle = centre ?? rect
            return " rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)) centreX=\(Int(middle.midX)) panel=\(Int(panel.frame.minX)),\(Int(panel.frame.width))"
        } ?? ""
        Self.logger.notice("Suggest anchor source=\(reading.source, privacy: .public) readMs=\(reading.milliseconds, privacy: .public) shownAfterMs=\(waited, privacy: .public) side=\(side.rawValue, privacy: .public)\(geometry, privacy: .public)")
    }

    /// Something outside the list happened while it shows (F7): it closes as Esc does, or not.
    private func outside(_ event: SuggestCore.OutsideEvent) {
        guard let session, let reason = SuggestCore.closeReason(for: event, phase: session.phase) else { return }
        Self.logger.notice("Suggest closed reason=\(reason, privacy: .public)")
        finish()
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
        openGeneration &+= 1
        request?.cancel()
        request = nil
        pressCheck?.cancel()
        pressCheck = nil
        keyMonitor.stop(reason: "suggest-closed")
        outsideWatch?.stop()
        outsideWatch = nil
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

/// Reads where the selected text is on screen, so the list can open there (F4). Read-only
/// Accessibility queries, each under a short messaging timeout. It never turns on an app's web
/// accessibility, so an Electron editor that has not exposed its text gives no rectangle; the apps
/// in `WebAccessibilityKeepOn` have it on (F5).
/// Order: the bounds of the selected range; then the caret (a zero-length range at the
/// selection's end, or its last character); then the bounds of the selected text-marker range
/// (WebKit and Chromium web text). Rectangles are in Accessibility coordinates (top-left origin).
enum SuggestAnchorReader {
    static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.suggest-anchor", qos: .userInteractive)
    /// How long the list waits for the rectangle before it shows where it always did. The keys
    /// are taken before the wait, so the shortcut never waits on it.
    static let budget: TimeInterval = 0.1
    private static let messagingTimeout: Float = 0.05

    struct Reading: Sendable {
        enum Result: Sendable {
            /// The selection's rectangle, and the part of it the list centres on (F7): the whole
            /// rectangle, or its last line (`SuggestCore.centreRect`).
            case rect(CGRect, centre: CGRect)
            case none
        }
        /// The focused element the rectangle came from (F7): the list closes when focus leaves it.
        struct Focused: @unchecked Sendable {
            let element: AXUIElement
        }
        let result: Result
        /// `bounds`, `caret`, `marker-bounds`, or `none:<reason>`.
        let source: String
        let milliseconds: Int
        var focused: Focused?

        static func none(reason: String) -> Reading { Reading(result: .none, source: "none:\(reason)", milliseconds: 0) }
    }

    static func read(processID: pid_t) -> Reading {
        let started = ProcessInfo.processInfo.systemUptime
        var focused: Reading.Focused?
        func done(_ rect: CGRect?, _ source: String, centre: CGRect? = nil) -> Reading {
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            guard let rect else { return Reading(result: .none, source: "none:\(source)", milliseconds: milliseconds, focused: focused) }
            return Reading(result: .rect(rect, centre: centre ?? rect), source: source, milliseconds: milliseconds, focused: focused)
        }
        guard AXIsProcessTrusted() else { return done(nil, "no-accessibility") }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let element = AccessibilityFocusReader.focusedElement(in: app).element else {
            return done(nil, "no-focused-element")
        }
        focused = Reading.Focused(element: element)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if let range = selectedRange(of: element) {
            let end = range.location + range.length
            if range.length > 0, let rect = bounds(of: range, in: element) {
                let last = lastCharacter(of: range, in: element).flatMap { bounds(of: $0, in: element) }
                return done(rect, "bounds", centre: SuggestCore.centreRect(selection: rect, lastCharacter: last))
            }
            if let rect = bounds(of: CFRange(location: end, length: 0), in: element) { return done(rect, "caret") }
            if range.length > 0, let rect = bounds(of: CFRange(location: end - 1, length: 1), in: element) {
                return done(rect, "caret")
            }
        }
        if let marker = markerGeometry(in: element) {
            return done(marker.rect, marker.reordered ? "marker-bounds-ordered" : "marker-bounds", centre: marker.centre)
        }
        return done(nil, "no-text-bounds")
    }

    /// The selection's last visible character as a character range (F7): trailing spaces and line
    /// breaks skipped when the selected text matches the range, else the range's last character.
    private static func lastCharacter(of range: CFRange, in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
            let text = value as? String, (text as NSString).length == range.length
        {
            guard let last = SuggestCore.lastVisibleCharacter(of: text) else { return nil }
            return CFRange(location: range.location + last.location, length: last.length)
        }
        return range.length > 0 ? CFRange(location: range.location + range.length - 1, length: 1) : nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0
        else { return nil }
        return range
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return rect(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter)
    }

    private static func markerGeometry(in element: AXUIElement) -> (rect: CGRect, centre: CGRect, reordered: Bool)? {
        var markers: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markers) == .success,
            let markers
        else { return nil }
        return SuggestCore.markerSelectionGeometry(markers, ElementMarkerQueries(element: element))
    }

    /// `SuggestCore.MarkerQueries` over Accessibility calls on one element.
    private struct ElementMarkerQueries: SuggestCore.MarkerQueries {
        let element: AXUIElement

        func bounds(_ range: CFTypeRef) -> CGRect? {
            SuggestAnchorReader.rect(element, "AXBoundsForTextMarkerRange" as CFString, range)
        }

        func inDocumentOrder(_ range: CFTypeRef) -> CFTypeRef? {
            guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
            let markers = unsafeBitCast(range, to: AXTextMarkerRange.self)
            let ends = [AXTextMarkerRangeCopyStartMarker(markers), AXTextMarkerRangeCopyEndMarker(markers)] as CFArray
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString, ends, &value) == .success
            else { return nil }
            return value
        }

        func lastCharacter(_ range: CFTypeRef) -> CFTypeRef? {
            guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
            let end = AXTextMarkerRangeCopyEndMarker(unsafeBitCast(range, to: AXTextMarkerRange.self))
            var previous: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXPreviousTextMarkerForTextMarker" as CFString, end, &previous) == .success,
                let previous
            else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString, [previous, end] as CFArray, &value) == .success
            else { return nil }
            return value
        }
    }

    /// A rectangle a parameterized attribute returns, if it could hold text (`SuggestCore.usableTextRect`).
    private static func rect(_ element: AXUIElement, _ attribute: CFString, _ parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return SuggestCore.usableTextRect(rect)
    }
}

/// What closes the list besides its keys and clicks (F7, `SuggestCore.closeReason`): a mouse
/// button down in any other app, another app becoming active, the app's focused element
/// changing away from the one the list opened on, and a key that changes the text. Read-only:
/// global event monitors (they see events and never consume them, so a typed key still reaches
/// the app), a workspace notification and an Accessibility observer, all removed by `stop`.
@MainActor
final class SuggestOutsideWatch {
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private let focused: AXUIElement?
    private let onEvent: (SuggestCore.OutsideEvent) -> Void
    private var stopped = false

    init(target: pid_t?, focused: AXUIElement?, onEvent: @escaping (SuggestCore.OutsideEvent) -> Void) {
        self.focused = focused
        self.onEvent = onEvent
        // Only events bound for other apps reach a global monitor, so a click on the list never does.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.emit(.mouseDown) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            let key = SuggestCore.TypedKey(
                keyCode: event.keyCode, characters: event.characters ?? "",
                command: flags.contains(.command), control: flags.contains(.control))
            Task { @MainActor in self?.emit(.keyDown(key)) }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isTarget = target != nil && app?.processIdentifier == target
            Task { @MainActor in self?.emit(.appActivated(isTarget: isTarget)) }
        }
        if let target, focused != nil { observeFocus(of: target) }
    }

    private func observeFocus(of processID: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<SuggestOutsideWatch>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.focusChanged(to: element) }
        }
        guard AXObserverCreate(processID, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(processID)
        guard AXObserverAddNotification(
            created, app, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func focusChanged(to element: AXUIElement) {
        emit(.focusChanged(isSame: focused.map { CFEqual($0, element) } ?? true))
    }

    /// Nothing reaches the controller after `stop`, so a late event never closes a later run.
    private func emit(_ event: SuggestCore.OutsideEvent) {
        guard !stopped else { return }
        onEvent(event)
    }

    func stop() {
        stopped = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }
}

@MainActor
final class SuggestPanelModel: ObservableObject {
    /// The selected text, once captured.
    @Published var original: String?
    /// nil while thinking. New content under the pointer clears its hover and press (F7).
    @Published var items: [String]? {
        didSet { pointer.reset() }
    }
    /// The picked line (1-based) while the list confirms it.
    @Published var picked: Int?
    /// What the pointer hovers and holds (F7).
    @Published var pointer = SuggestCore.Pointer()
    /// Where each clickable part is, in the panel's top-left coordinates, as the view lays it out.
    var frames: [SuggestCore.Target: CGRect] = [:]
    /// A click on a row, the esc chip or "more", or VoiceOver's press on one.
    var onClick: ((SuggestCore.Target) -> Void)?
}

/// Floats over the app and never takes keyboard focus (`SuggestNonActivatingPanel`), so the draft
/// keeps its focus and its selection. Its keys come from `SuggestController`'s key monitor; its
/// mouse events from `SuggestPointerView`, over the content (F7).
@MainActor
final class SuggestPanel: SuggestNonActivatingPanel {
    private let model: SuggestPanelModel
    private let hostingView: NSHostingView<SuggestPanelView>
    private let pointerView = SuggestPointerView()
    /// The selected text's rectangle in Accessibility coordinates, when it was read in time.
    private var anchor: CGRect?
    /// The part of it the list centres on (F7): the whole rectangle, or its last line.
    private var centre: CGRect?
    /// The side this run took at its first placement (F6), kept while the list fits there.
    private var runSide: SuggestCore.PanelSide?
    /// Where the pointer was when the list showed: AppKit may report a move when a window appears
    /// under a resting pointer, and that is not a move (F7).
    private var pointerAtShow: CGPoint?

    init(model: SuggestPanelModel) {
        self.model = model
        hostingView = NSHostingView(rootView: SuggestPanelView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120))
        appearance = nil  // follows VoiceInk's appearance, as the AutoLearn panel does
        let container = NSView()
        hostingView.autoresizingMask = [.width, .height]
        pointerView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        container.addSubview(pointerView)
        contentView = container
        hostingView.frame = container.bounds
        pointerView.frame = container.bounds
        pointerView.onEvent = { [weak self] event in self?.pointer(event) }
        setAccessibilityIdentifier("voiceink-suggest-panel")
    }

    func setAnchor(_ accessibilityRect: CGRect?, centre: CGRect? = nil) {
        anchor = accessibilityRect
        self.centre = centre
        runSide = nil
    }

    override func orderFrontRegardless() {
        pointerAtShow = NSEvent.mouseLocation
        model.pointer.reset()
        super.orderFrontRegardless()
    }

    /// Hover, press and click (F7). A picked line freezes the list while it goes.
    private func pointer(_ event: SuggestPointerView.Event) {
        guard model.picked == nil else { return }
        let wasOriginal = model.pointer.highlighted == .original
        var pointer = model.pointer
        var clicked: SuggestCore.Target?
        switch event {
        case .moved(let point, let screen):
            if let start = pointerAtShow, start == screen, pointer.pressed == nil { return }
            pointerAtShow = nil
            pointer.moved(over: SuggestCore.target(at: point, in: model.frames))
        case .exited:
            pointer.exited()
        case .down(let point):
            pointer.down(on: SuggestCore.target(at: point, in: model.frames))
        case .up(let point):
            clicked = pointer.up(on: SuggestCore.target(at: point, in: model.frames))
        }
        if pointer != model.pointer { model.pointer = pointer }
        // The whole original shows while the pointer is on it: the panel grows to fit.
        if wasOriginal != (model.pointer.highlighted == .original) { fitToContent() }
        if let clicked { model.onClick?(clicked) }
    }

    /// Sizes the panel to its content and places it at the anchor (`SuggestCore.panelOrigin`):
    /// under the selection, or above it when there is no room, whole on the screen that holds it.
    /// The first placement with an anchor picks the side for a full list (`SuggestCore.runSide`);
    /// later ones keep it while the list fits there. With no anchor, or one on no screen, it goes
    /// where it always did on the mouse's screen.
    @discardableResult
    func fitToContent() -> SuggestCore.PanelSide {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let screens = NSScreen.screens
        var placedAnchor: CGRect?
        var visible: CGRect?
        if let anchor, let primary = screens.first {
            let rect = SuggestCore.appKitRect(fromAccessibility: anchor, primaryScreenMaxY: primary.frame.maxY)
            if let index = SuggestCore.screenHolding(rect, screenFrames: screens.map(\.frame)) {
                placedAnchor = rect
                visible = screens[index].visibleFrame
            }
        }
        if visible == nil {
            let mouse = NSEvent.mouseLocation
            visible = (screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
        }
        guard let visible else {
            setContentSize(size)
            return .fallback
        }
        if placedAnchor != nil, runSide == nil {
            runSide = SuggestCore.runSide(size: size, anchor: placedAnchor, visible: visible)
        }
        let centreX = placedAnchor == nil ? nil : (centre ?? anchor)?.midX
        let placed = SuggestCore.panelOrigin(size: size, anchor: placedAnchor, visible: visible, keeping: runSide, centreX: centreX)
        if placedAnchor != nil { runSide = placed.side }
        setFrame(NSRect(origin: placed.origin, size: size), display: true)
        return placed.side
    }
}

/// Look A (F4, owner's choice from `design/suggest-panel/variants.html`), with 3b for long
/// fragments (`variant-a-sizes.html`). No title: the top line holds the original, then a muted
/// "→", with the "esc" chip on the right; long originals are cut to one line. Numbered rows with
/// the first one subtly highlighted; options wrap, the panel is 200 to 460 pt wide. For a
/// multi-word selection, what an option adds to the original is lit (`SuggestCore.segments`).
/// A small muted footer. The surface is VoiceInk's own (`AutoLearnSuggestionSurface`), so light
/// and dark follow the app. A picked line takes VoiceInk's selected-row look (`AppTheme.Selection`,
/// the green check of `ModePopover`), and the panel fades as before.
struct SuggestPanelView: View {
    @ObservedObject var model: SuggestPanelModel

    /// The AppKit twin of the option font, for its cap height.
    private static let optionMetrics = NSFont.systemFont(ofSize: 14)
    private static let badgeGap: CGFloat = 9
    private static let checkWidth: CGFloat = 14
    private static let minWidth: CGFloat = 200
    private static let maxWidth: CGFloat = 460
    /// The content edge: the top line, the badges and the footer start this far in.
    private static let edge: CGFloat = 10
    /// A row's highlight reaches this close to the panel's sides.
    private static let rowMargin: CGFloat = 4
    private static let changeFill = Color.accentColor.opacity(0.22)
    /// The panel's own coordinate space: top-left origin, as `SuggestPointerView` reports points.
    static let space = "suggest-panel"
    /// Hover and press fills (F7): VoiceInk's subtle surface for the row under the pointer, its
    /// selection fill while a press is held on it; the pick keeps the selection look with a border.
    private static let hoverFill = AppTheme.Surface.subtle
    private static let pressFill = AppTheme.Selection.fill

    @State private var originIsCut = false

    var body: some View {
        SuggestWidthLayout(minWidth: Self.minWidth, maxWidth: Self.maxWidth) {
            content
        }
        .modifier(AutoLearnSuggestionSurface())
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SuggestTargetFrames.self) { model.frames = $0 }
    }

    private func fill(for target: SuggestCore.Target) -> Color? {
        guard model.pointer.highlighted == target else { return nil }
        return model.pointer.pressed == target ? Self.pressFill : Self.hoverFill
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            topLine
                .padding(.horizontal, Self.edge)
                .padding(.top, 2)
                .padding(.bottom, 4)
            if let items = model.items {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    row(line: index + 1, text: item)
                }
                footer(count: items.count)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: "Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Self.edge)
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Thinking"))
                .accessibilityIdentifier("suggest-thinking")
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 7)
    }

    private var topLine: some View {
        // Cut to one line; the whole of a cut original shows while the pointer is on it (F7).
        let whole = originIsCut && model.pointer.highlighted == .original
        return HStack(alignment: whole ? .top : .center, spacing: 12) {
            if let original = model.original {
                let shown = original.replacingOccurrences(of: "\n", with: " ")
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    if whole {
                        // The arrow follows the text's last line, not the right edge.
                        (Text(verbatim: shown)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            + Text(verbatim: "  →")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary))
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(verbatim: shown)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .background {
                                GeometryReader { shownBox in
                                    Text(verbatim: shown)
                                        .font(.system(size: 13, weight: .medium))
                                        .fixedSize()
                                        .hidden()
                                        .background {
                                            GeometryReader { fullBox in
                                                Color.clear.preference(
                                                    key: SuggestOriginCut.self,
                                                    value: fullBox.size.width > shownBox.size.width + 0.5)
                                            }
                                        }
                                }
                            }
                        Text(verbatim: "→")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .reportFrame(.original)
                .onPreferenceChange(SuggestOriginCut.self) { cut in
                    if !(model.pointer.highlighted == .original && originIsCut) { originIsCut = cut }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: original))
                .accessibilityIdentifier("suggest-original")
            }
            Spacer(minLength: 0)
            SuggestKeyChip(text: "esc", fill: fill(for: .close))
                .reportFrame(.close)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Close"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onClick?(.close) }
                .accessibilityIdentifier("suggest-close")
        }
    }

    private func row(line: Int, text: String) -> some View {
        let isPicked = model.picked == line
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return HStack(alignment: .suggestFirstLine, spacing: Self.badgeGap) {
            SuggestKeyChip(text: "\(line)", badge: true)
            optionText(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineSpacing(3)
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
        .padding(.horizontal, Self.edge - Self.rowMargin)
        .padding(.vertical, 4)
        .background {
            if isPicked {
                shape.fill(AppTheme.Selection.fill)
                    .overlay(shape.strokeBorder(AppTheme.Selection.border, lineWidth: 1))
            } else if let fill = fill(for: .row(line)) {
                shape.fill(fill)
            }
        }
        .padding(.horizontal, Self.rowMargin)
        // The whole width of the panel is the row's to click, edge to edge with its neighbours.
        .reportFrame(.row(line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(line) \(text)"))
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.onClick?(.row(line)) }
        .accessibilityIdentifier("suggest-item-\(line)")
    }

    /// The option, with what it adds to the original lit where marking helps (`SuggestCore.segments`).
    private func optionText(_ text: String) -> Text {
        var attributed = AttributedString()
        for segment in SuggestCore.segments(of: text, original: model.original ?? "") {
            var run = AttributedString(segment.text)
            if segment.changed { run.backgroundColor = Self.changeFill }
            attributed += run
        }
        return Text(attributed)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: SuggestCore.FooterHints.pick(
                count: count,
                keyLabel: UserDefaults.standard.string(forKey: SuggestCore.FooterHints.pickKeyLabelDefaultsKey)
            ) + " · ")
                .accessibilityIdentifier("suggest-footer")
            // "more" does what another press of the Suggest shortcut does (F7): a new set, or a
            // fresh run for a new selection.
            Text(verbatim: SuggestCore.FooterHints.more(
                keyLabel: UserDefaults.standard.string(forKey: SuggestCore.FooterHints.moreKeyLabelDefaultsKey),
                boundShortcut: ShortcutStore.shortcut(for: .suggestReplacement)?.displayString
            ))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background {
                    if let fill = fill(for: .more) { RoundedRectangle(cornerRadius: 4).fill(fill) }
                }
                .padding(.horizontal, -3)
                .reportFrame(.more)
                .accessibilityLabel(Text(verbatim: "More suggestions"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onClick?(.more) }
                .accessibilityIdentifier("suggest-more")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Self.edge)
        .padding(.top, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.top, 4)
    }
}

/// The frames of the list's clickable parts, in `SuggestPanelView.space` (F7).
private struct SuggestTargetFrames: PreferenceKey {
    static let defaultValue: [SuggestCore.Target: CGRect] = [:]
    static func reduce(value: inout [SuggestCore.Target: CGRect], nextValue: () -> [SuggestCore.Target: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Whether the top line cuts the original (F7).
private struct SuggestOriginCut: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private extension View {
    func reportFrame(_ target: SuggestCore.Target) -> some View {
        background {
            GeometryReader { box in
                Color.clear.preference(key: SuggestTargetFrames.self, value: [target: box.frame(in: .named(SuggestPanelView.space))])
            }
        }
    }
}

/// Takes its content's one-line (ideal) width, kept within `minWidth…maxWidth`, then the height the
/// content needs at that width. So a short list is as narrow as its longest line, and a long option
/// wraps at `maxWidth` with the panel tall enough for every line.
private struct SuggestWidthLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(max(content.sizeThatFits(.unspecified).width, minWidth), maxWidth)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
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

/// The key chips of the mockup: "esc" on the top line, and an 18 pt square digit badge per row,
/// so 1 to 9 are all the same size. Colours from the Quick Add panel's chips (`AppTheme`).
private struct SuggestKeyChip: View {
    let text: String
    var badge = false
    /// Over the chip's own fill while the pointer is on a clickable chip (F7).
    var fill: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: badge ? 5 : 4)
        Text(verbatim: text)
            .font(.system(size: badge ? 11 : 10.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondary)
            .padding(.horizontal, badge ? 0 : 5)
            .frame(width: badge ? 18 : nil, height: badge ? 18 : 16)
            .background(AppTheme.Surface.controlActive, in: shape)
            .overlay { if let fill { shape.fill(fill) } }
    }
}

/// Fork F8: the system spell checker for Suggest's misspelling guard. Each word goes to the
/// checker of its own script: the English checker passes any Cyrillic word, and a word that mixes
/// the two scripts is never a real word.
enum SuggestSpelling {
    static func isWord(_ word: String) -> Bool {
        let cyrillic = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let latin = word.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
        if cyrillic && latin { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: cyrillic ? "ru" : "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}
