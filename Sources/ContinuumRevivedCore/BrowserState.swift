import Foundation

public struct BrowserState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var tiles: [BrowserTile]
    public var inspectorStates: [BrowserInspectorState]

    public init(
        schemaVersion: Int = BrowserState.currentSchemaVersion,
        tiles: [BrowserTile],
        inspectorStates: [BrowserInspectorState] = []
    ) {
        self.schemaVersion = schemaVersion
        self.tiles = tiles
        self.inspectorStates = inspectorStates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tiles, inspectorStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tiles = try container.decode([BrowserTile].self, forKey: .tiles)
        inspectorStates = try container.decodeIfPresent([BrowserInspectorState].self, forKey: .inspectorStates) ?? []
    }
}

public struct BrowserInspectorState: Codable, Equatable, Sendable {
    public var inspectorTileId: UUID
    public var inspectedBrowserTileId: UUID
    public var selectedPanel: BrowserInspectorPanel
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        inspectorTileId: UUID,
        inspectedBrowserTileId: UUID,
        selectedPanel: BrowserInspectorPanel,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.inspectorTileId = inspectorTileId
        self.inspectedBrowserTileId = inspectedBrowserTileId
        self.selectedPanel = selectedPanel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum BrowserInspectorPanel: String, Codable, Equatable, Sendable, CaseIterable {
    case elements
    case console
    case styles
    case network
}

public struct BrowserTab: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: String
    public var title: String
    public var faviconURL: String?
    public let createdAt: Date
    public var lastAccessedAt: Date
    public var interactionState: Data?

    public init(
        id: UUID = UUID(),
        url: String,
        title: String,
        faviconURL: String? = nil,
        createdAt: Date,
        lastAccessedAt: Date,
        interactionState: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.interactionState = interactionState
    }
}

public struct BrowserTabModel: Equatable, Sendable {
    public private(set) var tabs: [BrowserTab]
    public private(set) var activeTabId: UUID

    public init(tabs: [BrowserTab], activeTabId: UUID) {
        if tabs.isEmpty {
            let now = Date()
            let fallback = BrowserTab(url: DefaultBrowserURL.fallback, title: "", createdAt: now, lastAccessedAt: now)
            self.tabs = [fallback]
            self.activeTabId = fallback.id
        } else {
            self.tabs = tabs
            self.activeTabId = tabs.contains(where: { $0.id == activeTabId }) ? activeTabId : tabs[0].id
        }
    }

    public var activeTabIndex: Int { tabs.firstIndex(where: { $0.id == activeTabId }) ?? 0 }
    public var activeTab: BrowserTab { tabs[activeTabIndex] }

    public mutating func activate(tabId: UUID, now: Date = Date()) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
        tabs[idx].lastAccessedAt = now
    }

    @discardableResult
    public mutating func appendTab(url: String, title: String, now: Date = Date()) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title, createdAt: now, lastAccessedAt: now)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    public mutating func close(tabId: UUID, now: Date = Date()) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let fallback = BrowserTab(url: DefaultBrowserURL.fallback, title: "", createdAt: now, lastAccessedAt: now)
            tabs = [fallback]
            activeTabId = fallback.id
            return
        }
        if tabId == activeTabId || !tabs.contains(where: { $0.id == activeTabId }) {
            let next = min(idx, tabs.count - 1)
            activeTabId = tabs[next].id
            tabs[next].lastAccessedAt = now
        }
    }

    public mutating func updateActiveTab(url: String, title: String, faviconURL: String? = nil, interactionState: Data?, now: Date = Date()) {
        let idx = activeTabIndex
        tabs[idx].url = url
        tabs[idx].title = title
        tabs[idx].faviconURL = faviconURL
        tabs[idx].interactionState = interactionState
        tabs[idx].lastAccessedAt = now
    }
}

public struct BrowserTile: Codable, Equatable, Sendable {
    public let id: UUID
    public let tileId: UUID
    public var url: String
    public var title: String
    public var storageGroupId: String
    public var profileId: UUID
    public let createdAt: Date
    public var updatedAt: Date
    /// Opaque WKWebView interactionState blob (back/forward history + scroll + forms).
    /// nil = no snapshot. Decoded with decodeIfPresent so v1 tiles still load.
    public var interactionState: Data?
    public var tabs: [BrowserTab]
    public var activeTabId: UUID

