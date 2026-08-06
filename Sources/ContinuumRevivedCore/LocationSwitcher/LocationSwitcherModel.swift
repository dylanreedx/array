import Foundation

public enum LocationSwitcherMode: String, Hashable, Sendable, CaseIterable {
    case location
    case reference
    case global

    public var indexMode: LocationIndexMode {
        switch self {
        case .location: return .location
        case .reference: return .reference
        case .global: return .globalNavigation
        }
    }
}

public struct LocationSwitcherResult: Equatable, Identifiable, Sendable {
    public var id: LocationIndexID { entry.id }
    public var entry: LocationIndexEntry
    public var disambiguatedLabel: String
    public var matchedAlias: String?
    public var rankBucket: LocationIndexRankBucket
    public var fuzzyScore: Int
    public var selectionID: String

    public init(_ result: LocationIndexResult, mode: LocationSwitcherMode) {
        self.entry = result.entry
        self.disambiguatedLabel = result.disambiguatedLabel
        self.matchedAlias = result.matchedAlias
        self.rankBucket = result.rankBucket
        self.fuzzyScore = result.fuzzyScore
        self.selectionID = LocationSwitcherModel.selectionID(for: result.entry.id, mode: mode)
    }
}

public struct LocationSwitcherPreviewState: Equatable, Sendable {
    public var selectionID: String
    public var generation: UInt64
    public var preview: LocationIndexPreview

    public init(selectionID: String, generation: UInt64, preview: LocationIndexPreview) {
        self.selectionID = selectionID
        self.generation = generation
        self.preview = preview
    }
}

/// Pure state machine for location switching. Filtering and ranking stay delegated to
/// `LocationSessionIndex`; this model owns mode/query/selection identity and preview
/// generation guards only.
public struct LocationSwitcherModel: Sendable {
    public private(set) var index: LocationSessionIndex
    public private(set) var mode: LocationSwitcherMode
    public private(set) var query: String
    public private(set) var anchorID: LocationIndexID?
    public private(set) var results: [LocationSwitcherResult]
    public private(set) var selectedResultID: String?
    public private(set) var previewState: LocationSwitcherPreviewState?
    public private(set) var previewGeneration: UInt64

    public init(index: LocationSessionIndex = LocationSessionIndex(), mode: LocationSwitcherMode = .location, query: String = "", anchorID: LocationIndexID? = nil, now: Date = Date()) {
        self.index = index
        self.mode = mode
        self.query = query
        self.anchorID = anchorID
        self.results = []
        self.selectedResultID = nil
        self.previewState = nil
        self.previewGeneration = 0
        refresh(now: now, preservingSelectionID: nil)
    }

    public mutating func updateIndex(_ index: LocationSessionIndex, now: Date = Date()) {
        self.index = index
        refresh(now: now, preservingSelectionID: selectedResultID)
    }

    public mutating func setMode(_ mode: LocationSwitcherMode, now: Date = Date()) {
        guard self.mode != mode else { return }
        self.mode = mode
        refresh(now: now, preservingSelectionID: nil)
    }

    public mutating func setQuery(_ query: String, now: Date = Date()) {
        guard self.query != query else { return }
        self.query = query
        refresh(now: now, preservingSelectionID: selectedResultID)
    }

    public mutating func setAnchor(_ anchorID: LocationIndexID?, now: Date = Date()) {
        self.anchorID = anchorID
        refresh(now: now, preservingSelectionID: selectedResultID)
    }

    public mutating func select(selectionID: String?) {
        guard let selectionID, results.contains(where: { $0.selectionID == selectionID }) else {
            selectedResultID = results.first?.selectionID
            return
        }
        selectedResultID = selectionID
    }

    public var selectedResult: LocationSwitcherResult? {
        guard let selectedResultID else { return nil }
        return results.first { $0.selectionID == selectedResultID }
    }

    public mutating func beginPreviewRequest() -> LocationIndexPreviewRequest? {
        guard let selectedResult else { return nil }
        previewGeneration &+= 1
        previewState = nil
        return LocationIndexPreviewRequest(id: selectedResult.entry.id, mode: mode.indexMode)
    }

    public mutating func acceptPreview(_ preview: LocationIndexPreview, for selectionID: String, generation: UInt64) -> Bool {
        guard generation == previewGeneration, selectionID == selectedResultID else { return false }
        previewState = LocationSwitcherPreviewState(selectionID: selectionID, generation: generation, preview: preview)
        return true
    }

    public static func selectionID(for id: LocationIndexID, mode: LocationSwitcherMode) -> String {
        "\(mode.rawValue):\(id.rawValue)"
    }

    private mutating func refresh(now: Date, preservingSelectionID: String?) {
        let context = LocationIndexSearchContext(mode: mode.indexMode, anchorID: anchorID, now: now)
        results = index.search(query, context: context).map { LocationSwitcherResult($0, mode: mode) }
        if let preservingSelectionID, results.contains(where: { $0.selectionID == preservingSelectionID }) {
            selectedResultID = preservingSelectionID
        } else {
            selectedResultID = results.first?.selectionID
        }
        previewGeneration &+= 1
        previewState = nil
    }
}
