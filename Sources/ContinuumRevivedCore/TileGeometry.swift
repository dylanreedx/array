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
        case .note:
            return TilePreset(defaultSize: CGSize(width: 640, height: 400), aspect: .free, sizeQuantum: nil)
        case .file:
            return TilePreset(defaultSize: CGSize(width: 320, height: 480), aspect: .free, sizeQuantum: nil)
        case .fileTree:
            return TilePreset(defaultSize: CGSize(width: 360, height: 520), aspect: .free, sizeQuantum: nil)
        case .ticketQueue:
            return TilePreset(defaultSize: CGSize(width: 520, height: 480), aspect: .free, sizeQuantum: nil)
        }
    }

    public static func minimumSize(for kind: TileKind, terminalCell: TerminalCellSize = TerminalCellSize()) -> CGSize {
        switch kind {
        case .terminal:
            return CGSize(width: terminalCell.width * 20, height: terminalCell.height * 5 + terminalChromeHeight)
        case .browser:
            return CGSize(width: 320, height: 220)
        case .note:
            return CGSize(width: 240, height: 160)
        case .file:
            return CGSize(width: 200, height: 200)
        case .fileTree:
            return CGSize(width: 220, height: 240)
        case .ticketQueue:
            return CGSize(width: 320, height: 240)
        }
    }

    private static func terminalPreset(cell: TerminalCellSize) -> TilePreset {
        let cols: Double = 120
        let rows: Double = 32
        return TilePreset(
            defaultSize: CGSize(width: cols * cell.width, height: rows * cell.height + terminalChromeHeight),
            aspect: .free,
            sizeQuantum: CGSize(width: cell.width, height: cell.height)
        )
    }
}
