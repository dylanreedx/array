import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

struct ComposerImageAttachmentRailItem: Equatable {
    var attachment: AgentPromptImageAttachment
    var state: ComposerImageAttachmentState
    var statusMessage: String?

    init(
        attachment: AgentPromptImageAttachment,
        state: ComposerImageAttachmentState = .ready,
        statusMessage: String? = nil
    ) {
        self.attachment = attachment
        self.state = state
        self.statusMessage = statusMessage
    }

    var id: String { attachment.metadata.id.rawValue }
}

enum ComposerImageAttachmentState: String, Equatable, Sendable {
    case processing
    case ready
    case unsupported
    case failed

    var title: String {
        switch self {
        case .processing: return "Processing"
        case .ready: return "Ready"
        case .unsupported: return "Unsupported"
        case .failed: return "Failed"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .processing: return "processing"
        case .ready: return "ready"
        case .unsupported: return "unsupported"
        case .failed: return "failed"
        }
    }

    var lineRole: AgentLineRole {
        switch self {
        case .processing, .ready: return .controlBoundary
        case .unsupported, .failed: return .attention
        }
    }
}

@MainActor
final class ComposerImageAttachmentRailView: NSView, TokenThemed, AgentPageZoomScalable {
    static let itemSize = NSSize(width: 132, height: 72)
    static let railHeight: CGFloat = 108
    // Rasterization size, not a layout length: the thumbnail pipeline caches by
    // it, so it stays fixed across page zoom.
    static let thumbnailMaxPixelSize = 192

    /// One cell's box at `zoom`. The un-parameterised `itemSize` stays for
    /// callers that measure at 100%.
    static func itemSize(zoom: AgentPageZoom) -> NSSize {
        NSSize(width: CGFloat(zoom.scaled(132)), height: CGFloat(zoom.scaled(72)))
    }

