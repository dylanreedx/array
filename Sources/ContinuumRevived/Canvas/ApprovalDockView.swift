import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
struct ApprovalDockRequest: Equatable {
    var requestId: String
    var kind: ApprovalKind
    var detail: String?

    init(requestId: String, kind: ApprovalKind, detail: String?) {
        self.requestId = requestId
        self.kind = kind
        self.detail = Self.sanitizedDetail(detail)
    }

    static func sanitizedDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let collapsed = detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(160))
    }
}

extension ApprovalKind {
    var displayName: String {
        switch self {
        case .commandExecutionApproval: return "Run command"
        case .applyPatchApproval: return "Apply patch"
        case .toolUserInput: return "Answer needed"
        }
    }
}

@MainActor
final class ApprovalDockView: NSView {
    var pendingRequest: ApprovalDockRequest? {
        didSet { configure(with: pendingRequest) }
    }

    var onDecision: ((ApprovalDecision) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "⚠ Approval needed")
    private let detailLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 0
        isHidden = true
        alphaValue = 0

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .systemOrange

        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let approve = makeButton(title: "Approve", decision: .accept, orange: true)
        let approveSession = makeButton(title: "Approve for session", decision: .acceptForSession, orange: true)
        let decline = makeButton(title: "Decline", decision: .decline, orange: false)
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        [approve, approveSession, decline].forEach(buttonStack.addArrangedSubview)

        let layout = NSStackView(views: [headerLabel, detailLabel, buttonStack])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 6
        layout.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var qaDetailText: String { detailLabel.stringValue }
    var qaButtonTitles: [String] { buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func qaClick(_ decision: ApprovalDecision) {
        onDecision?(decision)
        pendingRequest = nil
        alphaValue = 0
        isHidden = true
    }

    private func configure(with request: ApprovalDockRequest?) {
        guard let request else {
            animateVisible(false)
            return
        }
        if let detail = request.detail {
            detailLabel.stringValue = "\(request.kind.displayName): \(detail)"
            detailLabel.isHidden = false
        } else {
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
        }
        animateVisible(true)
    }

    private func makeButton(title: String, decision: ApprovalDecision, orange: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(decisionClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = orange ? .systemOrange : .secondaryLabelColor
        button.identifier = NSUserInterfaceItemIdentifier("approvalDock.\(decision.rawValue)")
        return button
    }

    @objc private func decisionClicked(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case ApprovalDecision.accept.rawValue:
            qaClick(.accept)
        case ApprovalDecision.acceptForSession.rawValue:
            qaClick(.acceptForSession)
        case ApprovalDecision.decline.rawValue:
            qaClick(.decline)
        default:
            break
        }
    }

    private func animateVisible(_ show: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if show { isHidden = false }
        guard !reduced else {
            alphaValue = show ? 1 : 0
            isHidden = !show
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                if !show { self?.isHidden = true }
            }
        }
    }
}
