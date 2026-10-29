import ContinuumRevivedCore
import Foundation

func runBrowserProfileRegistryChecks() throws {
    let empty = Registry.empty()
    expect(empty.settings.browserProfiles == [BrowserProfile.builtInDefault(), BrowserProfile.builtInAgents()], "Registry.empty bootstraps Default and Agents")
    expect(empty.settings.defaultBrowserProfileId == BrowserProfile.defaultProfileId, "Registry.empty selects the built-in Default browser profile")
    expect(UUID(uuidString: BrowserProfile.defaultDataStoreIdentifier) != nil, "Built-in Default browser profile uses a UUID WKWebsiteDataStore identifier")

    let legacyJSON = """
    {
      "preferredEditor": "auto",
      "zoomModifier": "command",
      "openLastProjectOnLaunch": true
    }
    """.data(using: .utf8)!
    let legacySettings = try JSONCodec.makeDecoder().decode(RegistrySettings.self, from: legacyJSON)
    expect(legacySettings.browserProfiles == [BrowserProfile.builtInDefault(), BrowserProfile.builtInAgents()], "RegistrySettings tolerantly decodes old settings without browserProfiles")
    expect(legacySettings.defaultBrowserProfileId == BrowserProfile.defaultProfileId, "RegistrySettings tolerantly decodes old settings without defaultBrowserProfileId")

    let customProfile = BrowserProfile(
        id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
        name: "Work",
        dataStoreIdentifier: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!.uuidString,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let settingsWithExistingDefault = RegistrySettings(
        preferredEditor: .auto,
        zoomModifier: .command,
        openLastProjectOnLaunch: true,
        browserProfiles: [BrowserProfile.builtInDefault(), customProfile],
        defaultBrowserProfileId: customProfile.id
    )
    let decoded = try JSONCodec.makeDecoder().decode(
        RegistrySettings.self,
        from: JSONCodec.makeEncoder().encode(settingsWithExistingDefault)
    )
    expect(decoded.browserProfiles.filter { $0.id == BrowserProfile.defaultProfileId }.count == 1, "Browser profile bootstrap is idempotent and does not duplicate Default")
    expect(decoded.defaultBrowserProfileId == customProfile.id, "RegistrySettings preserves a valid selected browser profile")

    var mutableSettings = RegistrySettings(
        preferredEditor: .auto,
        zoomModifier: .command,
        openLastProjectOnLaunch: true
    )
    expect(mutableSettings.upsertBrowserProfile(customProfile), "RegistrySettings inserts a custom browser profile")
    expect(mutableSettings.setDefaultBrowserProfile(id: customProfile.id), "RegistrySettings selects an inserted custom browser profile")
    let renamedProfile = BrowserProfile(
        id: customProfile.id,
        name: "Work Renamed",
        dataStoreIdentifier: customProfile.dataStoreIdentifier,
        createdAt: customProfile.createdAt
    )
    expect(mutableSettings.upsertBrowserProfile(renamedProfile), "RegistrySettings updates an existing custom browser profile")
    expect(mutableSettings.browserProfiles.first(where: { $0.id == customProfile.id })?.name == "Work Renamed", "Updated browser profile name is stored")
    expect(mutableSettings.deleteBrowserProfile(id: customProfile.id), "RegistrySettings deletes a custom browser profile")
    expect(!mutableSettings.browserProfiles.contains(where: { $0.id == customProfile.id }), "Deleted browser profile is removed")
    expect(mutableSettings.defaultBrowserProfileId == BrowserProfile.defaultProfileId, "Deleting the selected browser profile falls back to Default")
    expect(!mutableSettings.deleteBrowserProfile(id: BrowserProfile.defaultProfileId), "RegistrySettings refuses to delete the built-in Default browser profile")
    let invalidProfile = BrowserProfile(
        id: UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!,
        name: "Invalid",
        dataStoreIdentifier: "not-a-uuid",
        createdAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    expect(!mutableSettings.upsertBrowserProfile(invalidProfile), "RegistrySettings refuses custom browser profiles without UUID dataStoreIdentifier")
}
