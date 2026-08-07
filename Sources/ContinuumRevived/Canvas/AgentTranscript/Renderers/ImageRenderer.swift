import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

@MainActor
final class AgentImageRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .image

    func makeView() -> NSView { AgentImageGalleryView(mode: .single) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentImageGalleryView, case let .image(payload) = block.payload else { return }
        view.apply(blockID: block.id, images: [payload], context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .image(payload) = block.payload else { return 0 }
        return AgentImageGalleryView.measuredHeight(images: [payload], width: width, context: context, mode: .single)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentImageGalleryView, case let .image(payload) = block.payload else { return }
        view.applyAccessibility(blockID: block.id, images: [payload], context: context)
    }
}

@MainActor
final class AgentImageGalleryRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .imageGallery

    func makeView() -> NSView { AgentImageGalleryView(mode: .gallery) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentImageGalleryView, case let .imageGallery(payload) = block.payload else { return }
        view.apply(blockID: block.id, images: payload.images, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .imageGallery(payload) = block.payload else { return 0 }
        return AgentImageGalleryView.measuredHeight(images: payload.images, width: width, context: context, mode: .gallery)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentImageGalleryView, case let .imageGallery(payload) = block.payload else { return }
        view.applyAccessibility(blockID: block.id, images: payload.images, context: context)
    }
}

@MainActor
final class AgentImageGalleryView: NSView {
    enum Mode { case single, gallery }

    static let horizontalInset = CGFloat(Space.l)
    static let verticalInset = CGFloat(Space.l)
    static let itemGap = CGFloat(Space.m)
    static let titleHeight = CGFloat(Metrics.lineHeight(for: .label))
    static let metadataHeight = CGFloat(Metrics.lineHeight(for: .caption))
    static let captionHeight = CGFloat(Metrics.lineHeight(for: .caption))
    static let minimumImageHeight: CGFloat = 72
    static let maximumSingleImageHeight: CGFloat = 360
    static let maximumGalleryImageHeight: CGFloat = 180

    private let mode: Mode
    private(set) var cells: [AgentImageCellView] = []
    private var blockID: AgentNodeID?
    private var images: [AgentImagePayload] = []
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, images: [AgentImagePayload], context: AgentRenderContext) {
        self.blockID = blockID
        self.images = images
        self.context = context
        rebuildCells()
        identifier = NSUserInterfaceItemIdentifier("agent.imageGallery.\(blockID.rawValue)")
        applyAccessibility(blockID: blockID, images: images, context: context)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(blockID: AgentNodeID, images: [AgentImagePayload], context: AgentRenderContext) {
        let countText = images.count == 1 ? "Image" : "Image gallery, \(images.count) images"
        setAccessibilityLabel(countText)
        setAccessibilityChildren(cells)
    }

    override func layout() {
        super.layout()
        let frames = Self.itemFrames(images: images, width: bounds.width, context: context, mode: mode)
        for (cell, frame) in zip(cells, frames) {
            cell.frame = frame
            cell.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        cells.forEach { $0.applyTokens(theme: theme, context: context) }
    }

    static func measuredHeight(
        images: [AgentImagePayload],
        width: CGFloat,
        context: AgentRenderContext,
        mode: Mode
    ) -> CGFloat {
        guard !images.isEmpty else {
            return verticalInset * 2 + titleHeight
        }
        let frames = itemFrames(images: images, width: width, context: context, mode: mode)
        return max(verticalInset * 2 + titleHeight, (frames.map(\.maxY).max() ?? 0) + verticalInset)
    }

    private func rebuildCells() {
        cells.forEach { $0.removeFromSuperview() }
        guard let blockID else {
            cells = []
            return
        }
        cells = images.enumerated().map { index, image in
            let resolution = context.imageResources.resolve(image.attachment.id)
            let cell = AgentImageCellView(frame: .zero)
            cell.apply(blockID: blockID, index: index, image: image, resolution: resolution, context: context)
            addSubview(cell)
            return cell
        }
    }

    private static func itemFrames(
        images: [AgentImagePayload],
        width: CGFloat,
        context: AgentRenderContext,
        mode: Mode
    ) -> [NSRect] {
        let safeWidth = max(1, width)
        let columns = columnCount(for: safeWidth, imageCount: images.count, mode: mode)
        let contentWidth = max(1, safeWidth - horizontalInset * 2 - CGFloat(max(0, columns - 1)) * itemGap)
        let cellWidth = max(1, floor(contentWidth / CGFloat(columns)))
        let imageHeights = images.map { payload -> CGFloat in
            let resolution = context.imageResources.resolve(payload.attachment.id)
            let ratio = aspectRatio(for: payload, resolution: resolution)
            let raw = cellWidth / max(0.1, ratio)
            let cap = mode == .single ? maximumSingleImageHeight : maximumGalleryImageHeight
            return min(max(minimumImageHeight, ceil(raw)), cap)
        }
        let cellHeights = images.enumerated().map { index, payload -> CGFloat in
            let caption = plainText(payload.caption)
            return titleHeight + metadataHeight + imageHeights[index] + (caption.isEmpty ? 0 : captionHeight + itemGap) + itemGap * 3
        }

        var frames: [NSRect] = []
        var y = verticalInset
        var index = 0
        while index < images.count {
            let rowCount = min(columns, images.count - index)
            let rowHeight = (0..<rowCount).map { cellHeights[index + $0] }.max() ?? 0
            for column in 0..<rowCount {
                let x = horizontalInset + CGFloat(column) * (cellWidth + itemGap)
                frames.append(NSRect(x: x, y: y, width: cellWidth, height: rowHeight))
            }
            y += rowHeight + itemGap
            index += rowCount
        }
        return frames
    }

    private static func columnCount(for width: CGFloat, imageCount: Int, mode: Mode) -> Int {
        guard mode == .gallery, imageCount > 1 else { return 1 }
        if width >= 560 { return min(3, imageCount) }
        if width >= 340 { return min(2, imageCount) }
        return 1
    }

    fileprivate static func aspectRatio(
        for payload: AgentImagePayload,
        resolution: AgentImageResourceResolution
    ) -> CGFloat {
        if case let .available(resource) = resolution {
            if let pixelSize = resource.pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
                return pixelSize.width / pixelSize.height
            }
            if let image = resource.image, image.size.width > 0, image.size.height > 0 {
                return image.size.width / image.size.height
            }
        }
        let width = CGFloat(payload.attachment.pixelWidth ?? 0)
        let height = CGFloat(payload.attachment.pixelHeight ?? 0)
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return width / height
    }

    fileprivate static func plainText(_ runs: [AgentInline]) -> String {
        runs.map(plainText).joined()
    }

    private static func plainText(_ run: AgentInline) -> String {
        switch run {
        case .text(let value), .code(let value): return value
        case .emphasis(let children), .strong(let children): return plainText(children)
        case .link(_, _, let children): return plainText(children)
        case .softBreak, .hardBreak: return "\n"
        }
    }
}

