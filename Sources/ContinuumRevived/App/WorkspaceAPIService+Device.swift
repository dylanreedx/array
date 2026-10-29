import AppKit
import CryptoKit
import ContinuumRevivedCore
import ImageIO

@MainActor
final class IOSPreviewWorkspaceAPIState {
    struct CachedAction { let hash: String; var reply: WorkspaceAPIService.Reply? }
    struct Ledger { let scope: IOSPreviewAutomationSessions.Scope; var actions: [String: CachedAction] = [:] }
    let sessions = IOSPreviewAutomationSessions.shared
    var ledgers: [UUID: Ledger] = [:]
    var pendingOwners: Set<UUID> = []
    // Deterministic device catalogue seam; production probes the Xcode CLI.
    var devices: () async throws -> [IOSPreviewDevice] = { try await IOSPreviewTools.devices() }
    var createDevice: @MainActor (IOSPreviewDeviceTemplate, IOSPreviewAutomationSessions.Scope) async throws -> String = { @MainActor template, scope in
        try await IOSPreviewManagedDevices.shared.create(template: template, scope: scope)
    }
    var isManagedDevice: @MainActor (String, IOSPreviewAutomationSessions.Scope) async throws -> Bool = { @MainActor id, scope in
        try await IOSPreviewManagedDevices.shared.isOwned(deviceID: id, scope: scope)
    }
    var discardDevice: @MainActor (String, IOSPreviewAutomationSessions.Scope) async throws -> Void = { @MainActor id, scope in
        try await IOSPreviewManagedDevices.shared.discard(deviceID: id, scope: scope)
    }
    static func templates(_ devices: [IOSPreviewDevice]) -> [IOSPreviewDeviceTemplate] {
        Dictionary(grouping: devices.compactMap(\.template), by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
    }
    func prune() {
        let inactive = ledgers.keys.filter { sessions.attachments[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        for id in inactive.dropLast(64) { ledgers[id] = nil }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension WorkspaceAPIService {
    func deviceDispatch(agentId: AgentID, requestId: String, op: WorkspaceAPIOp, payload: [String: Any],
                        isCancelled: @escaping () -> Bool) async -> Reply {
        do {
            guard let record = supervisor.records[agentId], record.workspaceToolsEnabled else {
                throw WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools are not enabled for this caller.")
            }
            guard let checkoutText = payload["checkoutHandle"] as? String, CheckoutHandle(rawValue: checkoutText) != nil else {
                throw WorkspaceAPIError(code: .invalidRequest, message: "checkoutHandle is required on every device call, including device.build_run. Copy your explicit Home checkoutHandle from array_workspace_context; sessionId does not replace it.")
            }
            let request = try JSONDecoder().decode(DeviceRequest.self, from: JSONSerialization.data(withJSONObject: payload))
            let checkout = Self.ownCheckoutHandle(record)
            guard request.checkoutHandle == checkout, let known = knownCheckouts()[checkout], let project = known.projectId,
                  let registry = try? registryStoreProvider()?.loadOrEmpty(),
                  registry.projects.contains(where: { $0.id == project && !$0.missing }),
                  FileManager.default.fileExists(atPath: known.root.path) else {
                throw WorkspaceAPIError(code: .permissionDenied, message: "Device control is limited to the caller's explicit Home checkout.")
            }
            let scope = IOSPreviewAutomationSessions.Scope(principal: agentId.rawValue, project: project, checkout: checkout)
            if op == .deviceBuildRun, request.kind == "cancel" {
                guard let id = payload["operationId"] as? String, deviceBuildJobs.lookup(id: id, scope: scope) != nil else {
                    throw WorkspaceAPIError(code: .permissionDenied, message: "That build job is not owned by this caller and checkout.")
                }
            } else if op != .deviceOpen && op != .deviceList {
                guard let sessionID = request.sessionId,
                      (deviceAPI.sessions.attachments[sessionID]?.scope ?? deviceAPI.ledgers[sessionID]?.scope) == scope else {
                    throw WorkspaceAPIError(code: .permissionDenied, message: "This device session expired or is not owned by this caller. Open an owned tile again.")
                }
            }
            if op == .deviceOpen, let tileID = request.tileId {
                guard let tile = try deviceTiles(project: project).first(where: { $0.id == tileID }),
                      tile.metadata.iosPreviewAutomationOwnership?.agentId == agentId.rawValue,
                      tile.metadata.iosPreviewAutomationOwnership?.checkout == checkout else {
                    throw WorkspaceAPIError(code: .permissionDenied, message: "That tile is human-owned or belongs to another agent. This version cannot adopt it; create a disposable agent preview instead.")
                }
            }
            seedGrantsIfNeeded(agentId: agentId, checkout: checkout)
            dropPolicyGrantsUnlessFree(agentId: agentId)
            let generation = revocationGeneration(for: agentId)
            func allowed() -> Bool {
                dropPolicyGrantsUnlessFree(agentId: agentId)
                guard supervisor.records[agentId]?.workspaceToolsEnabled == true,
                      revocationGeneration(for: agentId) == generation,
                      knownCheckouts()[checkout]?.projectId == project,
                      let currentRegistry = try? registryStoreProvider()?.loadOrEmpty(),
                      currentRegistry.projects.contains(where: { $0.id == project && !$0.missing }),
                      FileManager.default.fileExists(atPath: known.root.path) else { return false }
                if case .allowed = WorkspaceToolGrantEvaluator.evaluate(agentId: agentId, op: op, checkout: checkout,
                    requested: .preserveAll, grants: grants[agentId] ?? [], currentGeneration: generation) { return true }
                return false
            }
            if !allowed() {
                let prompt = UUID().uuidString
                let decision = decideScope(ScopeApprovalPrompt(requestId: prompt, agentId: agentId,
                    agentDisplayName: record.displayName, checkout: checkout, checkoutDisplayName: known.displayName,
                    op: op, relativePath: nil), withinCallerProject: Self.sameProject(record, project))
                guard !isCancelled(), supervisor.records[agentId]?.workspaceToolsEnabled == true,
                      revocationGeneration(for: agentId) == generation else { throw CancellationError() }
                guard decision != .deny else { throw WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user did not allow this device operation.", approvalRequestId: prompt) }
                mint(WorkspaceToolGrant(agentId: agentId, checkoutHandles: [checkout],
                    operations: op == .deviceOpen ? WorkspaceAPIOp.deviceOperations.subtracting([.deviceBuildRun]) : [op], presentationCeiling: .preserveAll,
                    issuer: decision == .allowOnce ? .userApprovalOnce(requestId: prompt) : Self.sessionIssuer(decision, requestId: prompt),
                    revocationGeneration: generation, singleUse: decision == .allowOnce))
            }
            defer {
                if let index = grants[agentId]?.firstIndex(where: { $0.singleUse && $0.operations.contains(op) && $0.checkoutHandles.contains(checkout) }) {
                    grants[agentId]?.remove(at: index)
                }
            }
            let authorized = { @MainActor in allowed() && !isCancelled() }
            guard authorized() else { throw WorkspaceAPIError(code: .permissionDenied, message: "Device access was revoked before dispatch.") }
            switch op {
            case .deviceList:
                let catalogue = try await deviceAPI.devices()
                guard authorized() else { throw WorkspaceAPIError(code: .permissionDenied, message: "Device access was revoked before reply.") }
                let allTiles = try deviceTiles(project: project)
                let tiles = allTiles.prefix(64).map { tile -> [String: Any] in
                    ["tileId": tile.id.uuidString, "deviceId": tile.metadata.iosPreviewDeviceID as Any? ?? NSNull(),
                     "ownedByCaller": tile.metadata.iosPreviewAutomationOwnership?.agentId == agentId.rawValue,
                     "handoverRequired": tile.metadata.iosPreviewAutomationOwnership == nil]
                }
                let templates = IOSPreviewWorkspaceAPIState.templates(catalogue)
                let managed = try await IOSPreviewManagedDevices.shared.owned(scope: scope)
                guard authorized() else { throw IOSPreviewAutomationSessions.Failure.permissionDenied }
                return deviceResult(["tiles": tiles, "templatesTruncated": templates.count > 128, "tilesTruncated": allTiles.count > 64,
                    "templates": templates.prefix(128).map { ["templateId": $0.id, "name": $0.name, "runtime": $0.runtime] },
                    "managedDevices": managed.map { receipt in ["deviceId": receipt.deviceID, "templateId": receipt.templateID,
                        "available": catalogue.contains(where: { $0.id == receipt.deviceID })] as [String: Any] },
                    "capabilities": ["fresh_screenshot", "tap", "swipe", "text", "key", "home", "rotate", "build_run"], "scope": "whole_simulator", "newDevicePolicy": "host_created_disposable"])

            case .deviceOpen:
                return try await deviceOpen(request: request, requestId: requestId, scope: scope, authorized: authorized, isCancelled: isCancelled)
            case .deviceObserve:
                guard let id = request.sessionId else { throw IOSPreviewAutomationSessions.Failure.notOwned }
                let (frameID, observation) = try await deviceAPI.sessions.observe(id: id, scope: scope, authorized: authorized)
                let imageData = try await Task.detached(priority: .userInitiated) {
                    let bytes = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { throw IOSPreviewObservation.Failure.invalidFrame }
                    CGImageDestinationAddImage(destination, observation.image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                    guard CGImageDestinationFinalize(destination), bytes.length <= IOSPreviewObservation.maximumBytes else { throw IOSPreviewObservation.Failure.invalidFrame }
                    return bytes as Data
                }.value
                guard authorized() else { throw WorkspaceAPIError(code: .permissionDenied, message: "Device access was revoked before image delivery.") }
                _ = try deviceAPI.sessions.validate(id: id, scope: scope)
                return deviceResult(["sessionId": id.uuidString, "observationId": frameID.uuidString,
                    "width": observation.image.width, "height": observation.image.height,
                    "orientation": observation.orientation, "geometryGeneration": observation.geometryGeneration,
                    "sequence": observation.sequence, "helperEmittedAt": observation.helperEmittedAt.timeIntervalSince1970,
                    "hostReceivedAt": observation.hostReceivedAt.timeIntervalSince1970, "nativeCaptureTimeKnown": false,
                    "expiresInSeconds": IOSPreviewAutomationSessions.idleSeconds,
                    "image": ["mimeType": "image/jpeg", "data": imageData.base64EncodedString()]])
            case .deviceAct:
                return try await deviceAct(request: request, scope: scope, authorized: authorized)
            case .deviceBuildRun:
                return try deviceBuildRun(payload: payload, scope: scope, root: known.root, authorized: authorized)
            case .deviceClose:
                guard let id = request.sessionId else { throw IOSPreviewAutomationSessions.Failure.notOwned }
                try deviceAPI.sessions.close(id: id, scope: scope)
                return deviceResult(["sessionId": id.uuidString, "closed": true, "simulatorLeftRunning": true])
            default: throw WorkspaceAPIError(code: .unsupported, message: "Unsupported device operation.")
            }
        } catch let error as WorkspaceAPIError { return .error(error) }
        catch let error as IOSPreviewAutomationSessions.Failure {
            if error == .handoverRequired { return .error(WorkspaceAPIError(code: .permissionDenied, message: "The user reclaimed this simulator. They can choose Allow Agent Control in its Preview menu to hand it back.")) }
            let code: WorkspaceAPIError.Code = error == .busy ? .busy : error == .permissionDenied || error == .notOwned ? .permissionDenied : .targetConflict
            return .error(WorkspaceAPIError(code: code, message: "Device session: \(error). Open an owned tile or obtain a fresh observation before another action."))
        } catch let error as IOSPreviewActionChannel.Failure {
            return .error(WorkspaceAPIError(code: error == .outcomeUnknown ? .outcomeUnknown : .targetConflict,
                message: error == .outcomeUnknown ? "Native input may have completed. Reconnect and observe; do not replay the tap." : "Native input was rejected. Observe again before acting."))
        } catch is CancellationError { return .cancelled(result: nil) }
        catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "Device operation failed. Check the request and reconnect explicitly if the simulator is unavailable."))
        }
    }

    private func deviceTiles(project: UUID) throws -> [Tile] {
        let base: [Tile]
        if let controller = runtimeProvider()?.controller(for: project) {
            base = try controller.projectStore.tryLoadCanvas()?.tiles ?? []
        } else if let entry = try registryStoreProvider()?.loadOrEmpty().projects.first(where: { $0.id == project && !$0.missing }) {
            base = try ProjectStore(projectRoot: URL(fileURLWithPath: entry.rootPath)).tryLoadCanvas()?.tiles ?? []
        } else { throw IOSPreviewAutomationSessions.Failure.unavailable }
        guard let canvas = canvasProvider() else { return base.filter { $0.kind == .iosPreview } }
        // The same cover-then-replace rule as persistence: preserve unmounted
        // zones, but never resurrect a deleted tile from a covered live zone.
        return CanvasEngine.mergeProjectTilesForPersistence(persisted: base,
            installed: canvas.tilesInWorldFrames(forProjectId: project),
            coveredZoneIds: canvas.installedZoneIds(forProjectId: project)).filter { $0.kind == .iosPreview }
    }
    private func deviceResult(_ value: [String: Any]) -> Reply {
        .result(value.mapValues(AnyHashableJSON.init(any:)))
    }

    private func deviceOpen(request: DeviceRequest, requestId: String, scope: IOSPreviewAutomationSessions.Scope,
                            authorized: @escaping () -> Bool, isCancelled: @escaping () -> Bool) async throws -> Reply {
        guard !deviceAPI.pendingOwners.contains(scope.principal) else { throw IOSPreviewAutomationSessions.Failure.busy }
        deviceAPI.pendingOwners.insert(scope.principal)
        defer { deviceAPI.pendingOwners.remove(scope.principal) }
        guard let workspace = runtimeProvider(), let canvas = canvasProvider() else { throw IOSPreviewAutomationSessions.Failure.unavailable }
        let key = request.idempotencyKey ?? requestId
        guard !key.isEmpty, key.utf8.count <= 128 else { throw WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey must contain 1–128 UTF-8 bytes.") }
        var normalized = request; normalized.idempotencyKey = nil
        let hash = IOSPreviewWorkspaceAPIState.digest(try Self.encoder.encode(normalized))
        let keyHash = IOSPreviewWorkspaceAPIState.digest(Data(key.utf8))
        let tiles = try deviceTiles(project: scope.project)
        let matches = tiles.filter { $0.metadata.iosPreviewAutomationOwnership?.agentId == scope.principal &&
            $0.metadata.iosPreviewAutomationOwnership?.checkout == scope.checkout &&
            $0.metadata.iosPreviewAutomationOwnership?.creationKeyDigest == keyHash }
        guard request.tileId != nil || matches.count <= 1 else { throw WorkspaceAPIError(code: .targetConflict, message: "Multiple owned tiles match this creation key; use an explicit tileId.") }
        let existing = request.tileId.flatMap { id in tiles.first { $0.id == id } } ?? matches.first
        if request.templateId != nil && (request.tileId != nil || request.deviceId != nil) {
            throw WorkspaceAPIError(code: .targetConflict, message: "Choose a template for creation, or an exact owned tile/device for reconnection.")
        }
        if request.tileId == nil, let existing, existing.metadata.iosPreviewAutomationOwnership?.creationPayloadDigest != hash {
            throw WorkspaceAPIError(code: .idempotencyConflict, message: "This creation key was used with a different payload.")
        }
        if request.tileId != nil, let existing,
           request.deviceId != nil && request.deviceId != existing.metadata.iosPreviewDeviceID || request.templateId != nil {
            throw WorkspaceAPIError(code: .targetConflict, message: "An explicit device/template disagrees with the owned tile.")
        }
        if request.tileId != nil, let existing, let requestedZone = request.zoneId, requestedZone != existing.zoneId {
            throw WorkspaceAPIError(code: .targetConflict, message: "The explicit zone disagrees with the owned tile.")
        }
        if let current = deviceAPI.sessions.attachments.values.first(where: { $0.scope.principal == scope.principal }) {
            guard current.scope == scope, current.runtime.tileID == existing?.id else { throw IOSPreviewAutomationSessions.Failure.busy }
            _ = try deviceAPI.sessions.validate(id: current.id, scope: scope)
            return deviceResult(["tileId": current.runtime.tileID.uuidString, "deviceId": current.runtime.deviceID!,
                "sessionId": current.id.uuidString, "idleSeconds": IOSPreviewAutomationSessions.idleSeconds, "scope": "whole_simulator",
                "managedSimulator": existing?.metadata.iosPreviewAutomationOwnership?.managedSimulator == true])
        }
        guard deviceAPI.sessions.attachments.count + deviceAPI.pendingOwners.count <= 2 else { throw IOSPreviewAutomationSessions.Failure.busy }
        let zone = existing?.zoneId ?? request.zoneId
        guard let zone, canvas.installedZoneLayerIds.contains(zone), canvas.projectId(forZone: zone) == scope.project else {
            throw WorkspaceAPIError(code: .presentationRequired, message: "The explicit project zone must already be mounted; this operation never switches workspaces or arms a zone.")
        }
        if request.tileId != nil, let requestedZone = request.zoneId, requestedZone != zone {
            throw WorkspaceAPIError(code: .targetConflict, message: "The explicit zone disagrees with the owned tile.")
        }
        // A new tile must not be a back door into an arbitrary human simulator.
        let restoringManaged: Bool
        if existing == nil, let requestedDevice = request.deviceId {
            restoringManaged = try await deviceAPI.isManagedDevice(requestedDevice, scope)
        } else { restoringManaged = false }
        guard existing != nil || request.deviceId == nil || restoringManaged else {
            throw WorkspaceAPIError(code: .permissionDenied, message: "New agent previews use host-created disposable devices. Select a templateId; existing simulator UUIDs cannot be adopted.")
        }
        let available = try await deviceAPI.devices()
        _beforeCommitHook?()
        if isCancelled() { throw CancellationError() }
        guard authorized() else { throw IOSPreviewAutomationSessions.Failure.permissionDenied }
        let spawner = try workspace.ensureSpawner(forProjectId: scope.project)
        let controller = workspace.controller(for: scope.project)!
        let deviceID: String
        let created: Bool
        if let existing {
            guard existing.metadata.iosPreviewAutomationOwnership?.agentId == scope.principal,
                  existing.metadata.iosPreviewAutomationOwnership?.checkout == scope.checkout,
                  let selected = available.first(where: { $0.id == existing.metadata.iosPreviewDeviceID }) else { throw IOSPreviewAutomationSessions.Failure.notOwned }
            guard !deviceAPI.sessions.isReclaimed(deviceID: selected.id) else { throw IOSPreviewAutomationSessions.Failure.handoverRequired }
            guard selected.isBooted || request.allowBoot == true else {
                throw WorkspaceAPIError(code: .targetConflict, message: "The owned simulator is stopped. Explicit allowBoot:true is required to start it.")
            }
            deviceID = selected.id; created = false
        } else if restoringManaged, let selected = available.first(where: { $0.id == request.deviceId }) {
            guard selected.isBooted || request.allowBoot == true else { throw IOSPreviewAutomationSessions.Failure.unavailable }
            guard !deviceAPI.sessions.isReclaimed(deviceID: selected.id) else { throw IOSPreviewAutomationSessions.Failure.handoverRequired }
            deviceID = selected.id; created = false
        } else {
            guard let templateID = request.templateId,
                  let template = IOSPreviewWorkspaceAPIState.templates(available).first(where: { $0.id == templateID }), request.allowBoot == true else {
                throw WorkspaceAPIError(code: .invalidRequest, message: "Creation requires zoneId, a templateId from device.list, and explicit allowBoot:true for the new disposable simulator.")
            }
            deviceID = try await deviceAPI.createDevice(template, scope); created = true
        }
        if !authorized() {
            if created { try? await deviceAPI.discardDevice(deviceID, scope) }
            if isCancelled() { throw CancellationError() }
            throw IOSPreviewAutomationSessions.Failure.permissionDenied
        }
        guard canvas.installedZoneLayerIds.contains(zone), canvas.projectId(forZone: zone) == scope.project else {
            if created { try? await deviceAPI.discardDevice(deviceID, scope) }
            throw WorkspaceAPIError(code: .presentationRequired, message: "The target zone was unmounted before creation committed. The API did not switch workspaces or install into another zone.")
        }
        let preview: IOSPreviewRuntime
        do {
            if let existing {
                guard let restored = controller.iosPreviewRuntimes[existing.id] ?? spawner.restoreIOSPreviewTile(tileID: existing.id) else { throw IOSPreviewAutomationSessions.Failure.unavailable }
                preview = restored
            } else {
                let ownership = IOSPreviewAutomationOwnership(agentId: scope.principal, checkout: scope.checkout,
                    creationKeyDigest: keyHash, creationPayloadDigest: hash, managedSimulator: true)
                preview = try spawner.spawnIOSPreview(targetZoneId: zone, deviceID: deviceID, ownership: ownership).get()
            }
        } catch {
            if created { try? await deviceAPI.discardDevice(deviceID, scope) }
            if existing == nil { throw WorkspaceAPIError(code: .durabilityFailed, message: "The owned preview tile could not be saved. No helper was started; only its newly created disposable device was eligible for cleanup.") }
            throw error
        }
        controller.iosPreviewRuntimes[preview.tileID] = preview
        let controlAtStart = preview.controlGeneration
        if preview.state != .connected && preview.state != .connecting {
            preview.connect(allowBoot: request.allowBoot == true, retainingForAutomation: true,
                controllerName: supervisor.records[AgentID(rawValue: scope.principal)]?.displayName ?? "Agent")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while preview.state == .connecting, ContinuousClock.now < deadline {
            if preview.controlGeneration != controlAtStart {
                deviceAPI.sessions.reclaim(deviceID: deviceID, tileID: preview.tileID)
                preview.disconnect(); throw IOSPreviewAutomationSessions.Failure.handoverRequired
            }
            if isCancelled() {
                preview.disconnect()
                return .cancelled(result: ["tileId": AnyHashableJSON(any: preview.tileID.uuidString), "durability": AnyHashableJSON(any: "committed")])
            }
            guard authorized() else { preview.disconnect(); throw WorkspaceAPIError(code: .permissionDenied, message: "Device access revoked while connecting; owned tileId \(preview.tileID.uuidString) remains available.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard preview.controlGeneration == controlAtStart else {
            deviceAPI.sessions.reclaim(deviceID: deviceID, tileID: preview.tileID)
            preview.disconnect(); throw IOSPreviewAutomationSessions.Failure.handoverRequired
        }
        guard preview.state == .connected else {
            preview.disconnect()
            throw WorkspaceAPIError(code: .targetConflict, message: "Simulator did not connect. Retry open with owned tileId \(preview.tileID.uuidString); no other device was selected.")
        }
        guard authorized() else { preview.disconnect(); throw IOSPreviewAutomationSessions.Failure.permissionDenied }
        let attachment = try deviceAPI.sessions.attach(runtime: preview, scope: scope,
            displayName: supervisor.records[AgentID(rawValue: scope.principal)]?.displayName ?? "Agent")
        return deviceResult(["tileId": preview.tileID.uuidString, "deviceId": deviceID, "sessionId": attachment.id.uuidString,
            "idleSeconds": IOSPreviewAutomationSessions.idleSeconds, "scope": "whole_simulator", "managedSimulator": existing.map { $0.metadata.iosPreviewAutomationOwnership?.managedSimulator == true } ?? true])
    }

    private func deviceInvalidAction() -> WorkspaceAPIError {
        WorkspaceAPIError(code: .invalidRequest, message: "Invalid bounded action: tap x/y; swipe x/y/endX/endY and milliseconds 100–1500; text 1–16384 UTF-8 bytes; named key; home; rotate orientation 1–4.")
    }

    private func deviceAct(request: DeviceRequest, scope: IOSPreviewAutomationSessions.Scope,
                           authorized: @escaping () -> Bool) async throws -> Reply {
        guard let id = request.sessionId, let observation = request.observationId,
              let key = request.idempotencyKey, !key.isEmpty, key.utf8.count <= 128 else {
            throw WorkspaceAPIError(code: .invalidRequest, message: "Actions require sessionId, observationId and an idempotencyKey (1–128 UTF-8 bytes).")
        }
        let action: IOSPreviewBoundedAction
        switch request.kind {
        case "tap":
            guard let x = request.x, let y = request.y else { throw deviceInvalidAction() }
            action = .tap(x: x, y: y)
        case "swipe":
            guard let x = request.x, let y = request.y, let endX = request.endX, let endY = request.endY,
                  let milliseconds = request.milliseconds, (100...1500).contains(milliseconds) else { throw deviceInvalidAction() }
            action = .swipe(x: x, y: y, endX: endX, endY: endY, milliseconds: milliseconds)
        case "text":
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 16_384 else { throw deviceInvalidAction() }
            action = .text(text)
        case "key":
            guard let key = request.key, IOSPreviewBoundedAction.keys.contains(key) else { throw deviceInvalidAction() }
            action = .key(key)
        case "home": action = .home
        case "rotate":
            guard let orientation = request.orientation, (1...4).contains(orientation) else { throw deviceInvalidAction() }
            action = .rotate(orientation)
        default: throw deviceInvalidAction()
        }
        var normalized = request; normalized.idempotencyKey = nil
        let hash = IOSPreviewWorkspaceAPIState.digest(try Self.encoder.encode(normalized))
        deviceAPI.prune()
        if let cached = deviceAPI.ledgers[id]?.actions[key] {
            guard cached.hash == hash else { throw WorkspaceAPIError(code: .idempotencyConflict, message: "This action key was used with a different payload.") }
            guard authorized() else { throw IOSPreviewAutomationSessions.Failure.permissionDenied }
            return cached.reply ?? .error(WorkspaceAPIError(code: .busy, message: "This action is pending. Retry the same key after it settles."))
        }
        _ = try deviceAPI.sessions.validate(id: id, scope: scope)
        if deviceAPI.ledgers[id] == nil { deviceAPI.ledgers[id] = .init(scope: scope) }
        guard deviceAPI.ledgers[id]!.actions.count < 128 else { throw WorkspaceAPIError(code: .busy, message: "This session reached its retry-record budget. Close and explicitly reopen the owned tile to continue.") }
        deviceAPI.ledgers[id]!.actions[key] = .init(hash: hash, reply: nil)
        let reply: Reply
        do {
            try await deviceAPI.sessions.act(id: id, scope: scope, observationID: observation, action: action, authorized: authorized)
            reply = deviceResult(["sessionId": id.uuidString, "outcome": "native_sequence_completed", "verifyWithNewObservation": true])
        } catch let failure as IOSPreviewActionChannel.Failure {
            reply = .error(WorkspaceAPIError(code: failure == .outcomeUnknown ? .outcomeUnknown : .targetConflict,
                message: "Native action \(failure). Observe before another action; do not blindly replay."))
        } catch let failure as IOSPreviewAutomationSessions.Failure {
            reply = .error(WorkspaceAPIError(code: failure == .permissionDenied ? .permissionDenied : .targetConflict,
                message: "Device action rejected: \(failure). Obtain a new owned session/observation."))
        } catch {
            reply = .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Action completion is unknown. Observe before another action; do not replay."))
        }
        deviceAPI.ledgers[id]?.actions[key]?.reply = reply
        return reply
    }
}
