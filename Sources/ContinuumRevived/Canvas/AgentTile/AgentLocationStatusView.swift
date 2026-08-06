import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Two quiet, host-local rows beneath the managed-agent header: collapsed
/// Home/Where and observed What. Externality owns a fixed marker lane, so an
/// elided path can never erase the fact that it is outside Home.
@MainActor
final class AgentLocationStatusView: NSView, TokenThemed {
    static var preferredHeight: CGFloat {
        CGFloat(Metrics.rowHeight(
            for: [.label, .label],
            insets: Inset.row,
            spacing: Space.xs))
    }

    private static let markerWidth = CGFloat(Metrics.lineHeight(for: .label))

    private let whereMarker = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let whatMarker = NSTextField(labelWithString: "")
    private let whatLabel = NSTextField(labelWithString: "")
    private var presentation: AgentLocationStatusPresentation?

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: presentation == nil ? 0 : Self.preferredHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        configureMarker(whereMarker)
        configureMarker(whatMarker)
        configureContentLabel(locationLabel, accessibilityLabel: "Home and Where")
        configureContentLabel(whatLabel, accessibilityLabel: "Observed activity")

        let locationRow = makeRow(marker: whereMarker, label: locationLabel)
        let whatRow = makeRow(marker: whatMarker, label: whatLabel)
        let rows = NSStackView(views: [locationRow, whatRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = CGFloat(Space.xs)
        rows.edgeInsets = NSEdgeInsets(Inset.row)
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            locationRow.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -Inset.row.horizontal),
            whatRow.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -Inset.row.horizontal),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent location and observed activity")
        setAccessibilityChildren([locationLabel, whatLabel])
        isHidden = true
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ next: AgentLocationStatusPresentation) {
        presentation = next
        isHidden = false
        locationLabel.stringValue = next.locationText
        whatLabel.stringValue = next.whatText
        whereMarker.stringValue = next.whereIsExternal ? "↗" : ""
        whatMarker.stringValue = next.whatIsExternal ? "↗" : ""
        // NSTextField exposes its visible string as AXValue. Put the complete,
        // relation-aware sentence in AXLabel so VoiceOver receives the semantic
        // fact instead of merely repeating an elided visual cell.
        locationLabel.setAccessibilityLabel(next.locationAccessibilityValue)
        whatLabel.setAccessibilityLabel(next.whatAccessibilityValue)
        locationLabel.toolTip = next.detailText
        whatLabel.toolTip = next.detailText
        toolTip = next.detailText
        invalidateIntrinsicContentSize()
        applyTokens()
    }

    func clear() {
        presentation = nil
        isHidden = true
        locationLabel.stringValue = ""
        whatLabel.stringValue = ""
        whereMarker.stringValue = ""
        whatMarker.stringValue = ""
        locationLabel.toolTip = nil
        whatLabel.toolTip = nil
        toolTip = nil
        invalidateIntrinsicContentSize()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: theme)
        locationLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        whatLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        let markerColor = TextToken.textPrimary.color.nsColor(for: theme)
        whereMarker.textColor = markerColor
        whatMarker.textColor = markerColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureMarker(_ label: NSTextField) {
        label.font = .token(.label)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.markerWidth).isActive = true
    }

    private func configureContentLabel(
        _ label: NSTextField,
        accessibilityLabel: String
    ) {
        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityLabel(accessibilityLabel)
    }

    private func makeRow(marker: NSTextField, label: NSTextField) -> NSStackView {
        let row = NSStackView(views: [marker, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(Space.s)
        return row
    }

    var qaLocationText: String { locationLabel.stringValue }
    var qaWhatText: String { whatLabel.stringValue }
    var qaLocationDetail: String { presentation?.detailText ?? "" }
    var qaWhereOutboundMarkerVisible: Bool { whereMarker.stringValue == "↗" }
    var qaWhatOutboundMarkerVisible: Bool { whatMarker.stringValue == "↗" }
    var qaLocationAccessibilityValue: String {
        locationLabel.accessibilityLabel() ?? ""
    }
    var qaWhatAccessibilityValue: String {
        whatLabel.accessibilityLabel() ?? ""
    }
    var qaAccessibilityLabels: [String] {
        (accessibilityChildren() ?? []).compactMap { child in
            (child as? NSView)?.accessibilityLabel()
        }
    }
    var qaMarkerLanesDoNotOverlapText: Bool {
        guard let whereMarkerFrame = frame(of: whereMarker),
              let locationFrame = frame(of: locationLabel),
              let whatMarkerFrame = frame(of: whatMarker),
              let whatFrame = frame(of: whatLabel) else { return false }
        return whereMarkerFrame.maxX <= locationFrame.minX
            && whatMarkerFrame.maxX <= whatFrame.minX
    }
    var qaContentFitsBounds: Bool {
        [whereMarker, locationLabel, whatMarker, whatLabel]
            .compactMap(frame(of:))
            .allSatisfy { bounds.contains($0) }
    }
    var qaCompactTextFitsWithoutTruncation: Bool {
        [locationLabel, whatLabel].allSatisfy { label in
            guard let frame = frame(of: label), let font = label.font else { return false }
            let needed = (label.stringValue as NSString)
                .size(withAttributes: [.font: font]).width + CGFloat(Metrics.cellTextInset)
            return needed <= frame.width
        }
    }

    private func frame(of view: NSView) -> NSRect? {
        view.superview.map { $0.convert(view.frame, to: self) }
    }
}
