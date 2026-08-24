import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

@MainActor
extension UIProbeGeometry {
    /// LAST-WAVE foundation: isolated completed-reasoning disclosure component.
    /// This deliberately exercises the new presenter/view directly; production
    /// transcript routing remains absent until the coordinator wires reasoning
    /// entries at the entry-row seam.
    static func checkCompletedReasoningDisclosure() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func visibleStrings(in view: NSView) -> [String] {
            let own: [String]
            if let field = view as? NSTextField { own = [field.stringValue] }
            else if let button = view as? NSButton { own = [button.title, button.toolTip ?? ""] }
            else if let text = view as? NSTextView { own = [text.string] }
            else { own = [] }
            return own + view.subviews.flatMap(visibleStrings)
        }
        func fail(_ message: String) -> GeometryError { GeometryError(message: message) }
        func assert(_ condition: @autoclosure () -> Bool, _ message: String, count: inout Int) throws {
            guard condition() else { throw fail(message) }
            count += 1
        }

        var assertions = 0
        let bodyText = "Compare the migration seams without claiming provider internals."
        let codeText = "let answer = 42\nprint(answer)"
        let opaqueSecret = "provider-private-payload-must-not-render"
        let unsupportedKind = AgentBlockKind(rawValue: "vendor.unsupported")!
        let entryID = id("reasoning.entry.completed")
        let paragraph = AgentBlock(
            id: id("reasoning.entry.completed.paragraph"),
            revision: 1,
            kind: .paragraph,
            payload: .paragraph([.text(bodyText)])
        )
        let fencedCode = AgentBlock(
            id: id("reasoning.entry.completed.code"),
            revision: 1,
            kind: .fencedCode,
            payload: .fencedCode(.init(language: "swift", code: codeText, isComplete: true))
        )
        let thematicRule = AgentBlock(
            id: id("reasoning.entry.completed.rule"),
            revision: 1,
            kind: .thematicBreak,
            payload: .thematicBreak
        )
        let unsupported = AgentBlock(
            id: id("reasoning.entry.completed.unknown"),
            revision: 1,
            kind: unsupportedKind,
            payload: .opaque(.init(debugLabel: "fixture-secret", value: .string(opaqueSecret)))
        )
        let entry = AgentEntry(
            id: entryID,
            revision: 1,
            role: .reasoning,
            provenance: .providerItem(provider: "fixture", itemID: "opaque-reasoning"),
            lifecycle: .finished,
            blocks: [paragraph, fencedCode, thematicRule, unsupported]
        )
        let openReasoning = AgentEntry(
            id: id("reasoning.entry.open"),
            revision: 1,
            role: .reasoning,
            provenance: .providerItem(provider: "fixture", itemID: "active-reasoning"),
            lifecycle: .open(markupBlockID: nil),
            blocks: [paragraph]
        )
        let assistantEntry = AgentEntry(
            id: id("assistant.entry.not-reasoning"),
            revision: 1,
            role: .assistant,
            provenance: .providerItem(provider: "fixture", itemID: nil),
            lifecycle: .finished,
            blocks: [paragraph]
        )
        let emptyReasoning = AgentEntry(
            id: id("reasoning.entry.empty"),
            role: .reasoning,
            provenance: .providerItem(provider: "fixture", itemID: nil),
            lifecycle: .finished,
            blocks: []
        )

        var semanticActions: [AgentRenderAction] = []
        var invalidations: [AgentNodeID] = []
        let store = DisclosureStateStore()
        let agentID = AgentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        let context = AgentRenderContext(
            actions: store.renderActions(
                for: agentID,
                perform: { semanticActions.append($0) },
                invalidatePresentation: { invalidations.append($0) }
            ),
            tokens: .transcript,
            appearance: .dark
        )

        try assert(
            CompletedReasoningDisclosurePresenter.presentation(for: nil, authoritativeDuration: nil, actions: context.actions) == nil
                && CompletedReasoningDisclosurePresenter.presentation(for: assistantEntry, authoritativeDuration: 65, actions: context.actions) == nil
                && CompletedReasoningDisclosurePresenter.presentation(for: emptyReasoning, authoritativeDuration: 65, actions: context.actions) == nil
                && CompletedReasoningDisclosurePresenter.presentation(for: openReasoning, authoritativeDuration: 65, actions: context.actions) == nil
                && CompletedReasoningDisclosureView.measuredHeight(for: openReasoning, authoritativeDuration: 65, width: 320, context: context) == 0,
            "completed reasoning presenter produced a row for absent/non-reasoning/empty/open input",
            count: &assertions
        )
        try assert(
            CompletedReasoningDisclosurePresenter.title(authoritativeDuration: nil) == "Thought"
                && CompletedReasoningDisclosurePresenter.title(authoritativeDuration: .nan) == "Thought"
                && CompletedReasoningDisclosurePresenter.title(authoritativeDuration: -1) == "Thought"
                && CompletedReasoningDisclosurePresenter.title(authoritativeDuration: 65) == "Thought for 1m 5s",
            "completed reasoning title invented a summary or mishandled unavailable/authoritative duration",
            count: &assertions
        )
        guard let presentation = CompletedReasoningDisclosurePresenter.presentation(
            for: entry,
            authoritativeDuration: 65,
            actions: context.actions
        ) else {
            throw fail("completed reasoning presenter rejected a finished reasoning entry with semantic blocks")
        }
        try assert(
            presentation.bodyBlocks.map(\.kind) == [.paragraph, .fencedCode, .thematicBreak, unsupportedKind],
            "completed reasoning presenter filtered, flattened, or reordered semantic reasoning blocks",
            count: &assertions
        )

