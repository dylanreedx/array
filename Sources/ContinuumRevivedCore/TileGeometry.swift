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
            return TilePreset(defaultSize: CGSize(width: 1024, height: 640), aspect: .free, sizeQuantum: nil)
        case .browserInspector:
            return TilePreset(defaultSize: CGSize(width: 640, height: 420), aspect: .free, sizeQuantum: nil)
        case .note:
            return TilePreset(defaultSize: CGSize(width: 640, height: 400), aspect: .free, sizeQuantum: nil)
        case .file:
            return TilePreset(defaultSize: CGSize(width: 320, height: 480), aspect: .free, sizeQuantum: nil)
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
        }
    }

    public static func minimumSize(for kind: TileKind, terminalCell: TerminalCellSize = TerminalCellSize()) -> CGSize {
        switch kind {
        case .terminal:
            return CGSize(width: terminalCell.width * 20, height: terminalCell.height * 5 + terminalChromeHeight)
        case .browser:
            return CGSize(width: 320, height: 220)
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
        }
    }

    private static func terminalPreset(cell: TerminalCellSize) -> TilePreset {
        // Keep new shell tiles usable at the default canvas zoom in a common
        // 1000×700 viewport. The previous 120×32 estimate (1080×664pt) forced
        // users to zoom out or pan immediately, which made embedded Ghostty/tmux
        // text feel too small. A 100×28 tile still provides a useful terminal
        // grid while fitting comfortably at zoom 1.
        let cols: Double = 100
        let rows: Double = 28
        return TilePreset(
            defaultSize: CGSize(width: cols * cell.width, height: rows * cell.height + terminalChromeHeight),
            aspect: .free,
            sizeQuantum: CGSize(width: cell.width, height: cell.height)
        )
    }
}
