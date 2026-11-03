import AppKit
import ContinuumRevivedCollaborationProtocol

/// What the browser tile's chrome paints, in one place, so a teammate's shared
/// browser (`SharedBrowserChromeView`) paints exactly what the owner's tile does.
@MainActor
enum BrowserChromeStyle {
    /// The chrome behind the tab and address rows, in both appearances. A
    /// literal, as the owner's tile has always drawn it; not yet a token.
    static let background = NSColor(white: 0.10, alpha: 1.0)
    static let rowInset: CGFloat = 6
    static let rowSpacing: CGFloat = 4
    static let rowHeight: CGFloat = 24

    /// The error line under the address row. Hidden, it still takes its height
    /// in the owner's layout, so the guest measures the same label to place the
    /// page where the owner's tile does.
    static func makeErrorBanner() -> NSTextField {
        let banner = NSTextField(labelWithString: "")
        banner.font = .systemFont(ofSize: 11)
        banner.textColor = .systemRed
        banner.maximumNumberOfLines = 2
        banner.lineBreakMode = .byTruncatingTail
        banner.isHidden = true
        return banner
    }

    /// Where the page starts under the owner's chrome: the tab row, the address
    /// row, the find row (closed, so 0 tall), the hidden error line, and the
    /// gaps `BrowserTileNSView` lays between them.
    static let pageTop: CGFloat = {
        let banner = makeErrorBanner().intrinsicContentSize.height
        return rowSpacing + rowHeight + rowSpacing + rowHeight + rowSpacing + 0 + 2 + max(0, banner) + 4
    }()
}

/// One tab in the strip. Read only, it looks the same and does nothing.
final class BrowserTabButton: NSButton {
    var isInert = false
    override func mouseDown(with event: NSEvent) { if !isInert { super.mouseDown(with: event) } }
    override var acceptsFirstResponder: Bool { isInert ? false : super.acceptsFirstResponder }
}

/// The browser tile's row of tabs. The owner's tile drives it (switch, new,
/// close). A teammate's shared browser shows the owner's row read only: the
/// same tabs, no "+" or "×", and tabs that do not switch.
@MainActor
final class BrowserTabStripView: NSStackView {
    let isReadOnly: Bool
    let newTabButton = NSButton(title: "+", target: nil, action: nil)
    let closeTabButton = NSButton(title: "×", target: nil, action: nil)
    /// Where a tab click goes (the owner's tile); the button's tag is its index.
    weak var tabTarget: AnyObject?
    var tabAction: Selector?
    private(set) var tabButtons: [BrowserTabButton] = []
    private var rendered: [String]?
    /// Read only, the tabs keep their own width; this takes the rest of the row.
    private let filler = NSView()

    init(readOnly: Bool) {
        isReadOnly = readOnly
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = BrowserChromeStyle.rowSpacing
        alignment = .centerY
        distribution = .fill
        newTabButton.bezelStyle = .rounded
        closeTabButton.bezelStyle = .rounded
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        filler.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What a tab is called in the strip: its title, else its page's host.
    static func label(title: String, url: String) -> String {
        let label = title.isEmpty ? (URL(string: url)?.host ?? url) : title
        return label.isEmpty ? "Browser" : label
    }

    /// The same label as it may leave the owner's Mac: a title, or a host the
    /// shared address would show anyway (`LiveTile.shareable`). A tab whose
    /// label would be its raw address (a file, data or about page) is "Browser".
    static func sharedLabel(title: String, url: String) -> String {
        if !title.isEmpty { return title }
        let shared = Collaboration.LiveTile.shareable(url).url
        if let host = shared.flatMap({ URLComponents(string: $0)?.host }), !host.isEmpty { return host }
        return "Browser"
    }

    func render(labels: [String], active: Int?) {
        let signature = labels.enumerated().map { "\($0.offset == active ? "*" : "")\($0.element)" }
        guard signature != rendered else { return }
        rendered = signature
        setViews([], in: .leading)
        tabButtons = labels.enumerated().map { index, label in
            let button = BrowserTabButton(title: label, target: isReadOnly ? nil : tabTarget, action: isReadOnly ? nil : tabAction)
            button.tag = index
            button.isInert = isReadOnly
            button.bezelStyle = index == active ? .regularSquare : .texturedRounded
            addArrangedSubview(button)
            return button
        }
        if isReadOnly {
            addArrangedSubview(filler)
        } else {
            addArrangedSubview(newTabButton)
            addArrangedSubview(closeTabButton)
        }
    }

    var qaLabels: [String] { tabButtons.map(\.title) }
    var qaActive: Int? { tabButtons.firstIndex { $0.bezelStyle == .regularSquare } }
}