    public init(
        id: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        profileId: UUID = BrowserProfile.defaultProfileId,
        createdAt: Date,
        updatedAt: Date,
        interactionState: Data? = nil,
        tabs: [BrowserTab]? = nil,
        activeTabId: UUID? = nil
    ) {
        self.id = id
        self.tileId = tileId
        self.url = url
        self.title = title
        self.storageGroupId = storageGroupId
        self.profileId = profileId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.interactionState = interactionState
        let decodedTabs = tabs ?? [BrowserTab(id: activeTabId ?? UUID(), url: url, title: title, createdAt: createdAt, lastAccessedAt: updatedAt, interactionState: interactionState)]
        let model = BrowserTabModel(tabs: decodedTabs, activeTabId: activeTabId ?? decodedTabs.first?.id ?? UUID())
        self.tabs = model.tabs
        self.activeTabId = model.activeTabId
        withActiveTabMirrorUpdated()
    }

    private enum CodingKeys: String, CodingKey {
        case id, tileId, url, title, storageGroupId, profileId, createdAt, updatedAt
        case interactionState, tabs, activeTabId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tileId = try container.decode(UUID.self, forKey: .tileId)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        storageGroupId = try container.decode(String.self, forKey: .storageGroupId)
        profileId = try container.decodeIfPresent(UUID.self, forKey: .profileId) ?? BrowserProfile.defaultProfileId
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        interactionState = try container.decodeIfPresent(Data.self, forKey: .interactionState)
        let decodedTabs = try container.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? [BrowserTab(url: url, title: title, createdAt: createdAt, lastAccessedAt: updatedAt, interactionState: interactionState)]
        let decodedActiveTabId = try container.decodeIfPresent(UUID.self, forKey: .activeTabId) ?? decodedTabs.first?.id
        let model = BrowserTabModel(tabs: decodedTabs, activeTabId: decodedActiveTabId ?? UUID())
        tabs = model.tabs
        activeTabId = model.activeTabId
        withActiveTabMirrorUpdated()
    }

    public var activeTabIndex: Int { tabs.firstIndex(where: { $0.id == activeTabId }) ?? 0 }
    public var activeTab: BrowserTab { tabs[activeTabIndex] }

    public mutating func withActiveTabMirrorUpdated() {
        guard !tabs.isEmpty else { return }
        let active = activeTab
        url = active.url
        title = active.title
        interactionState = active.interactionState
    }

    public mutating func activate(tabId: UUID, now: Date = Date()) {
        var model = BrowserTabModel(tabs: tabs, activeTabId: activeTabId)
        model.activate(tabId: tabId, now: now)
        tabs = model.tabs
        activeTabId = model.activeTabId
        updatedAt = now
        withActiveTabMirrorUpdated()
    }

    @discardableResult
    public mutating func appendTab(url: String, title: String, now: Date = Date()) -> BrowserTab {
        var model = BrowserTabModel(tabs: tabs, activeTabId: activeTabId)
        let tab = model.appendTab(url: url, title: title, now: now)
        tabs = model.tabs
        activeTabId = model.activeTabId
        updatedAt = now
        withActiveTabMirrorUpdated()
        return tab
    }

    public mutating func close(tabId: UUID, now: Date = Date()) {
        var model = BrowserTabModel(tabs: tabs, activeTabId: activeTabId)
        model.close(tabId: tabId, now: now)
        tabs = model.tabs
        activeTabId = model.activeTabId
        updatedAt = now
        withActiveTabMirrorUpdated()
    }

    public mutating func updateActiveTab(url: String, title: String, faviconURL: String? = nil, interactionState: Data?, now: Date = Date()) {
        var model = BrowserTabModel(tabs: tabs, activeTabId: activeTabId)
        model.updateActiveTab(url: url, title: title, faviconURL: faviconURL, interactionState: interactionState, now: now)
        tabs = model.tabs
        activeTabId = model.activeTabId
        updatedAt = now
        withActiveTabMirrorUpdated()
    }
}

extension BrowserState {
    /// Sentinel storage group id used by `BrowserStoragePolicy.shared`. The app
    /// layer maps this to `WKWebsiteDataStore.default()`; any other value is
    /// expected to parse as a UUID and feed `WKWebsiteDataStore(forIdentifier:)`.
    public static let sharedStorageGroupId: String = "shared"

    /// Resolves the storage group identifier for a project's browser-tile storage
    /// policy. `.perProject` returns the project's UUID string (stable across
    /// relaunches and unique per project). `.shared` returns the sentinel
    /// `sharedStorageGroupId`. Pure function — no I/O, no AppKit, no WebKit.
    public static func storageGroupIdentifier(for project: Project) -> String {
        switch project.settings.browserStoragePolicy {
        case .perProject:
            return project.id.uuidString
        case .shared:
            return sharedStorageGroupId
        }
    }
}
