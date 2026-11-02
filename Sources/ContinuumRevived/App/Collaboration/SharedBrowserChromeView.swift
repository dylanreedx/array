import AppKit
import ContinuumRevivedAgentUI

/// The top of a teammate's shared browser, drawn as the owner's browser tile
/// draws it (`BrowserTileNSView`): the same row of back, forward and reload,
/// the page icon and the address bar, 6 pt in from the edges and 24 pt tall.
/// Inside a portal there is no tile header around the item, so this also draws
/// one with the page's title. The guest cannot drive the owner's history, so
/// back, forward and reload are shown but off; the address is read only. On
/// the right, what this browser is doing: following the owner, a still, or a
/// page the guest clicked to, with the way back.
@MainActor
final class SharedBrowserChromeView: NSView {
    static let rowHeight: CGFloat = 24
    static let rowInset: CGFloat = 6
    static let spacing: CGFloat = 4

    let showsTitleBar: Bool
    let backButton = NSButton(title: "‹", target: nil, action: nil)
    let forwardButton = NSButton(title: "›", target: nil, action: nil)
    let reloadButton = NSButton(title: "↻", target: nil, action: nil)
    let faviconLabel = NSTextField(labelWithString: "◌")
    let urlField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "")
    let backToHostButton = NSButton(title: "", target: nil, action: nil)
    private(set) var title = ""

    override var isFlipped: Bool { true }

    /// The chrome's height: the row and its margins, and the header in a portal.
    var height: CGFloat { (showsTitleBar ? TileNSView.titleBarHeight : 0) + Self.rowHeight + 2 * Self.spacing }

    init(showsTitleBar: Bool) {
        self.showsTitleBar = showsTitleBar
        super.init(frame: .zero)
        for button in [backButton, forwardButton, reloadButton] {
            button.bezelStyle = .rounded
            button.isEnabled = false
            addSubview(button)
        }
        backButton.toolTip = "Back is the owner's"; forwardButton.toolTip = "Forward is the owner's"; reloadButton.toolTip = "Reload is the owner's"
        faviconLabel.font = .systemFont(ofSize: 13)
        faviconLabel.toolTip = "Page icon"
        urlField.isEditable = false
        urlField.isSelectable = true
        urlField.focusRingType = .none
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.usesSingleLineMode = true
        urlField.setAccessibilityLabel("Address")
        statusLabel.font = .token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        backToHostButton.bezelStyle = .rounded
        backToHostButton.isHidden = true
        for view in [faviconLabel, urlField, statusLabel, backToHostButton] as [NSView] { addSubview(view) }
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(title: String, address: String, hasPage: Bool, status: String, backTitle: String?) {
        if self.title != title { self.title = title; needsDisplay = true }
        if urlField.stringValue != address { urlField.stringValue = address; urlField.toolTip = address }
        faviconLabel.stringValue = hasPage ? "●" : "◌"
        if statusLabel.stringValue != status { statusLabel.stringValue = status }
        backToHostButton.isHidden = backTitle == nil
        if let backTitle, backToHostButton.title != backTitle { backToHostButton.title = backTitle }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = (showsTitleBar ? TileNSView.titleBarHeight : 0) + Self.spacing
        let h = Self.rowHeight
        var x = Self.rowInset
        func place(_ view: NSView, width: CGFloat) {
            view.frame = NSRect(x: x, y: top + (h - min(h, view.fittingSize.height)) / 2, width: width, height: min(h, view.fittingSize.height))
            x += width + Self.spacing
        }
        for button in [backButton, forwardButton, reloadButton] { place(button, width: button.fittingSize.width) }
        place(faviconLabel, width: faviconLabel.fittingSize.width)
        var right = bounds.width - Self.rowInset
        if !backToHostButton.isHidden {
            let width = backToHostButton.fittingSize.width
            backToHostButton.frame = NSRect(x: right - width, y: top + (h - backToHostButton.fittingSize.height) / 2,
                                            width: width, height: backToHostButton.fittingSize.height)
            right -= width + Self.spacing
        }
        let statusWidth = min(statusLabel.fittingSize.width, max(0, (right - x) / 2))
        statusLabel.frame = NSRect(x: right - statusWidth, y: top + (h - statusLabel.fittingSize.height) / 2,
                                   width: statusWidth, height: statusLabel.fittingSize.height)
        right -= statusWidth + Self.spacing
        urlField.frame = NSRect(x: x, y: top + (h - 22) / 2, width: max(0, right - x), height: 22)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        faviconLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        statusLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        urlField.textColor = TextToken.textPrimary.color.nsColor(in: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTitleBar else { return }
        // The tile header as the tile title bar draws it: `tileChrome`, the title,
        // and the separator hairline along its bottom.
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: TileNSView.titleBarHeight)
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill(); bar.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]
        let line = (title.isEmpty ? "Browser" : title) as NSString
        let size = line.size(withAttributes: attributes)
        line.draw(with: NSRect(x: 10, y: (bar.height - size.height) / 2, width: max(0, bar.width - 20), height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: bar.height - 1, width: bar.width, height: 1).fill()
    }
}