    /// The rail's reserved height at `zoom`. The un-parameterised `railHeight`
    /// stays for callers that reserve space at 100%.
    static func railHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(108))
    }

    private(set) var pageZoom: AgentPageZoom = .default

    /// This rail's cell box and reserved height at its own zoom.
    var itemSize: NSSize { Self.itemSize(zoom: pageZoom) }
    var railHeight: CGFloat { Self.railHeight(zoom: pageZoom) }

    let scrollView = NSScrollView(frame: .zero)
    let collectionView = ComposerImageAttachmentCollectionView(frame: .zero)

    var onRemoveAttachment: ((AgentPromptImageAttachment) -> Void)?

    private let flowLayout = NSCollectionViewFlowLayout()
    private let thumbnailLoader: any ComposerImageThumbnailLoading
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    private var items: [ComposerImageAttachmentRailItem] = []
    private var itemsByID: [String: ComposerImageAttachmentRailItem] = [:]
    private var thumbnailsByID: [String: ComposerImageThumbnail] = [:]
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var visibleThumbnailIDs = Set<String>()

    init(
        frame frameRect: NSRect,
        thumbnailLoader: any ComposerImageThumbnailLoading = ComposerImageIOThumbnailPipeline()
    ) {
        self.thumbnailLoader = thumbnailLoader
        super.init(frame: frameRect)
        configureViews()
        configureDataSource()
        applyTokens()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, thumbnailLoader: ComposerImageIOThumbnailPipeline())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            for task in thumbnailTasks.values { task.cancel() }
            thumbnailTasks.removeAll()
            visibleThumbnailIDs.removeAll()
            thumbnailsByID.removeAll()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: items.isEmpty ? 0 : railHeight)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === self else { return }
            window.makeFirstResponder(self.collectionView)
        }
        return true
    }

    func setItems(_ newItems: [ComposerImageAttachmentRailItem]) {
        let previousItemsByID = itemsByID
        items = newItems
        itemsByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        let ids = Set(newItems.map(\.id))
        for (id, task) in thumbnailTasks {
            let current = itemsByID[id]
            let previous = previousItemsByID[id]
            if current == nil || current?.state != .ready || current?.attachment.fileURL != previous?.attachment.fileURL {
                task.cancel()
                thumbnailTasks[id] = nil
            }
        }
        for id in Array(thumbnailsByID.keys) {
            let current = itemsByID[id]
            let previous = previousItemsByID[id]
            if current == nil || current?.state != .ready || current?.attachment.fileURL != previous?.attachment.fileURL {
                thumbnailsByID[id] = nil
            }
        }
        visibleThumbnailIDs.formIntersection(ids)

        if collectionView.bounds.height <= 0 {
            collectionView.setFrameSize(NSSize(width: max(bounds.width, 1), height: max(bounds.height, railHeight)))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
        invalidateIntrinsicContentSize()
        isHidden = newItems.isEmpty
        needsLayout = true
    }

    func item(for id: String) -> ComposerImageAttachmentRailItem? { itemsByID[id] }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = NSColor.clear.cgColor
        collectionView.backgroundColors = [.clear]
        for case let item as ComposerImageAttachmentRailCollectionItem in collectionView.visibleItems() {
            item.cellView.applyTokens(theme: theme)
        }
    }

    override var isHidden: Bool {
        didSet {
            guard oldValue != isHidden else { return }
            if isHidden {
                cancelAllThumbnailLeases(removeThumbnails: true)
            } else {
                scheduleVisibleThumbnailSync()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelAllThumbnailLeases(removeThumbnails: true)
        } else {
            scheduleVisibleThumbnailSync()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let documentHeight = max(
            scrollView.contentView.bounds.height,
            itemSize.height + CGFloat(pageZoom.scaled(Space.xs * 2)) + CGFloat(pageZoom.scaled(2))
        )
        if abs(collectionView.frame.height - documentHeight) > 0.5 {
            collectionView.setFrameSize(NSSize(width: max(collectionView.frame.width, bounds.width), height: documentHeight))
        }
        applyFlowLayoutMetrics()
    }

    private func applyFlowLayoutMetrics() {
        flowLayout.itemSize = itemSize
        flowLayout.minimumInteritemSpacing = CGFloat(pageZoom.scaled(Space.s))
        flowLayout.minimumLineSpacing = CGFloat(pageZoom.scaled(Space.s))
        flowLayout.sectionInset = NSEdgeInsets(
            top: CGFloat(pageZoom.scaled(Space.xs)),
            left: CGFloat(pageZoom.scaled(Space.xs)),
            bottom: CGFloat(pageZoom.scaled(Space.xs)),
            right: CGFloat(pageZoom.scaled(Space.xs))
        )
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        applyFlowLayoutMetrics()
        flowLayout.invalidateLayout()
        // Cells already materialized are re-derived here; a cell created after
        // this point is born scaled because `configure` carries the rung.
        for case let item as ComposerImageAttachmentRailCollectionItem in collectionView.visibleItems() {
            item.cellView.applyPageZoom(zoom)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Image attachments")
        setAccessibilityHelp("Attached images. Use left and right arrows to navigate, Delete to remove.")

        flowLayout.scrollDirection = .horizontal
        applyFlowLayoutMetrics()
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ComposerImageAttachmentRailCollectionItem.self,
            forItemWithIdentifier: ComposerImageAttachmentRailCollectionItem.identifier
        )
        collectionView.delegate = self
        collectionView.onRemoveSelected = { [weak self] in self?.removeSelectedAttachment() }
        collectionView.setAccessibilityRole(.list)
        collectionView.setAccessibilityLabel("Image attachment rail")

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self,
                  let item = self.itemsByID[id],
                  let cell = collectionView.makeItem(
                    withIdentifier: ComposerImageAttachmentRailCollectionItem.identifier,
                    for: indexPath
                  ) as? ComposerImageAttachmentRailCollectionItem
            else { return nil }
            cell.configure(
                with: item,
                thumbnail: self.thumbnailsByID[id],
                theme: self.effectiveTokenTheme,
                zoom: self.pageZoom,
                onRemove: { [weak self] removed in self?.onRemoveAttachment?(removed) }
            )
            self.visibleThumbnailIDs.insert(id)
            self.startThumbnailIfNeeded(for: item)
            return cell
        }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        syncVisibleThumbnailLeases()
    }

    private func syncVisibleThumbnailLeases(liveVisibleIDs suppliedVisibleIDs: Set<String>? = nil) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty, !items.isEmpty else {
            cancelAllThumbnailLeases(removeThumbnails: true)
            return
        }
        let liveVisibleIDs = suppliedVisibleIDs ?? Set(collectionView.indexPathsForVisibleItems().compactMap { indexPath -> String? in
            guard items.indices.contains(indexPath.item) else { return nil }
            return items[indexPath.item].id
        })
        guard !liveVisibleIDs.isEmpty else {
            cancelAllThumbnailLeases(removeThumbnails: true)
            return
        }
        for id in visibleThumbnailIDs where !liveVisibleIDs.contains(id) {
            cancelThumbnailLease(for: id, removeThumbnail: true)
        }
        visibleThumbnailIDs = liveVisibleIDs
        for id in liveVisibleIDs {
            guard let item = itemsByID[id] else { continue }
            startThumbnailIfNeeded(for: item)
        }
    }

    private func scheduleVisibleThumbnailSync() {
        DispatchQueue.main.async { [weak self] in
            self?.syncVisibleThumbnailLeases()
        }
    }

    private func startThumbnailIfNeeded(for item: ComposerImageAttachmentRailItem) {
        guard visibleThumbnailIDs.contains(item.id),
              item.state == .ready,
              thumbnailsByID[item.id] == nil,
              thumbnailTasks[item.id] == nil
        else { return }
        let id = item.id
        let fileURL = item.attachment.fileURL
        let loader = thumbnailLoader
        thumbnailTasks[id] = Task { [weak self] in
            do {
                let thumbnail = try await loader.thumbnail(for: fileURL, maxPixelSize: Self.thumbnailMaxPixelSize)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.visibleThumbnailIDs.contains(id),
                          self.itemsByID[id]?.attachment.fileURL == fileURL
                    else { return }
                    self.thumbnailTasks[id] = nil
                    self.thumbnailsByID[id] = thumbnail
                    self.reloadItem(id: id)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.thumbnailTasks[id] = nil }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, var current = self.itemsByID[id] else { return }
                    self.thumbnailTasks[id] = nil
                    current.state = .failed
                    current.statusMessage = "Thumbnail failed"
                    self.replaceItem(current)
                }
            }
        }
    }

    private func cancelThumbnailLease(for id: String, removeThumbnail: Bool) {
        thumbnailTasks[id]?.cancel()
        thumbnailTasks[id] = nil
        visibleThumbnailIDs.remove(id)
        if removeThumbnail { thumbnailsByID[id] = nil }
    }

    private func cancelAllThumbnailLeases(removeThumbnails: Bool) {
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks.removeAll()
        visibleThumbnailIDs.removeAll()
        if removeThumbnails { thumbnailsByID.removeAll() }
    }

    private func reloadItem(id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(id) != nil else { return }
        snapshot.reloadItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func replaceItem(_ item: ComposerImageAttachmentRailItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        itemsByID[item.id] = item
        reloadItem(id: item.id)
    }

    private func removeSelectedAttachment() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              items.indices.contains(indexPath.item)
        else { return }
        onRemoveAttachment?(items[indexPath.item].attachment)
    }
}

