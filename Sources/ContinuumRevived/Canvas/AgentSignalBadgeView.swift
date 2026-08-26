import AppKit
import ContinuumRevivedCore

@MainActor
final class AgentSignalBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var signal: AgentSignal?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyDown
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 7, y: 4, width: 14, height: 14)
        label.frame = NSRect(x: 25, y: 3, width: max(0, bounds.width - 31), height: 16)
    }

    func apply(_ signal: AgentSignal?) {
        self.signal = signal
        guard let signal else {
            isHidden = true
            setAccessibilityLabel(nil)
            return
        }
        isHidden = false
        label.stringValue = signal.kind.displayName
        icon.image = NSImage(systemSymbolName: signal.kind.symbolName, accessibilityDescription: signal.kind.displayName)
        let color = Self.color(for: signal.kind)
        label.textColor = color
        icon.contentTintColor = color
        layer?.borderColor = color.withAlphaComponent(0.72).cgColor
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel("Agent status: \(signal.kind.displayName)")
    }

    static func color(for kind: AgentSignalKind) -> NSColor {
        switch kind {
        case .actionRequired: return .systemOrange
        case .failed: return .systemRed
        case .completed: return .systemGreen
        case .gitPushSucceeded: return .systemBlue
        case .gitMergeSucceeded: return .systemPurple
        }
    }
}

@MainActor
final class AgentSignalBorderView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ signal: AgentSignal?) {
        guard let signal else { isHidden = true; return }
        let color = AgentSignalBadgeView.color(for: signal.kind)
        layer?.borderColor = color.withAlphaComponent(0.86).cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
        layer?.shadowRadius = 7
        layer?.shadowOffset = .zero
        isHidden = false
    }
}
