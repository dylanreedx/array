import ContinuumRevivedCore
import Foundation

func runDocumentLocationChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("array-document-location-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let nested = project.appendingPathComponent("worktrees/agent", isDirectory: true)
    let docs = nested.appendingPathComponent("Docs", isDirectory: true)
    try! fm.createDirectory(at: docs, withIntermediateDirectories: true)
    let file = docs.appendingPathComponent("Plan.md")
    try! "# plan".write(to: file, atomically: true, encoding: .utf8)
    let projectId = UUID()
    let location = DocumentLocationResolver.resolve(
        fileURL: file,
        knownRoots: [
            DocumentLocationRoot(rootURL: project, projectId: projectId),
            DocumentLocationRoot(rootURL: nested, projectId: projectId)
        ]
    )
    expect(location.path == file.standardizedFileURL.resolvingSymlinksInPath().path,
           "document location must canonicalize its file identity")
    expect(location.checkoutRootPath == nested.standardizedFileURL.resolvingSymlinksInPath().path,
           "the longest containing checkout root must win")
    expect(location.relativePath == "Docs/Plan.md" && location.relativeDirectory == "Docs",
           "checkout-relative file and parent directory must be derived")

    let outside = root.appendingPathComponent("standalone.md")
    try! "outside".write(to: outside, atomically: true, encoding: .utf8)
    let standalone = DocumentLocationResolver.resolve(fileURL: outside, knownRoots: [.init(rootURL: project, projectId: projectId)])
    expect(standalone.scope == .standalone, "an arbitrary path must remain standalone")
    let escape = project.appendingPathComponent("escape.md")
    try! fm.createSymbolicLink(at: escape, withDestinationURL: outside)
    expect(DocumentLocationResolver.resolve(
        fileURL: escape, knownRoots: [.init(rootURL: project, projectId: projectId)]
    ).scope == .standalone, "a symlink escape must not pass checkout containment")

    let secondCheckout = project.appendingPathComponent("worktrees/second", isDirectory: true)
    try! fm.createDirectory(at: secondCheckout.appendingPathComponent("Docs"), withIntermediateDirectories: true)
    let secondFile = secondCheckout.appendingPathComponent("Docs/Plan.md")
    try! "# other plan".write(to: secondFile, atomically: true, encoding: .utf8)
    let secondLocation = DocumentLocationResolver.resolve(
        fileURL: secondFile,
        knownRoots: [.init(rootURL: secondCheckout, projectId: projectId)]
    )
    expect(secondLocation.relativePath == location.relativePath && secondLocation.path != location.path,
           "the same relative file in separate worktrees must retain distinct identities")

    let legacyMetadata = TileMetadata(filePath: file.path)
    let legacyMetadataData = try! JSONEncoder().encode(legacyMetadata)
    let decodedLegacyMetadata = try! JSONDecoder().decode(TileMetadata.self, from: legacyMetadataData)
    expect(decodedLegacyMetadata.filePath == file.path && decodedLegacyMetadata.documentLocation == nil,
           "legacy filePath-only tile metadata must remain decodable")

    var workspace = WorkspaceDocument(
        viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil
    )
    let agent = AgentID(rawValue: UUID())
    let tile = UUID()
    let first = Date(timeIntervalSinceReferenceDate: 10)
    workspace.linkDocument(tile, to: agent, at: first)
    workspace.linkDocument(tile, to: agent, at: first.addingTimeInterval(5))
    expect(workspace.documentLinks.count == 1 && workspace.documentLinks[0].updatedAt > first,
           "workspace document links must dedupe by agent/tile and refresh updatedAt")
    let data = try! JSONEncoder().encode(workspace)
    let decoded = try! JSONDecoder().decode(WorkspaceDocument.self, from: data)
    expect(decoded.schemaVersion == WorkspaceDocument.currentSchemaVersion && decoded.documentLinks == workspace.documentLinks,
           "current workspace schema must round-trip document links")
    var v5Object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    v5Object["schemaVersion"] = 5
    let v5Data = try! JSONSerialization.data(withJSONObject: v5Object)
    let migratedV5 = try! JSONDecoder().decode(WorkspaceDocument.self, from: v5Data)
    expect(migratedV5.schemaVersion == WorkspaceDocument.currentSchemaVersion && migratedV5.documentLinks == workspace.documentLinks,
           "workspace v5 must migrate to current without losing document links")
    // A real store/relaunch witness, not just an in-memory decoder exercise.
    // Write the shipped v5 shape to the canonical workspace path, load it through
    // WorkspaceStore, save the migrated document, and load it twice more. The
    // relationship must remain singular and byte-stable across both relaunches.
    let workspaceId = UUID()
    let persistenceRoot = root.appendingPathComponent("AppSupport", isDirectory: true)
    let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: persistenceRoot)
    try! fm.createDirectory(at: workspaceStore.layout.workspaceDirectory, withIntermediateDirectories: true)
    var storeV5Object = try! JSONSerialization.jsonObject(
        with: JSONCodec.makeEncoder().encode(workspace)) as! [String: Any]
    storeV5Object["schemaVersion"] = 5
    let storeV5Data = try! JSONSerialization.data(withJSONObject: storeV5Object)
    try! storeV5Data.write(to: workspaceStore.layout.canvasFile)
    let firstRelaunch = try! workspaceStore.load()
    expect(firstRelaunch.schemaVersion == WorkspaceDocument.currentSchemaVersion && firstRelaunch.documentLinks == workspace.documentLinks,
           "WorkspaceStore must retain v5 document relationships on first relaunch")
    try! workspaceStore.save(firstRelaunch)
    let secondRelaunch = try! workspaceStore.load()
    try! workspaceStore.save(secondRelaunch)
    let thirdRelaunch = try! workspaceStore.load()
    expect(secondRelaunch.documentLinks == workspace.documentLinks
            && thirdRelaunch.documentLinks == workspace.documentLinks,
           "repeated v6 save/relaunch cycles must neither drop nor duplicate document relationships")
    var v4Object = v5Object
    v4Object["schemaVersion"] = 4
    v4Object.removeValue(forKey: "documentLinks")
    let v4Data = try! JSONSerialization.data(withJSONObject: v4Object)
    let migratedV4 = try! JSONDecoder().decode(WorkspaceDocument.self, from: v4Data)
    expect(migratedV4.schemaVersion == WorkspaceDocument.currentSchemaVersion && migratedV4.documentLinks.isEmpty,
           "workspace v4 must migrate to current with an empty relationship list")
    workspace.removeDocumentLinks(agentId: agent)
    expect(workspace.documentLinks.isEmpty, "agent deletion must remove its document relationships")
    workspace.linkDocument(tile, to: agent, at: first)
    workspace.removeDocumentLinks(tileId: tile)
    expect(workspace.documentLinks.isEmpty, "document-tile deletion must remove its relationships")
}
