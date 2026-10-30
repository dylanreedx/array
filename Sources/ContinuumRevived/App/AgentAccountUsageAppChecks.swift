import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// .plans/101 slice 1 — live limits and identity, through production.
///
/// A real `AgentSupervisor` with real records and real attached tiles; only the
/// CLI read is a fixture (`accountUsageReader`), because no check may ask a real
/// login. What it pins:
///
/// - attaching a tile asks for the account's limits with no turn, ONCE per
///   harness however many tiles attach, and the answer reaches the row: its
///   account presentation (drawn in the hover card) names the plan, the pills
///   say what is left;
/// - a newer read waits out its interval and never overlaps one in flight;
/// - a read that names no login (timeout or sign-out) changes nothing;
/// - a different login replaces the account and drops the old login's windows;
/// - pi is never asked and shows no account;
/// - with the live gate off, the production reader spawns nothing.
@MainActor
func runAgentAccountUsageAppChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }

    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [AgentHarness] = []
        private var next: [AgentHarness: AgentAccountUsageProbe.Reading?] = [:]
        private var gate: DispatchSemaphore?
        func set(_ harness: AgentHarness, _ reading: AgentAccountUsageProbe.Reading?) {
            lock.withLock { next[harness] = .some(reading) }
        }
        func hold() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
        func release() {
            let held = lock.withLock { () -> DispatchSemaphore? in defer { gate = nil }; return gate }
            held?.signal()
        }
        var callLog: [AgentHarness] { lock.withLock { calls } }
        func read(_ harness: AgentHarness) -> AgentAccountUsageProbe.Reading? {
            let (reading, gate) = lock.withLock { () -> (AgentAccountUsageProbe.Reading?, DispatchSemaphore?) in
                calls.append(harness)
                return ((next[harness] ?? nil), self.gate)
            }
            gate?.wait()
            return reading
        }
    }

    let now = Date()
    func identity(_ email: String, org: String, plan: String) -> AgentAccountIdentity {
        AgentAccountIdentity(harness: .claudeCode, email: email, organizationId: org, plan: plan, observedAt: now)
    }
    func quota(_ fiveHour: Double, _ weekly: Double) -> AgentAccountQuotaSnapshot {
        AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: [
                AgentQuotaWindow(kind: .fiveHour, utilization: fiveHour, resetsAt: now.addingTimeInterval(7_200)),
                AgentQuotaWindow(kind: .sevenDay, utilization: weekly, resetsAt: now.addingTimeInterval(500_000)),
            ],
            observedAt: now, source: .claudeUsageRequest)
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("account-usage-app-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    // The production reader, gate never enabled in a check process: it must
    // answer nil without spawning anything.
    let gated = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("gated")))
    try require(gated.accountUsageReader(.claudeCode) == nil && gated.accountUsageReader(.codex) == nil,
                "with the live gate off the production reader must read nothing")

    let reader = Reader()
    reader.set(.claudeCode, .init(identity: identity("personal@example.com", org: "org-personal", plan: "max"),
                                  quota: quota(0.11, 0.14)))
    let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("store")))
    defer { supervisor.stopAll() }
    supervisor.accountUsageReader = { reader.read($0) }

    func attachTile(harness: AgentHarness) -> (AgentID, ManagedAgentTileNSView) {
        let tileID = UUID()
        let config = AgentModelConfig.resolvedFromDefaults(harness: harness)
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: harness,
                                  model: config.model, thinking: config.thinking, tileId: tileID)
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "account-usage-check",
            frame: TileFrame(x: 0, y: 0, width: 900, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: root.appendingPathComponent("drafts-\(tileID.uuidString)"),
                debounceInterval: 60),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        return (id, tile)
    }
    /// The account the row holds for its hover card, e.g. `Claude · Max`.
    func account(_ tile: ManagedAgentTileNSView) -> String? {
        tile.qaCompactStatusRow.qaAccountPresentation?.card.title
    }
    func facts(_ tile: ManagedAgentTileNSView) -> String {
        let row = tile.qaCompactStatusRow
        return "account \(String(describing: account(tile))) 5h '\(row.qaQuotaText(.quotaFiveHour))' 7d '\(row.qaQuotaText(.quotaSevenDay))' reads \(reader.callLog)"
    }

    // (1) Attach asks once, with no turn, and the row names the account.
    let (firstID, first) = attachTile(harness: .claudeCode)
    try await expectEventually("attaching must read the account and paint it: \(facts(first))") {
        account(first) == "Claude · Max"
            && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 89%"
            && first.qaCompactStatusRow.qaQuotaText(.quotaSevenDay) == "7d 86%"
    }
    try require(supervisor.accountIdentity(for: firstID)?.email == "personal@example.com",
                "the supervisor must hold the login it read")
    let (_, second) = attachTile(harness: .claudeCode)
    try await expectEventually("a second tile on the same login must show the same account: \(facts(second))") {
        account(second) == "Claude · Max"
    }
    try require(reader.callLog == [.claudeCode],
                "two tiles on one login must cause ONE read, got \(reader.callLog)")

    // (2) Pi is never asked and shows no account.
    let (_, piTile) = attachTile(harness: .pi)
    try await Task.sleep(for: .milliseconds(100))
    try require(!reader.callLog.contains(.pi) && account(piTile) == nil,
                "pi reports no account and must not be asked: \(facts(piTile))")

    // (3) Throttle and in-flight: inside the interval nothing; past it one
    // read, and a second request while it is out does not start another.
    try require(!supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 30),
                "a read inside its interval must not start")
    reader.hold()
    reader.set(.claudeCode, .init(identity: identity("personal@example.com", org: "org-personal", plan: "max"),
                                  quota: quota(0.94, 0.20)))
    try require(supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 30, now: now.addingTimeInterval(31)),
                "a read past its interval must start")
    try require(!supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 0, now: now.addingTimeInterval(62)),
                "a read must never overlap one still in flight")
    reader.release()
    try await expectEventually("the newer reading must reach every tile on the login: \(facts(second))") {
        second.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 6%"
            && second.qaCompactStatusRow.qaQuotaState(.quotaFiveHour) == .critical
    }
    try require(reader.callLog.filter { $0 == .claudeCode }.count == 2,
                "exactly two reads so far, got \(reader.callLog)")

    // (4) A read that names no login changes nothing.
    reader.set(.claudeCode, .init(identity: nil, quota: nil))
    supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 0, now: now.addingTimeInterval(120))
    try await expectEventually("the third read must run and finish") {
        reader.callLog.count == 3 && supervisor.qaAccountUsageInFlight.isEmpty
    }
    try require(account(first) == "Claude · Max"
                    && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour) == "5h 6%",
                "a timeout or sign-out must not blank a real reading: \(facts(first))")

    // (5) A different login replaces the account and drops the old windows.
    reader.set(.claudeCode, .init(identity: identity("work@example.com", org: "org-team", plan: "team"), quota: nil))
    supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 0, now: now.addingTimeInterval(180))
    try await expectEventually("a changed login must replace the account and its windows: \(facts(first))") {
        account(first) == "Claude · Team"
            && first.qaCompactStatusRow.qaQuotaText(.quotaFiveHour).isEmpty
    }
    try require(supervisor.accountIdentity(for: firstID)?.email == "work@example.com",
                "the supervisor must hold the new login")

    print("AgentAccountUsageAppChecks passed: attach reads the account once per login with no turn and the row names it (Max, 5h 89%, 7d 86% left); throttle and in-flight guards hold; a read naming no login changes nothing; a new login replaces the account and drops the old windows; pi is never asked; the gated production reader spawns nothing")
}

