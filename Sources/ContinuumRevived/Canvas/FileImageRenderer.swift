import AppKit
import ContinuumRevivedAgentUI

/// One drawing surface regardless of source dimensions. Pixels are decoded by
/// FileImageBackend before installation; resizing and panning only change geometry.
@MainActor
final class FileImageRenderer: NSView, FileTileRenderer {
    var view: NSView { self }
    var focusView: NSView { viewport }
    private(set) var revision: UInt64 = 0
    var scrollOffsets: [CGPoint] { [viewport.pan] }
    var onRevisionChange: (() -> Void)?
    private let viewport: FileImageViewport
    private let status = NSTextField(labelWithString: "")
    private var controls: [NSButton] = []
    private var disposed = false

    init(document: FileImageDocument) {
        viewport = FileImageViewport(document: document)
        super.init(frame: .zero)
        clipsToBounds = true
        for (title, action) in [("Fit", #selector(fit)), (document.isDownsampled ? "Preview Pixels" : "Actual Pixels", #selector(actual)),
                                ("−", #selector(zoomOut)), ("+", #selector(zoomIn))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = NSFont.token(.body)
            button.setAccessibilityLabel(title == "−" ? "Zoom out" : title == "+" ? "Zoom in" : title)
            controls.append(button)
            addSubview(button)
        }
        status.font = NSFont.token(.caption)
        status.lineBreakMode = .byTruncatingTail
        status.stringValue = document.statusText
        status.toolTip = document.statusText
        addSubview(status)
        addSubview(viewport)
        viewport.onChange = { [weak self] in
            guard let self, !self.disposed else { return }
            self.revision &+= 1
            self.onRevisionChange?()
        }
        applyTheme()
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        dirtyRect.intersection(bounds).fill()
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for (index, button) in controls.enumerated() {
            let width: CGFloat = index == 1 ? 100 : index == 0 ? 44 : 30
            let frame = NSRect(x: x, y: bounds.height - 30, width: width, height: 24)
            if button.frame != frame { button.frame = frame }
            x += width + 6
        }
        let viewportFrame = NSRect(x: 0, y: 25, width: bounds.width, height: max(0, bounds.height - 59))
        if viewport.frame != viewportFrame { viewport.frame = viewportFrame }
        let statusFrame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 17)
        if status.frame != statusFrame { status.frame = statusFrame }
    }
    func applyTheme() {
        needsDisplay = true
        status.textColor = TextToken.textSecondary.color.nsColor(in: self)
        viewport.needsDisplay = true
    }
    func setVisible(_ visible: Bool) { isHidden = !visible }
    func dispose() { disposed = true; viewport.releaseDocument(); onRevisionChange = nil }
    @objc private func fit() { viewport.setFit() }
    @objc private func actual() { viewport.setActualPixels() }
    @objc private func zoomIn() { viewport.zoom(by: 1.25) }
    @objc private func zoomOut() { viewport.zoom(by: 0.8) }
    var qaViewport: FileImageViewport { viewport }
}

@MainActor
final class FileImageViewport: NSView {
    private(set) var document: FileImageDocument?
    private(set) var pan = CGPoint.zero
    private(set) var fit = true
    private(set) var scale: CGFloat = 1
    var onChange: (() -> Void)?
    private var dragOrigin: CGPoint?
    private var panOrigin = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    init(document: FileImageDocument) {
        self.document = document
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(document.statusText)
        setAccessibilityHelp("Use Fit or Actual Pixels, plus and minus to zoom, and drag or scroll to pan.")
    }
    required init?(coder: NSCoder) { nil }
    var displayScale: CGFloat {
        guard let image = document?.image else { return 1 }
        if fit { return min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) }
        return scale
    }
    var imageRect: CGRect {
        guard let image = document?.image else { return .zero }
        let size = CGSize(width: CGFloat(image.width) * displayScale, height: CGFloat(image.height) * displayScale)
        return CGRect(x: bounds.midX - size.width / 2 + pan.x, y: bounds.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }
    func setFit() { fit = true; pan = .zero; changed() }
    func setActualPixels() {
        fit = false
        // One decoded image pixel per physical screen pixel, including Retina.
        scale = 1 / max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        pan = .zero; changed()
    }
    func zoom(by factor: CGFloat) {
        scale = min(32, max(1.0 / 64, displayScale * factor))
        fit = false; changed()
    }
    func releaseDocument() { document = nil; onChange = nil; needsDisplay = true }
    private func changed() { needsDisplay = true; onChange?() }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        dirtyRect.intersection(bounds).fill()
        guard let image = document?.image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        let clipped = rect.intersection(bounds).intersection(dirtyRect)
        guard !clipped.isEmpty else { return }
        context.saveGState()
        context.clip(to: clipped)
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
        let side: CGFloat = 12
        let left = Int(floor(clipped.minX / side)), right = Int(ceil(clipped.maxX / side))
        let bottom = Int(floor(clipped.minY / side)), top = Int(ceil(clipped.maxY / side))
        for row in bottom..<top {
            for column in left..<right where (row + column) % 2 == 0 {
                NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).fill()
            }
        }
        context.interpolationQuality = displayScale >= 2 ? .none : .high
        context.draw(image, in: rect)
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragOrigin = convert(event.locationInWindow, from: nil); panOrigin = pan
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: panOrigin.x + point.x - origin.x, y: panOrigin.y + point.y - origin.y)
        changed()
    }
    override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    override func scrollWheel(with event: NSEvent) {
        pan.x -= event.scrollingDeltaX; pan.y += event.scrollingDeltaY; changed()
    }
    override func magnify(with event: NSEvent) { zoom(by: max(0.1, 1 + event.magnification)) }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoom(by: 1.25)
        case "-": zoom(by: 0.8)
        case "0": setFit()
        default: super.keyDown(with: event)
        }
    }
}
