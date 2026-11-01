import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

// Plan: .plans/110-agent-characters/README.md, slice 3 (§5)
/// An agent's character: one `CALayer` over its character's shared atlas.
///
/// The cost model is the benchmark winner. Every sprite of a character points its
/// `contents` at the same decoded image and steps through it by animating
/// `contentsRect` with a discrete `CAKeyframeAnimation`, which the render server
/// plays. Array's main thread touches a sprite only when its plan changes: no
/// timer, no `draw(_:)`, no layout and nothing per frame.
///
/// The MODEL `contentsRect` is always the plan's still frame, so a paused sprite,
/// a residency picture, Reduce Motion and every probe that reads the model layer
/// get the right pose with no animation at all.
final class CharacterSpriteLayer: CALayer {
    static let animationKey = "agentCharacter"
    /// Every animation install, across all sprites: a witness counts these.
    nonisolated(unsafe) static var installCount = 0

    private(set) var plan: AgentCharacterPlan?
    private(set) var sprite: AgentCharacterSpriteAtlas?
    private(set) var phase: Double = 0
    /// The plan whose animation is on the layer now; nil when it holds still.
    private(set) var installedPlan: AgentCharacterPlan?
    private var installedFlipped: Bool?
    /// A paused sprite holds its still frame: parked, pictured, scrolled off,
    /// in a hidden or occluded window. The plan is kept to resume with.
    private(set) var isPaused = false

    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        contentsGravity = .resize
        // Crisp at any zoom from a 1 px-per-art-pixel atlas.
        magnificationFilter = .nearest
        minificationFilter = .linear
        isOpaque = false
        needsDisplayOnBoundsChange = false
        // A sprite never animates implicitly; frame moves come from its owner's layout.
        actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(),
                   "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
    }

    /// Show `plan` from `sprite`. Installs an animation only when the plan or the
    /// picture changed, so a re-applied row costs nothing.
    func show(_ plan: AgentCharacterPlan, sprite: AgentCharacterSpriteAtlas, phase: Double, now: Date = Date()) {
        let pictureChanged = sprite !== self.sprite
        self.plan = plan
        self.sprite = sprite
        self.phase = phase
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pictureChanged { contents = sprite.image }
        let still = rect(of: sprite.atlas.frameIndex(of: plan.still))
        if contentsRect != still { contentsRect = still }
        CATransaction.commit()
        reconcile(now: now, force: pictureChanged)
    }

    /// Remove the sprite's picture entirely (characters turned off, row reused for
    /// an agent with none).
    func clear() {
        removeAnimation(forKey: Self.animationKey)
        installedPlan = nil
        plan = nil
        sprite = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = nil
        CATransaction.commit()
    }

    func setPaused(_ paused: Bool, now: Date = Date()) {
        guard paused != isPaused else { return }
        isPaused = paused
        reconcile(now: now, force: false)
    }

    var isAnimating: Bool { animation(forKey: Self.animationKey) != nil }

    private func reconcile(now: Date, force: Bool) {
        guard let plan, let sprite, plan.isAnimated, !isPaused else {
            if installedPlan != nil || animation(forKey: Self.animationKey) != nil {
                removeAnimation(forKey: Self.animationKey)
                installedPlan = nil
            }
            return
        }
        let flipped = contentsAreFlipped()
        guard force || installedPlan != plan || installedFlipped != flipped || !isAnimating else { return }
        add(Self.animation(for: plan, sprite: sprite, phase: phase, now: now, layerTime: convertTime(CACurrentMediaTime(), from: nil),
                           rect: { self.rect(of: $0, flipped: flipped) }),
            forKey: Self.animationKey)
        installedPlan = plan
        installedFlipped = flipped
        Self.installCount += 1
    }

    /// `frame` as this layer's `contentsRect`. The atlas is top-down; a layer's
    /// unit space runs bottom-up unless its contents are flipped.
    func rect(of frame: Int, flipped: Bool? = nil) -> CGRect {
        guard let sprite else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let unit = sprite.atlas.unitRect(of: frame)
        let y = (flipped ?? contentsAreFlipped()) ? unit.y : 1 - unit.y - unit.height
        return CGRect(x: unit.x, y: y, width: unit.width, height: unit.height)
    }

    /// One group per plan: a one-shot clip first, then what follows it, each
    /// child starting at its own time. One add per state change.
    static func animation(for plan: AgentCharacterPlan, sprite: AgentCharacterSpriteAtlas, phase: Double, now: Date,
                          layerTime: CFTimeInterval, rect: (Int) -> CGRect) -> CAAnimation {
        let atlas = sprite.atlas
        var children: [CAAnimation] = []
        var cursor: CFTimeInterval = 0
        var finite = true
        let wall = now.timeIntervalSinceReferenceDate
        func steps(_ frames: [Int], frameDuration: CFTimeInterval, startingAt start: CFTimeInterval,
                   repeating: Bool) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: "contentsRect")
            animation.values = frames.map { NSValue(rect: rect($0)) }
            animation.keyTimes = frames.indices.map { NSNumber(value: Double($0) / Double(frames.count)) }
            animation.calculationMode = .discrete
            animation.duration = frameDuration * Double(frames.count)
            animation.beginTime = start
            if repeating {
                animation.repeatCount = .infinity
                // On the agent's own clock: a recycled cell or a re-added plan lands
                // on the frame it was already showing.
                animation.timeOffset = (wall + start + phase * animation.duration)
                    .truncatingRemainder(dividingBy: animation.duration)
            }
            return animation
        }
        for segment in plan.segments {
            switch segment {
            case let .clip(clip, startedAt, duration):
                let frames = atlas.frameIndices(of: clip)
                let begin = startedAt.timeIntervalSince(now)
                children.append(steps(frames, frameDuration: max(duration / Double(frames.count), 0.05),
                                      startingAt: begin, repeating: false))
                cursor = begin + duration
            case let .loop(loop, slow):
                let duration = (sprite.loopFrameDuration[loop] ?? 0.3) * (slow ? 2 : 1)
                children.append(steps(atlas.frameIndices(of: loop), frameDuration: duration,
                                      startingAt: max(cursor, 0), repeating: true))
                finite = false
            case let .repeating(clip):
                let duration = clip == .asleep ? 0.6 : 0.3
                children.append(steps(atlas.frameIndices(of: clip), frameDuration: duration,
                                      startingAt: max(cursor, 0), repeating: true))
                finite = false
            case .hold:
                // The model value is the held frame; nothing to add.
                break
            }
        }
        let group = CAAnimationGroup()
        group.animations = children
        group.beginTime = layerTime
        if finite {
            group.duration = max(cursor, 0.001)
            group.isRemovedOnCompletion = true
        } else {
            group.duration = .greatestFiniteMagnitude
            group.isRemovedOnCompletion = false
        }
        group.fillMode = .removed
        return group
    }
}
