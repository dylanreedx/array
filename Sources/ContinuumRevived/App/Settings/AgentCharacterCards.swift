import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

/// What one card draws: a set's lead and first helpers. Built off the main thread
/// and kept instead of the frames it came from.
final class AgentCharacterCardArt: @unchecked Sendable {
    struct Cell {
        let picture: AgentCharacterSpriteAtlas
        let size: NSSize
        let plan: AgentCharacterPlan
    }

    /// One loop per helper. `scripts/make-character-pack-cards.py` keeps the first
    /// `leadHelpers` of these whole in a pack's card.
    static let loops: [AgentCharacterLoop] = [.type, .read, .think]
    /// How many helpers fit beside a lead on a card.
    static let leadHelpers = 2

    let cells: [Cell]

    init?(theme: AgentCharacterTheme, appearance: AgentCharacterAtlas.Appearance) {
        func plan(_ loop: AgentCharacterLoop) -> AgentCharacterPlan {
            .init(segments: [.loop(loop, slow: false)], still: .loop(loop), revisitAt: nil)
        }
        func size(_ set: AgentCharacterTheme) -> NSSize {
            let points = AgentCharacterPreviewGridView.pointsPerPixel
            return NSSize(width: CGFloat(set.frameWidth / set.scale) * points, height: CGFloat(set.frameHeight / set.scale) * points)
        }
        var cells: [Cell] = []
        if let lead = theme.leadSet,
           let picture = AgentCharacterSpriteAtlas(theme: lead, character: 0, appearance: appearance) {
            cells.append(Cell(picture: picture, size: size(lead), plan: plan(.run)))
        }
        let helpers = min(cells.isEmpty ? Self.loops.count : Self.leadHelpers, theme.characters.count)
        for character in 0..<helpers {
            guard let picture = AgentCharacterSpriteAtlas(theme: theme, character: character, appearance: appearance) else { continue }
            cells.append(Cell(picture: picture, size: size(theme), plan: plan(Self.loops[character])))
        }
        guard !cells.isEmpty else { return nil }
        self.cells = cells
    }
}

/// Moves a Settings preview's sprites only while they can be seen: in a window on
/// the active space, not fully covered, and scrolled into view. Otherwise they
/// hold their still frame. One comparison per scroll tick; nothing per frame.
@MainActor
final class CharacterPreviewMotion {
    private weak var view: NSView?
    private let sprites: () -> [CharacterSpriteLayer]
    private let changed: () -> Void
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(view: NSView, sprites: @escaping () -> [CharacterSpriteLayer], changed: @escaping () -> Void) {
        self.view = view
        self.sprites = sprites
        self.changed = changed
    }

    /// The view entered or left a window: follow that window's scroll view.
    func windowChanged() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let view, let window = view.window else { return update() }
        let center = NotificationCenter.default
        let revisit: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: revisit))
        }
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: revisit))
        observers.append(center.addObserver(forName: AgentCharacterController.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.changed() }
        })
        update()
    }

    func update() {
        let controller = AgentCharacterController.shared
        var visible = false
        if let view, let window = view.window {
            visible = !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty && controller.windowIsVisible(window)
        }
        for sprite in sprites() { sprite.setPaused(!visible) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// A card's sprites, left to right, bottom-aligned. At most a lead and three
/// helpers: a fixed number of layers, however large the set.
final class AgentCharacterCardArtView: NSView {
    private(set) var sprites: [CharacterSpriteLayer] = []
    private(set) var art: AgentCharacterCardArt?
    private lazy var motion = CharacterPreviewMotion(view: self, sprites: { [unowned self] in sprites }, changed: { [unowned self] in apply() })

    override var isFlipped: Bool { true }

    func show(_ art: AgentCharacterCardArt?) {
        guard art !== self.art else { return }
        self.art = art
        sprites.forEach { $0.removeFromSuperlayer() }
        sprites = (art?.cells ?? []).map { _ in
            let sprite = CharacterSpriteLayer()
            sprite.hostIsFlipped = isFlipped
            return sprite
        }
        wantsLayer = true
        sprites.forEach { layer?.addSublayer($0) }
        needsLayout = true
        apply()
    }

    private func apply() {
        guard let art else { return }
        let moving = AgentCharacterController.shared.allowsMotion
        for (index, (sprite, cell)) in zip(sprites, art.cells).enumerated() {
            sprite.show(moving ? cell.plan : .still(cell.plan.still), sprite: cell.picture, phase: Double(index) / 4)
        }
        motion.update()
    }

    override func layout() {
        super.layout()
        guard let art else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bottom = art.cells.map(\.size.height).max() ?? 0
        var x: CGFloat = 0
        for (sprite, cell) in zip(sprites, art.cells) {
            let rect = NSRect(x: x, y: bottom - cell.size.height, width: cell.size.width, height: cell.size.height)
            if sprite.frame != rect { sprite.frame = rect }
            x += cell.size.width + AgentCharacterPreviewGridView.gap
        }
        CATransaction.commit()
        motion.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motion.windowChanged()
    }
}

/// A card's sprites in SwiftUI, at the card's width and one lead tall.
struct CharacterCardArt: NSViewRepresentable {
    let art: AgentCharacterCardArt?
    let identifier: String

    func makeNSView(context: Context) -> AgentCharacterCardArtView {
        let view = AgentCharacterCardArtView()
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: AgentCharacterCardArtView, context: Context) { view.show(art) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentCharacterCardArtView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 56)
    }
}
