import AppKit
import ContinuumRevivedCore

/// A nonblocking, production-action checklist. Rows complete only when the real
/// command/navigation/zone callbacks record their milestones; the view itself
/// never grants progress for being shown or clicked.
@MainActor
final class CanvasGettingStartedView: NSVisualEffectView {
    var onOpenCommandCenter: (() -> Void)?
    var onShowZoneActions: (() -> Void)?
    var onSkipTask: ((GettingStartedTask) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Getting Started")
    private let subtitleLabel = NSTextField(labelWithString: "Three quick, real actions")
    private let taskStack = NSStackView()
    private var rows: [GettingStartedTask: GettingStartedTaskRowView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        setAccessibilityIdentifier("ArrayGettingStartedTasks")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1

        taskStack.orientation = .vertical
        taskStack.alignment = .leading
        taskStack.spacing = 8

        let root = NSStackView(views: [header, taskStack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 356),
        ])

        for task in GettingStartedTask.allCases {
            let row = GettingStartedTaskRowView(task: task)
            row.onPrimaryAction = { [weak self] task in
                switch task {
                case .openCommandCenter: self?.onOpenCommandCenter?()
                case .personalizeZone: self?.onShowZoneActions?()
                case .navigate: break
                }
            }
            row.onSkip = { [weak self] task in self?.onSkipTask?(task) }
            rows[task] = row
            taskStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func reload(
        progress: OnboardingProgress,
        commandCenterShortcut: String?,
        navKeymap: NavKeymap
    ) {
        let command = commandCenterShortcut ?? "the top-bar button"
        let hold = Self.modifierDisplay(navKeymap.leaderHoldModifier)
        rows[.openCommandCenter]?.configure(
            title: "Open Command Center",
            detail: "Use the top bar or \(command).",
            state: state(for: .openCommandCenter, in: progress),
            primaryTitle: "Open"
        )
        rows[.navigate]?.configure(
            title: "Navigate",
            detail: "Hold \(hold) to jump; then \(navKeymap.leader.displayString), move, Return.",
            state: state(for: .navigate, in: progress),
            primaryTitle: nil
        )
        rows[.personalizeZone]?.configure(
            title: "Personalize the Zone",
            detail: "Rename, choose a color, and inspect Project/Home.",
            state: state(for: .personalizeZone, in: progress),
            primaryTitle: "Show"
        )
        isHidden = !Self.shouldPresent(progress)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 356, height: taskStack.fittingSize.height + 59)
    }

    static func shouldPresent(_ progress: OnboardingProgress) -> Bool {
        guard progress.hasPendingGettingStartedTasks else { return false }
        switch progress.starter.phase {
        case .waitingForEnvironment, .creating, .complete, .skipped:
            return true
        case .notStarted, .ineligible:
            return progress.needsIntro || progress.educationReplayRequested
        }
    }

    private func state(
        for task: GettingStartedTask,
        in progress: OnboardingProgress
    ) -> GettingStartedTaskRowView.State {
        if progress.isTaskComplete(task) { return .complete }
        if progress.skippedTasks.contains(task) { return .skipped }
        return .pending
    }

    private static func modifierDisplay(_ modifiers: FocusKeyModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result.isEmpty ? "the leader key" : result
    }
}

@MainActor
private final class GettingStartedTaskRowView: NSView {
    enum State { case pending, complete, skipped }

    let task: GettingStartedTask
    var onPrimaryAction: ((GettingStartedTask) -> Void)?
    var onSkip: ((GettingStartedTask) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    init(task: GettingStartedTask) {
        self.task = task
        super.init(frame: .zero)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [primaryButton, skipButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10.5, weight: .medium)
        }
        primaryButton.target = self
        primaryButton.action = #selector(runPrimary(_:))
        skipButton.target = self
        skipButton.action = #selector(skip(_:))

        let actions = NSStackView(views: [primaryButton, skipButton])
        actions.orientation = .horizontal
        actions.spacing = 2

        let row = NSStackView(views: [statusLabel, copy, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func configure(title: String, detail: String, state: State, primaryTitle: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        primaryButton.title = primaryTitle ?? ""
        primaryButton.isHidden = primaryTitle == nil || state != .pending
        skipButton.isHidden = state != .pending
        switch state {
        case .pending:
            statusLabel.stringValue = "○"
            statusLabel.textColor = .secondaryLabelColor
            titleLabel.textColor = .labelColor
        case .complete:
            statusLabel.stringValue = "✓"
            statusLabel.textColor = .systemGreen
            titleLabel.textColor = .secondaryLabelColor
        case .skipped:
            statusLabel.stringValue = "–"
            statusLabel.textColor = .tertiaryLabelColor
            titleLabel.textColor = .tertiaryLabelColor
        }
    }

    @objc private func runPrimary(_ sender: NSButton) { onPrimaryAction?(task) }
    @objc private func skip(_ sender: NSButton) { onSkip?(task) }
}
