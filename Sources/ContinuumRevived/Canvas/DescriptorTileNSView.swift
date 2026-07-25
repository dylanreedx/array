import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view used when no live runtime is attached: a placeholder labeled with
/// the tile kind. Useful for descriptor-only tiles in Phase 3.
///
/// P1.11 retired the eleven per-`TileKind` fill literals. The packet asked to
/// "keep the eleven descriptor fills semantically distinct but derive them from
/// the token set", and the second half cannot be had with the first: the palette
/// declares eleven surfaces, but only `tileBody`/`tileChrome` are legal as a tile
/// body, and mapping tile kinds onto `canvas` or the six transcript-card tints
/// would paint a tile in a colour whose documented pairs it does not honour.
///
/// So the distinction moved off the fill and onto TYPE, which is where it was
/// already carried and where it is legible: the inherited title bar draws
/// `kind.displayName · title`, and the body label draws the title. The evidence
/// that this loses nothing is measured, not asserted by taste — the eleven
/// literals were mutually indistinguishable. The WIDEST pairwise WCAG ratio among
/// them is 1.13:1 and 46 of the 55 pairs are under 1.10:1, so nobody could ever
/// have named a tile's kind from its fill; and all eleven had a relative luminance
/// under 0.2, so under Aqua they were the shipped black-on-dark bug eleven times
/// over. Every one of those numbers, all eleven kinds' token fills in both
/// appearances, and the distinctness of the `displayName`s the distinction moved
/// ONTO are asserted by `UIProbeAppearance.runDescriptorTileFillCheck` — so this
/// reasoning cannot rot away from the code, and a future palette that grows a
/// family of legal tile-body tints has the numbers it has to beat.
@MainActor
final class DescriptorTileNSView: TileNSView {
    private let bodyLabel: NSTextField
    private let body: NSView

    override init(tile: Tile) {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        self.body = container

        let label = NSTextField(labelWithString: tile.title)
        label.font = NSFont.token(.body)
        label.translatesAutoresizingMaskIntoConstraints = false
        self.bodyLabel = label

        super.init(tile: tile)

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        setContentView(container)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The body is a plain `NSView`, so `UIProbeAppearance`'s owned-layer rule
    /// cannot attribute its fill to this tile — handed over the same way P1.10
    /// handed over the managed tile's backdrops.
    var qaTokenPaintedLayers: [(label: String, layer: CALayer)] {
        body.layer.map { [(label: "body", layer: $0)] } ?? []
    }

    override func applyTokens() {
        super.applyTokens()
        // Safe from `super.init`'s own `applyTokens()` call: Swift requires this
        // subclass's stored properties to be assigned BEFORE `super.init`, so both
        // are already in place when the override first runs.
        body.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        bodyLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}
