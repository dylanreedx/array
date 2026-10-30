import AppKit
import CryptoKit
import Darwin
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A background-only real Array process used by the local two-person witness.
/// It mounts production source/shared scenes and uses actual HTTP adapters. Its
/// mailbox, credentials, project and preferences are all explicit disposable QA.
@MainActor
enum SharedAreaPeerRuntime {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    struct Configuration: Codable {
        let label: String
        let instance: String
        let supportRoot: String
        let projectRoot: String
        let mailboxRoot: String
        let endpoint: String
        let enrollmentCode: String
        let defaultsSuite: String
    }
    private final class Vault: CollaborationCredentialVault, @unchecked Sendable {
        private let lock = NSLock()
        let directory: URL
        init(_ directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        private func file(_ service: String, _ account: String) -> URL {
            let key = SHA256.hash(data: Data((service + "/" + account).utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent(key + ".credential")
        }
        func read(service: String, account: String) throws -> Data? {
            try lock.withLock { let path = file(service, account); return FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil }
        }
        func write(_ data: Data, service: String, account: String) throws {
            try lock.withLock { let path = file(service, account); try data.write(to: path, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        }
        func remove(service: String, account: String) throws { try lock.withLock { let path = file(service, account); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } } }
    }
    private actor FaultGate {
        enum Mode: String { case none, beforeSend, afterCommit }
        var mode: Mode = .none
        let directory: URL
        init(_ directory: URL) { self.directory = directory }
        func arm(_ value: String) throws {
            guard let value = Mode(rawValue: value) else { throw Failure(description: "unknown fault boundary") }
            mode = value
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("fault-marker.json"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("fault-release"))
        }
        func wait(_ boundary: Mode, command: SharedArea.Command) async throws {
            guard mode == boundary else { return }
            mode = .none
            let data = try JSONSerialization.data(withJSONObject: ["operation": command.id.rawValue.uuidString, "expectedRevision": command.expectedRevision, "phase": boundary.rawValue], options: [.sortedKeys])
            let marker = directory.appendingPathComponent("fault-marker.json")
            try data.write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("fault-release").path) {
                guard ContinuousClock.now < deadline else { throw Failure(description: "fault gate deadline expired") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    private struct Transport: SharedAreaControllerTransport {
        let live: SharedAreaAPITransport
        let gate: FaultGate
        func identity() async throws -> Collaboration.Identity { try await live.identity() }
        func state() async throws -> Collaboration.State { try await live.state() }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await live.connection(initial: initial) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
            try await gate.wait(.beforeSend, command: mutation.command)
            let receipt = try await live.apply(mutation)
            try await gate.wait(.afterCommit, command: mutation.command)
            return receipt
        }
        func beginPresence() async throws -> Collaboration.PresenceSession { try await live.beginPresence() }
        func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await live.publishPresence(input) }
        func endPresence(_ session: UUID) async throws { try await live.endPresence(session) }
        func reportUsage(_ report: Collaboration.UsageReport) async throws { try await live.reportUsage(report) }
    }
    private final class Census { var runners: [ScriptedAgentRunner] = [] }
    private struct Source {
        let delegate: AppDelegate
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
        let controller: ZoneRuntimeController
        let browser: BrowserEngineContext
        let window: NSWindow
        let zone: UUID
        let agentTile: UUID
        let noteTile: UUID
        let census: Census
        let settings: QAIsolatedDefaults
        let sourceFiles: [URL]
    }
    @MainActor
    private final class Peer {
        let config: Configuration
        let directory: URL
        let account: CollaborationAccountController
        let source: Source
        let fault: FaultGate
        var controller: SharedAreaController?
        var scene: SharedAreaSceneView?
        var sharedWindow: NSWindow?
        var hostSession: SharedAreaHostSession?
        var presencePublisher: SharedAreaPresencePublisher?
        var handoff: SharedAreaHandoffCoordinator?
        var observer: UUID?
        var lastRequest = ""
        var revisions: [UInt64] = []
        var presenceSession: UUID?
        var presenceSequence: UInt64 = 0
        init(config: Configuration, account: CollaborationAccountController, source: Source, fault: FaultGate) {
            self.config = config; self.account = account; self.source = source; self.fault = fault
            directory = URL(fileURLWithPath: config.mailboxRoot)
        }
        func write(_ object: [String: Any], to file: String) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let url = directory.appendingPathComponent(file)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func status() -> [String: Any] {
            var result: [String: Any] = ["instance": config.instance, "person": account.activeAccount?.identity.person.rawValue.uuidString ?? "", "device": account.activeAccount?.identity.device.uuidString ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
                "sourceRecords": source.delegate.qaAgentSupervisor.records.count, "runnerConstructions": source.census.runners.count,
                "runnerCalls": source.census.runners.reduce(0) { $0 + $1.runCount },
                "runnerCompleted": source.census.runners.reduce(0) { $0 + $1.completedRuns },
                "sourceRunningAgents": source.delegate.qaAgentSupervisor.records.keys.filter { source.delegate.qaAgentSupervisor.isRunning($0) }.count,
                "runnerPrompts": source.census.runners.flatMap(\.prompts)]
            if let controller {
                result["status"] = String(describing: controller.status)
                result["area"] = controller.document?.id.rawValue.uuidString ?? account.activeAccount?.knownAreas.first?.id.uuidString ?? ""
                result["pending"] = controller.pendingOperations.map { ["id": $0.command.id.rawValue.uuidString, "attempts": $0.attempts] as [String: Any] }
                result["acceptedOperations"] = controller.deliveryRecords.compactMap { operation -> [String: Any]? in
                    guard case .accepted(let revision) = operation.state else { return nil }
                    return ["id": operation.command.id.rawValue.uuidString, "revision": revision]
                }
                result["revision"] = controller.document?.revision ?? 0
                result["epoch"] = controller.scope?.epoch ?? 0
                result["posts"] = controller.document?.posts.count ?? 0
                result["postIDs"] = controller.document?.posts.map { $0.id.rawValue.uuidString } ?? []
                result["contexts"] = controller.document?.contexts.map { ["id": $0.id.rawValue.uuidString, "text": $0.text, "object": $0.object.rawValue.uuidString] } ?? []
                result["items"] = controller.document?.items.map { ["id": $0.id.rawValue.uuidString, "kind": $0.kind.rawValue] } ?? []
                result["positions"] = controller.document?.positions.map { ["id": $0.id.rawValue.uuidString, "object": $0.object.rawValue.uuidString, "x": $0.rect.x, "y": $0.rect.y, "width": $0.rect.width, "height": $0.rect.height] as [String: Any] } ?? []
                if let document = controller.document, let data = try? document.canonicalData() {
                    result["documentHash"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                result["privateCamera"] = ["x": controller.view.x, "y": controller.view.y, "zoom": controller.view.zoom]
                result["bindings"] = controller.sourceBindings.count
                result["presence"] = controller.presence.count
            }
            result["canUndo"] = scene?.canUndoSharedGeometry ?? false
            result["canRedo"] = scene?.canRedoSharedGeometry ?? false
            result["gestureActive"] = scene?.isGeometryGestureActive ?? false
            result["sourceFiles"] = source.sourceFiles.compactMap { url -> [String: String]? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ["name": url.lastPathComponent, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
            }
            result["sourceWorld"] = source.canvas.allTilesInWorldFrames().sorted { $0.id.uuidString < $1.id.uuidString }.map { ["id": $0.id.uuidString, "x": $0.frame.x, "y": $0.frame.y, "width": $0.frame.width, "height": $0.frame.height] as [String: Any] }
            if let receipt = handoff?.model.receipt {
                result["handoffPhase"] = receipt.phase.rawValue
                result["handoffCommand"] = receipt.command.id.uuidString
                result["handoffRequester"] = receipt.command.requester.person.rawValue.uuidString
                result["handoffContext"] = receipt.command.context.id.rawValue.uuidString
            }
            if let usage = hostSession?.lastUsage {
                result["usage"] = ["input": usage.inputTokens, "output": usage.outputTokens, "todayInput": usage.todayInputTokens, "todayOutput": usage.todayOutputTokens, "sequence": usage.sequence]
            }
            result["hoverText"] = presencePublisher?.overlay.renderedUsageText ?? ""
            return result
        }
        func changed() {
            if let revision = controller?.document?.revision, revisions.last != revision { revisions.append(revision) }
            try? write(status(), to: "status.json")
        }
        func open(_ area: UUID) async throws {
            if let observer, let controller { controller.removeChangeObserver(observer) }
            presencePublisher?.stop(); hostSession?.stop()
            scene?.unmount(); if let controller { await controller.close() }
            let model = try account.makeSharedAreaController(area: area)
            let hasCachedDocument = model.document != nil
            controller = model
            let host = CollaborationWindow(contentRect: .init(x: -60_000, y: -60_000, width: 1120, height: 760),
                styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let view = source.delegate.mountWorkspaceSceneAtBoot(sharedAreaController: model, person: account.activeAccount!.identity.person, in: host)
            host.contentView?.layoutSubtreeIfNeeded(); sharedWindow = host; scene = view
            observer = model.addChangeObserver { [weak self] in self?.changed() }
            await model.open()
            // A killed peer's held reads keep its subscription slots until the
            // service's 25 s wait expires; the client retries 429 meanwhile.
            let deadline = Date().addingTimeInterval(40)
            while model.status != .connected, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard model.status == .connected else { throw Failure(description: "area did not connect: \(model.status), persistence: \(String(describing: model.lastPersistenceError))") }
            if !hasCachedDocument { try view.fitContent() }
            let hostSession = try SharedAreaHostSession(account: account, area: area, supervisor: source.delegate.qaAgentSupervisor)
            self.hostSession = hostSession; handoff = hostSession.handoff
            hostSession.start()
            let publisher = SharedAreaPresencePublisher(scene: view); publisher.start(); presencePublisher = publisher
            changed()
        }
        func item(_ request: [String: Any], fallback kind: SharedArea.Kind) throws -> SharedArea.ID<SharedArea.Object> {
            if let id = request["object"] as? String, let uuid = UUID(uuidString: id) { return .init(uuid) }
            guard let item = controller?.document?.items.first(where: { $0.kind == kind }) else { throw Failure(description: "shared object missing") }
            return item.id
        }
        func move(_ request: [String: Any], finish: Bool = true) async throws {
            guard let controller, let scene else { throw Failure(description: "no mounted shared area") }
            let object = try item(request, fallback: .agreement)
            guard let position = controller.document?.positions.first(where: { $0.object == object }) else { throw Failure(description: "placement missing") }
            let rect = SharedArea.Rect(x: request["x"] as? Double ?? position.rect.x + 80,
                y: request["y"] as? Double ?? position.rect.y + 40,
                width: request["width"] as? Double ?? position.rect.width,
                height: request["height"] as? Double ?? position.rect.height)
            guard scene.beginGeometry(placements: [position.id], kind: request["resize"] as? Bool == true ? .resize : .move),
                  scene.updateGeometry(frames: [position.id: rect]) else { throw Failure(description: "native geometry gesture refused") }
            if finish { await scene.finishGeometry() }
        }
        func perform(_ request: [String: Any]) async throws -> [String: Any] {
            guard let op = request["op"] as? String else { throw Failure(description: "missing command") }
            switch op {
            case "create": let state = try await account.createArea(label: "Pair shared area"); try await open(state.scope.area.rawValue)
            case "invite":
                guard let area = controller?.document?.id.rawValue, let person = request["person"] as? String, let uuid = UUID(uuidString: person) else { throw Failure(description: "invite scope missing") }
                let invitation = try await account.invite(area: area, person: .init(uuid), role: .editor)
                return ["invitation": invitation.code]
            case "join":
                guard let code = request["invitation"] as? String else { throw Failure(description: "invitation missing") }
                let state = try await account.acceptInvitation(code: code, label: "Pair shared area"); try await open(state.scope.area.rawValue)
            case "shareZone":
                guard let area = controller?.document?.id.rawValue, let person = account.activeAccount?.identity.person else { throw Failure(description: "share destination missing") }
                // The shipped review owns its controller. Reusing the mounted
                // scene controller would replace its legacy onChange callback
                // and accidentally bypass native refresh after publication.
                let reviewController = try account.makeSharedAreaController(area: area)
                await reviewController.open()
                guard reviewController.status == .connected else { throw Failure(description: "review controller did not connect") }
                let host = try await account.registerHost()
                var delivery = "not attempted"
                let review = try SharedAreaCaptureCoordinator(selection: .zone(source.zone), controller: reviewController, person: person, host: host,
                    inventoryProvider: { [source] in try SharedAreaInventory.capture(runtime: source.runtime, supervisor: source.delegate.qaAgentSupervisor, selection: .zone(source.zone)) },
                    submitter: {
                        let result = await reviewController.submitPublication($0)
                        switch result {
                        case .accepted(let receipt): delivery = "accepted revision \(receipt.revision)"
                        case .rejected(let reason): delivery = "rejected \(reason)"
                        case .uncertain: delivery = "uncertain"
                        }
                        return result
                    })
                let view = SharedAreaCaptureView(coordinator: review)
                for row in review.review.rows {
                    guard let choice = view.sourceChoice.items.first(where: { $0.id == "\(row.source.projectID.uuidString)/\(row.source.tileID.uuidString)" }) else { throw Failure(description: "QA review source choice missing") }
                    view.sourceChoice.handleSelection(choice)
                    let mode = row.tileKind == .note ? "agreement" : row.tileKind == .managedAgent ? "agent" : "omit"
                    guard let choice = view.modeChoice.items.first(where: { $0.id == mode && $0.enabled }), view.modeChoice.isEnabled else { throw Failure(description: "QA review mode \(mode) unavailable") }
                    view.modeChoice.handleSelection(choice)
                }
                await review.confirm()
                let persistence = reviewController.lastPersistenceError.map { String(describing: $0) } ?? "none"
                let diagnostic = "state=\(review.state), rows=\(review.review.rows.count), ready=\(review.readyCount), pending=\(review.pendingCount), refresh=\(review.requiresRefresh), controller=\(reviewController.status), delivery=\(delivery), persistence=\(persistence), message=\(review.message)"
                view.stop()
                await reviewController.close()
                guard review.state == .published else { throw Failure(description: "source-zone publication failed: \(diagnostic)") }
            case "edit":
                guard let scene else { throw Failure(description: "no shared scene") }
                try scene.selectObject(try item(request, fallback: .agreement))
                scene.setDraftText(request["text"] as? String ?? "Peer edit")
                await scene.submitDraft()
            case "move": try await move(request)
            case "beginMove": try await move(request, finish: false)
            case "finishMove": await scene?.finishGeometry()
            case "undo": await scene?.undoSharedGeometry()
            case "redo": await scene?.redoSharedGeometry()
            case "camera": try scene?.setCamera(.init(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0, zoom: request["zoom"] as? Double ?? 1))
            case "armFault": try await fault.arm(request["phase"] as? String ?? "none")
            case "burst":
                guard let controller, let document = controller.document else { throw Failure(description: "burst scope missing") }
                let discussion: SharedArea.ID<SharedArea.Object>
                if let existing = document.items.first(where: { $0.kind == .discussion }) { discussion = existing.id }
                else {
                    await scene?.createObject(kind: .discussion)
                    guard let object = controller.document?.items.first(where: { $0.kind == .discussion })?.id else { throw Failure(description: "discussion creation failed") }
                    discussion = object
                }
                let count = request["count"] as? Int ?? 0
                guard (1...700).contains(count) else { throw Failure(description: "burst count outside QA bounds") }
                for index in 0..<count {
                    guard let current = controller.document else { throw Failure(description: "burst lost authority") }
                    let command = SharedArea.Command(area: current.id, expectedRevision: current.revision,
                        edits: [.post(.init(id: .init(), object: discussion, author: controller.identity.person, text: "PAIR REPLAY \(index)"))])
                    if case .accepted = await controller.submit(command) {} else { throw Failure(description: "burst mutation failed at \(index)") }
                }
            case "localSend":
                guard let record = source.delegate.qaAgentSupervisor.records.values.first else { throw Failure(description: "source agent missing") }
                let outcome = await source.delegate.qaAgentSupervisor.accept(.sendPrompt(AgentPrompt("PAIR OWNER LOCAL SEND")), for: record.id)
                var result = status(); result["localControlRefused"] = outcome == .refused(.sharedAgentControlRequired)
                result["localControlAccepted"] = outcome == .accepted
                return result
            case "rebindSource":
                guard let record = source.delegate.qaAgentSupervisor.records.values.first else { throw Failure(description: "source agent missing") }
                source.delegate.qaAgentSupervisor.attach(agentID: record.id, to: UUID())
            case "hostPoll": await handoff?.pollOnce(); await hostSession?.updateUsage()
            case "usage": await hostSession?.updateUsage()
            case "hover":
                let device = (request["device"] as? String).flatMap(UUID.init(uuidString:))
                presencePublisher?.overlay.inspect(device: device)
                if let overlay = presencePublisher?.overlay, let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
                    overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
                }
            case "handoffOffer":
                guard let model = handoff?.model, let person = request["person"] as? String, let uuid = UUID(uuidString: person) else { throw Failure(description: "handoff target missing") }
                await model.refresh(object: try item(request, fallback: .agentObservation)); await model.offer(to: .init(uuid))
            case "handoffAccept":
                guard let model = handoff?.model else { throw Failure(description: "handoff model missing") }
                await model.refresh(object: try item(request, fallback: .agentObservation)); await model.acceptOffer()
            case "handoffSend":
                guard let model = handoff?.model else { throw Failure(description: "handoff model missing") }
                await model.refresh(object: try item(request, fallback: .agentObservation))
                guard let context = model.latestContexts.first?.id else { throw Failure(description: "handoff context missing") }
                await model.send(text: request["text"] as? String ?? "PAIR HANDOFF", context: context, mode: .send)
            case "handoffRefresh":
                guard let model = handoff?.model else { throw Failure(description: "handoff model missing") }
                await model.refresh(object: try item(request, fallback: .agentObservation))
            case "presence":
                guard controller != nil else { throw Failure(description: "presence scope missing") }
                await presencePublisher?.publishPointer(.init(x: request["x"] as? Double ?? 80, y: request["y"] as? Double ?? 80))
            case "reopen": if let area = account.activeAccount?.knownAreas.first?.id { try await open(area) }
            case "status": break
            case "quit": presencePublisher?.stop(); hostSession?.stop(); return ["quit": true]
            default: throw Failure(description: "unknown peer command \(op)")
            }
            changed(); return status()
        }
    }

    static func run() async throws {
        guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier,
              let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_PEER_CONFIG"] else { throw Failure(description: "peer check requires isolated configuration") }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Foundation rewrites existing /private/tmp paths back to /tmp on this
        // macOS. The tmux socket namespace must instead match POSIX realpath
        // (the same physical spelling as Python Path.resolve / shell pwd -P).
        let mailboxPath = try physicalPath(config.mailboxRoot)
        let mailbox = URL(fileURLWithPath: mailboxPath, isDirectory: true)
        let parentPath = (mailboxPath as NSString).deletingLastPathComponent
        let temporaryRoot = try physicalPath("/tmp")
        guard parentPath.hasPrefix(temporaryRoot + "/array-pair-") else { throw Failure(description: "peer root is outside disposable pair QA") }
        for candidate in [config.supportRoot, config.projectRoot, path] {
            let value = try physicalPath(candidate)
            guard value.hasPrefix(parentPath + "/") else { throw Failure(description: "peer path is outside its disposable QA root") }
        }
        guard let endpointURL = URL(string: config.endpoint), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(endpointURL.host?.lowercased() ?? "") else { throw Failure(description: "peer endpoint must be loopback") }
        guard let configuredSupport = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"],
              try physicalPath(configuredSupport) == physicalPath(config.supportRoot) else { throw Failure(description: "peer app support differs from its disposable configuration") }
        guard let tmux = ProcessInfo.processInfo.environment["TMUX_TMPDIR"], try physicalPath(tmux) == tmux,
              tmux.hasPrefix(parentPath + "/"), ProcessInfo.processInfo.environment["TMUX"] == nil,
              ProcessInfo.processInfo.environment["TMUX_PANE"] == nil else { throw Failure(description: "peer tmux namespace is not physical and isolated") }
        NSApp.setActivationPolicy(.prohibited)
        let endpoint = try CollaborationServiceEndpoint(endpointURL, allowsInsecureLoopback: true)
        let support = URL(fileURLWithPath: config.supportRoot)
        let gate = FaultGate(mailbox)
        let credentials = CollaborationCredentialStore(vault: try Vault(support.appendingPathComponent("qa-vault")), bundleIdentifier: nil)
        let account = try CollaborationAccountController(store: .init(applicationSupportRoot: support, bundleIdentifier: nil), credentialStore: credentials,
            bundleIdentifier: nil, areaTransportFactory: { endpoint, credential, area in
                Transport(live: try SharedAreaAPITransport(endpoint: endpoint, credential: credential, area: area), gate: gate)
            })
        if let remembered = account.accounts.first { _ = try await account.select(accountID: remembered.id) }
        else { _ = try await account.enroll(endpoint: endpoint, code: config.enrollmentCode, deviceLabel: "QA \(config.label)", accountLabel: "QA \(config.label)") }
        let source = try makeSource(config)
        let peer = Peer(config: config, account: account, source: source, fault: gate)
        defer { source.runtime.closeAll(); source.browser.shutdown(); source.settings.removePersistentDomain(forName: source.settings.suiteDomainName) }
        if let area = account.activeAccount?.knownAreas.first?.id { try await peer.open(area) }
        try peer.write(peer.status(), to: "ready.json")
        while !Task.isCancelled {
            let requestURL = mailbox.appendingPathComponent("request.json")
            if let data = try? Data(contentsOf: requestURL), let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = request["id"] as? String, request["instance"] as? String == config.instance, peer.lastRequest != id {
                peer.lastRequest = id
                do {
                    let result = try await peer.perform(request)
                    try peer.write(["id": id, "ok": true, "result": result], to: "response-\(id).json")
                    if result["quit"] as? Bool == true { if let model = peer.controller { await model.close() }; return }
                } catch {
                    try peer.write(["id": id, "ok": false, "error": String(describing: error)], to: "response-\(id).json")
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func physicalPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw Failure(description: "peer QA path does not exist") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func makeSource(_ config: Configuration) throws -> Source {
        let root = URL(fileURLWithPath: config.projectRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = URL(fileURLWithPath: config.supportRoot).appendingPathComponent("source-state")
        let projectID = UUID(uuidString: "A1D5D1F8-7666-4EF2-BD3F-80E4F8476601")!
        let zoneID = UUID(uuidString: "A1D5D1F8-7666-4EF2-BD3F-80E4F8476602")!
        let workspaceID = UUID(uuidString: "A1D5D1F8-7666-4EF2-BD3F-80E4F8476603")!
        let agentTileID = UUID(uuidString: "A1D5D1F8-7666-4EF2-BD3F-80E4F8476604")!
        let noteTileID = UUID(uuidString: "A1D5D1F8-7666-4EF2-BD3F-80E4F8476605")!
        let project = Project(id: projectID, name: "QA source \(config.label)", rootPath: root.path, createdAt: Date(timeIntervalSince1970: 1_900_000_000), updatedAt: Date(timeIntervalSince1970: 1_900_000_000),
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: .init(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        if !FileManager.default.fileExists(atPath: store.layout.canvasFile.path) {
            try store.saveProject(project)
            var tiles: [Tile] = [.init(id: noteTileID, kind: .note, title: "Shared coordination note", frame: .init(x: -730, y: 310, width: 300, height: 200),
                zPosition: .fromLegacyRank(1), zoneId: zoneID, runtimeRef: nil, metadata: .init(noteId: noteTileID))]
            if config.label == "A" { tiles.append(.init(id: agentTileID, kind: .managedAgent, title: "Published source", frame: .init(x: -390, y: 310, width: 320, height: 400),
                zPosition: .fromLegacyRank(2), zoneId: zoneID, runtimeRef: nil, metadata: .init())) }
            try store.saveCanvas(.init(viewport: .init(x: -900, y: 100, zoom: 1), tiles: tiles, groups: [], lastActiveTileId: noteTileID))
            try store.saveNoteBody(id: noteTileID, text: "Coordinate independent changes through this reviewed agreement.")
        }
        let registryStore = RegistryStore(applicationSupportDirectory: support)
        let zone = ZonePlacement(zoneId: zoneID, projectId: projectID, origin: .init(x: -800, y: 260), size: .init(width: 900, height: 600),
            color: "mint", collapsed: false, hydrationPolicy: .automatic, autoLayoutMode: .disabled, name: "Source zone")
        let workspaceStore = WorkspaceStore(workspaceId: workspaceID, applicationSupportDirectory: support)
        if !FileManager.default.fileExists(atPath: registryStore.registryFile.path) {
            var registry = Registry.empty(); registry.lastActiveWorkspaceId = workspaceID; registry.lastActiveProjectId = projectID
            registry.projects = [.init(id: projectID, name: project.name, rootPath: root.path, workspaceId: workspaceID, lastOpenedAt: project.createdAt, pinned: false, missing: false)]
            registry.workspaces = [.init(id: workspaceID, name: "QA source workspace", projectIds: [projectID], createdAt: project.createdAt, updatedAt: project.updatedAt)]
            try registryStore.save(registry)
            try workspaceStore.save(.init(viewport: .init(x: -900, y: 100, zoom: 1), zones: [zone], lastActiveZoneId: zoneID))
        }
        let document = try workspaceStore.load()
        let controller = ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        let zones = ZoneRuntimeRegistry(closeOnZero: true) { id in guard id == projectID else { throw Failure(description: "unexpected source project acquisition") }; return controller }
        let delegate = AppDelegate(), census = Census()
        let settings = QAIsolatedDefaults(isolatedSuiteName: config.defaultsSuite)!
        settings.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        delegate.qaSettingsDefaults = settings
        let agents = AgentStore(applicationSupportDirectory: support.appendingPathComponent("agents"))
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        delegate.agentSupervisor = AgentSupervisor(store: agents, makeRunner: { _ in
            let sequence = census.runners.count + 1
            let value = ScriptedAgentRunner(script: [
                .turnStarted(threadId: "qa-pair-source-session", turnId: "qa-pair-turn-\(sequence)"),
                .contentDelta(threadId: "qa-pair-source-session", turnId: "qa-pair-turn-\(sequence)", streamKind: .assistant, delta: "QA turn accepted and completed."),
                .tokenUsageUpdated(threadId: "qa-pair-source-session", snapshot: .init(inputTokens: sequence * 100, outputTokens: sequence * 20, totalCostUsd: nil)),
                .turnCompleted(threadId: "qa-pair-source-session", turnId: "qa-pair-turn-\(sequence)", outcome: .completed, errorMessage: nil)
            ])
            census.runners.append(value); return value
        },
            nameTitlerCommand: { _ in nil }, claudeSessionTitle: { _, _ in nil }, codexRestoredContextSnapshot: { _ in nil })
        _ = delegate.agentSupervisor.restore()
        if config.label == "A", !delegate.agentSupervisor.records.values.contains(where: { $0.tileId == agentTileID && $0.projectId == projectID }) {
            _ = delegate.agentSupervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .codex, model: AgentCatalogQAFixture.codex.seedModel!, thinking: "high",
                projectId: projectID, projectRoot: root, tileId: agentTileID, displayName: "Published source")
        }
        delegate.agentSupervisor.workspaceToolsPermission = { .off }
        let browser = BrowserEngineContext()
        let runtime = WorkspaceRuntime(boot: try zones.acquire(projectId: projectID), workspaceId: workspaceID, document: document,
            registry: zones, focusBroker: delegate.qaFocusBroker, registryStore: registryStore, ghostty: nil, browserEngine: browser)
        let boot = try store.loadCanvas()
        let canvas = CanvasNSView(canvasState: boot, activeZone: zone,
            zoneRenderModels: [.init(placement: zone, displayName: zone.name)], showsZoneChrome: true)
        canvas.frame = .init(x: 0, y: 0, width: 1400, height: 1000); canvas.autoLayoutDefaults = settings
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browser, runtime: runtime, registryStore: registryStore)
        let window = NSWindow(contentRect: .init(x: -60_000, y: -60_000, width: 1400, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; delegate.qaAttachWindowForOfflineCheck(window)
        delegate.userCommandWindowProvider = { [weak window] in window }
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas,
            spawner: TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browser, projectStore: store, project: project),
            projectStore: store, canvasState: boot, installsGlobalEventMonitors: false)
        try runtime.flushMountedWorkspaceState()
        return .init(delegate: delegate, runtime: runtime, canvas: canvas, controller: controller, browser: browser,
            window: window, zone: zoneID, agentTile: agentTileID, noteTile: noteTileID, census: census, settings: settings,
            sourceFiles: [store.layout.canvasFile, store.layout.noteFile(id: noteTileID)])
    }
}
