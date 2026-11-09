import CoreGraphics
import Foundation

public enum TileAspect: Equatable, Sendable {
    case free
    case locked(Double)
}

public struct TilePreset: Equatable, Sendable {
    public var defaultSize: CGSize
    public var aspect: TileAspect
    public var sizeQuantum: CGSize?

    public init(defaultSize: CGSize, aspect: TileAspect, sizeQuantum: CGSize?) {
        self.defaultSize = defaultSize
        self.aspect = aspect
        self.sizeQuantum = sizeQuantum
    }
}

public struct TerminalCellSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 9, height: Double = 20) {
        self.width = width
        self.height = height
    }
}

public enum TileGeometry {
    public static let terminalChromeHeight: Double = 24

    public static func preset(for kind: TileKind, terminalCell: TerminalCellSize = TerminalCellSize()) -> TilePreset {
        switch kind {
        case .terminal:
            return terminalPreset(cell: terminalCell)
        case .browser:
            // 16:9, the shape tidy gives a browser (`shapeRule`), so creation never
            // needs reshaping. Same width as the old 1024 x 640.
            return TilePreset(defaultSize: CGSize(width: 1024, height: 576), aspect: .free, sizeQuantum: nil)
        case .iosPreview:
            return TilePreset(defaultSize: CGSize(width: 440, height: 880), aspect: .free, sizeQuantum: nil)
        case .browserInspector:
            return TilePreset(defaultSize: CGSize(width: 640, height: 420), aspect: .free, sizeQuantum: nil)
        case .note:
            return TilePreset(defaultSize: CGSize(width: 640, height: 400), aspect: .free, sizeQuantum: nil)
        case .file:
            // About 75 columns by 26 lines of 13 pt monospace, the width of an agent tile: a file
            // opened beside an agent is readable where it lands. 320 x 480 held ~35 columns. Wider
            // (800) made the centre policy clamp an anchorless open over its anchor in a small view.
            return TilePreset(defaultSize: CGSize(width: 640, height: 560), aspect: .free, sizeQuantum: nil)
        case .fileTree:
            return TilePreset(defaultSize: CGSize(width: 360, height: 520), aspect: .free, sizeQuantum: nil)
        case .ticketQueue:
            return TilePreset(defaultSize: CGSize(width: 520, height: 480), aspect: .free, sizeQuantum: nil)
        case .conductorQueue:
            return TilePreset(defaultSize: CGSize(width: 520, height: 480), aspect: .free, sizeQuantum: nil)
        case .diffReview:
            return TilePreset(defaultSize: CGSize(width: 720, height: 520), aspect: .free, sizeQuantum: nil)
        case .runArtifacts:
            return TilePreset(defaultSize: CGSize(width: 640, height: 520), aspect: .free, sizeQuantum: nil)
        case .managedAgent, .sharedAgent:
            // Taller than wide (0.9), inside the agent band of `shapeRule`, at about
            // the old 640 x 520's area: a transcript reads down, not across.
            return TilePreset(defaultSize: CGSize(width: 576, height: 640), aspect: .free, sizeQuantum: nil)
        case .sharedTile:
            return TilePreset(defaultSize: CGSize(width: 640, height: 520), aspect: .free, sizeQuantum: nil)
        case .kanban:
            return TilePreset(defaultSize: CGSize(width: 800, height: 520), aspect: .free, sizeQuantum: nil)
        case .sharedPortal:
            return TilePreset(defaultSize: CGSize(width: 960, height: 620), aspect: .free, sizeQuantum: nil)
        }
    }

