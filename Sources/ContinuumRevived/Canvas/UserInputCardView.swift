import AppKit
import ContinuumRevivedCore

@MainActor
final class UserInputCardView: NSView {
    var onSubmit: ((String) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Agent is asking:")
    private let questionLabel = NSTextField(labelWithString: "")
    private let answerField = NSTextField(string: "")
    private let submitButton = NSButton(title: "Submit", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.32).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .systemOrange
        headerLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        questionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        questionLabel.textColor = .labelColor
        questionLabel.lineBreakMode = .byWordWrapping
        questionLabel.maximumNumberOfLines = 3

        answerField.placeholderString = "Type your answer..."
        answerField.font = .systemFont(ofSize: 12, weight: .regular)
        answerField.target = self
        answerField.action = #selector(submitClicked(_:))
        answerField.identifier = NSUserInterfaceItemIdentifier("userInputCard.answerField")

        submitButton.target = self
        submitButton.action = #selector(submitClicked(_:))
        submitButton.bezelStyle = .rounded
        submitButton.controlSize = .small
        submitButton.font = .systemFont(ofSize: 11, weight: .medium)
        submitButton.contentTintColor = .systemOrange
        submitButton.identifier = NSUserInterfaceItemIdentifier("userInputCard.submit")

        let inputRow = NSStackView(views: [answerField, submitButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        answerField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        submitButton.setContentHuggingPriority(.required, for: .horizontal)

        let layout = NSStackView(views: [headerLabel, questionLabel, inputRow])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 8
        layout.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputRow.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -24),
            answerField.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
