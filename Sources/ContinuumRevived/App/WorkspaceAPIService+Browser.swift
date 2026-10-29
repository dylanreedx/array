import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    @discardableResult
    func ensureBrowserLeaseLedger() -> Bool {
        if browserLeaseLedger != nil { return true }
        let ledger = BrowserLeaseLedger(runtime: { [weak self] id in self?.liveBrowser(tileId: id) },
                                        isRunning: { [weak self] id in self?.supervisor.isRunning(id) ?? false },
                                        closeIdle: { [weak self] tile, owner in self?.browserIdleClose?(tile, owner) ?? false })
        return installBrowserLeaseLedger(ledger)
    }

    private func wireAgentBrowserDownloads(_ browser: WKWebViewBrowserRuntime) {
        let root = supervisor.browserArtifactRoot.deletingLastPathComponent().appendingPathComponent("agent-browser-downloads", isDirectory: true)
        let tileId = browser.tileId
        browser.agentDownloadDestination = { filename in
            BrowserArtifactStore.downloadDestination(root: root, tileId: tileId, suggestedFilename: filename)
        }
    }

    /// Called after production hydration has registered the new runtime and
    /// before the browser budget chooses a victim.
    func trackHydratedOwnedBrowser(_ browser: WKWebViewBrowserRuntime) {
        guard !browserUserTakenOver.contains(browser.tileId),
              let owner = canvasProvider()?.tileRecord(for: browser.tileId)?.metadata.browserControllingAgentId,
              ensureBrowserLeaseLedger() else { return }
        wireAgentBrowserDownloads(browser)
        let tileId = browser.tileId
        browser.automation.onUserInput = { [weak self] in self?.takeBackBrowser(tileId: tileId) }
        if let surface = canvasProvider()?.tileView(for: browser.tileId) { browser.automation.trackInputSurface(surface) }
        _ = browserLeaseLedger?.track(tileId: browser.tileId, owner: owner, sweepEligible: true)
    }
    /// Resolve from the mounted scene on every use, including at queue head.
    func browserScopeTarget(tileId: UUID, agentId: AgentID) -> Result<Tile, WorkspaceAPIError> {
        guard let record = supervisor.records[agentId], record.workspaceToolsEnabled,
              let runtime = runtimeProvider(), let canvas = canvasProvider() else {
            return .failure(WorkspaceAPIError(code: .permissionDenied, message: "Browser access is unavailable."))
        }
        let handle = Self.ownCheckoutHandle(record)
        guard let projectId = record.projectId ?? knownCheckouts()[handle]?.projectId else {
            return .failure(WorkspaceAPIError(code: .permissionDenied, message: "Browser access is unavailable."))
        }
        let zones = canvas.installedZoneIds(containing: tileId)
        guard !zones.contains(where: { canvas.projectId(forZone: $0) != projectId }) else {
            return .failure(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not control that browser."))
        }
        guard zones.count <= 1 else {
            return .failure(WorkspaceAPIError(code: .unsupported, message: "The browser has multiple installed occurrences."))
        }
        guard let zone = zones.first,
              runtime.document.zones.contains(where: { $0.zoneId == zone && $0.projectId == projectId }),
              let tile = canvas.tileRecord(for: tileId), tile.kind == .browser else {
            return .failure(WorkspaceAPIError(code: .notFound, message: "No live browser tile with that id in this agent's project."))
        }
        return .success(tile)
    }

    /// Ownerless tiles require a separate user hand-over; workspace-tool or
    /// Free permission alone never grants control of one.
    func browserControlTarget(tileId: UUID, agentId: AgentID) -> Result<Tile, WorkspaceAPIError> {
        let tile: Tile
        switch browserScopeTarget(tileId: tileId, agentId: agentId) {
        case .failure(let error): return .failure(error)
        case .success(let target): tile = target
        }
        if let owner = tile.metadata.browserControllingAgentId {
            guard owner == agentId else {
                return .failure(WorkspaceAPIError(code: .permissionDenied, message: "This browser belongs to another agent."))
            }
        } else {
            guard let handOver = browserHandOvers[tileId], handOver.agentId == agentId,
                  handOver.generation == revocationGeneration(for: agentId),
                  let live = liveBrowser(tileId: tileId),
                  live.id == handOver.runtimeId, live.automation.userInputCount == handOver.userInputCount else {
                return .failure(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user must hand over this browser before the agent can control it."))
            }
        }
        return .success(tile)
    }

    /// Invoke only after an explicit, tile-specific user approval. Free policy
    /// cannot call this on its own. Input or runtime replacement invalidates it.
    @discardableResult
    func recordUserBrowserHandOver(tileId: UUID, agentId: AgentID) -> Bool {
        guard case let .failure(error) = browserControlTarget(tileId: tileId, agentId: agentId),
              error.code == .scopeApprovalRequired,
              let runtime = liveBrowser(tileId: tileId) else { return false }
        browserLeaseLedger?.release(tileId: tileId)
        browserHandOvers[tileId] = BrowserHandOver(agentId: agentId, generation: revocationGeneration(for: agentId),
                                                  runtimeId: runtime.id, userInputCount: runtime.automation.userInputCount)
        return true
    }

    /// Who the restore gate protects on rehydration: the controlling agent,
    /// unless the user took the tile back this session. Gating a taken-over
    /// tile would silently cancel the user's own remote navigation.
    func browserRestoreGateOwner(for tile: Tile) -> AgentID? {
        browserUserTakenOver.contains(tile.id) ? nil : tile.metadata.browserControllingAgentId
    }

    /// A user profile switch is a takeover: the tile may now hold the user's
    /// sessions, so no lease, gate or hand-over may survive it.
    func browserProfileDidChange(tileId: UUID) {
        guard browserHandOvers[tileId] != nil || browserGateInstallations[tileId] != nil
              || canvasProvider()?.tileRecord(for: tileId)?.metadata.browserOwnerAgentId != nil else { return }
        takeBackBrowser(tileId: tileId)
    }

    /// Revocation ends the agent's hand-overs at once. A gate left on the
    /// user's tile would deny the user's own navigation, because its
    /// generation no longer matches.
    func releaseHandedOverBrowsers(revoking agentId: AgentID) {
        let handedOver = browserHandOvers.filter { $0.value.agentId == agentId }.map(\.key)
        let gated = browserGateInstallations.filter { entry in
            entry.value.agentId == agentId && canvasProvider()?.tileRecord(for: entry.key)?.metadata.browserControllingAgentId != agentId
        }.map(\.key)
        for tileId in Set(handedOver + gated) {
            browserHandOvers[tileId] = nil
            browserGateInstallations[tileId] = nil
            browserLeaseLedger?.release(tileId: tileId)
            if let browser = liveBrowser(tileId: tileId) {
                browser.automation.onUserInput = nil
                browser.automation.onAgentClick = nil
                browser.agentNavigationDecision = nil
                browser.agentPopupRequest = nil
            }
            browserControlPresentation?(tileId, agentId, false, false)
        }
    }

    func takeBackBrowser(tileId: UUID) {
        let owner = browserHandOvers[tileId]?.agentId ?? canvasProvider()?.tileRecord(for: tileId)?.metadata.browserOwnerAgentId
        browserUserTakenOver.insert(tileId)
        browserHandOvers[tileId] = nil
        browserLeaseLedger?.release(tileId: tileId)
        browserGateInstallations[tileId] = nil
        if let owner { browserControlPresentation?(tileId, owner, false, true) }
        if let browser = liveBrowser(tileId: tileId) {
            browser.automation.onUserInput = nil
            browser.automation.onAgentClick = nil
            browser.agentNavigationDecision = nil
        }
        DispatchQueue.main.async { [weak self] in self?.runtimeProvider()?.reconcileHydration(rearmForCamera: false) }
    }

    /// Returns a dismissal for the domain sheet this raised, if any. A tile
    /// holds at most one pending browser prompt; a navigation that would raise
    /// a second is denied at once.
    @discardableResult
    func authorizeBrowserNavigation(tileId: UUID, agentId: AgentID, url: URL, readOnly: Bool = false,
                                    completion: @escaping @MainActor (Bool) -> Void) -> BrowserApprovalDismissal {
        let target = readOnly ? browserScopeTarget(tileId: tileId, agentId: agentId) : browserControlTarget(tileId: tileId, agentId: agentId)
        guard case .success = target,
              let record = supervisor.records[agentId] else { completion(false); return {} }
        let generation = revocationGeneration(for: agentId)
        switch BrowserAgentNavigationPolicy.classify(url, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)) {
        case .denied:
            completion(false)
            return {}
        case .local:
            completion(true)
            return {}
        case .approvalRequired(let host):
            if browserDomainApprovals[agentId]?.contains(host) == true { completion(true); return {} }
            guard browserPromptsPending.insert(tileId).inserted else { completion(false); return {} }
            var answered = false
            return browserDomainApprovalHandler(agentId, tileId, host) { [weak self] decision in
                guard !answered else { return }
                answered = true
                self?.browserPromptsPending.remove(tileId)
                guard let self, self.revocationGeneration(for: agentId) == generation else {
                    completion(false)
                    return
                }
                let target = readOnly ? self.browserScopeTarget(tileId: tileId, agentId: agentId) : self.browserControlTarget(tileId: tileId, agentId: agentId)
                guard case .success = target,
                      let browser = self.liveBrowser(tileId: tileId),
                      browser.agentNavigationAdmission?() != false else { completion(false); return }
                switch decision {
                case .deny: completion(false)
                case .allowOnce: completion(true)
                case .allowForSession:
                    self.browserDomainApprovals[agentId, default: []].insert(host)
                    completion(true)
                }
            }
        }
    }

    private func liveBrowser(tileId: UUID) -> WKWebViewBrowserRuntime? {
        let matches = runtimeProvider()?.liveControllers.flatMap(\.browserRuntimes).filter { $0.tileId == tileId && !$0.isTerminated } ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    private func installBrowserNavigationGate(_ browser: WKWebViewBrowserRuntime, agentId: AgentID, generation: UInt64) {
        wireAgentBrowserDownloads(browser)
        let tileId = browser.tileId
        let browserId = browser.id
        let inputCount = browser.automation.userInputCount
        browser.automation.onUserInput = { [weak self] in self?.takeBackBrowser(tileId: tileId) }
        browser.automation.onAgentClick = { [weak self, weak browser] point in
            guard let self, let browser,
                  let view = self.canvasProvider()?.tileView(for: tileId) as? BrowserTileNSView else { return }
            let colour = self.supervisor.records[agentId]?.identityColor.map { ZoneChromeNSView.color(named: $0) } ?? .controlAccentColor
            view.hostView.showAgentRipple(at: view.hostView.convert(point, from: browser.webView), colour: colour)
        }
        browser.agentPopupRequest = { [weak self, weak browser] request in
            guard let self, let browser, browser.automation.isEngaged,
                  browser.automation.userInputCount == inputCount,
                  self.revocationGeneration(for: agentId) == generation,
                  case .success = self.browserControlTarget(tileId: tileId, agentId: agentId),
                  (request.httpMethod ?? "GET").uppercased() == "GET",
                  request.httpBody == nil, request.httpBodyStream == nil,
                  let url = request.url else { return }
            let requestId = "browser-popup-" + UUID().uuidString
            self.dispatchBrowserOpen(agentId: agentId, requestId: requestId, payload: ["url": url.absoluteString],
                isCancelled: { [weak self, weak browser] in
                    guard let self, let browser, !browser.isTerminated, browser.automation.isEngaged,
                          browser.automation.userInputCount == inputCount,
                          self.revocationGeneration(for: agentId) == generation,
                          case .success = self.browserControlTarget(tileId: tileId, agentId: agentId) else { return true }
                    return false
                }, completion: { [weak browser] result in
                    guard let browser, !browser.isTerminated, browser.automation.userInputCount == inputCount else { return }
                    let answer: String
                    switch result {
                    case .result(let fields):
                        if fields["partial"]?.bool == true {
                            answer = "opened a blank browser; destination was not loaded"
                        } else {
                            answer = fields["tileId"]?.string.map { "opened browser " + $0 } ?? "could not open"
                        }
                    case .error(let error): answer = "refused: " + error.code.rawValue
                    case .cancelled: answer = "cancelled"
                    }
                    browser.automation.noteDialog("popup", message: url.host ?? "browser", answer: answer)
                })
        }
        if let existing = browserGateInstallations[tileId], existing.runtimeId == browser.id,
           existing.agentId == agentId, existing.generation == generation, existing.inputCount == inputCount,
           browser.agentNavigationDecision != nil { return }
        browserGateInstallations[tileId] = BrowserGateInstallation(runtimeId: browser.id, generation: generation, agentId: agentId, inputCount: inputCount)
        browser.agentNavigationDecision = { [weak self] url, reply in
            guard let self, self.revocationGeneration(for: agentId) == generation,
                  let current = self.liveBrowser(tileId: tileId), current.id == browserId,
                  current.automation.userInputCount == inputCount else { reply(false); return }
            self.authorizeBrowserNavigation(tileId: tileId, agentId: agentId, url: url) { [weak self] allowed in
                guard let self, let current = self.liveBrowser(tileId: tileId), current.id == browserId,
                      current.automation.userInputCount == inputCount,
                      self.revocationGeneration(for: agentId) == generation else { reply(false); return }
                reply(allowed)
            }
        }
    }

    /// A request that times out closes its own sheet, so a late click cannot
    /// answer a question nobody is waiting on.
    private func browserDomainAllowed(tileId: UUID, agentId: AgentID, url: URL, deadline: Date, readOnly: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = BrowserDomainWaiter(continuation)
            let dismiss = authorizeBrowserNavigation(tileId: tileId, agentId: agentId, url: url, readOnly: readOnly) { waiter.resolve($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) {
                if waiter.resolve(false) { dismiss() }
            }
        }
    }

    private func askBrowserHandOver(tileId: UUID, agentId: AgentID, evaluate: Bool, deadline: Date) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = BrowserDomainWaiter(continuation)
            guard browserPromptsPending.insert(tileId).inserted else { waiter.resolve(false); return }
            let dismiss = browserHandOverApprovalHandler(agentId, tileId, evaluate) { [weak self] allowed in
                self?.browserPromptsPending.remove(tileId)
                waiter.resolve(allowed)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) {
                if waiter.resolve(false) { dismiss() }
            }
        }
    }

    /// Ask-first approval runs before a request joins the tile's queue, so
    /// neither the modal prompt nor the user's reading time spends the
    /// action's deadline. A retried key the queue already holds skips the
    /// prompt: the queue replays or refuses it under its own rechecks.
    /// Returns whether the user was asked, so the caller restarts its clock.
    private func approveBrowserScope(agentId: AgentID, record: AgentRecord, handle: CheckoutHandle,
                                     operation: WorkspaceAPIOp, key: String?) -> (error: WorkspaceAPIError?, asked: Bool) {
        let generation = revocationGeneration(for: agentId)
        if let key, browserActionQueue.holds(agentId: agentId, key: key) { return (nil, false) }
        if case .allowed = WorkspaceToolGrantEvaluator.evaluate(agentId: agentId, op: operation, checkout: handle,
            requested: .preserveAll, grants: grants[agentId] ?? [], currentGeneration: generation) { return (nil, false) }
        let promptId = UUID().uuidString
        let decision = decideScope(ScopeApprovalPrompt(requestId: promptId, agentId: agentId,
            agentDisplayName: record.displayName, checkout: handle,
            checkoutDisplayName: knownCheckouts()[handle]?.displayName ?? record.displayName,
            op: operation, relativePath: nil), withinCallerProject: true)
        guard decision != .deny else {
            return (WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user has not allowed browser control.", approvalRequestId: promptId), true)
        }
        if decision != .allowOnce {
            let operations: Set<WorkspaceAPIOp> = [.browserOpen, .browserNavigate, .browserClick, .browserType,
                .browserPressKey, .browserScroll, .browserWaitFor, .browserEvaluate]
            mint(WorkspaceToolGrant(agentId: agentId, checkoutHandles: [handle], operations: operations,
                presentationCeiling: .preserveAll, issuer: Self.sessionIssuer(decision, requestId: promptId),
                revocationGeneration: generation))
        }
        return (nil, decision != .allowByPolicy)
    }

    func dispatchBrowserAction(agentId: AgentID, requestId: String, operation: WorkspaceAPIOp, payload: [String: Any],
                               isCancelled: @escaping () -> Bool, arrived: Date = Date(), completion: @escaping (Reply) -> Void) {
        let request: BrowserToolRequest
        do { request = try BrowserToolRequest.decode(operation: operation.rawValue, data: JSONSerialization.data(withJSONObject: payload)) }
        catch { completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "Invalid browser action request."))); return }
        let tileId: UUID
        let suppliedKey: String?
        var timeout: TimeInterval = 15
        switch request {
        case let .navigate(tile, _, key), let .snapshot(tile, key), let .click(tile, _, key), let .type(tile, _, _, _, _, key),
             let .pressKey(tile, _, key), let .scroll(tile, _, _, _, key), let .screenshot(tile, _, key),
             let .evaluate(tile, _, key), let .console(tile, _, key): tileId = tile; suppliedKey = key
        case let .waitFor(tile, _, seconds, key): tileId = tile; suppliedKey = key; timeout = max(15, seconds + 5)
        default: completion(.error(WorkspaceAPIError(code: .unsupported, message: "That browser action is not available yet."))); return
        }
        var deadline = arrived.addingTimeInterval(timeout)
        guard let record = supervisor.records[agentId], record.workspaceToolsEnabled,
              let runtime = runtimeProvider(), let canvas = canvasProvider() else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "Browser access is unavailable."))); return
        }
        if case let .navigate(_, .url(raw), _) = request {
            guard let url = URL(string: raw),
                  BrowserAgentNavigationPolicy.classify(url, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)) != .denied else {
                completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "That browser destination is not allowed."))); return
            }
        }
        // D1: reading follows the inspect rules. Free reads any browser in the
        // project; Ask first reads only what the agent controls or was handed.
        let readOnly = [.browserSnapshot, .browserScreenshot, .browserConsole].contains(operation)
            && supervisor.workspaceToolsPermission() == .free
        let target = readOnly ? browserScopeTarget(tileId: tileId, agentId: agentId) : browserControlTarget(tileId: tileId, agentId: agentId)
        if case let .failure(error) = target {
            guard !readOnly, error.code == .scopeApprovalRequired, let browser = liveBrowser(tileId: tileId) else {
                completion(.error(error)); return
            }
            let generation = revocationGeneration(for: agentId)
            let policy = supervisor.workspaceToolsPermission()
            let input = browser.automation.userInputCount
            let browserId = browser.id
            let box = BrowserOpenCompletionBox(completion)
            Task { @MainActor [weak self] in
                guard let self else { box.callback(.error(WorkspaceAPIError(code: .permissionDenied, message: "Browser access is unavailable."))); return }
                let allowed = await self.askBrowserHandOver(tileId: tileId, agentId: agentId, evaluate: false, deadline: deadline)
                guard allowed, Date() < deadline, !isCancelled(), self.revocationGeneration(for: agentId) == generation,
                      self.supervisor.workspaceToolsPermission() == policy,
                      let current = self.liveBrowser(tileId: tileId), current.id == browserId,
                      current.automation.userInputCount == input, self.recordUserBrowserHandOver(tileId: tileId, agentId: agentId) else {
                    box.callback(.error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user has not handed over this browser.")))
                    return
                }
                // The hand-over prompt spent this request's clock; the action gets its own.
                self.dispatchBrowserAction(agentId: agentId, requestId: requestId, operation: operation, payload: payload,
                                           isCancelled: isCancelled, arrived: Date(), completion: { box.callback($0) })
            }
            return
        }
        guard let browser = liveBrowser(tileId: tileId) else {
            if case .navigate(_, .reload, _) = request {
                dispatchBrowserRestart(agentId: agentId, requestId: requestId, payload: payload, arrived: arrived,
                                       isCancelled: isCancelled, completion: completion)
                return
            }
            completion(.error(WorkspaceAPIError(code: .browserNotLive, message: "This browser is not live. Use browser reload to restart it."))); return
        }
        if let surface = canvas.tileView(for: tileId) { browser.automation.trackInputSurface(surface) }
        let handle = Self.ownCheckoutHandle(record)
        seedGrantsIfNeeded(agentId: agentId, checkout: handle)
        dropPolicyGrantsUnlessFree(agentId: agentId)
        let approval = approveBrowserScope(agentId: agentId, record: record, handle: handle, operation: operation, key: suppliedKey)
        if let error = approval.error { completion(.error(error)); return }
        if approval.asked { deadline = Date().addingTimeInterval(timeout) }
        let generation = revocationGeneration(for: agentId)
        let permissionAtArrival = supervisor.workspaceToolsPermission()
        let inputCount = browser.automation.userInputCount
        let browserId = browser.id
        var normalized = payload; normalized["idempotencyKey"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "The browser request cannot be encoded."))); return
        }
        let authorize: BrowserActionQueue.Authorization = { [weak self, weak runtime, weak canvas] in
            guard let self, let runtime, let canvas, self.runtimeProvider() === runtime, self.canvasProvider() === canvas,
                  !isCancelled(), self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.revocationGeneration(for: agentId) == generation,
                  self.supervisor.workspaceToolsPermission() == permissionAtArrival else {
                return WorkspaceAPIError(code: .permissionDenied, message: "Browser access changed.")
            }
            let target = readOnly ? self.browserScopeTarget(tileId: tileId, agentId: agentId) : self.browserControlTarget(tileId: tileId, agentId: agentId)
            if case let .failure(error) = target { return error }
            guard self.liveBrowser(tileId: tileId)?.id == browserId else {
                return WorkspaceAPIError(code: .browserNotLive, message: "This browser is no longer live. Reload it.")
            }
            return nil
        }
        let completionBox = BrowserOpenCompletionBox(completion)
        browserActionQueue.submit(tileId: tileId, agentId: agentId, key: suppliedKey ?? requestId,
            operation: operation.rawValue, payload: String(decoding: data, as: UTF8.self), deadline: deadline,
            inputCount: inputCount, authorizationGeneration: generation, authorizationContext: permissionAtArrival.rawValue, currentInputCount: { [weak self] in
                guard let current = self?.liveBrowser(tileId: tileId), current.id == browserId else { return nil }
                return current.automation.userInputCount
            }, authorize: authorize, action: { [weak self, weak browser] actionDeadline in
                guard let self, let browser else { return .error(WorkspaceAPIError(code: .browserNotLive, message: "The browser is no longer live.")) }
                guard Date() < actionDeadline, browser.automation.userInputCount == inputCount else {
                    return .error(WorkspaceAPIError(code: .targetConflict, message: "The user took control or the request expired. Take a fresh snapshot."))
                }
                let owner = self.canvasProvider()?.tileRecord(for: tileId)?.metadata.browserControllingAgentId
                let agentControls = !readOnly || owner == agentId
                if agentControls { self.installBrowserNavigationGate(browser, agentId: agentId, generation: generation) }
                guard let url = browser.webView.url ?? URL(string: browser.url),
                      await self.browserDomainAllowed(tileId: tileId, agentId: agentId, url: url, deadline: actionDeadline, readOnly: readOnly) else {
                    return .error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The current page was not approved for this agent."))
                }
                if operation == .browserEvaluate && owner == nil {
                    guard await self.askBrowserHandOver(tileId: tileId, agentId: agentId, evaluate: true, deadline: actionDeadline) else {
                        return .error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user has not approved JavaScript in this browser."))
                    }
                }
                if let error = authorize() { return .error(error) }
                guard Date() < actionDeadline, browser.automation.userInputCount == inputCount else {
                    return .error(WorkspaceAPIError(code: .targetConflict, message: "The user took control or the request expired. Take a fresh snapshot."))
                }
                if agentControls {
                    guard self.ensureBrowserLeaseLedger(), self.browserLeaseLedger?.touch(tileId: tileId, owner: agentId, sweepEligible: owner == agentId) == true else {
                        return .error(WorkspaceAPIError(code: .browserNotLive, message: "The browser lease is unavailable. Reload the tile."))
                    }
                }
                if owner == agentId { self.browserUserTakenOver.remove(tileId) }
                var reply = await BrowserActionExecutor.perform(request, runtime: browser, deadline: actionDeadline,
                                                                checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true))
                if operation == .browserScreenshot, case let .result(fields) = reply {
                    guard authorize() == nil, browser.automation.userInputCount == inputCount, Date() < actionDeadline,
                          let encoded = fields["image"]?.object?["data"]?.string else {
                        return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Control changed while capturing the screenshot."))
                    }
                    let root = self.supervisor.browserArtifactRoot
                    let saved = await Task.detached(priority: .utility) {
                        guard let png = Data(base64Encoded: encoded),
                              let file = BrowserArtifactStore.save(root: root, agentId: agentId, png: png) else { return nil as (URL, Data)? }
                        return (file, png)
                    }.value
                    guard let (saved, png) = saved else {
                        return .error(WorkspaceAPIError(code: .durabilityFailed, message: "The screenshot could not be saved to the agent's artifacts."))
                    }
                    await self._afterBrowserScreenshotSaveHook?()
                    guard authorize() == nil, browser.automation.userInputCount == inputCount, Date() < actionDeadline else {
                        await Task.detached(priority: .utility) { BrowserArtifactStore.remove(root: root, agentId: agentId, file: saved) }.value
                        return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Control changed while saving the screenshot."))
                    }
                    let staged: AgentComposerStoredAttachment
                    do {
                        staged = try await self.supervisor.stageBrowserScreenshot(png, for: agentId)
                    } catch {
                        await Task.detached(priority: .utility) { BrowserArtifactStore.remove(root: root, agentId: agentId, file: saved) }.value
                        return .error(WorkspaceAPIError(code: .durabilityFailed, message: "The screenshot could not be added to the transcript."))
                    }
                    await self._afterBrowserScreenshotImportHook?()
                    guard authorize() == nil, browser.automation.userInputCount == inputCount, Date() < actionDeadline else {
                        try? await self.supervisor.discardBrowserScreenshot(staged.manifest.id, for: agentId)
                        await Task.detached(priority: .utility) { BrowserArtifactStore.remove(root: root, agentId: agentId, file: saved) }.value
                        return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Control changed while preparing the screenshot."))
                    }
                    do {
                        try self.supervisor.publishBrowserScreenshot(staged.manifest.metadata, for: agentId)
                    } catch {
                        try? await self.supervisor.discardBrowserScreenshot(staged.manifest.id, for: agentId)
                        await Task.detached(priority: .utility) { BrowserArtifactStore.remove(root: root, agentId: agentId, file: saved) }.value
                        return .error(WorkspaceAPIError(code: .durabilityFailed, message: "The screenshot could not be added to the transcript."))
                    }
                    await self.supervisor.commitBrowserScreenshot(staged.manifest.id, for: agentId)
                    var withArtifact = fields
                    withArtifact["screenshotPath"] = AnyHashableJSON(any: saved.path)
                    reply = .result(withArtifact)
                }
                if operation == .browserNavigate, case .result = reply {
                    if authorize() != nil || browser.automation.userInputCount != inputCount {
                        reply = .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Control changed while navigating. Take a fresh snapshot."))
                    } else if let canvas = self.canvasProvider(), let projectId = record.projectId ?? self.knownCheckouts()[handle]?.projectId,
                              let controller = self.runtimeProvider()?.controller(for: projectId),
                              canvas.setBrowserURL(browser.url, tileId: tileId) {
                        controller.scheduleCanvasSave()
                        do { try controller.flushCanvasSave() }
                        catch { reply = .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The page loaded but its URL could not be saved. Re-query before retrying.")) }
                    } else {
                        reply = .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The page loaded but its tile could not be updated. Re-query before retrying."))
                    }
                }
                let status: String
                switch reply { case .result: status = "ok"; case .error(let error): status = "error:\(error.code.rawValue)"; case .cancelled: status = "cancelled" }
                self.remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: operation, outcome: status, tileId: tileId))
                return reply
            }, completion: { reply in completionBox.callback(reply) })
    }

    /// An explicit reload is the only tool that may replace a dead runtime.
    /// The replacement starts without restoring navigation, then receives its
    /// policy gate before it loads the saved URL.
    private func dispatchBrowserRestart(agentId: AgentID, requestId: String, payload: [String: Any], arrived: Date,
                                        isCancelled: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              case let .navigate(tileId, .reload, suppliedKey)? = try? BrowserToolRequest.decode(operation: WorkspaceAPIOp.browserNavigate.rawValue, data: data),
              let record = supervisor.records[agentId], record.workspaceToolsEnabled,
              let runtime = runtimeProvider(), let canvas = canvasProvider(),
              let projectId = record.projectId ?? knownCheckouts()[Self.ownCheckoutHandle(record)]?.projectId,
              browserRuntimeWiring != nil else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "Browser restart is unavailable."))); return
        }
        if case let .failure(error) = browserControlTarget(tileId: tileId, agentId: agentId) { completion(.error(error)); return }
        let handle = Self.ownCheckoutHandle(record)
        seedGrantsIfNeeded(agentId: agentId, checkout: handle)
        dropPolicyGrantsUnlessFree(agentId: agentId)
        let approval = approveBrowserScope(agentId: agentId, record: record, handle: handle, operation: .browserNavigate, key: suppliedKey)
        if let error = approval.error { completion(.error(error)); return }
        let generation = revocationGeneration(for: agentId)
        let policy = supervisor.workspaceToolsPermission()
        let deadline = (approval.asked ? Date() : arrived).addingTimeInterval(15)
        var normalized = payload; normalized["idempotencyKey"] = nil
        guard let normalizedData = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "The browser request cannot be encoded."))); return
        }
        let authorize: BrowserActionQueue.Authorization = { [weak self, weak runtime, weak canvas] in
            guard let self, let runtime, let canvas, self.runtimeProvider() === runtime, self.canvasProvider() === canvas,
                  !isCancelled(), self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.revocationGeneration(for: agentId) == generation, self.supervisor.workspaceToolsPermission() == policy else {
                return WorkspaceAPIError(code: .permissionDenied, message: "Browser access changed.")
            }
            if case let .failure(error) = self.browserControlTarget(tileId: tileId, agentId: agentId) { return error }
            return nil
        }
        let box = BrowserOpenCompletionBox(completion)
        browserActionQueue.submit(tileId: tileId, agentId: agentId, key: suppliedKey ?? requestId,
            operation: WorkspaceAPIOp.browserNavigate.rawValue, payload: String(decoding: normalizedData, as: UTF8.self),
            deadline: deadline, inputCount: 0, authorizationGeneration: generation, authorizationContext: policy.rawValue,
            currentInputCount: { [weak self] in self?.liveBrowser(tileId: tileId)?.automation.userInputCount ?? 0 },
            authorize: authorize, action: { [weak self, weak runtime, weak canvas] actionDeadline in
                guard let self, let runtime, let canvas else { return .error(WorkspaceAPIError(code: .permissionDenied, message: "The workspace is unavailable.")) }
                self._beforeCommitHook?()
                if let error = authorize() { return .error(error) }
                guard Date() < actionDeadline, self.liveBrowser(tileId: tileId) == nil else {
                    return .error(WorkspaceAPIError(code: .busy, message: "The browser was restarted or the request expired. Re-query before retrying."))
                }
                guard self.ensureBrowserLeaseLedger(), let controller = runtime.controller(for: projectId) else {
                    return .error(WorkspaceAPIError(code: .unsupported, message: "The browser project is unavailable."))
                }
                let spawner: TileSpawner
                do { spawner = try runtime.ensureSpawner(forProjectId: projectId) }
                catch { return .error(WorkspaceAPIError(code: .unsupported, message: "The browser project is unavailable.")) }
                controller.browserRuntimes.removeAll { $0.tileId == tileId && $0.isTerminated }
                guard case let .restarted(browser) = spawner.restartBrowserTile(tileId: tileId, deferNavigation: true) else {
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser could not be restarted. Re-query before retrying."))
                }
                self.browserRuntimeWiring?(browser, projectId)
                guard self.browserLeaseLedger?.touch(tileId: tileId, owner: agentId, sweepEligible: true) == true else {
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted but could not be protected. Re-query before retrying."))
                }
                self.browserUserTakenOver.remove(tileId)
                self.installBrowserNavigationGate(browser, agentId: agentId, generation: generation)
                if let surface = canvas.tileView(for: tileId) { browser.automation.trackInputSurface(surface) }
                runtime.enforceBrowserRuntimeBudget()
                let savedURL = browser.url
                guard let url = URL(string: savedURL),
                      BrowserAgentNavigationPolicy.classify(url, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)) != .denied else {
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted, but its saved destination is not allowed. Take a fresh snapshot."))
                }
                let reply = await BrowserActionExecutor.perform(.navigate(tile: tileId, destination: .url(savedURL), key: nil), runtime: browser,
                    deadline: actionDeadline, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true))
                if let error = authorize() { return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted, but access changed: \(error.message)")) }
                guard browser.automation.userInputCount == 0 else {
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted, but the user took control. Take a fresh snapshot."))
                }
                switch reply {
                case .result(var fields):
                    guard canvas.setBrowserURL(browser.url, tileId: tileId) else {
                        return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted but its tile could not be updated."))
                    }
                    controller.scheduleCanvasSave()
                    do { try controller.flushCanvasSave() }
                    catch { return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted but its URL could not be saved.")) }
                    fields["tileId"] = AnyHashableJSON(any: tileId.uuidString)
                    self.remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .browserNavigate, outcome: "ok", tileId: tileId))
                    return .result(fields)
                case .error(let error):
                    self.remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .browserNavigate, outcome: "partial", tileId: tileId))
                    return .result(["tileId": AnyHashableJSON(any: tileId.uuidString), "partial": AnyHashableJSON(any: true),
                                    "navigationError": AnyHashableJSON(any: ["code": error.code.rawValue, "message": error.message])])
                case .cancelled:
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser restarted but navigation was cancelled."))
                }
            }, completion: { box.callback($0) })
    }

    /// Open next to the caller, then load the requested destination under the
    /// same navigation policy used for later actions.
    func dispatchBrowserOpen(agentId: AgentID, requestId: String, payload: [String: Any],
                             isCancelled: @escaping () -> Bool, completion: @escaping (Reply) -> Void) {
        var deadline = Date().addingTimeInterval(15)
        let request: BrowserToolRequest
        do { request = try BrowserToolRequest.decode(operation: WorkspaceAPIOp.browserOpen.rawValue,
                                                     data: JSONSerialization.data(withJSONObject: payload)) }
        catch { completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "Invalid browser open request."))); return }
        guard case let .open(url, suppliedKey) = request else {
            completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "Invalid browser open request."))); return
        }
        guard let record = supervisor.records[agentId], record.workspaceToolsEnabled,
              let runtime = runtimeProvider(), let canvas = canvasProvider(),
              let anchor = record.tileId, let projectId = record.projectId ?? knownCheckouts()[Self.ownCheckoutHandle(record)]?.projectId,
              let zone = canvas.installedZoneIds(containing: anchor).only,
              canvas.projectId(forZone: zone) == projectId,
              runtime.document.zones.contains(where: { $0.zoneId == zone && $0.projectId == projectId }),
              browserRuntimeWiring != nil else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "The agent's project and installed tile are required to open a browser."))); return
        }
        guard let destination = URL(string: url),
              BrowserAgentNavigationPolicy.classify(destination, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)) != .denied else {
            completion(.error(WorkspaceAPIError(code: .permissionDenied, message: "That browser destination is not allowed."))); return
        }
        let handle = Self.ownCheckoutHandle(record)
        seedGrantsIfNeeded(agentId: agentId, checkout: handle)
        dropPolicyGrantsUnlessFree(agentId: agentId)
        let approval = approveBrowserScope(agentId: agentId, record: record, handle: handle, operation: .browserOpen, key: suppliedKey)
        if let error = approval.error { completion(.error(error)); return }
        if approval.asked { deadline = Date().addingTimeInterval(15) }
        let generation = revocationGeneration(for: agentId)
        let permissionAtArrival = supervisor.workspaceToolsPermission()
        var normalized = payload
        normalized["idempotencyKey"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "The browser request cannot be encoded."))); return
        }
        let key = suppliedKey ?? requestId
        let completionBox = BrowserOpenCompletionBox(completion)
        browserActionQueue.submit(tileId: anchor, agentId: agentId, key: key, operation: WorkspaceAPIOp.browserOpen.rawValue,
                                  payload: String(decoding: data, as: UTF8.self), deadline: deadline, inputCount: 0, authorizationGeneration: generation, authorizationContext: permissionAtArrival.rawValue,
                                  currentInputCount: { 0 }, authorize: { [weak self, weak runtime, weak canvas] in
            guard let self, let runtime, let canvas, self.runtimeProvider() === runtime, self.canvasProvider() === canvas,
                  !isCancelled(), self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.revocationGeneration(for: agentId) == generation,
                  self.supervisor.workspaceToolsPermission() == permissionAtArrival,
                  canvas.installedZoneIds(containing: anchor) == [zone], canvas.projectId(forZone: zone) == projectId else {
                return WorkspaceAPIError(code: .permissionDenied, message: "Browser access or the agent's project changed.")
            }
            return nil
        }, action: { [weak self, weak runtime, weak canvas] actionDeadline in
            guard let self, let runtime, let canvas else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "The workspace is no longer mounted."))
            }
            self._beforeCommitHook?()
            guard actionDeadline > Date() else {
                return .error(WorkspaceAPIError(code: .busy, message: "The browser request expired before opening. Try again."))
            }
            guard !isCancelled(), self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.revocationGeneration(for: agentId) == generation,
                  self.supervisor.workspaceToolsPermission() == permissionAtArrival,
                  canvas.installedZoneIds(containing: anchor) == [zone], canvas.projectId(forZone: zone) == projectId else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Browser access changed before opening."))
            }
            guard let reservation = await self.browserOpenAdmission.acquire(deadline: actionDeadline) else {
                return .error(WorkspaceAPIError(code: .busy, message: "The browser request expired while waiting for an opening slot."))
            }
            var holdsReservation = true
            defer { if holdsReservation { self.browserOpenAdmission.release(reservation) } }
            guard let registryStore = self.registryStoreProvider(), let registry = try? registryStore.loadOrEmpty() else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "Browser limits cannot be checked while the project registry is unavailable."))
            }
            let roots = Set(registry.projects.filter { !$0.missing }.map { CheckoutHandle.canonicalRoot($0.rootPath) }
                + self.supervisor.records.values.compactMap { $0.projectRoot }.map(CheckoutHandle.canonicalRoot))
            let liveTiles = canvas.allWorkspaceTiles()
            let revisionBeforeInventory = runtime.structuralRevision
            let inventory = await Task.detached(priority: .utility) {
                scanAgentBrowserInventory(roots: Array(roots), liveTiles: liveTiles)
            }.value
            await self._browserInventoryReadHook?()
            guard let inventory else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "Browser limits cannot be checked because a project canvas is unreadable."))
            }
            guard self.browserOpenAdmission.owns(reservation), !isCancelled(), Date() < actionDeadline,
                  self.revocationGeneration(for: agentId) == generation,
                  self.supervisor.workspaceToolsPermission() == permissionAtArrival,
                  self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.runtimeProvider() === runtime, self.canvasProvider() === canvas,
                  runtime.structuralRevision == revisionBeforeInventory,
                  canvas.installedZoneIds(containing: anchor) == [zone], canvas.projectId(forZone: zone) == projectId else {
                return .error(WorkspaceAPIError(code: .busy, message: "The workspace changed while checking browser limits. Try again."))
            }
            guard inventory.count < 12, inventory.values.filter({ $0 == agentId }).count < 4 else {
                return .error(WorkspaceAPIError(code: .busy, message: "The agent browser limit is reached. Close an agent browser before opening another."))
            }
            guard self.ensureBrowserLeaseLedger() else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "Browser residency is unavailable."))
            }
            let spawner: TileSpawner
            do { spawner = try runtime.ensureSpawner(forProjectId: projectId) }
            catch { return .error(WorkspaceAPIError(code: .unsupported, message: "The browser project is unavailable.")) }
            guard case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: agentId,
                                                                           anchorTileId: anchor, targetZoneId: zone) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "The browser could not be opened in the agent's zone."))
            }
            self.browserRuntimeWiring?(browser, projectId)
            guard self.browserLeaseLedger?.touch(tileId: browser.tileId, owner: agentId, sweepEligible: true) == true else {
                return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser opened but its residency could not be protected. Re-query before retrying."))
            }
            self.installBrowserNavigationGate(browser, agentId: agentId, generation: generation)
            if let surface = canvas.tileView(for: browser.tileId) { browser.automation.trackInputSurface(surface) }
            runtime.enforceBrowserRuntimeBudget()
            self.browserOpenAdmission.release(reservation)
            holdsReservation = false
            var result: [String: AnyHashableJSON] = ["operationId": AnyHashableJSON(any: requestId),
                "tileId": AnyHashableJSON(any: browser.tileId.uuidString), "url": AnyHashableJSON(any: "about:blank")]
            var outcome = "ok"
            if url != "about:blank" {
                let inputCount = browser.automation.userInputCount
                browser.agentNavigationAdmission = { !isCancelled() }
                let navigation = await BrowserActionExecutor.perform(.navigate(tile: browser.tileId, destination: .url(url), key: nil),
                    runtime: browser, deadline: actionDeadline, checkoutRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true))
                browser.agentNavigationAdmission = nil
                guard !isCancelled(), self.revocationGeneration(for: agentId) == generation,
                      self.supervisor.workspaceToolsPermission() == permissionAtArrival,
                      self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                      browser.automation.userInputCount == inputCount else {
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "The browser opened but control changed during navigation. Re-query before retrying."))
                }
                switch navigation {
                case .result:
                    if canvas.setBrowserURL(browser.url, tileId: browser.tileId), let controller = runtime.controller(for: projectId) {
                        controller.scheduleCanvasSave()
                        do { try controller.flushCanvasSave(); result["url"] = AnyHashableJSON(any: browser.url) }
                        catch { outcome = "partial"; result["navigationError"] = AnyHashableJSON(any: "The page loaded but its URL could not be saved.") }
                    } else { outcome = "partial"; result["navigationError"] = AnyHashableJSON(any: "The page loaded but its tile could not be updated.") }
                case .error(let error):
                    outcome = "partial"
                    result["navigationError"] = AnyHashableJSON(any: ["code": error.code.rawValue, "message": error.message])
                case .cancelled:
                    outcome = "partial"
                    result["navigationError"] = AnyHashableJSON(any: "Navigation was cancelled.")
                }
            }
            if outcome == "partial" { result["partial"] = AnyHashableJSON(any: true) }
            self.remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .browserOpen,
                                                                     outcome: outcome, tileId: browser.tileId))
            return .result(result)
        }, completion: { reply in completionBox.callback(reply) })
    }

}


