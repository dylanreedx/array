import AppKit
import ContinuumRevivedAgentUI

/// One app-level message, kept outside navigation chrome so long failures wrap.
@MainActor
final class WorkspaceNotificationView: NSView {
    enum Kind { case success, warning, error }
    private let icon = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton(title: "", target: nil, action: nil)
    /// An offered repair ("Recover"): shown only with a message that carries one.
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionHandler: (() -> Void)?
    private var expiration: Timer?
    private(set) var kind: Kind = .warning
    var onDismiss: (() -> Void)?
    var message: String { messageLabel.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.maximumNumberOfLines = 0
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        dismissButton.image = CanvasSymbolImage.image(named: "xmark")
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel("Dismiss notification")
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.isHidden = true
        let row = NSStackView(views: [icon, messageLabel, actionButton, dismissButton])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            dismissButton.widthAnchor.constraint(equalToConstant: 18),
            dismissButton.heightAnchor.constraint(equalToConstant: 18)
        ])
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("App notification")
        applyColors()
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { expiration?.invalidate() }

    /// The offered action's title, when one is showing.
    var actionTitle: String? { actionButton.isHidden ? nil : actionButton.title }

    func show(_ message: String?, kind: Kind = .warning, action: (title: String, handler: () -> Void)? = nil) {
        expiration?.invalidate()
        expiration = nil
        self.kind = kind
        actionHandler = action?.handler
        actionButton.title = action?.title ?? ""
        actionButton.setAccessibilityLabel(action?.title)
        actionButton.isHidden = action == nil
        messageLabel.stringValue = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isHidden = messageLabel.stringValue.isEmpty
        icon.image = CanvasSymbolImage.image(named: kind == .success ? "checkmark.circle" : kind == .error ? "exclamationmark.circle" : "exclamationmark.triangle")
        setAccessibilityValue(messageLabel.stringValue)
        applyColors()
        if !isHidden {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: messageLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            if kind == .success, action == nil {
                expiration = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                }
            }
        }
    }

    /// Runs the offered action once. The message goes first, so the action's
    /// own outcome message is not dismissed by it.
    @objc func performAction() {
        let handler = actionHandler
        actionHandler = nil
        dismiss()
        handler?()
    }

    @objc func dismiss() {
        expiration?.invalidate()
        expiration = nil
        isHidden = true
        onDismiss?()
    }

    private func applyColors() {
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        messageLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        dismissButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        icon.contentTintColor = (kind == .success ? AccentToken.accentDone.color : kind == .error ? AccentToken.accentFailed.color : AccentToken.accentApproval.color).nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