@MainActor
final class AgentImageCellView: NSView {
    private(set) var titleLabel = NSTextField(labelWithString: "")
    private(set) var metadataLabel = NSTextField(labelWithString: "")
    private(set) var imageView = NSImageView(frame: .zero)
    private(set) var stateLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var captionLabel = NSTextField(wrappingLabelWithString: "")

    private var blockID: AgentNodeID?
    private var payload: AgentImagePayload?
    private var resolution: AgentImageResourceResolution = .missing
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        layer?.masksToBounds = true
        layer?.borderWidth = CGFloat(LineWidth.hairline)

        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.font = NSFont.token(.caption)
        metadataLabel.lineBreakMode = .byTruncatingTail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        stateLabel.font = NSFont.token(.caption)
        stateLabel.alignment = .center
        stateLabel.lineBreakMode = .byWordWrapping
        captionLabel.font = NSFont.token(.caption)
        captionLabel.maximumNumberOfLines = 1
        captionLabel.lineBreakMode = .byTruncatingTail

        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(imageView)
        addSubview(stateLabel)
        addSubview(captionLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(
        blockID: AgentNodeID,
        index: Int,
        image: AgentImagePayload,
        resolution: AgentImageResourceResolution,
        context: AgentRenderContext
    ) {
        self.blockID = blockID
        payload = image
        self.resolution = resolution
        self.context = context

        let title = Self.displayName(for: image, resolution: resolution, index: index)
        titleLabel.stringValue = title
        metadataLabel.stringValue = Self.metadataText(for: image.attachment, resolution: resolution)
        captionLabel.stringValue = AgentImageGalleryView.plainText(image.caption)
        captionLabel.isHidden = captionLabel.stringValue.isEmpty

        switch resolution {
        case .available(let resource):
            imageView.image = resource.image
            imageView.isHidden = resource.image == nil
            stateLabel.stringValue = resource.image == nil ? "Image ready" : ""
            stateLabel.isHidden = resource.image != nil
        case .processing:
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = "Processing image…"
            stateLabel.isHidden = false
        case .failed(let reason):
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = reason.map { "Image failed: \($0)" } ?? "Image failed"
            stateLabel.isHidden = false
        case .missing:
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = "Image unavailable on this host"
            stateLabel.isHidden = false
        }

        identifier = NSUserInterfaceItemIdentifier("agent.image.\(image.attachment.id.rawValue)")
        applyAccessibility(title: title)
        applyTokens(theme: context.appearance, context: context)
        needsLayout = true
    }

    func applyTokens(theme: TokenTheme, context: AgentRenderContext) {
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
        layer?.borderColor = context.tokens.decorativeLine.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        metadataLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        stateLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        captionLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
    }

    override func layout() {
        super.layout()
        let inset = CGFloat(Space.m)
        let titleY = inset
        titleLabel.frame = NSRect(x: inset, y: titleY, width: max(1, bounds.width - inset * 2), height: AgentImageGalleryView.titleHeight)
        metadataLabel.frame = NSRect(x: inset, y: titleLabel.frame.maxY + CGFloat(Space.xs), width: max(1, bounds.width - inset * 2), height: AgentImageGalleryView.metadataHeight)
        let captionReserve = captionLabel.isHidden ? 0 : AgentImageGalleryView.captionHeight + CGFloat(Space.m)
        let imageY = metadataLabel.frame.maxY + CGFloat(Space.m)
        let imageHeight = max(1, bounds.height - imageY - inset - captionReserve)
        let imageFrame = NSRect(x: inset, y: imageY, width: max(1, bounds.width - inset * 2), height: imageHeight)
        imageView.frame = imageFrame
        stateLabel.frame = imageFrame.insetBy(dx: CGFloat(Space.s), dy: CGFloat(Space.s))
        if !captionLabel.isHidden {
            captionLabel.frame = NSRect(
                x: inset,
                y: imageFrame.maxY + CGFloat(Space.m),
                width: max(1, bounds.width - inset * 2),
                height: AgentImageGalleryView.captionHeight
            )
        } else {
            captionLabel.frame = .zero
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        actionMenuForQA()
    }

    func actionMenuForQA() -> NSMenu {
        let menu = NSMenu()
        let canCopy = currentResource?.hasLocalResource == true
        let canFile = currentResource?.canRevealOrPreview == true
        addMenuItem("Preview", action: #selector(previewImage(_:)), enabled: canFile, to: menu)
        addMenuItem("Copy Image", action: #selector(copyImage(_:)), enabled: canCopy, to: menu)
        addMenuItem("Save As…", action: #selector(saveImageAs(_:)), enabled: canCopy, to: menu)
        addMenuItem("Reveal in Finder", action: #selector(revealImage(_:)), enabled: canFile, to: menu)
        return menu
    }

    @objc func previewImage(_ sender: Any?) {
        performAction { blockID, attachmentID, resource in
            context.actions.perform(.previewImage(blockID: blockID, attachmentID: attachmentID, resource: resource))
        }
    }

    @objc func copyImage(_ sender: Any?) {
        performAction { blockID, attachmentID, resource in
            context.actions.perform(.copyImage(blockID: blockID, attachmentID: attachmentID, resource: resource))
        }
    }

    @objc func saveImageAs(_ sender: Any?) {
        performAction { blockID, attachmentID, resource in
            context.actions.perform(.saveImageAs(blockID: blockID, attachmentID: attachmentID, resource: resource))
        }
    }

    @objc func revealImage(_ sender: Any?) {
        performAction { blockID, attachmentID, resource in
            context.actions.perform(.revealImage(blockID: blockID, attachmentID: attachmentID, resource: resource))
        }
    }

    private var currentResource: AgentResolvedImageResource? {
        if case let .available(resource) = resolution { return resource }
        return nil
    }

    private func addMenuItem(_ title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func performAction(_ send: (AgentNodeID, AgentImageAttachmentID, AgentResolvedImageResource) -> Void) {
        guard let blockID, let attachmentID = payload?.attachment.id, let resource = currentResource,
              resource.hasLocalResource else { return }
        send(blockID, attachmentID, resource)
    }

    private func applyAccessibility(title: String) {
        let status = Self.statusText(resolution)
        setAccessibilityLabel("Image, \(title), \(status)")
        var children: [NSView] = [titleLabel, metadataLabel]
        if !imageView.isHidden { children.append(imageView) }
        if !stateLabel.isHidden { children.append(stateLabel) }
        if !captionLabel.isHidden { children.append(captionLabel) }
        setAccessibilityChildren(children)
    }

    private static func displayName(
        for payload: AgentImagePayload,
        resolution: AgentImageResourceResolution,
        index: Int
    ) -> String {
        if case let .available(resource) = resolution,
           let name = safeSingleLine(resource.displayName), !name.isEmpty { return name }
        if let name = safeSingleLine(payload.attachment.displayName), !name.isEmpty { return name }
        return "Image \(index + 1)"
    }

    private static func metadataText(
        for metadata: AgentImageAttachmentMetadata,
        resolution: AgentImageResourceResolution
    ) -> String {
        var parts: [String] = []
        if let type = safeSingleLine(metadata.contentType), !type.isEmpty { parts.append(type) }
        if let width = metadata.pixelWidth, let height = metadata.pixelHeight, width > 0, height > 0 {
            parts.append("\(width)×\(height)")
        } else if case let .available(resource) = resolution,
                  let pixelSize = resource.pixelSize,
                  pixelSize.width > 0, pixelSize.height > 0 {
            parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))")
        }
        if let byteCount = metadata.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) }
        parts.append(statusText(resolution))
        return parts.joined(separator: " · ")
    }

    private static func statusText(_ resolution: AgentImageResourceResolution) -> String {
        switch resolution {
        case .available(let resource): return resource.hasLocalResource ? "Available locally" : "Unavailable"
        case .processing: return "Processing"
        case .failed: return "Failed"
        case .missing: return "Missing"
        }
    }

    private static func safeSingleLine(_ value: String?) -> String? {
        value?.split(whereSeparator: { $0.isNewline }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