private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

@MainActor
private final class BrowserOpenCompletionBox {
    let callback: (WorkspaceAPIService.Reply) -> Void
    init(_ callback: @escaping (WorkspaceAPIService.Reply) -> Void) { self.callback = callback }
}

@MainActor
private final class BrowserDomainWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    /// True when this call settled the wait, false when it was already settled.
    @discardableResult
    func resolve(_ result: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: result)
        return true
    }
}

/// Read only: never invoke ProjectStore's backup recovery while counting tiles.
/// A corrupt or unreadable canvas fails closed rather than being treated as empty.
private func scanAgentBrowserInventory(roots: [String], liveTiles: [Tile]) -> [UUID: AgentID]? {
    var owners: [UUID: AgentID] = [:]
    var origins: [UUID: String] = [:]
    for root in roots {
        let path = ProjectStoreLayout(projectRoot: URL(fileURLWithPath: root, isDirectory: true)).canvasFile
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError) { continue }
            return nil
        }
        guard let canvas = try? JSONCodec.makeCanvasDecoder().decode(CanvasState.self, from: data),
              canvas.schemaVersion <= CanvasState.currentSchemaVersion else { return nil }
        for tile in canvas.tiles where tile.kind == .browser {
            guard let owner = tile.metadata.browserOwnerAgentId else { continue }
            if let previousRoot = origins[tile.id], previousRoot != root { return nil }
            if let previousOwner = owners[tile.id], previousOwner != owner { return nil }
            origins[tile.id] = root
            owners[tile.id] = owner
        }
    }
    for tile in liveTiles where tile.kind == .browser {
        guard let owner = tile.metadata.browserOwnerAgentId else { continue }
        if let previousOwner = owners[tile.id], previousOwner != owner { return nil }
        owners[tile.id] = owner
    }
    return owners
}
