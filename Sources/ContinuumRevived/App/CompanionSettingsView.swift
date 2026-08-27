import AppKit
import ContinuumRevivedCore

@MainActor
final class CompanionSettingsView: NSView {
    struct Device: Equatable {
        var id: UUID
        var name: String
        var capabilitySummary: String
        var lastSeen: Date?
    }

    var onRedeemInvite: ((String) -> Void)?
    var onCreatePairing: (() -> Void)?
    var onCancelPairing: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRevoke: ((UUID) -> Void)?

    private let connectionLabel = NSTextField(labelWithString: "Checking relay…")
    private let notificationLabel = NSTextField(labelWithString: "Notifications are configured after an iPhone pairs.")
    private let inviteField = NSTextField()
    private let pairButton = NSButton(title: "Create iPhone Invitation", target: nil, action: nil)
    private let qrImageView = NSImageView()
    private let expiryLabel = NSTextField(labelWithString: "")
    private let devicesStack = NSStackView()
    private var expiryTimer: Timer?
    private var pairingExpiresAt: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(connection: String, notification: String, devices: [Device]) {
        connectionLabel.stringValue = connection
        notificationLabel.stringValue = notification
        renderDevices(devices)
    }

    func showPairing(image: NSImage, expiresAt: Date) {
        qrImageView.image = image
        qrImageView.isHidden = false
        pairingExpiresAt = expiresAt
        pairButton.title = "Refresh Invitation"
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshExpiry() }
        }
        refreshExpiry()
    }

    func clearPairing(message: String? = nil) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        pairingExpiresAt = nil
        qrImageView.image = nil
        qrImageView.isHidden = true
        expiryLabel.stringValue = message ?? ""
        pairButton.title = "Create iPhone Invitation"
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        stack.addArrangedSubview(copy("Connect Array on iPhone to this Mac through the encrypted relay. Paired phones can view safe agent status, answer approvals, and stop agents. They cannot operate terminals or administer Array.", size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(sectionTitle("Relay"))
        stack.addArrangedSubview(connectionLabel)
        stack.addArrangedSubview(notificationLabel)

        stack.addArrangedSubview(sectionTitle("Friends Alpha"))
        inviteField.placeholderString = "One-time alpha invite"
        inviteField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inviteField.translatesAutoresizingMaskIntoConstraints = false
        inviteField.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let redeem = NSButton(title: "Connect This Mac", target: self, action: #selector(redeemInvite))
        let inviteRow = NSStackView(views: [inviteField, redeem])
        inviteRow.orientation = .horizontal
        inviteRow.alignment = .centerY
        inviteRow.spacing = 8
        stack.addArrangedSubview(inviteRow)

        stack.addArrangedSubview(sectionTitle("Pair iPhone"))
        pairButton.target = self
        pairButton.action = #selector(createPairing)
        let cancel = NSButton(title: "Cancel Invitation", target: self, action: #selector(cancelPairing))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let pairingActions = NSStackView(views: [pairButton, cancel, refresh])
        pairingActions.orientation = .horizontal
        pairingActions.spacing = 8
        stack.addArrangedSubview(pairingActions)

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.widthAnchor.constraint(equalToConstant: 220).isActive = true
        qrImageView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        qrImageView.isHidden = true
        stack.addArrangedSubview(qrImageView)
        expiryLabel.textColor = .secondaryLabelColor
        expiryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(expiryLabel)

        stack.addArrangedSubview(sectionTitle("Paired Devices"))
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8
        stack.addArrangedSubview(devicesStack)
        renderDevices([])
    }

    private func renderDevices(_ devices: [Device]) {
        devicesStack.arrangedSubviews.forEach {
            devicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !devices.isEmpty else {
            devicesStack.addArrangedSubview(copy("No iPhones are paired.", size: 11, color: .secondaryLabelColor))
            return
        }
        for device in devices {
            let seen = device.lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "Never connected"
            let detail = copy("\(device.name)\n\(device.capabilitySummary) · Last seen \(seen)", size: 11, color: .labelColor)
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.widthAnchor.constraint(equalToConstant: 390).isActive = true
            let revoke = RevokeButton(deviceID: device.id, target: self, action: #selector(revokeDevice(_:)))
            let row = NSStackView(views: [detail, revoke])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            devicesStack.addArrangedSubview(row)
        }
    }

    private func refreshExpiry() {
        guard let expiresAt = pairingExpiresAt else { return }
        let seconds = max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
        expiryLabel.stringValue = seconds > 0 ? "Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))" : "Invitation expired"
        if seconds == 0 {
            expiryTimer?.invalidate()
            expiryTimer = nil
        }
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        copy(value, size: 12, weight: .semibold, color: .labelColor)
    }

    private func copy(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        return field
    }

    @objc private func redeemInvite() {
        let invite = inviteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invite.isEmpty else { return }
        onRedeemInvite?(invite)
    }

    @objc private func createPairing() { onCreatePairing?() }
    @objc private func cancelPairing() { clearPairing(message: "Invitation cancelled."); onCancelPairing?() }
    @objc private func refresh() { onRefresh?() }
    @objc private func revokeDevice(_ sender: RevokeButton) { onRevoke?(sender.deviceID) }
}

private final class RevokeButton: NSButton {
    let deviceID: UUID

    init(deviceID: UUID, target: AnyObject?, action: Selector?) {
        self.deviceID = deviceID
        super.init(frame: .zero)
        title = "Revoke"
        bezelStyle = .rounded
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
