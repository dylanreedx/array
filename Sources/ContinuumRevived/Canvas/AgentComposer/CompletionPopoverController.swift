import AppKit
import ContinuumRevivedCore

/// Provider-driven completion presentation. The controller owns exactly one
/// request generation: text/selection changes cancel the previous task, and the
/// generation guard prevents an uncooperative stale provider from repainting the
/// surface after a newer query or detach.
@MainActor
final class CompletionPopoverController {
    private let popover = ChoicePopoverController()
    private var requestTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private weak var textView: ComposerTextView?
    private var insertionInProgress = false
    private(set) var qaRequestStartCount = 0

    var isPresented: Bool { popover.isPresented }

    deinit {
        requestTask?.cancel()
        MainActor.assumeIsolated { popover.dismiss() }
    }

    func update(
        text: String,
        selection: NSRange,
        source: any AgentCompletionSuggestionSource,
        context: AgentCompletionContext?,
        anchor: NSRect,
        relativeTo textView: ComposerTextView,
        onAccept: @escaping (AgentCompletion, NSRange) -> Void
    ) {
        requestTask?.cancel()
        generation &+= 1
        let requestedGeneration = generation
        self.textView = textView

        // TextKit synchronously reports text/selection changes while a completion
        // replacement is being inserted. Do not immediately reopen the accepted
        // query from those callbacks.
        guard !insertionInProgress else {
            dismissSurface()
            return
        }

        guard let detectedQuery = AgentCompletionQueryDetector.activeQuery(
            in: text,
            selection: selection
        ) else {
            dismissSurface()
            return
        }
        let query = AgentCompletionQuery(
            trigger: detectedQuery.trigger,
            text: detectedQuery.text,
            replacementRange: detectedQuery.replacementRange,
            context: context
        )

        // Hide old-query rows immediately instead of leaving actionable stale
        // content visible while a slower replacement provider runs.
        popover.dismiss()
        textView.suggestionsAreVisible = false
        requestTask = Task { [weak self, weak textView] in
            self?.qaRequestStartCount += 1
            let suggestions = await source.suggestions(for: query)
            let staleWitness = ProcessInfo.processInfo.environment[
                "CONTINUUM_P4_9_STALE_NEGATIVE_WITNESS"
            ] == "1"
            guard !Task.isCancelled || staleWitness,
                  let self,
                  let textView,
                  (self.generation == requestedGeneration || staleWitness),
                  textView.window != nil else { return }
            guard !suggestions.isEmpty else {
                self.dismissSurface()
                return
            }

            let keyed = suggestions.enumerated().map { index, completion in
                (key: "completion-\(index)", completion: completion)
            }
            let byKey = Dictionary(uniqueKeysWithValues: keyed.map { ($0.key, $0.completion) })
            self.popover.present(
                items: keyed.map {
                    ChoiceItem(
                        id: $0.key,
                        title: $0.completion.title,
                        detail: $0.completion.detail
                    )
                },
                selectedID: nil,
                anchor: anchor,
                relativeTo: textView,
                takesFocus: false
            ) { [weak self, weak textView] item in
                guard let self,
                      let textView,
                      self.generation == requestedGeneration,
                      let completion = byKey[item.id] else { return }
                textView.suggestionsAreVisible = false
                self.insertionInProgress = true
                if case let .insertText(text) = completion.payload {
                    textView.insertCompletion(text, replacementRange: query.replacementRange)
                } else {
                    onAccept(completion, query.replacementRange)
                }
                self.insertionInProgress = false
            }
            textView.suggestionsAreVisible = self.popover.isPresented
        }
    }

    /// Routes keyboard navigation while the passive panel leaves the native
    /// editor first responder so typing and IME continue through TextKit.
    @discardableResult
    func perform(_ command: ChoiceListCommand) -> Bool {
        popover.perform(command)
    }

    /// Called for Escape, caret movement that has no active query, and tile
    /// detach. Cancellation is immediate even if a provider ignores it.
    func dismiss() {
        requestTask?.cancel()
        requestTask = nil
        generation &+= 1
        dismissSurface()
    }

    private func dismissSurface() {
        popover.dismiss()
        textView?.suggestionsAreVisible = false
        textView = nil
    }

    // Deterministic AppKit probes inspect the real presented list and panel.
    var qaTitles: [String] { popover.listView?.items.map(\.title) ?? [] }
    var qaFocusedTitle: String? {
        guard let list = popover.listView else { return nil }
        return list.items.first(where: { $0.id == list.focusedID })?.title
    }
    var qaPanelFrame: NSRect? { popover.panel?.frame }
}
