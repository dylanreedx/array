import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The guest's reading of a shared agent's chrome: the host's facts turned into
/// the presentations the host tile builds, with the host tile's presenters.
@MainActor
enum SharedAgentChromePresenter {
    typealias Chrome = SharedAgentTranscriptWire.Chrome

    /// What the under-bar's header shows.
    static func header(_ chrome: Chrome, now: Date = AgentElapsedClock.now()) -> AgentTileStatePresenter.Presentation {
        let header = chrome.header
        return .init(
            name: header.name, status: header.status, stateLabel: header.stateLabel,
            stateAccessibilityLabel: header.stateAccessibilityLabel, revealRequestID: nil,
            availableActionDescription: header.availableActionDescription,
            branch: header.branch.map { .init(text: $0.text, tooltip: $0.tooltip, isWarning: $0.isWarning) },
            startedAt: header.startedAt,
            elapsedSeconds: header.startedAt.map { max(0, Int(now.timeIntervalSince($0))) })
    }

    /// The status row, as the host tile paints it (its account and cost stay home).
    static func statusRow(_ chrome: Chrome, now: Date = AgentElapsedClock.now()) -> AgentCompactStatusPresentation {
        let location = chrome.location.map {
            AgentCompactStatusPresentation.Location(symbolName: $0.symbolName, text: $0.text,
                                                    accessibilityLabel: $0.accessibilityLabel,
                                                    detailText: $0.text, isExternal: $0.isExternal)
        } ?? .init(symbolName: "house", text: "—", accessibilityLabel: "Home and Where: unknown.",
                   detailText: "Location unavailable", isExternal: false)
        let activity = chrome.activity.flatMap(SharedAgentChromeBuilder.activityInput)
            .map { AgentCompactStatusPresentation.presentActivity($0, now: now) } ?? ManagedAgentTileNSView.unknownCompactActivity
        return ManagedAgentTileNSView.presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
            location: location, activity: activity,
            context: AgentRadialContextMeterPresenter.present(chrome.context),
            quotas: [], cost: nil, account: nil,
            enabledElements: chrome.enabledElements.compactMap(AgentStatusElement.init(rawValue:))))
    }

    /// The words at the transcript's tail now, and whether the working tail shows.
    static func tail(_ chrome: Chrome, now: Date = AgentElapsedClock.now()) -> (working: Bool, text: String?, settled: String?) {
        guard chrome.tail.working, let text = chrome.tail.text else {
            return (chrome.tail.working, nil, chrome.tail.settled)
        }
        let elapsed: String?
        if let since = chrome.tail.since {
            elapsed = ManagedAgentTileNSView.liveElapsedText(now.timeIntervalSince(since))
        } else {
            elapsed = chrome.activity.flatMap(SharedAgentChromeBuilder.activityInput)
                .flatMap { AgentCompactStatusPresentation.presentActivity($0, now: now).elapsedText }
        }
        guard let elapsed, !elapsed.isEmpty else { return (true, text, nil) }
        return (true, "\(text) · \(elapsed)", nil)
    }

    static func selection(_ chrome: Chrome) -> AgentLaunchSelection? {
        AgentHarness(rawValue: chrome.harness).map { AgentLaunchSelection(harness: $0, model: chrome.model, thinking: chrome.thinking) }
    }

    /// The primary action as the host shows it. Nothing here can stop the
    /// host's turn, so its Stop is drawn and never enabled; a guest who may
    /// prompt sends (or, mid-turn, queues) with it.
    static func action(_ chrome: Chrome, mayPrompt: Bool, hasDraft: Bool, sending: Bool) -> AgentComposerPresentation {
        let turn = chrome.turn
        if mayPrompt, hasDraft || !turn.working {
            return .resolve(state: .ready, capabilities: .init(canSend: true, canStop: false, canSteer: false, canQueue: false),
                            hasDraft: hasDraft, isExecutingPrimaryAction: sending)
        }
        var shown = AgentComposerPresentation.resolve(
            state: turn.working ? .working : .ready,
            capabilities: .init(canSend: turn.canSend, canStop: turn.canStop, canSteer: false, canQueue: false),
            hasDraft: false)
        shown.isEnabled = false
        shown.secondaryActions = []
        return shown
    }

    /// The identity treatment the host's style asks for: a wash over the title
    /// bar, or a border.
    static func identity(_ chrome: Chrome) -> (bar: NSColor?, border: NSColor?) {
        guard let name = chrome.identityColor else { return (nil, nil) }
        let tint = ZoneChromeNSView.color(named: name)
        if chrome.identityStyle == AgentIdentityColorStyle.border.rawValue {
            return (nil, tint.withAlphaComponent(ManagedAgentTileNSView.identityBorderAlpha))
        }
        return (tint.withAlphaComponent(ManagedAgentTileNSView.identityBarAlpha), nil)
    }
}

