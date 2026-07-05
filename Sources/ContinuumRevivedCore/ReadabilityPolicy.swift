import Foundation

public enum ReadabilityBand: String, Equatable, Sendable, Codable {
    case overviewLabelOnly
    case readableSummary
    case editableDetail
}

public enum ReadabilityTargetKind: Equatable, Sendable {
    case zone
    case tile(TileKind)
    case other
}

public enum ReadabilityPolicy {
    public static let minimumPolicyZoom = 0.10

    public static func band(for target: ReadabilityTargetKind, zoom: Double) -> ReadabilityBand {
        switch target {
        case .zone:
            return zoom < 0.35 ? .overviewLabelOnly : .readableSummary
        case let .tile(kind):
            switch kind {
            case .note:
                if zoom < 0.60 { return .overviewLabelOnly }
                return zoom < 0.85 ? .readableSummary : .editableDetail
            case .browser, .browserInspector:
                if zoom < 0.70 { return .overviewLabelOnly }
                return zoom < 0.90 ? .readableSummary : .editableDetail
            case .terminal:
                if zoom < 0.85 { return .overviewLabelOnly }
                return zoom < 0.95 ? .readableSummary : .editableDetail
            case .file, .fileTree, .diffReview, .ticketQueue, .conductorQueue, .runArtifacts, .managedAgent:
                if zoom < 0.70 { return .overviewLabelOnly }
                return zoom < 0.90 ? .readableSummary : .editableDetail
            }
        case .other:
            if zoom < 0.70 { return .overviewLabelOnly }
            return zoom < 0.90 ? .readableSummary : .editableDetail
        }
    }

    public static func editingReliable(for target: ReadabilityTargetKind, zoom: Double) -> Bool {
        band(for: target, zoom: zoom) == .editableDetail
    }
}
