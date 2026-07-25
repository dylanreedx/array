import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
final class UserInputCardView: NSView, TokenThemed {
    var onSubmit: ((String) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Agent is asking:")
    private let questionLabel = NSTextField(labelWithString: "")
    private let answerField = NSTextField(string: "")
    private let submitButton = NSButton(title: "Submit", target: nil, action: nil)

    /// The same derivation as `ApprovalDockView.attentionAccent`, for the same
    /// reason: an open question puts the tile in `.needsAttention`, so the hue is
    /// read off `StatusChipPresenter` rather than picked. Neither copy chooses a
    /// colour, so this is not a second palette — it is two call sites of the one
    /// mapping.
    private static var attentionAccent: TokenColor {
        StatusChipPresenter.display(for: .needsAttention).accent
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = Radius.card
        applyTokens()

        headerLabel.font = .token(.label)
        headerLabel.textColor = StatusChipNSView.dynamicNSColor(Self.attentionAccent)
        headerLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        questionLabel.font = .token(.body)
        questionLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        questionLabel.lineBreakMode = .byWordWrapping
        questionLabel.maximumNumberOfLines = 3

        answerField.placeholderString = "Type your answer..."
        answerField.font = .token(.body)
        answerField.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        answerField.target = self
        answerField.action = #selector(submitClicked(_:))
        answerField.identifier = NSUserInterfaceItemIdentifier("userInputCard.answerField")

        submitButton.target = self
        submitButton.action = #selector(submitClicked(_:))
        submitButton.bezelStyle = .rounded
        submitButton.controlSize = .small
        submitButton.font = .token(.label)
        submitButton.contentTintColor = StatusChipNSView.dynamicNSColor(Self.attentionAccent)
        submitButton.identifier = NSUserInterfaceItemIdentifier("userInputCard.submit")

        let inputRow = NSStackView(views: [answerField, submitButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = Space.m
        answerField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        submitButton.setContentHuggingPriority(.required, for: .horizontal)

        let layout = NSStackView(views: [headerLabel, questionLabel, inputRow])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = Space.m
        layout.edgeInsets = NSEdgeInsets(Inset.card)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputRow.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -Inset.card.horizontal),
            answerField.heightAnchor.constraint(equalToConstant: Metrics.rowHeight(for: .body))
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A card in the transcript stack, so it takes a CARD fill — `cardMessage`, the
    /// agent's own voice, which is what an agent asking a question is. The accent
    /// does the attention work on the outline and the header, exactly as in
    /// `ApprovalDockView`; a tinted fill would not be a documented pair.
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.cardMessage.color.cgColor(for: theme)
        layer?.borderColor = Self.attentionAccent.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func configure(question: String) {
        questionLabel.stringValue = AgentUserInputRequest.sanitizedQuestion(question)
        answerField.stringValue = ""
        if window?.firstResponder == nil {
            window?.makeFirstResponder(answerField)
        }
    }

    func dismissAnimated() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduced else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.removeFromSuperview() }
        }
    }

    @objc private func submitClicked(_ sender: Any?) {
        let answer = answerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onSubmit?(answer)
    }

    var qaQuestionText: String { questionLabel.stringValue }
    var qaAnswerText: String {
        get { answerField.stringValue }
        set { answerField.stringValue = newValue }
    }
    func qaSubmit(_ answer: String) {
        answerField.stringValue = answer
        submitClicked(submitButton)
    }
}