/// The host tile's compose strip, on the guest: its status row, its composer
/// and its provider row with the primary action, in the host's arrangement
/// (`ManagedAgentTileNSView.makeV2ContentView`, status above the composer).
/// The provider controls show the host's harness, model and effort and are
/// never enabled: they belong to the agent on the host's Mac.
@MainActor
final class SharedAgentComposeStrip: NSView {
    let statusRow = AgentCompactStatusRowView()
    let composer = AgentComposerView(frame: .zero, variant: .fullTurn)
    let footer = AgentComposerFooterView()
    let action = ComposerActionButton(presentation: .resolve(
        state: .ready, capabilities: .init(canSend: false, canStop: false, canSteer: false, canQueue: false), hasDraft: false))
    private let column = NSStackView()
    private let footerRow = NSStackView()
    private var lastSelection: AgentLaunchSelection?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let zoom = AgentPageZoom.default
        statusRow.hideLocationActions()
        footer.controlsEnabled = false
        footerRow.setViews([footer, action], in: .leading)
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = CGFloat(zoom.scaled(Space.m))
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)
        column.setViews([statusRow, composer, footerRow], in: .leading)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = CGFloat(zoom.scaled(Space.m))
        column.edgeInsets = NSEdgeInsets(Inset.row, zoom: zoom)
        for view in [column, footerRow, statusRow, composer, footer, action] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(column)
        let inset = CGFloat(zoom.scaled(Inset.row).horizontal)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            composer.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            footerRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -inset),
            statusRow.heightAnchor.constraint(equalToConstant: AgentCompactStatusRowView.preferredHeight(zoom: zoom)),
            footer.heightAnchor.constraint(equalToConstant: AgentComposerFooterView.height(zoom: zoom)),
            action.heightAnchor.constraint(equalToConstant: ComposerActionButton.controlHeight(zoom: zoom)),
        ])
        identifier = NSUserInterfaceItemIdentifier("sharedAgent.composeStrip")
        applyTokens()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The strip's height at `width`: what the live view gives it.
    func height(forWidth width: CGFloat) -> CGFloat {
        if frame.width != width { setFrameSize(NSSize(width: width, height: max(frame.height, 1))) }
        layoutSubtreeIfNeeded()
        return ceil(column.fittingSize.height)
    }

    func apply(_ chrome: SharedAgentTranscriptWire.Chrome, mayPrompt: Bool, readOnlyReason: String?, sending: Bool,
               now: Date = AgentElapsedClock.now()) {
        statusRow.apply(SharedAgentChromePresenter.statusRow(chrome, now: now))
        if let selection = SharedAgentChromePresenter.selection(chrome), selection != lastSelection {
            lastSelection = selection
            footer.apply(selection)
            footer.controlsEnabled = false
        }
        // Array only mirrors this agent: the host shows no composer and no
        // provider row, and neither does this.
        composer.isHidden = chrome.turn.isMirrored
        footerRow.isHidden = chrome.turn.isMirrored
        if composer.readOnlyReason != readOnlyReason { composer.readOnlyReason = readOnlyReason }
        let draft = !composer.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let presentation = SharedAgentChromePresenter.action(chrome, mayPrompt: mayPrompt, hasDraft: draft, sending: sending)
        if action.presentation != presentation { action.presentation = presentation }
        // A view-only guest's action is unavailable, not resting: it fades like
        // the provider chips and says why, as the composer does.
        action.dimsWhenDisabled = readOnlyReason != nil
        action.unavailableReason = readOnlyReason
            ?? (presentation.primaryAction == .stop && !presentation.isEnabled ? "Only its owner can stop it, on the owner's Mac." : nil)
        action.setAccessibilityHelp(action.unavailableReason)
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: effectiveTokenTheme)
        statusRow.applyTokens()
        composer.applyTokens()
        composer.layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: effectiveTokenTheme)
        footer.applyTokens()
        action.applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// QA: what the strip shows, as text, for the chrome parity comparison.
    var qaFacts: [String: String] {
        var facts: [String: String] = [:]
        SharedAgentChromeFacts.read(statusRow: statusRow, footer: footer, action: action, into: &facts)
        facts["composer.readOnly"] = composer.readOnlyReason ?? ""
        return facts
    }
}

