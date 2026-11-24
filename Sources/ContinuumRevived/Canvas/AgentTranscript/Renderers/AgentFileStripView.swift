import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// The Changes card's row of file previews: one small picture per one-off file
/// (image, pdf, page, a document or source file the operation created), with the
/// file's name under it. One view for the whole strip and one pooled layer
/// stack per picture; no view per file, and nothing measured in `layout()`
/// beyond the aspect ratio the store already knows.
///
/// A picture's lower part fades into the card and blurs slightly, so it reads
/// as the top of something longer. Hovering a picture animates that away, over
/// the transcript's own `emphasis` duration with the same ease-out the sidebar's
/// hover card uses. Clicking opens the file in a tile beside the agent
/// (`AgentRenderAction.openLocalFile`, which the app resolves and places);
/// dragging hands the real file to Mail, Slack or Finder.
@MainActor
final class AgentFileStripView: NSView, NSDraggingSource {
    static func thumbHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(72)) }
    private static func maxWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(240)) }
    private static func minWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(96)) }
    private static func placeholderWidth(_ zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(115)) }
    /// How much of the picture's height the fade and blur cover, from the bottom.
    private static let fadedShare: CGFloat = 0.55
    static let fadeKey = "file-strip-fade"

    private final class Thumb {
        let container = CALayer()
        let picture = CALayer()
        let blur = CALayer()
        let blurMask = CAGradientLayer()
        let fade = CAGradientLayer()
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
        perform: @escaping (AgentRenderAction) -> Void, blockID: AgentNodeID?
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
            thumb.blurMask.startPoint = CGPoint(x: 0.5, y: 1 - Self.fadedShare)
            thumb.blurMask.endPoint = CGPoint(x: 0.5, y: 1)
            thumb.blur.mask = thumb.blurMask
            thumb.fade.startPoint = CGPoint(x: 0.5, y: 1 - Self.fadedShare)
            thumb.fade.endPoint = CGPoint(x: 0.5, y: 1)
            [thumb.picture, thumb.blur, thumb.fade].forEach(thumb.container.addSublayer)
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
            thumb.container.applyCorner(.artifact, zoom: zoom)
            thumb.container.borderWidth = CGFloat(LineWidth.hairline)
            thumb.container.borderColor = tokens.decorativeLine.color.cgColor(for: theme)
            thumb.fade.colors = [surface.copy(alpha: 0) ?? surface, surface.copy(alpha: 0.8) ?? surface]
            thumb.preview = FilePreviewStore.shared.preview(url, kind: kind, dark: dark) { [weak self] in
                self?.previewArrived()
            }
            applyContents(thumb)
        }
        accessibilityNames = files.map { $0.fileURL?.lastPathComponent ?? $0.displayName }
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
        if let preview = thumb.preview {
            thumb.picture.contents = preview.image
            thumb.picture.backgroundColor = nil
            thumb.blur.contents = preview.blurred
            thumb.blur.isHidden = false
            thumb.fade.isHidden = false
        } else {
            // A quiet placeholder while the picture is made: the card's own
            // recessed surface, no spinner.
            thumb.picture.contents = nil
            thumb.picture.backgroundColor = AgentSurfaceRole.codeSubdued.color.cgColor(for: theme)
            thumb.blur.isHidden = true
            thumb.fade.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: layout

    private var gap: CGFloat { CGFloat(zoom.scaled(Space.m)) }
    private var captionTop: CGFloat { Self.thumbHeight(zoom: zoom) + CGFloat(zoom.scaled(Space.s)) / 2 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let height = Self.thumbHeight(zoom: zoom)
        var x: CGFloat = 0
        for thumb in thumbs.prefix(count) {
            let natural = thumb.preview.map { height * $0.aspect } ?? Self.placeholderWidth(zoom)
            let width = min(Self.maxWidth(zoom), max(Self.minWidth(zoom), natural))
            let frame = CGRect(x: x, y: 0, width: min(width, max(1, bounds.width - x)), height: height)
            thumb.frame = frame
            thumb.container.frame = frame
            let local = CGRect(origin: .zero, size: frame.size)
            [thumb.picture, thumb.blur, thumb.fade, thumb.blurMask].forEach { $0.frame = local }
            x += width + gap
        }
        CATransaction.commit()
    }

    // MARK: caption

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.token(.caption, zoom: zoom).pointSize, weight: .regular)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        // NSTextField paints text 2pt inside its frame; so does the card's header.
        let inset: CGFloat = 2
        for thumb in thumbs.prefix(count) {
            guard let name = thumb.file?.fileURL?.lastPathComponent else { continue }
            let h = ceil(font.ascender - font.descender + font.leading)
            let row = AgentDiffSummaryView.fileRowHeight(zoom: zoom)
            (name as NSString).draw(
                in: NSRect(x: thumb.frame.minX, y: captionTop + (row - h) / 2, width: thumb.frame.width + inset, height: h),
                withAttributes: [.font: font, .paragraphStyle: style,
                                 .foregroundColor: tokens.primaryText.color.nsColor(for: theme)])
        }
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

    /// Fade and blur leave the hovered picture; they come back when it is left.
    func setHovered(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        for (i, thumb) in thumbs.prefix(count).enumerated() {
            let target: Float = i == index ? 0 : 1
            for layer in [thumb.blur, thumb.fade] {
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
    func qaFadeOpacity(at index: Int) -> Float { thumbs[index].fade.opacity }
    func qaBlurOpacity(at index: Int) -> Float { thumbs[index].blur.opacity }
    func qaHasFadeAnimation(at index: Int) -> Bool { thumbs[index].fade.animation(forKey: Self.fadeKey) != nil }
}

