import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class TranscriptCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(card: ManagedTranscriptCard) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        // separatorColor@0.45 rendered at ~1.1:1 on these fills — invisible.
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.backgroundColor = Self.background(for: card.kind).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        // The body IS the content of the tile — it gets primary text, not the
        // secondary grey it had. Metadata sits one step down, but never
        // tertiary (2.25:1 on every card fill, fails AA outright).
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .labelColor
        bodyLabel.isSelectable = true
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, NSView(), statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let stack = NSStackView(views: [header, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        apply(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ card: ManagedTranscriptCard) {
        titleLabel.stringValue = Self.title(for: card)
        bodyLabel.stringValue = card.body.isEmpty ? Self.bodyFallback(for: card) : card.body
        statusLabel.stringValue = Self.statusText(for: card)
        identifier = NSUserInterfaceItemIdentifier("managedAgent.card.\(card.id)")
    }

    private static func title(for card: ManagedTranscriptCard) -> String {
        switch card.kind {
        case .message, .userMessage: return card.title
        case .toolCall: return "tool · \(card.title)"
        case .plan: return "plan · \(card.title)"
        case .diff: return "diff · \(card.title)"
        case .error: return "error · \(card.title)"
        }
    }

    private static func bodyFallback(for card: ManagedTranscriptCard) -> String {
        switch card.kind {
        case .message, .userMessage: return ""
        case .toolCall: return card.itemKind?.rawValue ?? "tool call"
        case .plan: return "Plan is updating"
        case .diff: return "File changes pending"
        case .error: return "Runtime error"
        }
    }

    private static func statusText(for card: ManagedTranscriptCard) -> String {
        guard let status = card.status else { return "" }
        switch status {
        case .inProgress: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        case .declined: return "declined"
        }
    }

    private static func background(for kind: ManagedTranscriptCardKind) -> NSColor {
        switch kind {
        case .message: return NSColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1)
        // Your own messages read as a distinct, slightly blue surface.
        case .userMessage: return NSColor(red: 0.15, green: 0.19, blue: 0.26, alpha: 1)
        case .toolCall: return NSColor(red: 0.12, green: 0.16, blue: 0.18, alpha: 1)
        case .plan: return NSColor(red: 0.15, green: 0.14, blue: 0.18, alpha: 1)
        case .diff: return NSColor(red: 0.12, green: 0.17, blue: 0.14, alpha: 1)
        case .error: return NSColor(red: 0.20, green: 0.11, blue: 0.11, alpha: 1)
        }
    }
}
