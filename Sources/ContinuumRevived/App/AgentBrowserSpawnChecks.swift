import AppKit
import ContinuumRevivedCore
import Foundation

/// Drive the same project spawner the workspace API will use, mounted through
/// the production workspace boot route in a different, unarmed project zone.
@MainActor
enum AgentBrowserSpawnChecks {
    static func run() throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser spawn check requires isolated app support and a dev binary")
        }
        for autoLayout in [false, true] { try check(autoLayout: autoLayout) }
    }

    private static func check(autoLayout: Bool) throws {
        guard let defaults = QAIsolatedDefaults(isolatedSuiteName: "array.qa.agent-browser.\(UUID().uuidString)") else {
            throw WorkspaceAPIChecks.Failure(message: "could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: defaults.suiteDomainName) }
        defaults.set(autoLayout, forKey: CanvasAutoLayoutConfig.enabledKey)
        let f = try WorkspaceAPIChecks.makeFixture()
        f.canvas.autoLayoutDefaults = defaults
        defer { f.tearDown() }
        let beforeViewport = f.canvas.viewport
        let beforeArmed = f.canvas.armedZoneId
        let beforeGeneration = f.runtime.interactionGeneration
        let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
        let result = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
                                                anchorTileId: f.agentTileB, targetZoneId: f.zoneB)
        guard case let .spawned(runtime) = result else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser did not spawn: \(result)")
        }
        defer { runtime.terminate(policy: .force) }
        guard let controller = f.runtime.controller(for: f.projectPb) else {
            throw WorkspaceAPIChecks.Failure(message: "missing browser project controller")
        }
        controller.browserRuntimes.append(runtime)
        f.runtime.registerLiveBrowser(tileId: runtime.tileId)
        defer { controller.browserRuntimes.removeAll { $0.id == runtime.id } }
        guard let tile = f.canvas.tileRecord(for: runtime.tileId) else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser is not installed")
        }
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        guard case .success = f.api.browserControlTarget(tileId: runtime.tileId, agentId: f.agentId) else {
            throw WorkspaceAPIChecks.Failure(message: "owning agent must resolve its browser for control")
        }
        var promptCount = 0
        var domainDecision: WorkspaceAPIService.BrowserDomainDecision = .allowForSession
        f.api.browserDomainApprovalHandler = { _, _, host, reply in
            guard host == "example.com" else { reply(.deny); return {} }
            promptCount += 1
            reply(domainDecision)
            return {}
        }
        func mayNavigate(_ url: String) -> Bool {
            var allowed = false
            f.api.authorizeBrowserNavigation(tileId: runtime.tileId, agentId: f.agentId, url: URL(string: url)!) { allowed = $0 }
            return allowed
        }
        guard mayNavigate("http://localhost:3000") && promptCount == 0,
              mayNavigate("https://example.com/first") && promptCount == 1,
              mayNavigate("https://example.com/second") && promptCount == 1,
              !mayNavigate("javascript:alert(1)") else {
            throw WorkspaceAPIChecks.Failure(message: "domain gate must allow local, ask once for a remote host, and reject unsafe schemes")
        }
        f.api.revoke(agentId: f.agentId)
        domainDecision = .allowOnce
        guard mayNavigate("https://example.com/once") && mayNavigate("https://example.com/once-again"), promptCount == 3 else {
            throw WorkspaceAPIChecks.Failure(message: "allow once must not grant the domain for later visits")
        }
        domainDecision = .deny
        guard !mayNavigate("https://example.com/third"), promptCount == 4 else {
            throw WorkspaceAPIChecks.Failure(message: "revocation must discard session domain approval")
        }
        var pendingDomainReply: (@MainActor (WorkspaceAPIService.BrowserDomainDecision) -> Void)?
        f.api.browserDomainApprovalHandler = { _, _, _, reply in pendingDomainReply = reply; return {} }
        var staleAllowed = true
        f.api.authorizeBrowserNavigation(tileId: runtime.tileId, agentId: f.agentId, url: URL(string: "https://example.com/stale")!) { staleAllowed = $0 }
        guard pendingDomainReply != nil else { throw WorkspaceAPIChecks.Failure(message: "remote domain approval must be requested") }
        f.api.revoke(agentId: f.agentId)
        pendingDomainReply?(.allowForSession)
        guard !staleAllowed else { throw WorkspaceAPIChecks.Failure(message: "a revoked agent cannot receive a pending domain approval") }
        let other = f.delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot,
            harness: .pi, model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: f.projectPb,
            projectRoot: f.pbRoot, tileId: f.agentTileB)
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: other, true)
        guard case .failure = f.api.browserControlTarget(tileId: runtime.tileId, agentId: other) else {
            throw WorkspaceAPIChecks.Failure(message: "another agent cannot control an owned browser")
        }
        guard case let .spawned(userBrowser) = spawner.spawnBrowser(url: "about:blank", beside: f.agentTileB, targetZoneId: f.zoneB) else {
            throw WorkspaceAPIChecks.Failure(message: "user browser spawn failed")
        }
        defer { userBrowser.terminate(policy: .force) }
        guard case let .failure(userError) = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: f.agentId),
              userError.code == .scopeApprovalRequired else {
            throw WorkspaceAPIChecks.Failure(message: "ownerless browser requires an explicit hand-over")
        }
        controller.browserRuntimes.append(userBrowser)
        defer { controller.browserRuntimes.removeAll { $0.id == userBrowser.id } }
        guard f.api.recordUserBrowserHandOver(tileId: userBrowser.tileId, agentId: f.agentId),
              case .success = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: f.agentId),
              case .failure = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: other) else {
            throw WorkspaceAPIChecks.Failure(message: "explicit hand-over must grant just the chosen agent")
        }
        f.api.revoke(agentId: f.agentId)
        guard case .failure = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: f.agentId),
              f.api.recordUserBrowserHandOver(tileId: userBrowser.tileId, agentId: f.agentId) else {
            throw WorkspaceAPIChecks.Failure(message: "revocation must cancel hand-over until a new user approval")
        }
        let window = NSWindow(contentRect: f.canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = f.canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        window.makeFirstResponder(userBrowser.webView)
        let priorInput = userBrowser.automation.userInputCount
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        NSApp.sendEvent(event)
        guard userBrowser.automation.userInputCount == priorInput + 1,
              case .failure = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: f.agentId),
              f.api.recordUserBrowserHandOver(tileId: userBrowser.tileId, agentId: f.agentId) else {
            throw WorkspaceAPIChecks.Failure(message: "real user input must invalidate hand-over until a new approval")
        }
        f.api.takeBackBrowser(tileId: userBrowser.tileId)
        guard case .failure = f.api.browserControlTarget(tileId: userBrowser.tileId, agentId: f.agentId) else {
            throw WorkspaceAPIChecks.Failure(message: "taking back the browser must end hand-over")
        }
        guard tile.metadata.browserProfileId == BrowserProfile.agentsProfileId else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser must use the Agents profile")
        }
        let beforeTiles = Set(f.canvas.allWorkspaceTiles().map(\.id))
        for zone in [f.zoneA, f.zoneB2] {
            guard case .failure = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
                anchorTileId: f.agentTileB, targetZoneId: zone) else {
                throw WorkspaceAPIChecks.Failure(message: "foreign or unhydrated zone must refuse agent spawn")
            }
        }
        guard Set(f.canvas.allWorkspaceTiles().map(\.id)) == beforeTiles else {
            throw WorkspaceAPIChecks.Failure(message: "refused agent spawn changed the canvas")
        }
        let browserRecord = try f.storePb.loadBrowserState().tiles.first(where: { $0.tileId == runtime.tileId })
        guard browserRecord?.profileId == BrowserProfile.agentsProfileId,
              browserRecord?.storageGroupId == BrowserProfile.agentsDataStoreIdentifier,
              runtime.webView.configuration.websiteDataStore === f.browserEngine.dataStore(for: BrowserProfile.agentsDataStoreIdentifier) else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser must persist and use the Agents WebKit store")
        }
        let legacyMetadata = try JSONDecoder().decode(TileMetadata.self, from: Data("{}".utf8))
        guard legacyMetadata.browserOwnerAgentId == nil else {
            throw WorkspaceAPIChecks.Failure(message: "legacy tile metadata must remain ownerless")
        }
        let data = try JSONEncoder().encode(tile.metadata)
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard metadata?["browserOwnerAgentId"] as? String == f.agentId.rawValue.uuidString,
              tile.metadata.browserOwnerAgentId == f.agentId else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser owner must be persisted")
        }
        let saved = try f.storePb.loadCanvas()
        guard let savedTile = saved.tiles.first(where: { $0.id == runtime.tileId }),
              savedTile.metadata == tile.metadata else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser metadata must persist in the owning project")
        }
        guard let zone = f.canvas.installedZonePlacement(for: f.zoneB),
              let displayed = f.canvas.navigationTileSnapshot(for: runtime.tileId),
              tile.zoneId == f.zoneB, displayed.worldFrame == savedTile.frame,
              savedTile.frame.x >= zone.origin.x, savedTile.frame.y >= zone.origin.y,
              savedTile.frame.x + savedTile.frame.width <= zone.origin.x + zone.size.width,
              savedTile.frame.y + savedTile.frame.height <= zone.origin.y + zone.size.height,
              abs(savedTile.frame.x - 3040) < 1400, abs(savedTile.frame.y - 440) < 1000 else {
            throw WorkspaceAPIChecks.Failure(message: "browser world frame must persist near its agent inside the zone: saved=\(savedTile.frame), live=\(String(describing: f.canvas.navigationTileSnapshot(for: runtime.tileId))), zone=\(String(describing: f.canvas.installedZonePlacement(for: f.zoneB)))")
        }
        guard f.canvas.viewport == beforeViewport, f.canvas.armedZoneId == beforeArmed,
              f.runtime.interactionGeneration == beforeGeneration else {
            throw WorkspaceAPIChecks.Failure(message: "agent browser spawn changed the user's navigation")
        }
        print("Agent browser spawn: Agents profile, owner, project persistence, world frame and preserved navigation passed (auto-layout \(autoLayout))")
    }
}
