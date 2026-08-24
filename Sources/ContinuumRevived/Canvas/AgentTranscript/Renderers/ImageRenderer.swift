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
    static let cellInset = CGFloat(Space.m)
    static let labelGap = CGFloat(Space.xs)
    static let imageGap = CGFloat(Space.m)
    static let minimumImageHeight: CGFloat = 72
    static let maximumSingleImageHeight: CGFloat = 360
    static let maximumGalleryImageHeight: CGFloat = 180
    static let maximumGalleryViewportHeight: CGFloat = 420
    static let maximumThumbnailPixelEdge: CGFloat = 768

    private let mode: Mode
    private let contentView = LazyImageGalleryContentView(frame: .zero)
    private var blockID: AgentNodeID?
    private var images: [AgentImagePayload] = []
    private var occurrenceKeys: [ImageOccurrenceKey] = []
    private var snapshots: [ImageOccurrenceKey: AgentImageResourceSnapshot] = [:]
    private var observations: [AgentImageAttachmentID: AgentImageResourceObservation] = [:]
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    var qaVisibleCellCount: Int { contentView.qaVisibleCellCount }
    var qaVisibleAttachmentIDs: [AgentImageAttachmentID] { contentView.qaVisibleAttachmentIDs }
    var qaReusePoolCount: Int { contentView.qaReusePoolCount }
    var cells: [AgentImageCellView] { contentView.qaVisibleCells }

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        addSubview(contentView)

        contentView.onVisibleCellsChanged = { [weak self] in
            guard let self else { return }
            if let blockID = self.blockID {
                self.applyAccessibility(blockID: blockID, images: self.images, context: self.context)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    deinit {
        observations.values.forEach { $0.cancel() }
    }

    func apply(blockID: AgentNodeID, images: [AgentImagePayload], context: AgentRenderContext) {
        self.blockID = blockID
        self.images = images
        self.context = context
        occurrenceKeys = Self.occurrenceKeys(for: images)
        snapshots = Self.snapshotMap(images: images, keys: occurrenceKeys, context: context)
        replaceObservations(blockID: blockID, images: images, context: context)
        identifier = NSUserInterfaceItemIdentifier("agent.imageGallery.\(blockID.rawValue)")
        contentView.apply(blockID: blockID, images: images, occurrenceKeys: occurrenceKeys, snapshots: snapshots, context: context)
        applyAccessibility(blockID: blockID, images: images, context: context)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(blockID: AgentNodeID, images: [AgentImagePayload], context: AgentRenderContext) {
        let countText = images.count == 1 ? "Image" : "Image gallery, \(images.count) images"
        setAccessibilityLabel(countText)
        setAccessibilityChildren(contentView.qaAccessibilityChildren)
    }

    override func layout() {
        super.layout()
        let frames = Self.itemFrames(images: images, keys: occurrenceKeys, width: bounds.width, snapshots: snapshots, context: context, mode: mode)
        let contentHeight = Self.contentHeight(for: frames)
        contentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        let viewport = contentView.convert(visibleRect, from: self)
        contentView.applyLayout(frames: frames, viewport: viewport.isEmpty ? contentView.bounds : viewport)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // `.plans/45` T6. An image supplies its own content; a card behind it is
        // one more nested fill for nothing. nil, never .clear (hazard 8).
        layer?.backgroundColor = nil
        contentView.applyTokens(theme: theme, context: context)
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
        let keys = occurrenceKeys(for: images)
        let snapshots = snapshotMap(images: images, keys: keys, context: context)
        let frames = itemFrames(images: images, keys: keys, width: width, snapshots: snapshots, context: context, mode: mode)
        let fullHeight = max(verticalInset * 2 + titleHeight, contentHeight(for: frames))
        return fullHeight
    }

    private func replaceObservations(blockID: AgentNodeID, images: [AgentImagePayload], context: AgentRenderContext) {
        observations.values.forEach { $0.cancel() }
        observations.removeAll(keepingCapacity: true)
        for id in Set(images.map(\.attachment.id)) {
            observations[id] = context.imageResources.observe(id: id) { [weak self] _ in
                guard let self, self.blockID == blockID else { return }
                let snapshot = context.imageResources.snapshot(id)
                for key in self.occurrenceKeys where key.attachmentID == id {
                    self.snapshots[key] = snapshot
                }
                self.contentView.updateSnapshot(snapshot, for: id)
                context.actions.invalidatePresentation(blockID: blockID)
                self.needsLayout = true
            }
        }
    }

    private static func occurrenceKeys(for images: [AgentImagePayload]) -> [ImageOccurrenceKey] {
        var counts: [AgentImageAttachmentID: Int] = [:]
        return images.map { payload in
            let ordinal = counts[payload.attachment.id, default: 0]
            counts[payload.attachment.id] = ordinal + 1
            return ImageOccurrenceKey(attachmentID: payload.attachment.id, ordinal: ordinal)
        }
    }

    private static func snapshotMap(
        images: [AgentImagePayload],
        keys: [ImageOccurrenceKey],
        context: AgentRenderContext
    ) -> [ImageOccurrenceKey: AgentImageResourceSnapshot] {
        var map: [ImageOccurrenceKey: AgentImageResourceSnapshot] = [:]
        for (index, payload) in images.enumerated() where keys.indices.contains(index) {
            map[keys[index]] = context.imageResources.snapshot(payload.attachment.id)
        }
        return map
    }

    private static func contentHeight(for frames: [NSRect]) -> CGFloat {
        (frames.map(\.maxY).max() ?? 0) + verticalInset
    }

    private static func itemFrames(
        images: [AgentImagePayload],
        keys: [ImageOccurrenceKey],
        width: CGFloat,
        snapshots: [ImageOccurrenceKey: AgentImageResourceSnapshot],
        context: AgentRenderContext,
        mode: Mode
    ) -> [NSRect] {
        let safeWidth = max(1, width)
        let columns = columnCount(for: safeWidth, imageCount: images.count, mode: mode)
        let availableWidth = max(1, safeWidth - horizontalInset * 2 - CGFloat(max(0, columns - 1)) * itemGap)
        let cellWidth = max(1, floor(availableWidth / CGFloat(columns)))
        let imageAreaWidth = max(1, cellWidth - cellInset * 2)
        let imageHeights = images.enumerated().map { index, payload -> CGFloat in
            let key = keys.indices.contains(index) ? keys[index] : ImageOccurrenceKey(attachmentID: payload.attachment.id, ordinal: index)
            let snapshot = snapshots[key] ?? context.imageResources.snapshot(payload.attachment.id)
            let ratio = aspectRatio(for: payload, snapshot: snapshot)
            let raw = imageAreaWidth / max(0.1, ratio)
            let cap = mode == .single ? maximumSingleImageHeight : maximumGalleryImageHeight
            return min(max(minimumImageHeight, ceil(raw)), cap)
        }
        let cellHeights = images.enumerated().map { index, payload -> CGFloat in
            let caption = plainText(payload.caption)
            return cellInset
                + titleHeight
                + labelGap
                + metadataHeight
                + imageGap
                + imageHeights[index]
                + (caption.isEmpty ? 0 : imageGap + captionHeight)
                + cellInset
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

    fileprivate static func aspectRatio(for payload: AgentImagePayload, snapshot: AgentImageResourceSnapshot) -> CGFloat {
        if let pixelSize = snapshot.pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            return pixelSize.width / pixelSize.height
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
private final class LazyImageGalleryContentView: NSView {
    private var blockID: AgentNodeID?
    private var images: [AgentImagePayload] = []
    private var occurrenceKeys: [ImageOccurrenceKey] = []
    private var snapshots: [ImageOccurrenceKey: AgentImageResourceSnapshot] = [:]
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var frames: [NSRect] = []
    private var visibleCellsByKey: [ImageOccurrenceKey: AgentImageCellView] = [:]
    private var reusePool: [AgentImageCellView] = []
    private var accessibilityElementsByKey: [ImageOccurrenceKey: AgentImageAccessibilityElement] = [:]

    var onVisibleCellsChanged: (() -> Void)?
    var qaVisibleCellCount: Int { visibleCellsByKey.count }
    var qaVisibleAttachmentIDs: [AgentImageAttachmentID] { occurrenceKeys.compactMap { visibleCellsByKey[$0] == nil ? nil : $0.attachmentID } }
    var qaReusePoolCount: Int { reusePool.count }
    var qaVisibleCells: [AgentImageCellView] { occurrenceKeys.compactMap { visibleCellsByKey[$0] } }
    var qaAccessibilityChildren: [Any] {
        occurrenceKeys.enumerated().map { index, key in
            visibleCellsByKey[key] ?? accessibilityElement(for: key, index: index)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private weak var observedClipView: NSClipView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateObservedClipView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservedClipView()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func apply(
        blockID: AgentNodeID,
        images: [AgentImagePayload],
        occurrenceKeys: [ImageOccurrenceKey],
        snapshots: [ImageOccurrenceKey: AgentImageResourceSnapshot],
        context: AgentRenderContext
    ) {
        self.blockID = blockID
        self.images = images
        self.occurrenceKeys = occurrenceKeys
        self.snapshots = snapshots
        self.context = context
        accessibilityElementsByKey = accessibilityElementsByKey.filter { occurrenceKeys.contains($0.key) }
        recycleCellsNotIn(Set(occurrenceKeys))
        needsLayout = true
    }

    func applyLayout(frames: [NSRect], viewport: NSRect) {
        self.frames = frames
        updateVisibleCells(viewport: viewport)
    }

    func updateSnapshot(_ snapshot: AgentImageResourceSnapshot?, for id: AgentImageAttachmentID) {
        for (index, key) in occurrenceKeys.enumerated() where key.attachmentID == id {
            let nextSnapshot = snapshot ?? fallbackSnapshot(for: id)
            snapshots[key] = nextSnapshot
            accessibilityElementsByKey[key]?.configure(
                label: accessibilityLabel(for: index, key: key, snapshot: nextSnapshot),
                enabled: nextSnapshot.state == .available && nextSnapshot.canPreview,
                performPreview: { [weak self] in self?.performPreview(for: key) ?? false }
            )
            if let cell = visibleCellsByKey[key], images.indices.contains(index), let blockID {
                cell.frame = frames.indices.contains(index) ? frames[index] : cell.frame
                cell.apply(blockID: blockID, index: index, occurrenceKey: key, image: images[index], snapshot: nextSnapshot, context: context)
            }
        }
    }

    func applyTokens(theme: TokenTheme, context: AgentRenderContext) {
        visibleCellsByKey.values.forEach { $0.applyTokens(theme: theme, context: context) }
        reusePool.forEach { $0.applyTokens(theme: theme, context: context) }
    }

    override func layout() {
        super.layout()
        updateVisibleCells(viewport: currentViewport())
    }

    @objc private func clipBoundsDidChange(_ note: Notification) {
        updateVisibleCells(viewport: currentViewport())
    }

    private func updateObservedClipView() {
        let nextClipView = enclosingScrollView?.contentView
        guard observedClipView !== nextClipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = nextClipView
        if let nextClipView {
            nextClipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: nextClipView
            )
        }
    }

    private func updateVisibleCells(viewport: NSRect) {
        guard let blockID else { return }
        let paddedViewport = viewport.insetBy(dx: 0, dy: -AgentImageGalleryView.maximumGalleryImageHeight)
        let visibleIndexes = Set(frames.indices.filter { frames[$0].intersects(paddedViewport) })
        let visibleKeys = Set(visibleIndexes.compactMap { occurrenceKeys.indices.contains($0) ? occurrenceKeys[$0] : nil })
        recycleCellsNotIn(visibleKeys)
        for index in visibleIndexes.sorted() where images.indices.contains(index) && occurrenceKeys.indices.contains(index) {
            let payload = images[index]
            let key = occurrenceKeys[index]
            let cell = visibleCellsByKey[key] ?? dequeueCell(for: key)
            cell.frame = frames[index]
            cell.apply(blockID: blockID, index: index, occurrenceKey: key, image: payload, snapshot: snapshots[key] ?? fallbackSnapshot(for: key.attachmentID), context: context)
        }
        onVisibleCellsChanged?()
    }

    private func dequeueCell(for key: ImageOccurrenceKey) -> AgentImageCellView {
        let cell = reusePool.popLast() ?? AgentImageCellView(frame: .zero)
        visibleCellsByKey[key] = cell
        if cell.superview !== self { addSubview(cell) }
        return cell
    }

    private func recycleCellsNotIn(_ keys: Set<ImageOccurrenceKey>) {
        for (key, cell) in visibleCellsByKey where !keys.contains(key) {
            cell.cancelThumbnailRequest()
            cell.removeFromSuperview()
            visibleCellsByKey.removeValue(forKey: key)
            reusePool.append(cell)
        }
    }

    private func currentViewport() -> NSRect {
        guard let clipView = enclosingScrollView?.contentView, let documentView = clipView.documentView else {
            return visibleRect.isEmpty ? bounds : visibleRect
        }
        return convert(clipView.documentVisibleRect, from: documentView)
    }

    private func accessibilityElement(for key: ImageOccurrenceKey, index: Int) -> AgentImageAccessibilityElement {
        if let element = accessibilityElementsByKey[key] { return element }
        let element = AgentImageAccessibilityElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityParent(self)
        let snapshot = snapshots[key] ?? fallbackSnapshot(for: key.attachmentID)
        element.configure(
            label: accessibilityLabel(for: index, key: key, snapshot: snapshot),
            enabled: snapshot.state == .available && snapshot.canPreview,
            performPreview: { [weak self] in self?.performPreview(for: key) ?? false }
        )
        accessibilityElementsByKey[key] = element
        return element
    }

    private func accessibilityLabel(for index: Int, key: ImageOccurrenceKey, snapshot: AgentImageResourceSnapshot) -> String {
        guard images.indices.contains(index) else { return "Image, Missing" }
        return AgentImageCellView.accessibilityLabelText(for: images[index], snapshot: snapshot, index: index)
    }

    private func performPreview(for key: ImageOccurrenceKey) -> Bool {
        guard let blockID, let snapshot = snapshots[key], snapshot.state == .available, snapshot.canPreview else { return false }
        context.actions.perform(.previewImage(blockID: blockID, attachmentID: key.attachmentID))
        return true
    }

    private func fallbackSnapshot(for id: AgentImageAttachmentID) -> AgentImageResourceSnapshot {
        AgentImageResourceSnapshot(attachmentID: id, state: .missing)
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
    private var snapshot: AgentImageResourceSnapshot = .init(attachmentID: AgentImageAttachmentID(rawValue: "missing")!, state: .missing)
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var thumbnailRequest: AgentImageThumbnailRequest?
    private var requestedThumbnailKey: ThumbnailKey?
    private var thumbnailGeneration: UInt64 = 0

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
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press Return or Space to preview the image")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, index: Int, occurrenceKey: ImageOccurrenceKey, image: AgentImagePayload, snapshot: AgentImageResourceSnapshot, context: AgentRenderContext) {
        if payload?.attachment.id != image.attachment.id || self.snapshot.revision != snapshot.revision {
            cancelThumbnailRequest()
            imageView.image = nil
            requestedThumbnailKey = nil
        }
        self.blockID = blockID
        payload = image
        self.snapshot = snapshot
        self.context = context

        let title = Self.displayName(for: image, snapshot: snapshot, index: index)
        titleLabel.stringValue = title
        metadataLabel.stringValue = Self.metadataText(for: image.attachment, snapshot: snapshot)
        captionLabel.stringValue = AgentImageGalleryView.plainText(image.caption)
        captionLabel.isHidden = captionLabel.stringValue.isEmpty

        switch snapshot.state {
        case .available:
            imageView.isHidden = imageView.image == nil
            stateLabel.stringValue = imageView.image == nil ? "Image ready" : ""
            stateLabel.isHidden = imageView.image != nil
        case .processing:
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = "Processing image…"
            stateLabel.isHidden = false
        case .failed:
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = "Image failed"
            stateLabel.isHidden = false
        case .missing:
            imageView.image = nil
            imageView.isHidden = true
            stateLabel.stringValue = "Image unavailable on this host"
            stateLabel.isHidden = false
        }

        identifier = NSUserInterfaceItemIdentifier("agent.image.\(image.attachment.id.rawValue).\(occurrenceKey.ordinal)")
        applyAccessibility(title: title)
        applyTokens(theme: context.appearance, context: context)
        needsLayout = true
    }

    func cancelThumbnailRequest() {
        thumbnailGeneration &+= 1
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        requestedThumbnailKey = nil
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
        let inset = AgentImageGalleryView.cellInset
        titleLabel.frame = NSRect(x: inset, y: inset, width: max(1, bounds.width - inset * 2), height: AgentImageGalleryView.titleHeight)
        metadataLabel.frame = NSRect(x: inset, y: titleLabel.frame.maxY + AgentImageGalleryView.labelGap, width: max(1, bounds.width - inset * 2), height: AgentImageGalleryView.metadataHeight)
        let captionReserve = captionLabel.isHidden ? 0 : AgentImageGalleryView.captionHeight + AgentImageGalleryView.imageGap
        let imageY = metadataLabel.frame.maxY + AgentImageGalleryView.imageGap
        let imageHeight = max(1, bounds.height - imageY - inset - captionReserve)
        let imageFrame = NSRect(x: inset, y: imageY, width: max(1, bounds.width - inset * 2), height: imageHeight)
        imageView.frame = imageFrame
        stateLabel.frame = imageFrame.insetBy(dx: CGFloat(Space.s), dy: CGFloat(Space.s))
        if !captionLabel.isHidden {
            captionLabel.frame = NSRect(x: inset, y: imageFrame.maxY + AgentImageGalleryView.imageGap, width: max(1, bounds.width - inset * 2), height: AgentImageGalleryView.captionHeight)
        } else {
            captionLabel.frame = .zero
        }
        requestThumbnailIfNeeded()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", " ": previewImage(event)
        default: super.keyDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return super.mouseUp(with: event) }
        previewImage(event)
    }

    override func accessibilityPerformPress() -> Bool { performPreviewForQA() }

    override func menu(for event: NSEvent) -> NSMenu? { actionMenuForQA() }

    func actionMenuForQA() -> NSMenu {
        let menu = NSMenu()
        addMenuItem("Preview", action: #selector(previewImage(_:)), enabled: snapshot.state == .available && snapshot.canPreview, to: menu)
        addMenuItem("Copy Image", action: #selector(copyImage(_:)), enabled: snapshot.state == .available && snapshot.canCopy, to: menu)
        addMenuItem("Save As…", action: #selector(saveImageAs(_:)), enabled: snapshot.state == .available && snapshot.canSave, to: menu)
        addMenuItem("Reveal in Finder", action: #selector(revealImage(_:)), enabled: snapshot.state == .available && snapshot.canReveal, to: menu)
        return menu
    }

    @objc func previewImage(_ sender: Any?) { _ = performPreviewForQA() }
    @objc func copyImage(_ sender: Any?) { performAction { context.actions.perform(.copyImage(blockID: $0, attachmentID: $1)) } }
    @objc func saveImageAs(_ sender: Any?) { performAction { context.actions.perform(.saveImageAs(blockID: $0, attachmentID: $1)) } }
    @objc func revealImage(_ sender: Any?) { performAction { context.actions.perform(.revealImage(blockID: $0, attachmentID: $1)) } }

    private func addMenuItem(_ title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @discardableResult
    func performPreviewForQA() -> Bool {
        guard let blockID, let attachmentID = payload?.attachment.id, snapshot.state == .available, snapshot.canPreview else { return false }
        context.actions.perform(.previewImage(blockID: blockID, attachmentID: attachmentID))
        return true
    }

    private func performAction(_ send: (AgentNodeID, AgentImageAttachmentID) -> Void) {
        guard let blockID, let attachmentID = payload?.attachment.id, snapshot.state == .available else { return }
        send(blockID, attachmentID)
    }

    private func requestThumbnailIfNeeded() {
        guard snapshot.state == .available, let attachmentID = payload?.attachment.id else { return }
        let target = Self.boundedTargetPixelSize(for: imageView.bounds.size, scale: backingScale)
        guard target.width >= 1, target.height >= 1 else { return }
        let key = ThumbnailKey(attachmentID: attachmentID, revision: snapshot.revision, width: Int(target.width), height: Int(target.height), scale: Int((backingScale * 1000).rounded()))
        guard requestedThumbnailKey != key else { return }
        thumbnailGeneration &+= 1
        let generation = thumbnailGeneration
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        requestedThumbnailKey = key
        imageView.image = nil
        imageView.isHidden = true
        stateLabel.stringValue = "Image ready"
        stateLabel.isHidden = false
        var completedBeforeAssignment = false
        let request = context.imageResources.requestThumbnail(id: attachmentID, targetPixelSize: target, revision: snapshot.revision) { [weak self] result in
            completedBeforeAssignment = true
            guard let self, self.thumbnailGeneration == generation, self.requestedThumbnailKey == key else { return }
            self.thumbnailRequest = nil
            switch result {
            case .success(let thumbnail) where thumbnail.attachmentID == attachmentID && thumbnail.revision == self.snapshot.revision:
                self.imageView.image = thumbnail.image
                self.imageView.isHidden = false
                self.stateLabel.stringValue = ""
                self.stateLabel.isHidden = true
                self.applyAccessibility(title: self.titleLabel.stringValue)
            case .success, .failed:
                self.requestedThumbnailKey = nil
                self.imageView.image = nil
                self.imageView.isHidden = true
                self.stateLabel.stringValue = "Image unavailable on this host"
                self.stateLabel.isHidden = false
            }
        }
        if thumbnailGeneration == generation, requestedThumbnailKey == key, !completedBeforeAssignment {
            thumbnailRequest = request
        } else if thumbnailGeneration != generation || requestedThumbnailKey != key {
            request.cancel()
        }
    }

    private var backingScale: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(1, scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard snapshot.state == .available else { return }
        cancelThumbnailRequest()
        imageView.image = nil
        needsLayout = true
    }

    private func applyAccessibility(title: String) {
        let status = Self.statusText(snapshot)
        setAccessibilityLabel("Image, \(title), \(status)")
        var children: [NSView] = [titleLabel, metadataLabel]
        if !imageView.isHidden { children.append(imageView) }
        if !stateLabel.isHidden { children.append(stateLabel) }
        if !captionLabel.isHidden { children.append(captionLabel) }
        setAccessibilityChildren(children)
    }

    fileprivate static func accessibilityLabelText(for payload: AgentImagePayload, snapshot: AgentImageResourceSnapshot, index: Int) -> String {
        "Image, \(displayName(for: payload, snapshot: snapshot, index: index)), \(statusText(snapshot))"
    }

    fileprivate static func displayName(for payload: AgentImagePayload, snapshot: AgentImageResourceSnapshot, index: Int) -> String {
        if let name = safeDisplayLabel(snapshot.displayName), !name.isEmpty { return name }
        if let name = safeDisplayLabel(payload.attachment.displayName), !name.isEmpty { return name }
        return "Image \(index + 1)"
    }

    private static func metadataText(for metadata: AgentImageAttachmentMetadata, snapshot: AgentImageResourceSnapshot) -> String {
        var parts: [String] = []
        if let type = safeContentType(snapshot.contentType ?? metadata.contentType), !type.isEmpty { parts.append(type) }
        if let pixelSize = snapshot.pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))")
        } else if let width = metadata.pixelWidth, let height = metadata.pixelHeight, width > 0, height > 0 {
            parts.append("\(width)×\(height)")
        }
        if let byteCount = snapshot.byteCount ?? metadata.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) }
        parts.append(statusText(snapshot))
        return parts.joined(separator: " · ")
    }

    fileprivate static func statusText(_ snapshot: AgentImageResourceSnapshot) -> String {
        switch snapshot.state {
        case .available: return "Available locally"
        case .processing: return "Processing"
        case .failed: return "Failed"
        case .missing: return "Missing"
        }
    }

    private static func safeDisplayLabel(_ value: String?) -> String? {
        guard let safe = safeSingleLine(value), !safe.isEmpty else { return nil }
        let basename = (safe as NSString).lastPathComponent
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "/" else { return nil }
        let scalars = trimmed.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? UnicodeScalar(0xFFFD)! : scalar
        }
        let filtered = String(String.UnicodeScalarView(scalars))
        return String(filtered.prefix(80))
    }

    private static func safeSingleLine(_ value: String?) -> String? {
        value?.split(whereSeparator: { $0.isNewline }).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeContentType(_ value: String?) -> String? {
        guard let safe = safeSingleLine(value), !safe.isEmpty else { return nil }
        let scalars = safe.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? UnicodeScalar(0xFFFD)! : scalar
        }
        let filtered = String(String.UnicodeScalarView(scalars))
        return String(filtered.prefix(64))
    }

    private static func boundedTargetPixelSize(for size: NSSize, scale: CGFloat) -> NSSize {
        let width = max(1, ceil(size.width * scale))
        let height = max(1, ceil(size.height * scale))
        let edge = max(width, height)
        guard edge > AgentImageGalleryView.maximumThumbnailPixelEdge else { return NSSize(width: width, height: height) }
        let factor = AgentImageGalleryView.maximumThumbnailPixelEdge / edge
        return NSSize(width: max(1, floor(width * factor)), height: max(1, floor(height * factor)))
    }

    private struct ThumbnailKey: Equatable {
        var attachmentID: AgentImageAttachmentID
        var revision: UInt64
        var width: Int
        var height: Int
        var scale: Int
    }
}

struct ImageOccurrenceKey: Hashable {
    var attachmentID: AgentImageAttachmentID
    var ordinal: Int
}

private final class AgentImageAccessibilityElement: NSAccessibilityElement {
    private var performPreviewValue: (() -> Bool)?

    func configure(label: String, enabled: Bool, performPreview: @escaping () -> Bool) {
        setAccessibilityLabel(label)
        setAccessibilityEnabled(enabled)
        performPreviewValue = performPreview
    }

    override func accessibilityPerformPress() -> Bool {
        performPreviewValue?() ?? false
    }
}