/// Review captures of the row and its account card, light and dark, normal and
/// near a limit — the four frames of the approved mockup, drawn by the real
/// views. Written only when `CONTINUUM_ACCOUNT_USAGE_CAPTURE_DIR` is set; no
/// gate reads them.
@MainActor
func captureAccountUsageForReview(to directory: URL) throws {
    final class TileBody: NSView {
        override func draw(_ dirtyRect: NSRect) {
            SurfaceToken.tileBody.color.nsColor(in: self).setFill()
            bounds.fill()
        }
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let checkout = URL(fileURLWithPath: "/Users/qa/Projects/array", isDirectory: true)
    let location = AgentLocationSnapshot(
        home: AgentHome(projectId: nil, projectRoot: checkout, checkoutRoot: checkout),
        whereDirectory: checkout)
    let identity = AgentAccountIdentity(
        harness: .claudeCode, email: "personal@example.com", plan: "max", observedAt: now)
    let cases: [(String, Double, Double)] = [("normal", 0.16, 0.07), ("near-limit", 0.94, 0.19)]
    for (name, fiveHour, weekly) in cases {
        let quota = AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: [
                AgentQuotaWindow(kind: .fiveHour, utilization: fiveHour, resetsAt: now.addingTimeInterval(8_220)),
                AgentQuotaWindow(kind: .sevenDay, utilization: weekly, resetsAt: now.addingTimeInterval(540_000)),
            ],
            observedAt: now.addingTimeInterval(-60), source: .claudeUsageRequest)
        let context = AgentContextWindowSnapshot(
            usedTokens: 273_000, maxTokens: 1_000_000, observedAt: now,
            source: .providerSessionStats, freshness: .live)
        let presentation = AgentCompactStatusPresentation.present(
            location: location, projectName: "Array",
            activity: AgentCompactActivityInput(phase: .ready, phaseStartedAt: now),
            now: now, contextWindow: context, accountQuota: quota, accountIdentity: identity,
            enabledElements: [.location, .activity, .contextMeter, .quotaFiveHour, .quotaSevenDay])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: 720, height: 330)
            let probe = try UIProbe.render(
                UIProbe.Spec(id: "account-usage.\(name)", size: size, appearance: appearance)
            ) {
                let body = TileBody(frame: NSRect(origin: .zero, size: size))
                let row = AgentCompactStatusRowView(
                    frame: NSRect(x: 12, y: 12, width: size.width - 24,
                                  height: AgentCompactStatusRowView.preferredHeight))
                row.apply(presentation)
                body.addSubview(row)
                row.layoutSubtreeIfNeeded()
                if let account = presentation.account, let pills = row.qaAccountPillsFrame {
                    let card = AgentAccountUsageCardView(frame: .zero)
                    card.apply(account.card)
                    card.layoutSubtreeIfNeeded()
                    let cardSize = card.intrinsicContentSize
                    let anchor = row.convert(pills, to: body)
                    card.frame = NSRect(
                        x: max(12, min(anchor.midX - cardSize.width / 2, size.width - cardSize.width - 12)),
                        y: anchor.maxY + CGFloat(Space.m), width: cardSize.width, height: cardSize.height)
                    body.addSubview(card)
                }
                return body
            }
            let label = appearance == .darkAqua ? "dark" : "light"
            try probe.hostRep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("account-usage-\(name)-\(label).png"))
        }
    }
}