extension ComposerImageAttachmentRailView: NSCollectionViewDelegate {
    func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard items.indices.contains(indexPath.item) else { return }
        let railItem = items[indexPath.item]
        visibleThumbnailIDs.insert(railItem.id)
        startThumbnailIfNeeded(for: railItem)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard items.indices.contains(indexPath.item) else { return }
        let id = items[indexPath.item].id
        DispatchQueue.main.async { [weak self, weak collectionView] in
            guard let self else { return }
            let stillVisible = collectionView?.indexPathsForVisibleItems().contains { visibleIndexPath in
                self.items.indices.contains(visibleIndexPath.item) && self.items[visibleIndexPath.item].id == id
            } ?? false
            if !stillVisible {
                self.cancelThumbnailLease(for: id, removeThumbnail: true)
            }
        }
    }
}

@MainActor
final class ComposerImageAttachmentCollectionView: NSCollectionView {
    var onRemoveSelected: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.shift, .control, .option, .command]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: // Left
            moveSelection(by: -1)
        case 124: // Right
            moveSelection(by: 1)
        case 51, 117: // Delete / Forward delete
            onRemoveSelected?()
        default:
            super.keyDown(with: event)
        }
    }

    func moveSelection(by delta: Int) {
        let count = numberOfItems(inSection: 0)
        guard count > 0 else { return }
        let current = selectionIndexPaths.first?.item ?? (delta > 0 ? -1 : count)
        let target = min(max(current + delta, 0), count - 1)
        let indexPath = IndexPath(item: target, section: 0)
        selectionIndexPaths = [indexPath]
        scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
    }
}

