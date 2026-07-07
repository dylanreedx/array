import CloudKit
import ContinuumRevivedCore
import ContinuumRevivedSync
import SwiftUI
import UIKit
import UserNotifications

private let continuumCloudKitContainerIdentifier = CompanionSyncConfig.cloudKitContainerIdentifier

@main
struct ContinuumApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var model = AgentsBoardModel()

    var body: some Scene {
        WindowGroup {
            ContinuumRootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task {
                    pushDelegate.model = model
                    await model.start()
                }
        }
    }
}

private final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AgentsBoardModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories())
        center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { granted, error in
            if let error {
                print("notification authorization failed: \(error.localizedDescription)")
            }
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            model?.apnsDeviceToken = token
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            model?.apnsDeviceToken = "registration failed: \(error.localizedDescription)"
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let model else { return }
        let grantedScope = await MainActor.run { model.grantedScope }
        guard let intent = handlePushAction(actionId: response.actionIdentifier, userInfo: userInfo, grantedScope: grantedScope) else {
            return
        }
        do {
            _ = try await model.respondToApproval(tileId: intent.tileId, requestId: intent.requestId, decision: intent.decision)
        } catch {
            print("push approval response failed: \(error.localizedDescription)")
        }
    }

    private static func notificationCategories() -> Set<UNNotificationCategory> {
        Set(PushCategory.allCases.map { category in
            UNNotificationCategory(identifier: category.identifier, actions: notificationActions(for: category), intentIdentifiers: [], options: [])
        })
    }

    private static func notificationActions(for category: PushCategory) -> [UNNotificationAction] {
        switch category {
        case .approvalRequested:
            return [
                UNNotificationAction(identifier: PushCategory.approveActionId, title: PushCategory.approveActionTitle, options: [.authenticationRequired]),
                UNNotificationAction(identifier: PushCategory.denyActionId, title: PushCategory.denyActionTitle, options: [.authenticationRequired])
            ]
        case .agentWaitingForInput:
            return [
                UNNotificationAction(identifier: PushCategory.openActionId, title: PushCategory.openActionTitle, options: [.foreground])
            ]
        case .agentFinished, .agentFailed, .stillWorkingDigest, .desktopConnectionChanged, .deviceSecurityChanged, .sessionReapedOrRevived:
            return []
        }
    }
}

private enum ContinuumTab: Hashable {
    case agents
    case canvas
    case approvals
    case settings
}

private struct ContinuumRootView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @State private var selectedTab: ContinuumTab = .agents

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentsBoardView(selectedTab: $selectedTab)
                .tabItem { Label("Agents", systemImage: "person.2.fill") }
                .tag(ContinuumTab.agents)

            CanvasTabView()
                .tabItem { Label("Canvas", systemImage: "square.grid.2x2") }
                .tag(ContinuumTab.canvas)

            ApprovalsInboxView(selectedTab: $selectedTab)
                .tabItem { Label("Approvals", systemImage: "checkmark.seal") }
                .badge(model.attentionCount)
                .tag(ContinuumTab.approvals)

            SettingsDiagnosticsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(ContinuumTab.settings)
        }
        .tint(.orange)
    }
}

@MainActor
private final class AgentsBoardModel: ObservableObject {
    private static let approvalAckTimeout: Duration = .seconds(5)

    enum State: Equatable {
        case loading
        case unpaired
        case unavailable(String)
        case live
    }

    @Published var state: State = .loading
    @Published private(set) var pairedSessionState: PairedCompanionSessionState = .unpaired
    @Published var snapshot: ActivityLogSnapshot = .empty
    @Published var rows: [AgentsBoardRow] = []
    @Published var lastApprovalAck: ApprovalResponseAck?
    @Published var apnsDeviceToken: String?
    @Published var freshnessNow = Date()

    // Ticket: docs/38-tickets/61b-canvas-editor.md
    @Published var canvasScene: CanvasScene = CanvasScene(zones: [], tiles: [])
    @Published var canvasFocusRequest: UUID?
    @Published var canvasHighlightedTileId: UUID?
    @Published var canvasEditError: String?
    @Published var canvasFocusError: String?
    @Published private var transportAvailability: CompanionTransportAvailability = .connecting
    @Published private var latestActivityFreshness: CompanionFreshnessSample?
    @Published private var latestSpatialFreshness: CompanionFreshnessSample?
    var grantedScope: Scope {
        let storedScope = CompanionUICapability(state: pairedSessionState).scope
        #if DEBUG
        if scopeOverrideActive {
            return .operator
        }
        #endif
        return storedScope
    }

