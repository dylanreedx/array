import AppKit

/// Streams an agent's turn: prose, tool rows and approvals.
final class TranscriptView: NSView {
    /// New rows fade in over 0.18 s; a tool row settles over 0.16 s.
    static let arrival: TimeInterval = 0.18
    static let emphasis: TimeInterval = 0.16

    func append(_ row: TranscriptRow) {
        let view = row.makeView()
        stack.addArrangedSubview(view)
        Motion.fadeIn(view, duration: Self.arrival)
    }

    private let stack = NSStackView()
}