@MainActor
final class ComposerImageAttachmentRailCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ComposerImageAttachmentRailCollectionItem")

    var cellView: ComposerImageAttachmentCellView { view as! ComposerImageAttachmentCellView }

    override func loadView() {
        view = ComposerImageAttachmentCellView(frame: NSRect(origin: .zero, size: ComposerImageAttachmentRailView.itemSize))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cellView.prepareForReuseForAttachmentRail()
    }

    func configure(
        with item: ComposerImageAttachmentRailItem,
        thumbnail: ComposerImageThumbnail?,
        theme: TokenTheme,
        zoom: AgentPageZoom = .default,
        onRemove: @escaping (AgentPromptImageAttachment) -> Void
    ) {
        cellView.configure(with: item, thumbnail: thumbnail, theme: theme, zoom: zoom, onRemove: onRemove)
    }
}

@MainActor
final class ComposerImageAttachmentCellView: NSView, AgentPageZoomScalable {
    private let imageContainer = NSView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "×", target: nil, action: nil)

    private var item: ComposerImageAttachmentRailItem?
    private var onRemove: ((AgentPromptImageAttachment) -> Void)?

    private(set) var pageZoom: AgentPageZoom = .default

    // Metrics baked into an activated anchor cannot be re-derived, so every
    // zoom-dependent constant is held.
    private var imageContainerLeadingConstraint: NSLayoutConstraint!
    private var imageContainerTopConstraint: NSLayoutConstraint!
    private var imageContainerWidthConstraint: NSLayoutConstraint!
    private var imageContainerHeightConstraint: NSLayoutConstraint!
    private var removeTrailingConstraint: NSLayoutConstraint!
    private var removeTopConstraint: NSLayoutConstraint!
    private var removeWidthConstraint: NSLayoutConstraint!
    private var removeHeightConstraint: NSLayoutConstraint!
    private var filenameLeadingConstraint: NSLayoutConstraint!
    private var filenameTrailingConstraint: NSLayoutConstraint!
    private var filenameTopConstraint: NSLayoutConstraint!
    private var detailTrailingConstraint: NSLayoutConstraint!
    private var detailTopConstraint: NSLayoutConstraint!
    private var stateLeadingConstraint: NSLayoutConstraint!
    private var stateTrailingConstraint: NSLayoutConstraint!
    private var stateBottomConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        with item: ComposerImageAttachmentRailItem,
        thumbnail: ComposerImageThumbnail?,
        theme: TokenTheme,
        zoom: AgentPageZoom = .default,
        onRemove: @escaping (AgentPromptImageAttachment) -> Void
    ) {
        self.item = item
        self.onRemove = onRemove
        applyPageZoom(zoom)

        let metadata = item.attachment.metadata
        let filename = ComposerImageDisplay.sanitizedFilename(metadata.displayName)
        filenameLabel.stringValue = filename
        detailLabel.stringValue = ComposerImageDisplay.detailLabel(
            contentType: metadata.contentType,
            width: metadata.pixelWidth,
            height: metadata.pixelHeight
        )
        stateLabel.stringValue = item.statusMessage ?? item.state.title
        placeholderLabel.stringValue = placeholderGlyph(for: item.state)
        if let thumbnail, let image = NSImage(data: thumbnail.pngData) {
            imageView.image = image
            placeholderLabel.isHidden = true
        } else {
            imageView.image = nil
            placeholderLabel.isHidden = false
        }
        let accessibility = ComposerImageDisplay.accessibilityLabel(
            filename: metadata.displayName,
            contentType: metadata.contentType,
            width: metadata.pixelWidth,
            height: metadata.pixelHeight,
            state: item.state
        )
        setAccessibilityLabel(accessibility)
        toolTip = accessibility
        applyTokens(theme: theme)
    }

    func prepareForReuseForAttachmentRail() {
        imageView.image = nil
        placeholderLabel.isHidden = false
        item = nil
        onRemove = nil
        toolTip = nil
        setAccessibilityLabel(nil)
    }

    func applyTokens(theme: TokenTheme) {
        wantsLayer = true
        // Every metric here is re-derived from `pageZoom`: a token pass must
        // never put an unscaled value back.
        layer?.cornerRadius = CGFloat(pageZoom.scaled(AgentTileRadius.artifact))
        layer?.backgroundColor = AgentSurfaceRole.artifact.color.cgColor(for: theme)
        let lineRole = item?.state.lineRole ?? .decorativeHairline
        layer?.borderColor = lineRole.color.cgColor(for: theme)
        layer?.borderWidth = item?.state == .ready ? 1 : 1.5

        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = CGFloat(pageZoom.scaled(AgentTileRadius.artifact - 2))
        imageContainer.layer?.backgroundColor = AgentSurfaceRole.codeSubdued.color.cgColor(for: theme)
        imageContainer.layer?.masksToBounds = true

        filenameLabel.font = .token(.caption, zoom: pageZoom)
        filenameLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        detailLabel.font = .token(.caption, zoom: pageZoom)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        stateLabel.font = .token(.caption, zoom: pageZoom)
        stateLabel.textColor = stateTextColor(theme: theme)
        placeholderLabel.font = .systemFont(ofSize: CGFloat(pageZoom.scaled(22)), weight: .semibold)
        placeholderLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        removeButton.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
    }

    private func configureViews() {
        wantsLayer = true
        setAccessibilityRole(.group)

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageContainer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.addSubview(imageView)

        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.addSubview(placeholderLabel)

        filenameLabel.lineBreakMode = .byTruncatingTail
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filenameLabel)

        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateLabel)

        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove image attachment")
        addSubview(removeButton)

        imageContainerLeadingConstraint = imageContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        imageContainerTopConstraint = imageContainer.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        imageContainerWidthConstraint = imageContainer.widthAnchor.constraint(equalToConstant: 0)
        imageContainerHeightConstraint = imageContainer.heightAnchor.constraint(equalToConstant: 0)
        removeTrailingConstraint = removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        removeTopConstraint = removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        removeWidthConstraint = removeButton.widthAnchor.constraint(equalToConstant: 0)
        removeHeightConstraint = removeButton.heightAnchor.constraint(equalToConstant: 0)
        filenameLeadingConstraint = filenameLabel.leadingAnchor.constraint(
            equalTo: imageContainer.trailingAnchor, constant: 0
        )
        filenameTrailingConstraint = filenameLabel.trailingAnchor.constraint(
            equalTo: removeButton.leadingAnchor, constant: 0
        )
        filenameTopConstraint = filenameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        detailTrailingConstraint = detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        detailTopConstraint = detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 0)
        stateLeadingConstraint = stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        stateTrailingConstraint = stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        stateBottomConstraint = stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0)

        NSLayoutConstraint.activate([
            imageContainerLeadingConstraint,
            imageContainerTopConstraint,
            imageContainerWidthConstraint,
            imageContainerHeightConstraint,

            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),

            removeTrailingConstraint,
            removeTopConstraint,
            removeWidthConstraint,
            removeHeightConstraint,

            filenameLeadingConstraint,
            filenameTrailingConstraint,
            filenameTopConstraint,

            detailLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            detailTrailingConstraint,
            detailTopConstraint,

            stateLeadingConstraint,
            stateTrailingConstraint,
            stateBottomConstraint,
        ])

        applyPageZoom(pageZoom)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        removeButton.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        placeholderLabel.font = .systemFont(ofSize: CGFloat(zoom.scaled(22)), weight: .semibold)
        filenameLabel.font = .token(.caption, zoom: zoom)
        detailLabel.font = .token(.caption, zoom: zoom)
        stateLabel.font = .token(.caption, zoom: zoom)
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        imageContainer.layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact - 2))
        imageContainerLeadingConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        imageContainerTopConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        imageContainerWidthConstraint.constant = CGFloat(zoom.scaled(46))
        imageContainerHeightConstraint.constant = CGFloat(zoom.scaled(46))
        removeTrailingConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        removeTopConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        removeWidthConstraint.constant = CGFloat(zoom.scaled(22))
        removeHeightConstraint.constant = CGFloat(zoom.scaled(22))
        filenameLeadingConstraint.constant = CGFloat(zoom.scaled(Space.s))
        filenameTrailingConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        filenameTopConstraint.constant = CGFloat(zoom.scaled(Space.s))
        detailTrailingConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        detailTopConstraint.constant = CGFloat(zoom.scaled(1))
        stateLeadingConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        stateTrailingConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        stateBottomConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let item else { return }
        onRemove?(item.attachment)
    }

    private func placeholderGlyph(for state: ComposerImageAttachmentState) -> String {
        switch state {
        case .processing: return "…"
        case .ready: return "▧"
        case .unsupported: return "?"
        case .failed: return "!"
        }
    }

    private func stateTextColor(theme: TokenTheme) -> NSColor {
        switch item?.state {
        case .unsupported, .failed:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .processing:
            return AccentToken.accentWorking.color.nsColor(for: theme)
        case .ready, nil:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }
}