    var scopeOverrideActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CONTINUUM_SCOPE_OVERRIDE"] == "operator"
        #else
        false
        #endif
    }

    private var task: Task<Void, Never>?
    private var receiver: ActivityProjectionReceiver?
    private var spatialReceiver: SpatialOpReceiver?
    private var spatialTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var demux: SyncMessageDemux?
    private var freshnessSequence: Int64 = 0
    private let pairedSessionStore: any PairedCompanionSessionStoring = KeychainPairedCompanionSessionStore()

    var freshness: CompanionFreshness {
        CompanionFreshness.derive(
            CompanionFreshnessInput(
                sessionState: pairedSessionState,
                spatialSnapshot: latestSpatialFreshness,
                activitySnapshot: latestActivityFreshness,
                transportAvailability: transportAvailability,
                now: freshnessNow
            )
        )
    }

    var hasCachedAgentData: Bool { !rows.isEmpty }
    var hasCachedCanvasData: Bool { !canvasScene.zones.isEmpty || !canvasScene.tiles.isEmpty }
    var canMutateFromFreshness: Bool { freshness.allowsMutations }
    var canvasFreshnessDisplay: CanvasMirrorFreshnessDisplay {
        CanvasMirrorPresentation.freshnessDisplay(
            freshness: freshness,
            hasCanvasData: hasCachedCanvasData,
            spatialSample: latestSpatialFreshness,
            activitySample: latestActivityFreshness,
            now: freshnessNow
        )
    }
    var canvasStatusOverlays: [UUID: CanvasMirrorTileStatus] {
        CanvasMirrorPresentation.statusOverlays(scene: canvasScene, rows: rows)
    }
    var isFreshnessLive: Bool {
        if case .live = freshness.state { return true }
        return false
    }

    func start() async {
        guard task == nil else { return }
        state = .loading
        transportAvailability = .connecting
        startFreshnessTicker()
        pairedSessionState = pairedSessionStore.loadState()
        let capability = CompanionUICapability(state: pairedSessionState)
        guard capability.canStartTransport else {
            state = .unpaired
            return
        }

        let container = CKContainer(identifier: continuumCloudKitContainerIdentifier)
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                transportAvailability = .accountUnavailable
                state = .unavailable("Sign in to iCloud in Settings to observe your agents")
                return
            }
        } catch {
            transportAvailability = .accountUnavailable
            state = .unavailable("Sign in to iCloud in Settings to observe your agents")
            return
        }
        transportAvailability = .available

        let transport = CloudKitSyncTransport(containerIdentifier: continuumCloudKitContainerIdentifier)
        // ONE transport, ONE demux — the spatial receiver below is a second
        // independent subscriber over the SAME demux the activity receiver
        // uses (ticket 61b banner (c).7), never a second transport.
        let demux = SyncMessageDemux(transport: transport)
        self.demux = demux

        let receiver = ActivityProjectionReceiver(demux: demux, scope: capability.scope)
        self.receiver = receiver
        task = Task { [weak self] in
            await receiver.connect(cursor: nil)
            let stream = await receiver.subscribe()
            for await item in stream {
                await self?.consume(item)
            }
        }

        let spatial = SpatialOpReceiver(demux: demux)
        self.spatialReceiver = spatial
        spatialTask = Task { [weak self] in
            await spatial.connect()
            let stream = await spatial.subscribe()
            for await materialized in stream {
                await self?.consumeSpatial(materialized)
            }
        }
    }

    func activity(for tileId: UUID) -> TileActivity? {
        snapshot.byTile[tileId]
    }

    var approvalRows: [AgentsBoardRow] {
        AgentsBoardProjection.approvalsInboxRows(from: snapshot)
    }

    var attentionCount: Int {
        AgentsBoardProjection.attentionCount(from: snapshot)
    }

    func respondToApproval(tileId: UUID, requestId: String, decision: ApprovalDecision) async throws -> ApprovalResponseOutcome {
        guard canMutateFromFreshness else {
            throw ApprovalSendError.freshnessBlocked(freshness.actionBlocker ?? "Reconnect to act")
        }
        guard let demux else {
            throw ApprovalSendError.unavailable
        }
        let stream = await demux.subscribe()
        let ackTask = Task<ApprovalResponseOutcome, Error> {
            for await message in stream {
                guard case .approvalResponseAck(let ack) = message, ack.requestId == requestId else { continue }
                await MainActor.run { self.lastApprovalAck = ack }
                return ack.outcome
            }
            throw ApprovalSendError.unavailable
        }
        defer { ackTask.cancel() }
        do {
            try await demux.send(.approvalResponse(ApprovalResponseRequest(tileId: tileId, requestId: requestId, decision: decision)))
            return try await withThrowingTaskGroup(of: ApprovalResponseOutcome.self) { group in
                group.addTask {
                    try await ackTask.value
                }
                group.addTask {
                    try await Task.sleep(for: Self.approvalAckTimeout)
                    throw ApprovalSendError.ackTimedOut
                }
                guard let outcome = try await group.next() else {
                    throw ApprovalSendError.unavailable
                }
                group.cancelAll()
                return outcome
            }
        } catch {
            ackTask.cancel()
            throw error
        }
    }

    private func consume(_ item: ActivityStreamItem) {
        switch item {
        case .snapshot(let incoming):
            snapshot = incoming
        case .event(let event):
            snapshot = AgentsBoardProjection.applyEvent(event, to: snapshot)
        }
        rows = AgentsBoardProjection.rows(from: snapshot)
        latestActivityFreshness = syntheticFreshnessSample(
            spatialWatermark: nil,
            activityWatermark: "activity-\(snapshot.snapshotSequence)"
        )
        state = .live
    }

    private func consumeSpatial(_ materialized: MaterializedState) {
        canvasScene = CanvasSceneProjection.scene(canvasState: materialized.canvasState, workspaceDocument: materialized.workspaceDocument)
        latestSpatialFreshness = syntheticFreshnessSample(
            spatialWatermark: "spatial-v\(materialized.canvasState.schemaVersion)-t\(materialized.canvasState.tiles.count)-z\(materialized.workspaceDocument.zones.count)",
            activityWatermark: nil
        )
    }

    /// "Show on canvas" centers/highlights the tile when the canvas already
    /// has it; otherwise the caller still switches tabs and the canvas shows
    /// an explicit not-synced-yet message instead of failing silently.
    func requestCanvasFocus(tileId: UUID) {
        guard canvasScene.tiles.contains(where: { $0.tileId == tileId }) else {
            canvasFocusError = "Tile not synced to canvas yet"
            return
        }
        canvasFocusError = nil
        canvasFocusRequest = tileId
    }

    /// Emits one op per gesture end. On failure the receiver has already
    /// reverted its optimistic local apply (fanned back through
    /// `consumeSpatial`, so `canvasScene` snaps back automatically) — this
    /// only surfaces a non-blocking error.
    func emitCanvasOp(_ op: Op) async {
        guard canMutateFromFreshness else {
            canvasEditError = freshness.actionBlocker ?? "Reconnect to act"
            return
        }
        guard let spatialReceiver else { return }
        do {
            try await spatialReceiver.emit(op)
        } catch {
            canvasEditError = "Couldn't sync your change — it was reverted."
        }
    }

    /// Sends an ordered op list from a single gesture end (e.g. a drag-drop's
    /// move + membership change) via `SpatialOpReceiver.emitAll`, which stops
    /// at the first failure — surfaces the same non-blocking error `emitCanvasOp`
    /// does, never emits a membership change after a failed move.
    func emitCanvasOps(_ ops: [Op]) async {
        guard canMutateFromFreshness else {
            canvasEditError = freshness.actionBlocker ?? "Reconnect to act"
            return
        }
        guard let spatialReceiver else { return }
        do {
            try await spatialReceiver.emitAll(ops)
        } catch {
            canvasEditError = "Couldn't sync your change — it was reverted."
        }
    }

    private func startFreshnessTicker() {
        guard freshnessTask == nil else { return }
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await MainActor.run {
                    self?.freshnessNow = Date()
                }
            }
        }
    }

    private func syntheticFreshnessSample(spatialWatermark: String?, activityWatermark: String?) -> CompanionFreshnessSample {
        freshnessSequence += 1
        let receivedAt = Date()
        freshnessNow = receivedAt
        let instanceId: UUID
        if case .paired(let session) = pairedSessionState {
            instanceId = session.instanceId
        } else {
            instanceId = UUID(uuidString: "00000000-0000-4000-8000-000000000080")!
        }
        return CompanionFreshnessSample(
            metadata: CompanionFreshnessMetadata(
                instanceId: instanceId,
                desktopReplicaId: "cloudkit-receiver",
                bootId: "ios-session",
                sequence: freshnessSequence,
                publishedAt: receivedAt,
                receivedAt: receivedAt,
                powerHint: .unknown,
                spatialWatermark: spatialWatermark,
                activityWatermark: activityWatermark
            )
        )
    }
}