    public static func minimumSize(for kind: TileKind, terminalCell: TerminalCellSize = TerminalCellSize()) -> CGSize {
        switch kind {
        case .terminal:
            return CGSize(width: terminalCell.width * 20, height: terminalCell.height * 5 + terminalChromeHeight)
        case .browser:
            return CGSize(width: 320, height: 220)
        case .iosPreview:
            return CGSize(width: 300, height: 420)
        case .browserInspector:
            return CGSize(width: 520, height: 360)
        case .note:
            return CGSize(width: 240, height: 160)
        case .file:
            return CGSize(width: 200, height: 200)
        case .fileTree:
            return CGSize(width: 220, height: 240)
        case .ticketQueue:
            return CGSize(width: 320, height: 240)
        case .conductorQueue:
            return CGSize(width: 320, height: 240)
        case .diffReview:
            return CGSize(width: 360, height: 260)
        case .runArtifacts:
            return CGSize(width: 320, height: 240)
        case .managedAgent, .sharedAgent, .sharedTile:
            return CGSize(width: 320, height: 240)
        case .kanban:
            return CGSize(width: 300, height: 260)
        case .sharedPortal:
            return CGSize(width: 360, height: 260)
        }
    }

    private static func terminalPreset(cell: TerminalCellSize) -> TilePreset {
        // Taller than wide, inside the terminal band of `shapeRule` (0.6-0.9), so
        // tidy does not reshape a new terminal. 80 columns is the usable floor;
        // 39 rows is the fewest that keeps 80 columns at or under 0.9
        // (720 x 804 with the default cell). The previous 100 x 28 (900 x 584)
        // was wide, and the 120 x 32 before it forced a zoom-out at zoom 1.
        let cols: Double = 80
        let rows: Double = 39
        return TilePreset(
            defaultSize: CGSize(width: cols * cell.width, height: rows * cell.height + terminalChromeHeight),
            aspect: .free,
            sizeQuantum: CGSize(width: cell.width, height: cell.height)
        )
    }
}

/// The shape tidy gives a tile, and the shape creation starts it in
/// (`.plans/auto-layout-night`). Ratios are width / height of the whole tile frame.
public enum TileShapeRule: Equatable, Sendable {
    /// Always this ratio: a browser is 16:9 after tidy and at creation.
    case aspect(Double)
    /// Keep the tile's current ratio, clamped into this band: a terminal or an
    /// agent stays taller than wide however it was left.
    case band(min: Double, max: Double)
    /// Never reshaped by tidy (a device-shaped iOS preview); only moved.
    case keep
}

extension TileGeometry {
    public static func shapeRule(for kind: TileKind) -> TileShapeRule {
        switch kind {
        case .browser:
            return .aspect(16.0 / 9.0)
        case .terminal:
            return .band(min: 0.6, max: 0.9)
        case .managedAgent, .sharedAgent:
            return .band(min: 0.6, max: 1.0)
        case .iosPreview, .sharedPortal, .sharedTile:
            return .keep
        case .note, .file, .fileTree, .diffReview, .runArtifacts:
            return .band(min: 0.6, max: 1.8)
        case .browserInspector, .ticketQueue, .conductorQueue, .kanban:
            return .band(min: 0.8, max: 2.0)
        }
    }

    /// The sizes a new tile may take to fit an auto-layout zone's free space,
    /// largest first: its default, then 7/8 and 3/4 of it. Every step keeps the
    /// default's ratio, so it stays inside `shapeRule` (eighths keep a 1024 x 576
    /// browser exactly 16:9: 896 x 504, 768 x 432), and none is below the
    /// kind's minimum. A terminal and a `.keep` kind offer only the default: a
    /// smaller terminal costs columns, and a device-shaped preview has one size.
    public static func spawnFitSizes(for kind: TileKind) -> [CGSize] {
        let base = preset(for: kind).defaultSize
        if kind == .terminal || shapeRule(for: kind) == .keep { return [base] }
        let minimum = minimumSize(for: kind)
        return [1.0, 0.875, 0.75].compactMap { scale -> CGSize? in
            let size = CGSize(width: (base.width * scale).rounded(), height: (base.height * scale).rounded())
            return size.width >= minimum.width && size.height >= minimum.height ? size : nil
        }
    }
}
