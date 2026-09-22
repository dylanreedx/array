import AppKit
import ContinuumRevivedAgentUI

/// How much width a label needs to DRAW a string, measured rather than guessed.
///
/// `NSString.size(withAttributes:)` returns the glyph run only. An `NSTextField`
/// label draws inside its cell, and the cell keeps a horizontal inset of its
/// own, so a control that sizes itself (or its rows) from the glyph run hands
/// the label a frame a few points short of what the cell needs — and the cell
/// then elides at EVERY width, however much free space surrounds it.
///
/// That inset used to be a hard-coded `+ 4` in `ChoiceButton` and absent
/// entirely from `ChoiceListView`'s rows. It is measured here instead, once per
/// font, from a real label: a guess cannot survive a font change, and at a page
/// zoom `AgentPageZoom.scaled` quantizes to a half point, which can round a
/// guessed constant below the cell's real inset.
@MainActor
enum ChoiceLabelMetrics {
    private static var insetCache: [String: CGFloat] = [:]

    /// The cell's own horizontal inset at `font`.
    ///
    /// Measured from two probe strings of different lengths and taking the
    /// larger difference: the inset is a per-cell constant, so two probes both
    /// witness it and neither can be mistaken for a per-character effect.
    static func cellInset(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(font.fontDescriptor.symbolicTraits.rawValue)"
        if let cached = insetCache[key] { return cached }
        var inset: CGFloat = 0
        for probe in ["Hn", "Claude Sonnet 4.5 (Extended Thinking)"] {
            let field = NSTextField(labelWithString: probe)
            field.font = font
            let glyphs = (probe as NSString).size(withAttributes: [.font: font]).width
            inset = max(inset, field.intrinsicContentSize.width - glyphs)
        }
        let rounded = max(0, ceil(inset))
        insetCache[key] = rounded
        return rounded
    }

    /// The width a label must be given to draw `title` at `font` in full.
    static func labelWidth(for title: String, font: NSFont) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + cellInset(for: font)
    }
}