private enum ApprovalSendError: LocalizedError {
    case unavailable
    case ackTimedOut
    case freshnessBlocked(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Approval channel is not connected."
        case .ackTimedOut:
            "Approval response timed out."
        case .freshnessBlocked(let message):
            message
        }
    }
}

private struct AgentsBoardView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @Binding var selectedTab: ContinuumTab

    var body: some View {
        NavigationStack {
            Group {
                switch model.freshness.state {
                case .unpaired:
                    PairingRequiredView()
                case .syncing:
                    LoadingBoardView()
                case .live:
                    if model.rows.isEmpty {
                        EmptyBoardView()
                    } else {
                        agentsList
                    }
                case .stale, .desktopSleeping, .offline:
                    if model.hasCachedAgentData {
                        agentsList
                    } else {
                        WaitingForMacView(freshness: model.freshness)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.freshness.state != .unpaired {
                    FreshnessFooter(freshness: model.freshness)
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle("Agents")
            .navigationDestination(for: UUID.self) { tileId in
                AgentDetailView(tileId: tileId, selectedTab: $selectedTab)
            }
        }
    }

    private var agentsList: some View {
        List(model.rows) { row in
            NavigationLink(value: row.tileId) {
                AgentRowView(row: row)
            }
            .listRowBackground(row.status == .needsAttention ? Color.orange.opacity(0.12) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct ApprovalsInboxView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @Binding var selectedTab: ContinuumTab

    var body: some View {
        NavigationStack {
            Group {
                if model.freshness.state == .unpaired {
                    PairingRequiredView()
                } else if model.approvalRows.isEmpty {
                    if model.hasCachedAgentData || model.isFreshnessLive {
                        Text("Nothing needs you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AppColors.background.ignoresSafeArea())
                    } else {
                        WaitingForMacView(freshness: model.freshness)
                    }
                } else {
                    List(model.approvalRows) { row in
                        NavigationLink(value: row.tileId) {
                            AgentRowView(row: row)
                        }
                        .listRowBackground(Color.orange.opacity(0.12))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(AppColors.background.ignoresSafeArea())
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.freshness.state != .unpaired {
                    FreshnessFooter(freshness: model.freshness)
                }
            }
            .navigationTitle("Approvals")
            .navigationDestination(for: UUID.self) { tileId in
                AgentDetailView(tileId: tileId, selectedTab: $selectedTab)
            }
        }
    }
}

private struct AgentRowView: View {
    let row: AgentsBoardRow

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyphView(status: row.status, presentation: row.presentation)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusPill(status: row.status, presentation: row.presentation)
                    Spacer(minLength: 8)
                    Text(row.updatedAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(row.lastSummary.isEmpty ? "No activity yet" : row.lastSummary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct AgentDetailView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    let tileId: UUID
    @Binding var selectedTab: ContinuumTab

    private var row: AgentsBoardRow? {
        model.rows.first { $0.tileId == tileId }
    }

    private var activity: TileActivity? {
        model.activity(for: tileId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let row, let activity {
                    DetailHeader(row: row)
                    if row.status == .needsAttention {
                        PendingAttentionCard(activity: activity, grantedScope: model.grantedScope, freshness: model.freshness) { target, decision in
                            try await model.respondToApproval(
                                tileId: target.tileId,
                                requestId: target.approvalRequestId,
                                decision: decision
                            )
                        }
                    }
                    Button {
                        model.requestCanvasFocus(tileId: tileId)
                        selectedTab = .canvas
                    } label: {
                        Label("Show on canvas", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    TimelineView(events: AgentsBoardProjection.timelineEvents(for: activity))
                } else {
                    Text("Agent activity is no longer available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                }
            }
            .padding()
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailHeader: View {
    let row: AgentsBoardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusPill(status: row.status, presentation: row.presentation)
                Spacer()
                Text(row.updatedAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(row.lastSummary.isEmpty ? "No activity yet" : row.lastSummary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(row.tileId.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
        .background(AppColors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingAttentionCard: View {
    let activity: TileActivity
    let grantedScope: Scope
    let freshness: CompanionFreshness
    var onRespond: (ApprovalResponseTarget, ApprovalDecision) async throws -> ApprovalResponseOutcome

    @State private var resolving: ApprovalDecision?
    @State private var settled = false
    @State private var note: String?
    @State private var isError = false

    private var latest: AgentActivityEvent? {
        AgentsBoardProjection.latestPendingAttentionEvent(in: activity)
    }

    private var target: ApprovalResponseTarget? {
        AgentsBoardProjection.respondableRequest(in: activity)
    }

    private var gateHint: String? {
        if case .live = freshness.state {
        } else {
            return freshness.actionBlocker ?? "Reconnect to act"
        }
        if target == nil {
            return "No approval id synced"
        }
        do {
            try authorize(.respondToApproval, grantedScopes: grantedScope)
            return nil
        } catch {
            return "Observer scope"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pending attention")
                    .font(.headline)
                Spacer()
                if let latest {
                    Text(latest.occurredAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(latest?.summary ?? activity.lastSummary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                approvalButton("Approve", decision: .accept, prominent: true)
                approvalButton("Deny", decision: .decline, prominent: false)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            } else if let gateHint {
                Text(gateHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func approvalButton(_ title: String, decision: ApprovalDecision, prominent: Bool) -> some View {
        if prominent {
            Button {
                Task { await submit(decision) }
            } label: {
                HStack(spacing: 6) {
                    if resolving == decision {
                        ProgressView()
                    }
                    Text(title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolving != nil || settled || gateHint != nil)
        } else {
            Button {
                Task { await submit(decision) }
            } label: {
                HStack(spacing: 6) {
                    if resolving == decision {
                        ProgressView()
                    }
                    Text(title)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(resolving != nil || settled || gateHint != nil)
        }
    }

    private func submit(_ decision: ApprovalDecision) async {
        guard let target else { return }
        resolving = decision
        note = nil
        isError = false
        do {
            let outcome = try await onRespond(target, decision)
            resolving = nil
            switch outcome {
            case .resolved:
                note = nil
                settled = true
            case .stale:
                note = "Already resolved"
                isError = false
                settled = true
            case .unauthorized:
                note = "Not authorized to approve"
                isError = true
            case .unknownRequest:
                note = "Approval is no longer available"
                isError = true
                settled = true
            }
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? "Couldn't send approval"
            isError = true
            resolving = nil
        }
    }
}

private struct TimelineView: View {
    let events: [AgentActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timeline")
                .font(.headline)
            if events.isEmpty {
                Text("No transcript available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(AppColors.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(events, id: \.compositeId) { event in
                    TimelineEventRow(event: event)
                }
            }
        }
    }
}

private extension AgentActivityEvent {
    var compositeId: String {
        "\(replicaId.uuidString)-\(sequence)"
    }
}

private struct TimelineEventRow: View {
    let event: AgentActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text(event.occurredAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding()
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        switch event.tone {
        case .info: .blue
        case .tool: .teal
        case .approval: .orange
        case .error: .red
        }
    }
}

private struct StatusGlyphView: View {
    let status: AgentStatus
    let presentation: AgentStatusPresentation

    var body: some View {
        Text(presentation.glyph)
            .font(.title3.weight(.bold))
            .foregroundStyle(AppColors.color(for: presentation.colorToken))
            .accessibilityLabel(status.rawValue)
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    let presentation: AgentStatusPresentation

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.glyph)
            Text(status.rawValue)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(AppColors.color(for: presentation.colorToken))
        .background(AppColors.color(for: presentation.colorToken).opacity(0.16))
        .clipShape(Capsule())
    }
}

private struct LoadingBoardView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking paired session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairingRequiredView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Pair this phone")
                .font(.headline)
            Text("Connect to your Continuum instance before CloudKit starts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActionableErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WaitingForMacView: View {
    let freshness: CompanionFreshness

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Waiting for your Mac")
                .font(.headline)
            Text(freshness.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FreshnessFooter: View {
    let freshness: CompanionFreshness

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(freshness.title)
                .font(.caption.weight(.semibold))
            Text(freshness.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let lastFreshAt = freshness.lastFreshAt {
                Text(lastFreshAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.panel)
    }

    private var dotColor: Color {
        switch freshness.state {
        case .live:
            return .green
        case .syncing:
            return .blue
        case .stale:
            return .orange
        case .desktopSleeping, .offline:
            return .gray
        case .unpaired:
            return .secondary
        }
    }
}

private struct EmptyBoardView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("No agents observed")
                .font(.headline)
            Text("Spawn agents on the desktop to populate this board.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas tab (ticket 61b)

private struct CanvasTabView: View {
    @EnvironmentObject private var model: AgentsBoardModel

    @State private var scale: CGFloat = 0.35
    @State private var pan: CGSize = .zero
    @State private var framingState: CanvasMirrorFramingState = .waitingForFirstSnapshot
    @GestureState private var pinchDelta: CGFloat = 1.0
    @GestureState private var panTranslation: CGSize = .zero

    @State private var activeDragTileId: UUID?
    @GestureState private var tileDragTranslation: CGSize = .zero
    @State private var activeResizeTileId: UUID?
    @GestureState private var resizeTranslation: CGSize = .zero
    @State private var hoveredZoneId: UUID?

    private var canEdit: Bool { model.canMutateFromFreshness && CanvasEditIntent.isEditingPermitted(scope: model.grantedScope) }
    // Hard-blocks the camera (pan/zoom) from moving while a tile drag or
    // resize is in progress — the editor contract requires gesture-end edits
    // to be evaluated against a fixed camera, never a camera that shifted
    // mid-gesture underneath the tile.
    private var isEditingTile: Bool { activeDragTileId != nil || activeResizeTileId != nil }
    private var effectiveScale: CGFloat { scale * pinchDelta }
    private var effectivePan: CGSize {
        CGSize(width: pan.width + panTranslation.width, height: pan.height + panTranslation.height)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    AppColors.background.ignoresSafeArea()
                    if model.canvasScene.zones.isEmpty && model.canvasScene.tiles.isEmpty {
                        CanvasEmptyStateView(display: model.canvasFreshnessDisplay)
                    } else {
                        canvasContent
                            .contentShape(Rectangle())
                            .gesture(panGesture)
                            .simultaneousGesture(zoomGesture)
                            // Tile drag/resize are attached to descendant views
                            // with `.highPriorityGesture` (below) so they win
                            // the arena over these ancestor camera gestures;
                            // `isEditingTile` additionally hard-guards the
                            // camera state updates as defense in depth.
                    }
                    overlayChrome(in: geo.size)
                }
                .onChange(of: model.canvasFocusRequest) { tileId in
                    guard let tileId else { return }
                    let result = CanvasMirrorPresentation.showOnCanvas(
                        tileId: tileId,
                        scene: model.canvasScene,
                        viewportSize: mirrorSize(geo.size),
                        currentScale: Double(scale)
                    )
                    apply(result.viewport)
                    model.canvasHighlightedTileId = result.highlightedTileId
                    if let message = result.message {
                        model.canvasFocusError = message
                    }
                    model.canvasFocusRequest = nil
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await MainActor.run {
                            if model.canvasHighlightedTileId == tileId {
                                model.canvasHighlightedTileId = nil
                            }
                        }
                    }
                }
                .onChange(of: model.canvasScene) { scene in
                    applyFirstSnapshotFrame(scene: scene, size: geo.size)
                }
                .onAppear {
                    applyFirstSnapshotFrame(scene: model.canvasScene, size: geo.size)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.freshness.state != .unpaired {
                    FreshnessFooter(freshness: model.freshness)
                }
            }
            .navigationTitle("Canvas")
        }
    }

    private var canvasContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.canvasScene.zones) { zone in
                zoneView(zone)
            }
            ForEach(model.canvasScene.tiles) { tile in
                tileView(tile)
            }
        }
    }

    private func overlayChrome(in size: CGSize) -> some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CanvasMirrorPresentation.workspaceTitle(nil))
                        .font(.caption.weight(.semibold))
                    CanvasMirrorFreshnessBadge(display: model.canvasFreshnessDisplay)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppColors.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let badge = CanvasMirrorPresentation.scopeBadge(
                    grantedScope: model.grantedScope,
                    freshness: model.freshness,
                    operatorOverrideActive: model.scopeOverrideActive
                ) {
                    LockBadge(text: badge.text, systemImage: badge.systemImage)
                }
                Spacer()
                Button {
                    fitAll(in: size)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(10)
                        .background(AppColors.panel)
                        .clipShape(Circle())
                        .foregroundStyle(.primary)
                }
            }
            .padding()
            Spacer()
            if let message = model.canvasFocusError ?? model.canvasEditError {
                Text(message)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 16)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        model.canvasEditError = nil
                        model.canvasFocusError = nil
                    }
            }
        }
    }

    // MARK: Zones

    private func zoneView(_ zone: CanvasSceneZone) -> some View {
        let point = screenPoint(worldX: zone.origin.x + zone.size.width / 2, worldY: zone.origin.y + zone.size.height / 2)
        return VStack(alignment: .leading, spacing: 0) {
            Text(zone.name.isEmpty ? "Zone" : zone.name)
                .font(.caption.weight(.semibold))
                .padding(6)
                .foregroundStyle(.primary)
            Spacer()
        }
        .frame(width: zone.size.width * effectiveScale, height: zone.size.height * effectiveScale, alignment: .topLeading)
        .background(zoneTint(for: zone.tintToken).opacity(hoveredZoneId == zone.zoneId ? 0.35 : 0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(zoneTint(for: zone.tintToken).opacity(hoveredZoneId == zone.zoneId ? 0.9 : 0.5), lineWidth: hoveredZoneId == zone.zoneId ? 2.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .position(point)
    }

    // MARK: Tiles

    private func tileView(_ tile: CanvasSceneTile) -> some View {
        let dragOffset = activeDragTileId == tile.tileId ? tileDragTranslation : .zero
        let resizeOffset = activeResizeTileId == tile.tileId ? resizeTranslation : .zero
        let width = max(40, tile.frame.width * effectiveScale + resizeOffset.width)
        let height = max(30, tile.frame.height * effectiveScale + resizeOffset.height)
        let center = screenPoint(worldX: tile.frame.x + tile.frame.width / 2, worldY: tile.frame.y + tile.frame.height / 2)
        let position = CGPoint(x: center.x + dragOffset.width + resizeOffset.width / 2, y: center.y + dragOffset.height + resizeOffset.height / 2)
        let isHighlighted = model.canvasHighlightedTileId == tile.tileId

        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isHighlighted ? Color.orange : (activeDragTileId == tile.tileId || activeResizeTileId == tile.tileId ? Color.orange : Color.white.opacity(0.15)),
                            lineWidth: isHighlighted ? 3 : (activeDragTileId == tile.tileId ? 2 : 1)
                        )
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: tile.kindGlyphToken)
                        .font(.caption)
                    statusDot(for: tile.tileId)
                    Spacer()
                }
                Text(tile.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if canEdit {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2)
                    .padding(5)
                    .background(Circle().fill(AppColors.panel))
                    .padding(4)
                    .highPriorityGesture(resizeGesture(tile: tile))
            }
        }
        .frame(width: width, height: height)
        .position(position)
        .animation(.easeInOut(duration: 0.18), value: tile.frame)
        .animation(.easeInOut(duration: 0.18), value: isHighlighted)
        .modifier(EditableTileGestures(canEdit: canEdit, tile: tile, dragGesture: tileDragGesture(tile: tile), longPress: bringToFrontAction(tile: tile)))
    }

    private func statusDot(for tileId: UUID) -> some View {
        let token = model.canvasStatusOverlays[tileId]?.presentation.colorToken
        return Circle().fill(token.map { AppColors.color(for: $0) } ?? Color.gray.opacity(0.4)).frame(width: 7, height: 7)
    }

    private func bringToFrontAction(tile: CanvasSceneTile) -> () -> Void {
        {
            guard let op = CanvasEditIntent.bringToFront(tile: tile.tileId, scene: model.canvasScene) else { return }
            Task { await model.emitCanvasOp(op) }
        }
    }

    // MARK: Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($panTranslation) { value, state, _ in
                guard !isEditingTile else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !isEditingTile else { return }
                pan.width += value.translation.width
                pan.height += value.translation.height
                framingState = .userControlled
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchDelta) { value, state, _ in
                guard !isEditingTile else { return }
                state = value
            }
            .onEnded { value in
                guard !isEditingTile else { return }
                scale = min(3.0, max(0.05, scale * value))
                framingState = .userControlled
            }
    }

    private func tileDragGesture(tile: CanvasSceneTile) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($tileDragTranslation) { value, state, _ in state = value.translation }
            .onChanged { value in
                activeDragTileId = tile.tileId
                let worldPoint = ZonePoint(
                    x: tile.frame.x + tile.frame.width / 2 + value.translation.width / effectiveScale,
                    y: tile.frame.y + tile.frame.height / 2 + value.translation.height / effectiveScale
                )
                hoveredZoneId = CanvasEditIntent.dropTarget(point: worldPoint, zones: model.canvasScene.zones)
            }
            .onEnded { value in
                let newFrame = TileFrame(
                    x: tile.frame.x + value.translation.width / effectiveScale,
                    y: tile.frame.y + value.translation.height / effectiveScale,
                    width: tile.frame.width,
                    height: tile.frame.height
                )
                activeDragTileId = nil
                hoveredZoneId = nil
                Task { await commitMove(tile: tile, to: newFrame) }
            }
    }

    private func resizeGesture(tile: CanvasSceneTile) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($resizeTranslation) { value, state, _ in state = value.translation }
            .onChanged { _ in activeResizeTileId = tile.tileId }
            .onEnded { value in
                let newFrame = TileFrame(
                    x: tile.frame.x,
                    y: tile.frame.y,
                    width: max(80, tile.frame.width + value.translation.width / effectiveScale),
                    height: max(60, tile.frame.height + value.translation.height / effectiveScale)
                )
                activeResizeTileId = nil
                Task { await model.emitCanvasOp(CanvasEditIntent.resizeEnded(tile: tile.tileId, to: newFrame)) }
            }
    }

    // Exactly one gesture end, up to two ops: the move, then (only if the
    // drop target's zone differs from the tile's current zone) the
    // membership change — sent as one ordered batch via `emitAll` so a failed
    // move never lets a membership change happen after it (61b rev.2 §1).
    private func commitMove(tile: CanvasSceneTile, to frame: TileFrame) async {
        let ops = CanvasEditIntent.moveDropOps(tile: tile.tileId, currentZoneId: tile.zoneId, to: frame, zones: model.canvasScene.zones)
        await model.emitCanvasOps(ops)
    }

    // MARK: World <-> screen mapping

    private func screenPoint(worldX: Double, worldY: Double) -> CGPoint {
        CGPoint(x: worldX * effectiveScale + effectivePan.width, y: worldY * effectiveScale + effectivePan.height)
    }

    private func fitAll(in size: CGSize) {
        apply(CanvasMirrorPresentation.fitAllViewport(scene: model.canvasScene, viewportSize: mirrorSize(size)))
        framingState = .userControlled
    }

    private func applyFirstSnapshotFrame(scene: CanvasScene, size: CGSize) {
        let result = CanvasMirrorPresentation.firstSnapshotViewport(
            scene: scene,
            viewportSize: mirrorSize(size),
            current: CanvasMirrorViewport(scale: Double(scale), panX: Double(pan.width), panY: Double(pan.height)),
            framingState: framingState
        )
        apply(result.viewport)
        framingState = result.framingState
    }

    private func apply(_ viewport: CanvasMirrorViewport) {
        scale = CGFloat(viewport.scale)
        pan = CGSize(width: viewport.panX, height: viewport.panY)
    }

    private func mirrorSize(_ size: CGSize) -> CanvasMirrorViewportSize {
        CanvasMirrorViewportSize(width: Double(size.width), height: Double(size.height))
    }
}

/// Applies the drag + long-press (bring-to-front) gestures only when editing
/// is permitted (`.orchestrationOperate`) — observer scope stays read-only.
/// The drag is attached with `.highPriorityGesture` (not `.simultaneousGesture`)
/// so it wins the gesture arena over the ancestor canvas pan/zoom gestures:
/// a tile drag must never also move the camera underneath it.
private struct EditableTileGestures<DragG: Gesture>: ViewModifier {
    let canEdit: Bool
    let tile: CanvasSceneTile
    let dragGesture: DragG
    let longPress: () -> Void

    func body(content: Content) -> some View {
        if canEdit {
            content
                .highPriorityGesture(dragGesture)
                .onLongPressGesture(minimumDuration: 0.6, perform: longPress)
        } else {
            content
        }
    }
}

private func zoneTint(for token: String) -> Color {
    switch token.lowercased() {
    case "mint": return .mint
    case "amber": return .orange
    case "blue": return .blue
    case "teal": return .teal
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "green": return .green
    default: return .gray
    }
}

private struct LockBadge: View {
    var text: String = "Read only"
    var systemImage: String = "lock.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.panel)
            .clipShape(Capsule())
    }
}

private struct CanvasEmptyStateView: View {
    let display: CanvasMirrorFreshnessDisplay

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(display.title)
                .font(.headline)
            Text(display.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CanvasMirrorFreshnessBadge: View {
    let display: CanvasMirrorFreshnessDisplay

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var label: String {
        guard let asOf = display.asOf else { return display.title }
        return "\(display.title) · \(asOf.formatted(date: .omitted, time: .shortened))"
    }

    private var color: Color {
        switch display.title {
        case "Live":
            return .green
        case "Syncing…":
            return .blue
        case "Canvas stale · Agents live", "Stale":
            return .orange
        case "Offline", "Mac asleep":
            return .gray
        default:
            return .secondary
        }
    }
}

private struct PlaceholderScreen: View {
    let title: String
    let subtitle: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(title)
        }
    }
}

private struct SettingsDiagnosticsView: View {
    @EnvironmentObject private var model: AgentsBoardModel

    var body: some View {
        NavigationStack {
            List {
                Section("Pairing") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Session")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pairingSummary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Granted scope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(scopeSummary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if model.scopeOverrideActive {
                        Label("DEBUG operator scope override active", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Section("Push Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("APNS device token")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.apnsDeviceToken ?? "Waiting for APNS registration")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(nil)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Text("Settings land with ticket B8.")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }

    private var pairingSummary: String {
        switch model.pairedSessionState {
        case .unpaired:
            return "unpaired"
        case .paired(let session):
            return "paired instance=\(session.instanceId.uuidString) device=\(session.deviceId.uuidString)"
        case .expired(let session):
            return "expired instance=\(session.instanceId.uuidString) device=\(session.deviceId.uuidString)"
        case .revoked(let session):
            guard let session else { return "revoked" }
            return "revoked instance=\(session.instanceId.uuidString) device=\(session.deviceId.uuidString)"
        case .unavailable(let reason):
            return "unavailable \(reason)"
        }
    }

    private var scopeSummary: String {
        "raw=\(model.grantedScope.rawValue)"
    }
}

private enum AppColors {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.14)

    static func color(for token: String) -> Color {
        switch token {
        case "blue": .blue
        case "orange": .orange
        case "green": .green
        case "gray": .gray
        case "teal": .teal
        case "tertiaryLabel": Color(.tertiaryLabel)
        default: .secondary
        }
    }
}
