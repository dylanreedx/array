import AppKit
import ContinuumRevivedAgentUI

/// `Hidden (N)` pinned under the sidebar's list (.plans/87): the shelf heading's
/// own view, and — while open — a `Show all` pill at the trailing edge. Paints
/// nothing itself; the heading and the pill are already on the census.
@MainActor
final class InboxHiddenFooter: NSView {
    static let height: CGFloat = 36
    private let header = AgentInboxShelfHeaderView()
    private let showAll = InboxSettleNudgeButton(frame: .zero)
    var onToggle: (() -> Void)?
    var onShowAll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Hidden sessions")
        setAccessibilityIdentifier("ContinuumAgentInboxHiddenFooter")
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onToggle = { [weak self] in self?.onToggle?() }
        showAll.translatesAutoresizingMaskIntoConstraints = false
        showAll.title = "Show all"
        showAll.font = .systemFont(ofSize: Typography.style(for: .label).size, weight: .medium)
        showAll.target = self
        showAll.action = #selector(showAllPressed)
        showAll.setAccessibilityLabel("Show all")
        showAll.setAccessibilityIdentifier("ContinuumAgentInboxHiddenShowAll")
        showAll.isHidden = true
        addSubview(header)
        addSubview(showAll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
            showAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right - 4),
            showAll.centerYAnchor.constraint(equalTo: centerYAnchor),
            showAll.heightAnchor.constraint(equalToConstant: InboxSettleNudgeButton.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(count: Int, expanded: Bool) {
        header.apply(section: .hidden, count: count, isExpanded: expanded)
        showAll.isHidden = !expanded
        setAccessibilityChildren(expanded ? [header, showAll] : [header])
    }

    @objc private func showAllPressed() { onShowAll?() }

    var titleForQA: String { header.qaTitle }
}
