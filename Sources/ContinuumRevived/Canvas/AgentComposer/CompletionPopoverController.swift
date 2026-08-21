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
    private var completionsByChoiceID: [String: AgentCompletion] = [:]
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
        navigationPath: String?,
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
        let fileNavigation = detectedQuery.trigger == "@"
            ? Self.fileNavigation(
                queryText: detectedQuery.text,
                navigationPath: navigationPath,
                checkoutRoot: context?.checkoutRoot
            )
            : nil
        let query = AgentCompletionQuery(
            trigger: detectedQuery.trigger,
            text: fileNavigation?.queryText ?? detectedQuery.text,
            replacementRange: detectedQuery.replacementRange,
            context: context,
            navigationPath: fileNavigation?.navigationPath
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
            var displayedSuggestions = suggestions
            if query.trigger == "@", query.text.isEmpty,
               let root = query.context?.checkoutRoot.standardizedFileURL,
               let current = Self.fileScopeURL(
                   navigationPath: query.navigationPath,
                   checkoutRoot: root
               ),
               current.path != "/" {
                let parent = current.deletingLastPathComponent().standardizedFileURL
                let parentDetail: String
                if parent.path == root.path {
                    parentDetail = root.lastPathComponent
                } else if parent.path.hasPrefix(root.path + "/") {
                    parentDetail = String(parent.path.dropFirst(root.path.count + 1))
                } else {
                    parentDetail = parent.path
                }
                displayedSuggestions.insert(AgentCompletion(
                    id: "completion-parent-directory",
                    title: "../",
                    detail: parentDetail,
                    insertionText: "@",
                    score: Int.max,
                    payload: .directory(DirectoryNavigationTarget(directoryURL: parent)),
                    provenance: AgentCompletionProvenance(
                        backend: query.context?.backend,
                        scope: .project,
                        sourceIdentifier: parent.path,
                        invocationName: "../"
                    )
                ), at: 0)
            }
            // A nested directory can legitimately contain no referenceable
            // children. The synthetic parent row is still actionable in that
            // state, so decide whether to dismiss only after adding it.
            guard !displayedSuggestions.isEmpty else {
                self.dismissSurface()
                return
            }
            let keyed = displayedSuggestions.enumerated().map { index, completion in
                (key: "completion-\(index)", completion: completion)
            }
            let byKey = Dictionary(uniqueKeysWithValues: keyed.map { ($0.key, $0.completion) })
            self.completionsByChoiceID = byKey
            let items = keyed.map {
                ChoiceItem(
                    id: $0.key,
                    title: $0.completion.title,
                    detail: query.trigger == "@" ? Self.fileRowDetail(for: $0.completion) : $0.completion.detail,
                    icon: query.trigger == "@" ? Self.fileRowIcon(for: $0.completion) : Self.commandRowIcon(for: $0.completion),
                    enabled: $0.completion.isEnabled,
                    destructive: Self.isDestructive($0.completion)
                )
            }
            let popoverLayout: ChoicePopoverLayout
            let listPresentation: ChoiceListPresentation
            if query.trigger == "@" {
                let breadcrumb = Self.fileBreadcrumb(
                    navigationPath: query.navigationPath,
                    checkoutRoot: query.context?.checkoutRoot
                )
                popoverLayout = .completion(CompletionPopoverLayout(
                    breadcrumb: breadcrumb,
                    footer: "↑↓ Navigate   →/Tab Open   ←/⌫ Up   ↵ Select   Esc Close"
                ))
                listPresentation = .completions
            } else {
                popoverLayout = .commands(CommandPopoverLayout())
                listPresentation = .commands
            }
            self.popover.present(
                items: items,
                selectedID: nil,
                presentation: listPresentation,
                layout: popoverLayout,
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
        if command == .open,
           let focusedID = popover.listView?.focusedID,
           let completion = completionsByChoiceID[focusedID] {
            guard case .directory = completion.payload else { return true }
        }
        return popover.perform(command)
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
        completionsByChoiceID = [:]
    }

    private static func fileRowIcon(for completion: AgentCompletion) -> ChoiceIcon {
        if case .directory = completion.payload { return .system("folder") }
        return .system("doc.text")
    }

    /// Resolve the directory portion of a typed file path exactly as a shell
    /// resolves a path relative to its current directory, while leaving the
    /// composer text untouched until the user accepts a result. The final,
    /// unfinished component remains the fuzzy query. For example, from
    /// `/Users/me/workspace`, `@../personal/Arr` browses `/Users/me/personal`
    /// and fuzzy-matches `Arr` there. Traversal is not clamped to the checkout;
    /// the checkout is merely the initial Home and `/` is the only upper bound.
    private static func fileNavigation(
        queryText: String,
        navigationPath: String?,
        checkoutRoot: URL?
    ) -> (queryText: String, navigationPath: String?) {
        guard let checkoutRoot = checkoutRoot?.standardizedFileURL,
              var directory = fileScopeURL(
                  navigationPath: navigationPath,
                  checkoutRoot: checkoutRoot
              ) else {
            return (queryText, navigationPath)
        }
        guard let finalSlash = queryText.lastIndex(of: "/") else {
            return (queryText, navigationPath)
        }

        let directoryText = String(queryText[...finalSlash])
        let remainder = String(queryText[queryText.index(after: finalSlash)...])
        if directoryText.hasPrefix("/") {
            directory = URL(fileURLWithPath: directoryText, isDirectory: true)
                .standardizedFileURL
        } else {
            directory = directory.appendingPathComponent(
                directoryText,
                isDirectory: true
            ).standardizedFileURL
        }
        return (
            queryText: remainder,
            navigationPath: fileNavigationPath(
                for: directory,
                checkoutRoot: checkoutRoot
            )
        )
    }

    private static func fileScopeURL(
        navigationPath: String?,
        checkoutRoot: URL
    ) -> URL? {
        guard let navigationPath, !navigationPath.isEmpty else {
            return checkoutRoot.standardizedFileURL
        }
        if navigationPath.hasPrefix("/") {
            return URL(fileURLWithPath: navigationPath, isDirectory: true).standardizedFileURL
        }
        return checkoutRoot.appendingPathComponent(
            navigationPath,
            isDirectory: true
        ).standardizedFileURL
    }

    private static func fileNavigationPath(
        for directory: URL,
        checkoutRoot: URL
    ) -> String? {
        let directory = directory.standardizedFileURL
        let checkoutRoot = checkoutRoot.standardizedFileURL
        if directory.path == checkoutRoot.path { return nil }
        if directory.path.hasPrefix(checkoutRoot.path + "/") {
            return String(directory.path.dropFirst(checkoutRoot.path.count + 1))
        }
        return directory.path
    }

    private static func fileBreadcrumb(
        navigationPath: String?,
        checkoutRoot: URL?
    ) -> String {
        guard let checkoutRoot = checkoutRoot?.standardizedFileURL,
              let directory = fileScopeURL(
                  navigationPath: navigationPath,
                  checkoutRoot: checkoutRoot
              ) else { return "checkout" }
        if directory.path == checkoutRoot.path
            || directory.path.hasPrefix(checkoutRoot.path + "/") {
            let relative = directory.path == checkoutRoot.path
                ? ""
                : String(directory.path.dropFirst(checkoutRoot.path.count + 1))
            return (["Home"] + relative
                .split(separator: "/").map(String.init)).joined(separator: "  ›  ")
        }

        let homeComponents = checkoutRoot.pathComponents
        let directoryComponents = directory.pathComponents
        var commonCount = 0
        while commonCount < min(homeComponents.count, directoryComponents.count),
              homeComponents[commonCount] == directoryComponents[commonCount] {
            commonCount += 1
        }
        let ascents = Array(
            repeating: "..",
            count: max(0, homeComponents.count - commonCount)
        )
        let descendants = directoryComponents.dropFirst(commonCount)
            .filter { $0 != "/" }
        return (["Home"] + ascents + descendants).joined(separator: "  ›  ")
    }

    private static func commandRowIcon(for completion: AgentCompletion) -> ChoiceIcon? {
        guard case let .command(invocation) = completion.payload else { return nil }
        switch invocation.surface {
        case .array: return .system("sparkles")
        case .skill, .promptTemplate: return .system("wand.and.stars")
        case .cli, .extensionCommand: return .system("terminal")
        case .providerSlash: return .system("command")
        }
    }

    private static func isDestructive(_ completion: AgentCompletion) -> Bool {
        guard case let .command(invocation) = completion.payload else { return false }
        return completion.detail?.localizedCaseInsensitiveContains("destructive") == true
            || ["delete", "logout", "exit", "quit", "archive"].contains(invocation.name)
    }

    private static func fileRowDetail(for completion: AgentCompletion) -> String? {
        if completion.id == "completion-parent-directory" {
            return "Go to \(completion.detail ?? "checkout")"
        }
        guard let rawPath = completion.detail, !rawPath.isEmpty else { return "./" }
        let isAbsolute = rawPath.hasPrefix("/")
        let cleanPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parent = (cleanPath as NSString).deletingLastPathComponent
        if parent == "." || parent.isEmpty { return isAbsolute ? "/" : "./" }
        return (isAbsolute ? "/" : "") + parent + "/"
    }

    // Deterministic AppKit probes inspect the real presented list and panel.
    var qaTitles: [String] { popover.listView?.items.map(\.title) ?? [] }
    var qaDetails: [String?] { popover.listView?.items.map(\.detail) ?? [] }
    var qaFocusedTitle: String? {
        guard let list = popover.listView else { return nil }
        return list.items.first(where: { $0.id == list.focusedID })?.title
    }
    var qaPanelFrame: NSRect? { popover.panel?.frame }
    var qaBreadcrumb: String? { popover.qaCompletionBreadcrumb }
    var qaFooter: String? { popover.qaCompletionFooter }
    var qaFocusedRowIsVisible: Bool { popover.listView?.qaFocusedRowIsVisible ?? false }
}