/// What a tile's chrome shows, read off its views, so the host's tile and the
/// guest's can be compared fact by fact.
@MainActor
enum SharedAgentChromeFacts {
    static func read(statusRow: AgentCompactStatusRowView, footer: AgentComposerFooterView,
                     action: ComposerActionButton, into facts: inout [String: String]) {
        facts["status.accessibility"] = statusRow.accessibilityLabel() ?? ""
        let selection = footer.qaLaunchSelection
        facts["footer.harness"] = selection.harness.rawValue
        facts["footer.model"] = selection.model
        facts["footer.thinking"] = selection.thinking
        facts["action.kind"] = "\(action.presentation.primaryAction)"
        facts["action.title"] = action.presentation.title
    }

    static func read(tile: TileNSView, header: AgentTileHeaderView, into facts: inout [String: String]) {
        let chrome = tile.chromeSnapshot
        facts["title"] = chrome?.title ?? ""
        facts["title.providerModel"] = chrome?.providerModel ?? ""
        facts["title.providerMark"] = String(chrome?.showsProviderMark ?? false)
        facts["title.status"] = chrome?.agentStatus.map { "\($0)" } ?? ""
        facts["title.statusLabel"] = chrome?.agentStatusLabel ?? ""
        facts["title.tint"] = tile.qaTitleBarTint.flatMap { $0.usingColorSpace(.sRGB) }.map {
            String(format: "%.3f %.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent)
        } ?? ""
        facts["title.character"] = tile.qaCharacterRect == nil ? "none" : "shown"
        facts["header.state"] = header.qaState
        facts["header.branch"] = header.qaBranch ?? ""
        facts["header.managed"] = String(header.showsManaged)
    }
}

extension SharedAgentComposeStrip {
    /// The strip as the appearance census renders it: a working host agent
    /// with a context reading, seen by someone who may not prompt it.
    static func appearanceFixture(width: CGFloat) -> SharedAgentComposeStrip {
        let chrome = SharedAgentTranscriptWire.Chrome(
            agent: UUID(), title: "Map the checkout states", harness: AgentHarness.claudeCode.rawValue, model: "fixture/appearance",
            thinking: "medium", identityColor: nil, identityStyle: nil,
            header: .init(name: "Map the checkout states", status: .working, stateLabel: "Working",
                          stateAccessibilityLabel: "Agent is working.", availableActionDescription: "Stop current turn",
                          startedAt: nil, branch: nil, managed: false),
            turn: .init(working: true, canSend: false, canStop: true, canSteer: false, canQueue: false, isMirrored: false),
            context: AgentContextWindowSnapshot(usedTokens: 92_000, maxTokens: 200_000, observedAt: Date(),
                                                source: .claudeAssistantUsage, freshness: .live),
            activity: nil, location: .init(symbolName: "house", text: "checkout", accessibilityLabel: "Home and Where: checkout, project root.",
                                           isExternal: false),
            enabledElements: [], tail: .init(working: true, text: nil, since: nil, settled: nil), character: nil, helpers: [:])
        let strip = SharedAgentComposeStrip(frame: .zero)
        strip.apply(chrome, mayPrompt: false, readOnlyReason: "View only. Dylan and editors can prompt it.", sending: false)
        let height = strip.height(forWidth: width)
        strip.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return strip
    }
}