        let collapsedHeight = CompletedReasoningDisclosureView.measuredHeight(
            for: entry,
            authoritativeDuration: 65,
            width: 320,
            context: context
        )
        try assert(
            collapsedHeight == CompletedReasoningDisclosureView.headerHeight,
            "completed reasoning collapsed height is not deterministic header-only geometry",
            count: &assertions
        )

        let view = CompletedReasoningDisclosureView(frame: NSRect(x: 0, y: 0, width: 320, height: collapsedHeight))
        var remeasureCount = 0
        view.apply(entry: entry, authoritativeDuration: 65, context: context) { remeasureCount += 1 }
        view.layoutSubtreeIfNeeded()
        try assert(
            !view.isExpanded
                && view.titleLabel.stringValue == "Thought for 1m 5s"
                && view.bodyContainer.isHidden
                && view.bodyHosts.isEmpty
                && view.accessibilityValue() as? String == "Collapsed"
                && view.disclosureButton.accessibilityValue() as? String == "Collapsed"
                && !visibleStrings(in: view).contains(bodyText)
                && !visibleStrings(in: view).contains("✓"),
            "completed reasoning collapsed state exposed body text, drew a competing completion glyph, or lost static title/AX state",
            count: &assertions
        )

        let space = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        view.keyDown(with: space)
        let expandedHeight = CompletedReasoningDisclosureView.measuredHeight(
            for: entry,
            authoritativeDuration: 65,
            width: 320,
            context: context
        )
        view.frame.size.height = expandedHeight
        view.layoutSubtreeIfNeeded()
        try assert(
            view.isExpanded
                && expandedHeight > collapsedHeight
                && store.explicitState(for: ToolDisclosureKey(agentID: agentID, blockID: entryID)) == true
                && invalidations == [entryID]
                && remeasureCount == 1
                && view.accessibilityValue() as? String == "Expanded"
                && view.disclosureButton.accessibilityValue() as? String == "Expanded"
                && view.bodyHosts.count == 4
                && view.bodyHosts.allSatisfy { $0.representedRole == .reasoning },
            "keyboard expansion did not persist state, request remeasurement, use reasoning-role hosts, or set expanded AX state",
            count: &assertions
        )

        guard let proseView = view.bodyHosts[0].rendererView as? AssistantProseView,
              let codeView = view.bodyHosts[1].rendererView as? CodeBlockView,
              let unknownView = view.bodyHosts[3].rendererView as? AgentUnknownBlockView else {
            throw fail("expanded reasoning did not use the production block-host renderer views for prose/code/unknown content")
        }
        let codeHeight = try view.bodyHosts[1].measuredHeight(for: fencedCode, entryRole: .reasoning, width: 288, context: context)
        let ruleHeight = try view.bodyHosts[2].measuredHeight(for: thematicRule, entryRole: .reasoning, width: 288, context: context)
        let unknownHeight = try view.bodyHosts[3].measuredHeight(for: unsupported, entryRole: .reasoning, width: 288, context: context)
        try assert(
            proseView.textFields.first?.stringValue == bodyText
                && proseView.textFields.first?.isSelectable == true
                && codeView.codeTextView.string == codeText
                && codeHeight > CodeBlockView.headerHeight
                && ruleHeight > 0
                // `.plans/45` T9 corrected this expectation. It pinned the safe
                // label of AgentDeferredBlockRenderer, i.e. it asserted that a
                // thematic break was still UNIMPLEMENTED: the deferred renderer
                // vends a bare NSView measuring 24pt and painting nothing. A rule
                // now renders, so the contract to gate is the real one — the
                // splitter role a screen reader needs.
                && view.bodyHosts[2].rendererView is ThematicBreakView
                && view.bodyHosts[2].rendererView?.accessibilityRole() == .splitter
                && view.bodyHosts[2].rendererView?.accessibilityLabel() as? String == "Section break"
                && unknownView.summaryLabel.stringValue == "Unsupported content: \(unsupportedKind.rawValue)"
                && unknownHeight == AgentUnknownBlockView.height
                && !visibleStrings(in: unknownView).contains(opaqueSecret),
            "expanded reasoning dropped semantic code/rule/unknown blocks, bypassed deterministic measurement, or exposed opaque payload",
            count: &assertions
        )

