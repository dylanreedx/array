import ContinuumRevivedCore
import Foundation

struct BrowserProfileDeletionRewrite: Equatable {
    var registryDeleted: Bool
    var browserTileIdsRewritten: [UUID]
    var canvasTileIdsRewritten: [UUID]

    var affectedTileIds: [UUID] {
        Array(Set(browserTileIdsRewritten + canvasTileIdsRewritten))
    }
}

enum BrowserProfilePersistenceActions {
    static func makeProfile(
        name: String,
        id: UUID = UUID(),
        dataStoreIdentifier: String = UUID().uuidString,
        createdAt: Date = Date()
    ) -> BrowserProfile {
        BrowserProfile(id: id, name: name, dataStoreIdentifier: dataStoreIdentifier, createdAt: createdAt)
    }

    @discardableResult
    static func createProfile(named name: String, in registry: inout Registry, now: Date = Date()) -> BrowserProfile? {
        let profile = makeProfile(name: name, createdAt: now)
        guard registry.settings.upsertBrowserProfile(profile) else { return nil }
        return profile
    }

    @discardableResult
    static func renameProfile(id: UUID, to name: String, in registry: inout Registry) -> Bool {
        guard id != BrowserProfile.defaultProfileId,
              let index = registry.settings.browserProfiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        registry.settings.browserProfiles[index].name = name
        return true
    }

    @discardableResult
    static func deleteProfile(
        id: UUID,
        in registry: inout Registry,
        browserState: inout BrowserState?,
        canvasState: inout CanvasState?,
        now: Date = Date()
    ) -> BrowserProfileDeletionRewrite {
        let registryDeleted = registry.settings.deleteBrowserProfile(id: id)
        guard registryDeleted else {
            return BrowserProfileDeletionRewrite(registryDeleted: false, browserTileIdsRewritten: [], canvasTileIdsRewritten: [])
        }

        let defaultProfile = BrowserProfile.builtInDefault()
        var browserTileIdsRewritten: [UUID] = []
        if browserState != nil {
            for index in browserState!.tiles.indices where browserState!.tiles[index].profileId == id {
                browserState!.tiles[index].profileId = defaultProfile.id
                browserState!.tiles[index].storageGroupId = defaultProfile.dataStoreIdentifier
                browserState!.tiles[index].updatedAt = now
                browserTileIdsRewritten.append(browserState!.tiles[index].tileId)
            }
        }

        var canvasTileIdsRewritten: [UUID] = []
        if canvasState != nil {
            for index in canvasState!.tiles.indices where canvasState!.tiles[index].metadata.browserProfileId == id {
                canvasState!.tiles[index].metadata.browserProfileId = defaultProfile.id
                canvasTileIdsRewritten.append(canvasState!.tiles[index].id)
            }
        }

        return BrowserProfileDeletionRewrite(
            registryDeleted: true,
            browserTileIdsRewritten: browserTileIdsRewritten,
            canvasTileIdsRewritten: canvasTileIdsRewritten
        )
    }
}
