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
final class ComposerImageAttachmentRailView: NSView, TokenThemed {
    static let itemSize = NSSize(width: 132, height: 72)
    static let railHeight: CGFloat = 108
    static let thumbnailMaxPixelSize = 192

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
        for task in thumbnailTasks.values { task.cancel() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: items.isEmpty ? 0 : Self.railHeight)
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
        items = newItems
        itemsByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        let ids = Set(newItems.map(\.id))
        for (id, task) in thumbnailTasks where !ids.contains(id) {
            task.cancel()
            thumbnailTasks[id] = nil
            thumbnailsByID[id] = nil
        }

        if collectionView.bounds.height <= 0 {
            collectionView.setFrameSize(NSSize(width: max(bounds.width, 1), height: max(bounds.height, Self.railHeight)))
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let documentHeight = max(scrollView.contentView.bounds.height, Self.itemSize.height + CGFloat(Space.xs * 2) + 2)
        if abs(collectionView.frame.height - documentHeight) > 0.5 {
            collectionView.setFrameSize(NSSize(width: max(collectionView.frame.width, bounds.width), height: documentHeight))
        }
        flowLayout.itemSize = Self.itemSize
        flowLayout.minimumInteritemSpacing = CGFloat(Space.s)
        flowLayout.minimumLineSpacing = CGFloat(Space.s)
        flowLayout.sectionInset = NSEdgeInsets(
            top: CGFloat(Space.xs),
            left: CGFloat(Space.xs),
            bottom: CGFloat(Space.xs),
            right: CGFloat(Space.xs)
        )
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Image attachments")
        setAccessibilityHelp("Attached images. Use left and right arrows to navigate, Delete to remove.")

        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = Self.itemSize
        flowLayout.minimumInteritemSpacing = CGFloat(Space.s)
        flowLayout.minimumLineSpacing = CGFloat(Space.s)
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ComposerImageAttachmentRailCollectionItem.self,
            forItemWithIdentifier: ComposerImageAttachmentRailCollectionItem.identifier
        )
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
                onRemove: { [weak self] removed in self?.onRemoveAttachment?(removed) }
            )
            self.startThumbnailIfNeeded(for: item)
            return cell
        }
    }

    private func startThumbnailIfNeeded(for item: ComposerImageAttachmentRailItem) {
        guard item.state == .ready,
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
                    guard let self, self.itemsByID[id]?.attachment.fileURL == fileURL else { return }
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

    func configure(
        with item: ComposerImageAttachmentRailItem,
        thumbnail: ComposerImageThumbnail?,
        theme: TokenTheme,
        onRemove: @escaping (AgentPromptImageAttachment) -> Void
    ) {
        cellView.configure(with: item, thumbnail: thumbnail, theme: theme, onRemove: onRemove)
    }
}

@MainActor
final class ComposerImageAttachmentCellView: NSView {
    private let imageContainer = NSView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "×", target: nil, action: nil)

    private var item: ComposerImageAttachmentRailItem?
    private var onRemove: ((AgentPromptImageAttachment) -> Void)?

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
        onRemove: @escaping (AgentPromptImageAttachment) -> Void
    ) {
        self.item = item
        self.onRemove = onRemove

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

    func applyTokens(theme: TokenTheme) {
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.backgroundColor = AgentSurfaceRole.artifact.color.cgColor(for: theme)
        let lineRole = item?.state.lineRole ?? .decorativeHairline
        layer?.borderColor = lineRole.color.cgColor(for: theme)
        layer?.borderWidth = item?.state == .ready ? 1 : 1.5

        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = CGFloat(AgentTileRadius.artifact) - 2
        imageContainer.layer?.backgroundColor = AgentSurfaceRole.codeSubdued.color.cgColor(for: theme)
        imageContainer.layer?.masksToBounds = true

        filenameLabel.font = .token(.caption)
        filenameLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        detailLabel.font = .token(.caption)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        stateLabel.font = .token(.caption)
        stateLabel.textColor = stateTextColor(theme: theme)
        placeholderLabel.font = .systemFont(ofSize: 22, weight: .semibold)
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
        removeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove image attachment")
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            imageContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.xs)),
            imageContainer.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.xs)),
            imageContainer.widthAnchor.constraint(equalToConstant: 46),
            imageContainer.heightAnchor.constraint(equalToConstant: 46),

            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.xs)),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.xs)),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),

            filenameLabel.leadingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: CGFloat(Space.s)),
            filenameLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -CGFloat(Space.xs)),
            filenameLabel.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.s)),

            detailLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.xs)),
            detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 1),

            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.xs)),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.xs)),
            stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.xs)),
        ])
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
}

extension ComposerImageAttachmentCellView {
    var qaStateLabel: String { stateLabel.stringValue }
    var qaImageScaling: NSImageScaling { imageView.imageScaling }
}