        let initialIdentities = view.bodyHosts.map { ObjectIdentifier($0) }
        let initialGenerations = view.bodyHosts.map(\.reuseGeneration)
        view.apply(entry: entry, authoritativeDuration: 65, context: context) { remeasureCount += 1 }
        try assert(
            view.bodyHosts.map { ObjectIdentifier($0) } == initialIdentities
                && view.bodyHosts.map(\.reuseGeneration) == initialGenerations,
            "identical expanded apply rebuilt or reset stable child hosts",
            count: &assertions
        )

        let removedCodeHost = view.bodyHosts[1]
        let removedRuleHost = view.bodyHosts[2]
        let codeReuseGeneration = removedCodeHost.reuseGeneration
        let ruleReuseGeneration = removedRuleHost.reuseGeneration
        let reducedEntry = AgentEntry(
            id: entryID,
            revision: 2,
            role: .reasoning,
            provenance: .providerItem(provider: "fixture", itemID: "opaque-reasoning"),
            lifecycle: .finished,
            blocks: [paragraph, unsupported]
        )
        view.apply(entry: reducedEntry, authoritativeDuration: 65, context: context) { remeasureCount += 1 }
        try assert(
            view.bodyHosts.count == 2
                && ObjectIdentifier(view.bodyHosts[0]) == initialIdentities[0]
                && ObjectIdentifier(view.bodyHosts[1]) == initialIdentities[3]
                && removedCodeHost.superview == nil
                && removedRuleHost.superview == nil
                && removedCodeHost.rendererView == nil
                && removedRuleHost.rendererView == nil
                && removedCodeHost.representedID == nil
                && removedRuleHost.representedID == nil
                && removedCodeHost.reuseGeneration > codeReuseGeneration
                && removedRuleHost.reuseGeneration > ruleReuseGeneration
                && (view.bodyHosts[1].rendererView as? AgentUnknownBlockView)?.summaryLabel.stringValue == "Unsupported content: \(unsupportedKind.rawValue)",
            "block removal failed to reuse stable survivors, safely reset removed hosts, or keep unsupported payload visible through fallback",
            count: &assertions
        )

        try assert(
            view.accessibilityPerformPress()
                && !view.isExpanded
                && view.bodyContainer.isHidden
                && remeasureCount == 2
                && invalidations == [entryID, entryID],
            "accessibility press did not collapse the completed reasoning disclosure and request remeasurement",
            count: &assertions
        )
        view.keyDown(with: space)
        try assert(
            view.isExpanded
                && remeasureCount == 3
                && invalidations == [entryID, entryID, entryID],
            "keyboard re-expansion after AX collapse did not restore expanded state or request remeasurement",
            count: &assertions
        )

        let recreated = CompletedReasoningDisclosureView(frame: NSRect(x: 0, y: 0, width: 320, height: expandedHeight))
        recreated.apply(entry: reducedEntry, authoritativeDuration: nil, context: context)
        try assert(
            recreated.isExpanded
                && recreated.titleLabel.stringValue == "Thought"
                && recreated.bodyHosts.count == 2
                && (recreated.bodyHosts[0].rendererView as? AssistantProseView)?.textFields.first?.stringValue == bodyText
                && (recreated.bodyHosts[1].rendererView as? AgentUnknownBlockView)?.summaryLabel.stringValue == "Unsupported content: \(unsupportedKind.rawValue)",
            "completed reasoning disclosure did not restore entry-keyed state, tolerate nil duration, or preserve unknown fallback",
            count: &assertions
        )

        let otherEntry = AgentEntry(
            id: id("reasoning.entry.other"),
            revision: 1,
            role: .reasoning,
            provenance: .providerItem(provider: "fixture", itemID: nil),
            lifecycle: .finished,
            blocks: [paragraph]
        )
        let other = CompletedReasoningDisclosureView(frame: NSRect(x: 0, y: 0, width: 320, height: collapsedHeight))
        other.apply(entry: otherEntry, authoritativeDuration: 65, context: context)
        try assert(
            !other.isExpanded
                && semanticActions.isEmpty,
            "completed reasoning disclosure leaked expansion across entry IDs or emitted a semantic agent action",
            count: &assertions
        )

        return assertions
    }
}
