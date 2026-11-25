import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// The Changes card's row of file previews: one small picture per one-off file
/// (image, pdf, page, a document or source file the operation created). One
/// view for the whole strip and one pooled layer stack per picture; no view per
/// file, and nothing measured in `layout()` beyond the aspect ratio the store
/// already knows.
///
/// A picture's lower part is a frosted band — the picture's own blurred copy
/// under a tint of the card surface — and the file's name and a quiet line of
/// facts (kind, pixel size, size, folder) sit inside it, so the strip carries
/// no caption row. Hovering a picture animates the band away, over
/// the transcript's own `emphasis` duration with the same ease-out the sidebar's
/// hover card uses. Clicking opens the file in a tile beside the agent
/// (`AgentRenderAction.openLocalFile`, which the app resolves and places);
/// dragging hands the real file to Mail, Slack or Finder.
@MainActor
final class AgentFileStripView: NSView, NSDraggingSource {
    static func thumbHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(80)) }
    private static func maxWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(240)) }
    /// Wide enough that the facts line ("PNG · 1280×800 · 212 KB") fits.
    private static func minWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(128)) }
    private static func placeholderWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(128)) }
    /// One picture's width: its own proportions, clamped; a quiet fixed width
    /// until the picture exists. Shared with the drawn transcript.
    static func thumbWidth(aspect: CGFloat?, zoom: AgentPageZoom) -> CGFloat {
        let natural = aspect.map { thumbHeight(zoom: zoom) * $0 } ?? placeholderWidth(zoom)
        return min(maxWidth(zoom), max(minWidth(zoom), natural))
    }
    /// Gap between pictures.
    static func thumbGap(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }
    /// How opaque the card-surface tint over the band's blur is: enough that the
    /// facts line holds its contrast over a white picture in dark mode and a
    /// black one in light mode.
    static let bandTintAlpha: CGFloat = 0.86
    static let fadeKey = "file-strip-fade"

    // MARK: the band: shared with the drawn transcript

    static func nameFont(zoom: AgentPageZoom) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.token(.label, zoom: zoom).pointSize, weight: .regular)
    }
    static func factsFont(zoom: AgentPageZoom) -> NSFont { NSFont.token(.caption, zoom: zoom) }
    /// Inset of the band's text from the picture's sides and top; the bottom is `Space.s`.
    static func bandPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.s + Space.xs)) }
    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }
    /// The frosted band's height: padding, the name, a 2pt gap, the facts, padding.
    static func bandHeight(zoom: AgentPageZoom) -> CGFloat {
        bandPadding(zoom: zoom) + lineHeight(nameFont(zoom: zoom)) + CGFloat(zoom.scaled(Space.xs))
            + lineHeight(factsFont(zoom: zoom)) + CGFloat(zoom.scaled(Space.s))
    }
    /// The band's top, and the short feather above it where the blur comes in.
    static func band(in rect: CGRect, zoom: AgentPageZoom) -> (band: CGRect, feather: CGFloat) {
        let height = min(rect.height, bandHeight(zoom: zoom))
        return (CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height),
                CGFloat(zoom.scaled(Space.l + Space.xs)))
    }
    /// Baselines of the name and the facts, in the same space as `rect` (y down).
    static func baselines(in rect: CGRect, zoom: AgentPageZoom) -> (name: CGFloat, facts: CGFloat) {
        let band = band(in: rect, zoom: zoom).band
        let name = nameFont(zoom: zoom), facts = factsFont(zoom: zoom)
        let nameBaseline = band.minY + bandPadding(zoom: zoom) + ceil(name.ascender)
        return (nameBaseline, nameBaseline + ceil(-name.descender) + CGFloat(zoom.scaled(Space.xs)) + ceil(facts.ascender))
    }

    /// The helper's orb: a small disc in its identity colour, leading the name
    /// of a file a helper made, centred on the name's capitals.
    static func orbRect(in rect: CGRect, zoom: AgentPageZoom) -> CGRect {
        let side = CGFloat(zoom.scaled(8))
        let centre = baselines(in: rect, zoom: zoom).name - nameFont(zoom: zoom).capHeight / 2
        return CGRect(x: rect.minX + bandPadding(zoom: zoom), y: centre - side / 2, width: side, height: side)
    }
    /// Where the name starts: after the orb when there is one.
    static func nameInset(hasOrb: Bool, zoom: AgentPageZoom) -> CGFloat {
        bandPadding(zoom: zoom) + (hasOrb ? CGFloat(zoom.scaled(8 + Space.xs)) : 0)
    }
    /// The orb's colour: the helper's identity colour, or quiet text when it has none.
    static func orbColor(_ maker: AgentMessageSenderSource.Sender?, tokens: AgentRenderTokens, theme: TokenTheme) -> CGColor {
        maker?.identityColorName.map { ZoneChromeNSView.color(named: $0).cgColor }
            ?? tokens.secondaryText.color.cgColor(for: theme)
    }

    /// What kind of file it is, in words.
    static func kindName(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "Markdown"
        case "jpg", "jpeg": return "JPEG"
        case "webp": return "WebP"
        case "htm", "html": return "HTML"
        case "swift": return "Swift"
        case "ts": return "TypeScript"
        case "js": return "JavaScript"
        case "py": return "Python"
        case "sh": return "Shell"
        default: return ext.isEmpty ? "File" : ext.uppercased()
        }
    }

    /// The facts line: kind, an image's pixel size, the file's size, and its
    /// folder when that still fits `width` in `font`. A file a helper made
    /// leads with the helper's name instead of ending with the folder; the
    /// line is then cut at its end, so the name is what stays.
    static func facts(_ url: URL, picture: FilePreviewPicture?, font: NSFont, width: CGFloat, maker: String? = nil) -> String {
        var parts = [kindName(url)]
        if let size = picture?.pixelSize { parts.append("\(Int(size.width))×\(Int(size.height))") }
        if let bytes = picture?.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        let base = parts.joined(separator: " · ")
        if let maker { return maker + " · " + base }
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard !folder.isEmpty, folder != "/" else { return base }
        let withFolder = base + " · " + folder
        let measured = (withFolder as NSString).size(withAttributes: [.font: font]).width
        return measured <= width ? withFolder : base
    }

    private final class Thumb {
        let container = CALayer()
        let picture = CALayer()
        let blur = CALayer()
        let blurMask = CAGradientLayer()
        let fade = CAGradientLayer()
        let name = CATextLayer()
        let facts = CATextLayer()
        let orb = CALayer()
        var maker: AgentMessageSenderSource.Sender?
        var file: AgentDiffFileSummary?
        var preview: FilePreviewPicture?
        var frame: CGRect = .zero
    }

    private var thumbs: [Thumb] = []
    private var count = 0
    private var tokens: AgentRenderTokens = .transcript
    private var theme: TokenTheme = .dark
    private var zoom: AgentPageZoom = .default
    private var perform: ((AgentRenderAction) -> Void)?
    private var blockID: AgentNodeID?
    private var accessibilityNames: [String] = []
    private(set) var hoveredIndex: Int?
    private var pressed: (index: Int, point: NSPoint)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File previews")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: apply

    func apply(
        files: [AgentDiffFileSummary], tokens: AgentRenderTokens, theme: TokenTheme, zoom: AgentPageZoom,
        perform: @escaping (AgentRenderAction) -> Void, blockID: AgentNodeID?,
        senders: AgentMessageSenderSource = .unavailable
    ) {
        self.tokens = tokens; self.theme = theme; self.zoom = zoom
        self.perform = perform; self.blockID = blockID
        count = files.count
        while thumbs.count < files.count {
            let thumb = Thumb()
            thumb.container.masksToBounds = true
            thumb.picture.contentsGravity = .resizeAspectFill
            thumb.picture.masksToBounds = true
            thumb.blur.contentsGravity = .resizeAspectFill
            thumb.blurMask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
            thumb.blur.mask = thumb.blurMask
            for text in [thumb.name, thumb.facts] {
                text.truncationMode = .middle
                text.contentsScale = window?.backingScaleFactor ?? 2
                text.actions = ["contents": NSNull()]
            }
            thumb.orb.actions = ["backgroundColor": NSNull(), "hidden": NSNull()]
            [thumb.picture, thumb.blur, thumb.fade, thumb.orb, thumb.name, thumb.facts].forEach(thumb.container.addSublayer)
            layer?.addSublayer(thumb.container)
            thumbs.append(thumb)
        }
        let dark = theme == .dark
        let surface = tokens.artifactSurface.color.cgColor(for: theme)
        for (index, thumb) in thumbs.enumerated() {
            thumb.container.isHidden = index >= files.count
            guard index < files.count, let url = files[index].fileURL,
                  let kind = AgentDiffSummaryView.previewKind(files[index]) else { continue }
            thumb.file = files[index]
            thumb.maker = files[index].madeByAgentID.flatMap { senders.current($0) }
            thumb.orb.isHidden = files[index].madeByAgentID == nil
            thumb.orb.backgroundColor = Self.orbColor(thumb.maker, tokens: tokens, theme: theme)
            thumb.container.applyCorner(.artifact, zoom: zoom)
            thumb.container.borderWidth = CGFloat(LineWidth.hairline)
            thumb.container.borderColor = tokens.decorativeLine.color.cgColor(for: theme)
            thumb.fade.colors = [surface.copy(alpha: 0) ?? surface, surface.copy(alpha: Self.bandTintAlpha) ?? surface]
            let nameFont = Self.nameFont(zoom: zoom), factsFont = Self.factsFont(zoom: zoom)
            thumb.name.font = nameFont; thumb.name.fontSize = nameFont.pointSize
            thumb.name.foregroundColor = tokens.primaryText.color.cgColor(for: theme)
            thumb.name.string = url.lastPathComponent
            thumb.facts.font = factsFont; thumb.facts.fontSize = factsFont.pointSize
            thumb.facts.foregroundColor = tokens.secondaryText.color.cgColor(for: theme)
            thumb.preview = FilePreviewStore.shared.preview(url, kind: kind, dark: dark) { [weak self] in
                self?.previewArrived()
            }
            applyContents(thumb)
        }
        accessibilityNames = files.map { file in
            let name = file.fileURL?.lastPathComponent ?? file.displayName
            return file.madeByAgentID.flatMap { senders.current($0)?.name }.map { "\(name), made by \($0)" } ?? name
        }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func previewArrived() {
        guard window != nil || true else { return }
        let dark = theme == .dark
        for thumb in thumbs.prefix(count) {
            guard let file = thumb.file, let url = file.fileURL, let kind = AgentDiffSummaryView.previewKind(file) else { continue }
            thumb.preview = FilePreviewStore.shared.cached(url, kind: kind, dark: dark)
            applyContents(thumb)
        }
        needsLayout = true
    }

    private func applyContents(_ thumb: Thumb) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let url = thumb.file?.fileURL {
            // The picture's natural width, known without laying out.
            let width = max(1, Self.thumbWidth(aspect: thumb.preview?.aspect, zoom: zoom) - Self.bandPadding(zoom: zoom) * 2)
            let maker = thumb.file?.madeByAgentID == nil ? nil : (thumb.maker?.name ?? "Helper")
            thumb.facts.string = Self.facts(url, picture: thumb.preview, font: Self.factsFont(zoom: zoom), width: width, maker: maker)
            thumb.facts.truncationMode = maker == nil ? .middle : .end
        }
        if let preview = thumb.preview {
            thumb.picture.contents = preview.image
            thumb.picture.backgroundColor = nil
            thumb.blur.contents = preview.blurred
            thumb.blur.isHidden = false
        } else {
            // A quiet placeholder while the picture is made: the card's own
            // recessed surface, no spinner.
            thumb.picture.contents = nil
            thumb.picture.backgroundColor = AgentSurfaceRole.codeSubdued.color.cgColor(for: theme)
            thumb.blur.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: layout

    private var gap: CGFloat { CGFloat(zoom.scaled(Space.m)) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let height = Self.thumbHeight(zoom: zoom)
        var x: CGFloat = 0
        for thumb in thumbs.prefix(count) {
            let width = Self.thumbWidth(aspect: thumb.preview?.aspect, zoom: zoom)
            let frame = CGRect(x: x, y: 0, width: min(width, max(1, bounds.width - x)), height: height)
            thumb.frame = frame
            thumb.container.frame = frame
            let local = CGRect(origin: .zero, size: frame.size)
            [thumb.picture, thumb.blur, thumb.fade, thumb.blurMask].forEach { $0.frame = local }
            // The band, in the container's flipped space: blur and tint come in
            // over a short feather and hold to the bottom edge.
            let (band, feather) = Self.band(in: local, zoom: zoom)
            let start = CGPoint(x: 0.5, y: max(0, band.minY - feather) / max(1, local.height))
            let end = CGPoint(x: 0.5, y: band.minY / max(1, local.height))
            for gradient in [thumb.blurMask, thumb.fade] { gradient.startPoint = start; gradient.endPoint = end }
            let padding = Self.bandPadding(zoom: zoom)
            let lines = Self.baselines(in: local, zoom: zoom)
            let nameFont = Self.nameFont(zoom: zoom), factsFont = Self.factsFont(zoom: zoom)
            let nameX = Self.nameInset(hasOrb: !thumb.orb.isHidden, zoom: zoom)
            thumb.name.frame = CGRect(x: nameX, y: lines.name - ceil(nameFont.ascender),
                                      width: max(1, local.width - nameX - padding), height: ceil(nameFont.ascender - nameFont.descender))
            thumb.orb.frame = Self.orbRect(in: local, zoom: zoom)
            thumb.orb.cornerRadius = thumb.orb.frame.height / 2
            thumb.facts.frame = CGRect(x: padding, y: lines.facts - ceil(factsFont.ascender),
                                       width: max(1, local.width - padding * 2), height: ceil(factsFont.ascender - factsFont.descender))
            x += width + gap
        }
        CATransaction.commit()
    }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    func thumbIndex(at point: NSPoint) -> Int? {
        thumbs.prefix(count).firstIndex { $0.frame.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(thumbIndex(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// The band (blur, tint, name and facts) leaves the hovered picture; it comes back when it is left.
    func setHovered(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        for (i, thumb) in thumbs.prefix(count).enumerated() {
            let target: Float = i == index ? 0 : 1
            for layer in [thumb.blur, thumb.fade, thumb.orb, thumb.name, thumb.facts] {
                let from = layer.presentation()?.opacity ?? layer.opacity
                layer.opacity = target
                guard AgentTranscriptMotion.shouldAnimate, from != target else { continue }
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.toValue = target
                animation.duration = AgentTranscriptMotion.emphasis
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: Self.fadeKey)
            }
        }
    }

    override func resetCursorRects() {
        for thumb in thumbs.prefix(count) { addCursorRect(thumb.frame, cursor: .pointingHand) }
    }

    // MARK: click and drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = thumbIndex(at: point).map { ($0, point) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, thumbIndex(at: point) == pressed.index else { return }
        open(pressed.index)
    }

    /// Opens the file in a tile beside this agent's, or reveals the tile already
    /// holding it. The app owns resolution and placement.
    func open(_ index: Int) {
        guard thumbs.indices.contains(index), index < count,
              let path = thumbs[index].file?.fileURL?.path, let blockID else { return }
        perform?(.openLocalFile(blockID: blockID, destination: path))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed, let url = thumbs[start.index].file?.fileURL else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.point.x, point.y - start.point.y) > 4 else { return }
        pressed = nil
        let thumb = thumbs[start.index]
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSImage(cgImage: thumb.preview?.image ?? Self.emptyImage, size: thumb.frame.size)
        item.setDraggingFrame(thumb.frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private static let emptyImage: CGImage = {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    // MARK: accessibility

    /// One button per picture, named for its file; pressing it opens the file.
    override func accessibilityChildren() -> [Any]? {
        thumbs.prefix(count).enumerated().map { index, thumb in
            let element = NSAccessibilityElement.element(
                withRole: .button, frame: .zero, label: "Open \(accessibilityNames.indices.contains(index) ? accessibilityNames[index] : "file")",
                parent: self)
            if let element = element as? NSAccessibilityElement { element.setAccessibilityFrameInParentSpace(thumb.frame) }
            return element
        }
    }

    // MARK: checks

    var qaThumbFrames: [CGRect] { thumbs.prefix(count).map(\.frame) }
    var qaThumbCount: Int { count }
    var qaPlaceholderCount: Int { thumbs.prefix(count).filter { $0.preview == nil }.count }
    /// Each picture's name and facts as the band shows them.
    var qaBandText: [(name: String, facts: String)] {
        thumbs.prefix(count).map { ($0.name.string as? String ?? "", $0.facts.string as? String ?? "") }
    }
    func qaFadeOpacity(at index: Int) -> Float { thumbs[index].fade.opacity }
    func qaBlurOpacity(at index: Int) -> Float { thumbs[index].blur.opacity }
    func qaHasFadeAnimation(at index: Int) -> Bool { thumbs[index].fade.animation(forKey: Self.fadeKey) != nil }
}