// MARK: - QA seams

extension ComposerImageAttachmentRailView {
    var qaItemCount: Int { items.count }
    var qaVisibleItemCount: Int { collectionView.visibleItems().count }
    var qaThumbnailCount: Int { thumbnailsByID.count }
    var qaThumbnailTaskCount: Int { thumbnailTasks.count }
    var qaVisibleThumbnailLeaseIDs: Set<String> { visibleThumbnailIDs }
    var qaThumbnailTaskIDs: Set<String> { Set(thumbnailTasks.keys) }
    var qaVisibleStateLabels: [String] {
        collectionView.visibleItems().compactMap { item in
            (item as? ComposerImageAttachmentRailCollectionItem)?.cellView.qaStateLabel
        }
    }
    var qaVisibleAccessibilityLabels: [String] {
        collectionView.visibleItems().compactMap { item in
            (item as? ComposerImageAttachmentRailCollectionItem)?.cellView.accessibilityLabel()
        }
    }
    var qaSelectedItemID: String? {
        guard let path = collectionView.selectionIndexPaths.first, items.indices.contains(path.item) else { return nil }
        return items[path.item].id
    }

    func qaSelectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
    }

    func qaMoveSelection(by delta: Int) {
        collectionView.moveSelection(by: delta)
    }

    func qaRemoveSelectionFromKeyboard() {
        removeSelectedAttachment()
    }

    func qaSyncVisibleThumbnailLeases() {
        syncVisibleThumbnailLeases()
    }

    func qaSyncVisibleThumbnailLeases(liveVisibleIDsForChecks liveVisibleIDs: Set<String>) {
        syncVisibleThumbnailLeases(liveVisibleIDs: liveVisibleIDs)
    }

    func qaCancelVisibleThumbnailLease(id: String) {
        cancelThumbnailLease(for: id, removeThumbnail: true)
    }
}

extension ComposerImageAttachmentCellView {
    var qaStateLabel: String { stateLabel.stringValue }
    var qaImageScaling: NSImageScaling { imageView.imageScaling }
}
