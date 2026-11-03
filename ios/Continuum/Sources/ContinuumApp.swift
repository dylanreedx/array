import AVFoundation
import ActivityKit
import CloudKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedRelayClient
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import SwiftUI
import UIKit
import UserNotifications

private let continuumCloudKitContainerIdentifier = CompanionSyncConfig.cloudKitContainerIdentifier

@main
struct ContinuumApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushDelegate
    @StateObject private var model = AgentsBoardModel()
    @State private var showsNotificationPrimer = false

    var body: some Scene {
        WindowGroup {
            ContinuumRootView()
                .environmentObject(model)
                .task {
                    pushDelegate.model = model
                    await model.start()
                    if model.canUnpairThisPhone {
                        showsNotificationPrimer = await pushDelegate.prepareNotificationsAfterPairing()
                    }
                }
                .onChange(of: model.canUnpairThisPhone) { _, paired in
                    guard paired else { return }
                    Task { showsNotificationPrimer = await pushDelegate.prepareNotificationsAfterPairing() }
                }
                .onOpenURL { url in
                    Task { @MainActor in
                        await model.handleIncomingURL(url)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { @MainActor in await model.handleIncomingURL(url) }
                }
                .sheet(isPresented: $showsNotificationPrimer) {
                    NotificationPrimerView {
                        Task {
                            await pushDelegate.enableNotificationsAfterPairing()
                            showsNotificationPrimer = false
                        }
                    } notNow: {
                        showsNotificationPrimer = false
                    }
                }
        }
    }
}

private struct NotificationPrimerView: View {
    let enable: () -> Void
    let notNow: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.orange)
                VStack(spacing: 9) {
                    Text("Know when Array needs you")
                        .font(.title2.bold())
                    Text("Get a banner when an agent needs approval, is waiting for input, finishes, or fails. Ordinary progress stays quiet in the widget and Live Activity.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Enable Notifications", action: enable)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Not Now", action: notNow)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .navigationTitle("Agent Updates")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

@MainActor
private final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var deferredNotificationURL: URL?
    weak var model: AgentsBoardModel? {
        didSet {
            if let model, let url = deferredNotificationURL {
                model.pendingDeepLink = url
                deferredNotificationURL = nil
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories())
        return true
    }

    func enableNotificationsAfterPairing() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                print("notification authorization failed: \(error.localizedDescription)")
            }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            break
        @unknown default:
            break
        }
    }

    func prepareNotificationsAfterPairing() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            return true
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
            return false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            model?.apnsDeviceToken = token
            UserDefaults(suiteName: ArraySystemSurfaceConstants.appGroupIdentifier)?
                .set(token, forKey: ArraySystemSurfaceConstants.apnsTokenDefaultsKey)
            _ = await SystemSurfaceCoordinator.shared.registerPushToken(deviceToken, kind: .apns)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            model?.apnsDeviceToken = "registration failed: \(error.localizedDescription)"
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let model else {
            if let raw = userInfo[ArraySystemSurfaceConstants.deepLinkUserInfoKey] as? String {
                deferredNotificationURL = URL(string: raw)
            }
            return
        }
        let grantedScope = await MainActor.run { model.grantedScope }
        guard let intent = handlePushAction(actionId: response.actionIdentifier, userInfo: userInfo, grantedScope: grantedScope) else {
            await MainActor.run { model.openPushDeepLink(userInfo) }
            return
        }
        do {
            _ = try await model.respondToApproval(agentId: intent.agentId, requestId: intent.requestId, decision: intent.decision)
        } catch {
            print("push approval response failed: \(error.localizedDescription)")
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let model else { completionHandler(.noData); return }
        Task { @MainActor in
            await model.refreshNow()
            model.openPushDeepLink(userInfo, navigate: false)
            completionHandler(.newData)
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
        .onChange(of: model.pendingDeepLink) { _, url in
            guard let url else { return }
            switch url.host?.lowercased() {
            case "approval": selectedTab = .approvals
            case "devices", "status": selectedTab = .settings
            case "agent":
                guard model.pairedInstanceID != nil else { return }
                model.navigateToAgent(url)
                selectedTab = .agents
            case "agents": selectedTab = .agents
            default: break
            }
            model.pendingDeepLink = nil
        }
        .onChange(of: model.pairedInstanceID) { _, instance in
            guard instance != nil, let url = model.pendingDeepLink, url.host?.lowercased() == "agent" else { return }
            model.navigateToAgent(url)
            selectedTab = .agents
            model.pendingDeepLink = nil
        }
    }
}

@MainActor
private final class AgentsBoardModel: ObservableObject {
    private static let approvalAckTimeout: Duration = .seconds(5)
    private static let pairingRetryDelays: [Duration] = [.milliseconds(350), .seconds(1)]
    /// Inbound mobile spatial ops are not yet acknowledged by the canonical Mac
    /// workspace revision. Keep the mirror read-only rather than reporting a
    /// transport-fresh but divergent edit as Live.
    static let authoritativeCanvasMutationEnabled = false

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
    @Published var lastStopAck: AgentStopAck?
    @Published var transcripts: [UUID: AgentDocument] = [:]
    /// Paired through the hosted relay before the pairing secret existed: the
    /// Mac holds no key this phone can open, so transcripts need a re-pair.
    @Published var transcriptsNeedRepair = false
    /// Why an open agent shows no transcript, in the Mac's words; nil while
    /// it is loading or shown.
    @Published var transcriptNotes: [UUID: String] = [:]
    /// Phone message drafts per agent, kept while the app runs so leaving an
    /// agent's screen keeps the text and the same sealed request (plan 104).
    @Published var messageDrafts = PhoneMessageDrafts()
    @Published var parentByChild: [UUID: UUID] = [:]
    @Published var apnsDeviceToken: String?
    @Published var freshnessNow = Date()
    @Published var pairingStatusMessage: String?
    @Published var pairingInProgress = false
    @Published var pendingDeepLink: URL?
    @Published var agentNavigationPath: [UUID] = []
    @Published var notificationDestination: CompanionAgentDestination?
    @Published var taskObservation: CompanionTaskObservation?
    @Published var agentNavigationError: String?
    private var taskObservationTask: Task<Void, Never>?

    func navigateToAgent(_ url: URL) {
        guard let destination = CompanionAgentDestination(url: url, pairedInstanceID: pairedInstanceID) else {
            agentNavigationError = "This notification does not belong to the paired Mac, or its agent link is invalid."
            return
        }
        agentNavigationError = nil
        notificationDestination = destination
        agentNavigationPath = [destination.agentID]
    }

    #if DEBUG
    private func installNotificationDetailFixture() {
        let agent = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let child = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let taskID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let run = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let childRun = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
        let data = Data("""
        {"publisherID":"\(UUID())","revision":1,"tasks":[{"taskID":"\(taskID)","rootRunID":"\(run)","membershipComplete":true,"members":[{"agentID":"\(agent)","runID":"\(run)","state":"succeeded"},{"agentID":"\(child)","runID":"\(childRun)","parentRunID":"\(run)","state":"running"}]}]}
        """.utf8)
        guard let batch = try? JSONDecoder().decode(CompanionTaskSnapshotBatch.self, from: data) else { return }
        let now = Date()
        snapshot = .init(snapshotSequence: 1, snapshotReplicaId: UUID(), byAgent: [
            agent: .init(status: .working, lastSummary: "Newer work on this agent", recent: [], updatedAt: now),
            child: .init(status: .working, lastSummary: "Checking the remaining work", recent: [], updatedAt: now)
        ])
        rows = AgentsBoardProjection.rows(from: snapshot)
        taskObservation = .init(batch: batch, publishedAt: now.addingTimeInterval(-120), sequence: 1)
        navigateToAgent(URL(string: "array://agent/\(agent)?task=\(taskID)&run=\(run)")!)
        state = .live
    }
    #endif

    // Ticket: docs/38-tickets/61b-canvas-editor.md
    @Published var canvasScene: CanvasScene = CanvasScene(zones: [], tiles: [])
    @Published var canvasFocusRequest: UUID?
    @Published var canvasHighlightedTileId: UUID?
    @Published var canvasEditError: String?
    @Published var canvasFocusError: String?
    @Published private var transportAvailability: CompanionTransportAvailability = .connecting
    @Published private var latestActivityFreshness: CompanionFreshnessSample?
    @Published private var latestSpatialFreshness: CompanionFreshnessSample?
    @Published private(set) var lastFetchReport: String = "never ran"
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
    private var syncTransport: CloudKitSyncTransport?
    private var fetchTask: Task<Void, Never>?
    /// Set in relay mode (D4-R1, ticket 86); the transport owns its poll loop.
    private var relayTransport: RelaySyncTransport?
    /// Hosted relay only. Stop and Approve go through the relay's command
    /// queue: it refuses events published by a phone, so the sync-message path
    /// below never reached the Mac there.
    private var commandChannel: RelayCommandChannel?
    private var relayStateTask: Task<Void, Never>?
    private var transcriptControlTask: Task<Void, Never>?
    private var transcriptReceiver: TranscriptProjectionReceiver?
    private var transcriptTask: Task<Void, Never>?
    private nonisolated static let relayCursorDefaultsKey = "continuum.relay.cursor"
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

    var diagnosticsTransportSummary: String { transportAvailability.rawValue }
    var transportModeSummary: String {
        RelayClientConfig.resolve().map { "relay \($0.baseURL.absoluteString)" } ?? "cloudkit"
    }
    var diagnosticsRemoteBackedLiveSummary: String { isFreshnessLive ? "yes" : "no" }
    var diagnosticsActivitySummary: String { Self.diagnosticsSummary(for: latestActivityFreshness, fallback: "no remote activity snapshot") }
    var diagnosticsSpatialSummary: String { Self.diagnosticsSummary(for: latestSpatialFreshness, fallback: "no remote spatial snapshot") }
    var diagnosticsAgentRowCount: Int { rows.count }
    var diagnosticsCanvasTileCount: Int { canvasScene.tiles.count }

    var canUnpairThisPhone: Bool {
        if case .unpaired = pairedSessionState { return false }
        return true
    }

    var pairedInstanceID: UUID? {
        guard case .paired(let session) = pairedSessionState else { return nil }
        return session.instanceId
    }

    func openPushDeepLink(_ userInfo: [AnyHashable: Any], navigate: Bool = true) {
        guard navigate,
              let raw = userInfo[ArraySystemSurfaceConstants.deepLinkUserInfoKey] as? String,
              let url = URL(string: raw) else { return }
        pendingDeepLink = url
    }

    func start() async {
        guard task == nil else { return }
        #if DEBUG
        // Rendering-only fixture: no Keychain, network, phone token or command.
        if ProcessInfo.processInfo.environment["CONTINUUM_COMPANION_DETAIL_QA"] == "1" {
            installNotificationDetailFixture()
            return
        }
        #endif
        state = .loading
        transportAvailability = .connecting
        startFreshnessTicker()
        pairedSessionState = pairedSessionStore.loadState()
        let capability = CompanionUICapability(state: pairedSessionState)
        guard capability.canStartTransport else {
            state = .unpaired
            Self.appendFetchLog("start: unpaired — transport not started")
            return
        }

        let resolvedRelayConfig = RelayClientConfig.resolve()
        if HostedPairingPolicy.requiresHostedRepair(
            isPaired: canUnpairThisPhone,
            relayURL: resolvedRelayConfig?.baseURL
        ) {
            transportAvailability = .transportUnavailable
            state = .unavailable("This phone uses legacy sync. Unpair it in Settings, then scan a new invitation from a relay-connected Mac.")
            pairingStatusMessage = "Pair again: this saved pairing predates Array Relay."
            Self.appendFetchLog("start: legacy pairing has no relay endpoint — explicit re-pair required")
            return
        }

        // D4-R1 (ticket 86): a configured relay URL selects the self-owned
        // relay — no iCloud account gate, and the transport owns its own
        // poll loop. Without a relay URL the parked CloudKit path below runs
        // unchanged.
        let transport: any ContinuumRevivedSync.SyncTransport
        if let relayConfig = resolvedRelayConfig {
            guard case .paired(let pairedSession) = pairedSessionState else {
                state = .unpaired
                Self.appendFetchLog("start: relay configured but no paired session token — pair first")
                return
            }
            let storedCursor = (UserDefaults.standard.object(forKey: Self.relayCursorDefaultsKey) as? NSNumber)?.uint64Value ?? 0
            let relay = RelaySyncTransport(
                baseURL: relayConfig.baseURL,
                bearerToken: pairedSession.token,
                deviceLabel: UIDevice.current.name,
                initialCursor: storedCursor,
                onCursorChange: { cursor in
                    UserDefaults.standard.set(NSNumber(value: cursor), forKey: Self.relayCursorDefaultsKey)
                },
                onDiagnostic: { line in
                    Self.appendFetchLog(line)
                },
                apiVersion: relayConfig.baseURL.scheme == "https" ? .hardenedV2 : .legacyV1
            )
            await SystemSurfaceCoordinator.shared.configureRelayPushRegistration(
                baseURL: relayConfig.baseURL,
                credential: pairedSession.token
            )
            relayTransport = relay
            commandChannel = relayConfig.baseURL.scheme == "https"
                ? RelayCommandChannel(baseURL: relayConfig.baseURL, bearerToken: pairedSession.token) : nil
            taskObservationTask = Task { [weak self] in
                for await observation in relay.taskObservations {
                    guard !Task.isCancelled, let self else { return }
                    if let previous = self.taskObservation {
                        guard observation.supersedes(previous) else { continue }
                    }
                    self.taskObservation = observation
                }
            }
            relay.start()
            transportAvailability = .available
            lastFetchReport = "relay: connecting to \(relayConfig.baseURL.absoluteString)"
            Self.appendFetchLog("start: relay mode url=\(relayConfig.baseURL.absoluteString) cursor=\(storedCursor) — transport polling; CloudKit unused")
            relayStateTask = Task { [weak self] in
                for await connection in relay.connectionState {
                    let report: String
                    switch connection {
                    case .connected: report = "relay connected (\(relayConfig.baseURL.absoluteString))"
                    case .reconnecting: report = "relay reconnecting"
                    case .disconnected(let reason): report = "relay disconnected: \(reason)"
                    }
                    print("[companion-fetch] \(report)")
                    Self.appendFetchLog(report)
                    guard let self else { return }
                    await MainActor.run { self.lastFetchReport = report }
                }
            }
            transport = relay
        } else {
            let container = CKContainer(identifier: continuumCloudKitContainerIdentifier)
            do {
                let status = try await container.accountStatus()
                guard status == .available else {
                    transportAvailability = .accountUnavailable
                    state = .unavailable("Sign in to iCloud in Settings to observe your agents")
                    Self.appendFetchLog("start: iCloud account unavailable (CKAccountStatus=\(status.rawValue)) — transport not started")
                    return
                }
            } catch {
                transportAvailability = .accountUnavailable
                state = .unavailable("Sign in to iCloud in Settings to observe your agents")
                Self.appendFetchLog("start: accountStatus FAILED: \(String(describing: error)) — transport not started")
                return
            }
            transportAvailability = .available
            Self.appendFetchLog("start: paired + iCloud available — starting receivers and fetch loop")
            let cloudKit = CloudKitSyncTransport(containerIdentifier: continuumCloudKitContainerIdentifier)
            self.syncTransport = cloudKit
            transport = cloudKit
        }
        // ONE transport, ONE demux — the spatial receiver below is a second
        // independent subscriber over the SAME demux the activity receiver
        // uses (ticket 61b banner (c).7), never a second transport.
        let demux = SyncMessageDemux(transport: transport)
        self.demux = demux
        transcriptControlTask = Task { [weak self] in
            let stream = await demux.subscribe()
            for await message in stream {
                guard !Task.isCancelled else { return }
                switch message {
                case .childLifecycle(let update):
                    await MainActor.run { self?.parentByChild[update.agentID] = update.parentAgentID }
                case .transcriptHistoryResponse(let response):
                    // Decryption is installed when transcript keys are negotiated.
                    // Until then the UI remains explicitly activity-only.
                    if response.envelope == nil { continue }
                default:
                    continue
                }
            }
        }

        transcriptsNeedRepair = false
        if relayTransport != nil,
           capability.scope.contains(.transcriptRead),
           case .paired(let pairedSession) = pairedSessionState,
           let channel = transcriptChannel(for: pairedSession) {
            let transcriptReceiver = TranscriptProjectionReceiver(
                demux: demux,
                scope: capability.scope,
                channelKeys: [channel.keyID: channel.key]
            )
            self.transcriptReceiver = transcriptReceiver
            transcriptTask = Task { [weak self] in
                let stream = await transcriptReceiver.subscribe()
                for await (agentID, document) in stream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.transcripts[agentID] = document }
                }
            }
        }

        let receiver = ActivityProjectionReceiver(demux: demux, scope: capability.scope)
        self.receiver = receiver
        task = Task { [weak self] in
            await receiver.connect(cursor: nil)
            let stream = await receiver.subscribe()
            for await item in stream {
                self?.consume(item)
            }
        }

        let spatial = SpatialOpReceiver(demux: demux)
        self.spatialReceiver = spatial
        spatialTask = Task { [weak self] in
            await spatial.connect()
            let stream = await spatial.subscribe()
            for await materialized in stream {
                self?.consumeSpatial(materialized)
            }
        }

        // CloudKit mode only: that transport's inbound stream is fed ONLY by
        // fetchChanges() — the app-lifecycle layer owns the poll. Without
        // this loop the receivers above subscribe to a stream nothing ever
        // writes to (the pre-ticket-85 false-Live masked this). The relay
        // transport polls itself, so no loop exists to forget there.
        if let cloudKit = syncTransport {
            fetchTask = Task { [weak self] in
                while !Task.isCancelled {
                    var report: String
                    do {
                        report = try await cloudKit.fetchChangesWithReport()
                    } catch {
                        report = "FAILED: \(String(describing: error))"
                    }
                    print("[companion-fetch] \(report)")
                    Self.appendFetchLog(report)
                    guard let self else { return }
                    await MainActor.run { self.lastFetchReport = report }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    /// Foreground/manual refresh: one immediate fetch pass.
    func refreshNow() async {
        if relayTransport != nil {
            print("[companion-fetch] manual refresh: relay polls continuously")
            Self.appendFetchLog("manual refresh: relay polls continuously")
            return
        }
        guard let syncTransport else { return }
        var report: String
        do {
            report = try await syncTransport.fetchChangesWithReport()
        } catch {
            report = "FAILED: \(String(describing: error))"
        }
        print("[companion-fetch] manual \(report)")
        Self.appendFetchLog("manual \(report)")
        lastFetchReport = report
    }

    // stdout/os_log are unreadable in this dev environment (see
    // _PHONE_SYNC_HANDOFF.md gotchas), so fetch reports also land in
    // <container>/Documents/companion-fetch.log — read it on the simulator via
    // `xcrun simctl get_app_container <device> dev.dylanreedx.continuum data`.
    nonisolated private static func appendFetchLog(_ line: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("companion-fetch.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    func unpairThisPhone() async {
        // Remove every server-side push registration while the phone
        // credential is still available. Unpair remains local-successful even
        // if the relay is temporarily unreachable; desktop revocation is the
        // authoritative final backstop for that credential.
        await SystemSurfaceCoordinator.shared.unregisterRelayPushTokens()
        do {
            try pairedSessionStore.clear()
        } catch {
            pairingStatusMessage = "Could not clear the saved pairing. Try again."
            return
        }

        await tearDownSyncReceivers()
        UserDefaults.standard.removeObject(forKey: Self.relayCursorDefaultsKey)
        UserDefaults.standard.removeObject(forKey: RelayClientConfig.urlDefaultsKey)
        pairedSessionState = .unpaired
        state = .unpaired
        transportAvailability = .connecting
        latestActivityFreshness = nil
        latestSpatialFreshness = nil
        snapshot = .empty
        rows = []
        canvasScene = CanvasScene(zones: [], tiles: [])
        lastApprovalAck = nil
        canvasFocusRequest = nil
        canvasHighlightedTileId = nil
        canvasEditError = nil
        canvasFocusError = nil
        pairingStatusMessage = "Unpaired this phone. Pair again from your Mac to reconnect."
        await SystemSurfaceCoordinator.shared.clear()
    }

    private func tearDownSyncReceivers() async {
        taskObservationTask?.cancel()
        taskObservationTask = nil
        taskObservation = nil
        notificationDestination = nil
        agentNavigationPath = []
        let activityReceiver = receiver
        let spatial = spatialReceiver
        task?.cancel()
        spatialTask?.cancel()
        fetchTask?.cancel()
        relayStateTask?.cancel()
        transcriptControlTask?.cancel()
        transcriptTask?.cancel()
        relayTransport?.stop()
        task = nil
        spatialTask = nil
        fetchTask = nil
        relayStateTask = nil
        transcriptControlTask = nil
        transcriptTask = nil
        relayTransport = nil
        commandChannel = nil
        receiver = nil
        self.spatialReceiver = nil
        let transcript = transcriptReceiver
        transcriptReceiver = nil
        demux = nil
        syncTransport = nil
        if let activityReceiver {
            await activityReceiver.stop()
        }
        if let spatial {
            await spatial.stop()
        }
        if let transcript {
            await transcript.stop()
        }
    }

    func activity(for agentId: UUID) -> AgentActivity? {
        snapshot.byAgent[agentId]
    }

    var approvalRows: [AgentsBoardRow] {
        AgentsBoardProjection.approvalsInboxRows(from: snapshot)
    }

    var attentionCount: Int {
        AgentsBoardProjection.attentionCount(from: snapshot)
    }

    func respondToApproval(agentId: UUID, requestId: String, decision: ApprovalDecision) async throws -> ApprovalResponseOutcome {
        guard canMutateFromFreshness else {
            throw ApprovalSendError.freshnessBlocked(freshness.actionBlocker ?? "Reconnect to act")
        }
        if let commandChannel {
            let payload = try JSONEncoder().encode(CompanionApprovalCommand(requestId: requestId, decision: decision))
            let status = try await Self.relayCommand { try await commandChannel.send(
                .init(idempotencyKey: UUID(), kind: RelayCommandKind.approvalRespond, agentID: agentId, payload: payload),
                waitingUpTo: Self.approvalAckTimeout) }
            let outcome = try Self.commandOutcome(status, as: ApprovalResponseOutcome.self)
            lastApprovalAck = ApprovalResponseAck(requestId: requestId, outcome: outcome)
            return outcome
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
            try await demux.send(.approvalResponse(ApprovalResponseRequest(agentId: agentId, requestId: requestId, decision: decision)))
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

    /// Hosted pairings key transcripts from the secret in the pairing link
    /// (plan 104 step 2); the relay never sees it. A hosted phone paired before
    /// that has no key the Mac can match. Local pairings keep the session token.
    private func transcriptChannel(for session: PairedCompanionSession) -> TranscriptChannelKey? {
        guard commandChannel != nil else {
            return TranscriptSyncCrypto.derivePairedSessionChannel(token: session.token, pairingID: session.instanceId)
        }
        guard let secret = session.pairingSecret else {
            transcriptsNeedRepair = true
            return nil
        }
        return TranscriptSyncCrypto.derivePairingSecretChannel(secret: secret, instanceID: session.instanceId)
    }

    /// Hosted relay: ask the Mac for one agent's transcript through the command
    /// queue (the relay refuses phone-published events). The Mac answers with
    /// an encrypted event the receiver opens; only changed versions are sent.
    /// The Mac's answer becomes the card's sentence when nothing can be shown.
    func requestTranscript(agentId: UUID) async {
        guard let commandChannel, let transcriptReceiver,
              case .paired(let session) = pairedSessionState,
              let channel = transcriptChannel(for: session) else { return }
        await transcriptReceiver.follow(agentIDs: [agentId])
        let known = await transcriptReceiver.currentDocument(agentID: agentId)?.version
        guard let payload = try? JSONEncoder().encode(CompanionTranscriptRequest(keyID: channel.keyID, knownVersion: known)) else { return }
        let status: RelayCommandStatus
        do {
            status = try await commandChannel.send(
                .init(idempotencyKey: UUID(), kind: RelayCommandKind.transcriptRequest, agentID: agentId, payload: payload),
                waitingUpTo: .seconds(4))
        } catch RelayCommandChannel.Failure.http(let code, _) where code == 400 || code == 404 {
            // A relay from before transcript requests: unknown kind or no status route.
            transcriptNotes[agentId] = "The relay needs an update before your phone can show transcripts."
            return
        } catch {
            return
        }
        switch (status.state, status.outcome.flatMap(CompanionTranscriptOutcome.init(rawValue:))) {
        case (.pending, _):
            transcriptNotes[agentId] = "Waiting for your Mac. The transcript appears when it is online."
        case (.completed, .published?), (.completed, .unchanged?), (.expired, _):
            transcriptNotes[agentId] = nil
        case (.completed, .unavailable?):
            transcriptNotes[agentId] = "Your Mac has no transcript for this agent yet."
        case (.completed, .unknownKey?):
            transcriptsNeedRepair = true
            transcriptNotes[agentId] = nil
        case (.completed, .unauthorized?):
            transcriptNotes[agentId] = "This iPhone is not allowed to read transcripts. Pair it again from your Mac."
        case (.completed, .failed?):
            transcriptNotes[agentId] = "Your Mac could not send this transcript."
        case (.completed, nil):
            // "unsupported": a Mac from before transcript requests.
            transcriptNotes[agentId] = "Update Array on your Mac to read transcripts here."
        }
    }

    /// Sends this agent's draft (or re-sends its sealed request) and records
    /// the Mac's answer here, so it lands even if the composer has gone.
    func sendMessage(agentId: UUID) async {
        guard let request = messageDrafts[agentId].beginSend(seal: { makeMessage(agentId: agentId, text: $0) }) else { return }
        let result = await deliver(request)
        messageDrafts[agentId].finish(result, for: request.idempotencyKey)
    }

    /// A message the Mac has not answered yet: keep asking until it does.
    func pollMessage(agentId: UUID) async {
        while !Task.isCancelled, let key = messageDrafts[agentId].pollKey {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            messageDrafts[agentId].finish(await messageStatus(key), for: key)
        }
    }

    /// Whether this phone can message agents: the relay granted it and the
    /// pairing carries the secret the text is sealed with.
    var canMessageAgents: Bool {
        guard grantedScope.contains(.agentMessage), commandChannel != nil,
              case .paired(let session) = pairedSessionState else { return false }
        return session.pairingSecret != nil
    }

    /// One draft's message, sealed once. Retrying must resend these exact
    /// bytes: a new seal has a new nonce, and the relay refuses a known key
    /// carrying different bytes.
    func makeMessage(agentId: UUID, text: String) -> RelayCommandRequest? {
        guard case .paired(let session) = pairedSessionState,
              let channel = transcriptChannel(for: session) else { return nil }
        let key = UUID()
        guard let sealed = try? TranscriptSyncCrypto.sealMessage(text, channel: channel, idempotencyKey: key, agentID: agentId),
              let payload = try? JSONEncoder().encode(sealed) else { return nil }
        return RelayCommandRequest(idempotencyKey: key, kind: RelayCommandKind.agentMessage, agentID: agentId, payload: payload)
    }

    /// Sends (or re-sends) the message and waits briefly for the Mac's answer.
    func deliver(_ request: RelayCommandRequest) async -> PhoneMessageDelivery {
        guard let commandChannel else { return .unreachable("Messaging needs the hosted relay.") }
        do {
            return Self.messageDelivery(try await commandChannel.send(request, waitingUpTo: Self.approvalAckTimeout))
        } catch {
            return Self.messageDelivery(error)
        }
    }

    /// What became of a message already sent, without sending it again.
    func messageStatus(_ key: UUID) async -> PhoneMessageDelivery {
        guard let commandChannel else { return .unreachable("Messaging needs the hosted relay.") }
        do { return Self.messageDelivery(try await commandChannel.status(key)) } catch { return Self.messageDelivery(error) }
    }

    private static func messageDelivery(_ status: RelayCommandStatus) -> PhoneMessageDelivery {
        switch status.state {
        case .pending: return .waiting
        case .expired: return .refused("Your Mac didn't pick this up within 10 minutes, so nothing was sent.")
        case .completed: break
        }
        switch status.outcome.flatMap(AgentMessageOutcome.init(rawValue:)) {
        case .accepted?: return .accepted
        case .busy?: return .refused("The agent is working. Send this when it finishes.")
        case .notReady?: return .refused("The agent's CLI can't take a message right now. Check it on your Mac.")
        case .notFound?: return .refused("Your Mac no longer has this agent.")
        case .empty?: return .refused("Type a message first.")
        case .unauthorized?: return .refused("This iPhone isn't allowed to message agents. Pair it again from your Mac.")
        case .unknownKey?, .invalid?: return .refused("Your Mac couldn't open this message. Pair this iPhone again from your Mac.")
        case .unsupported?, nil: return .refused("Update Array on your Mac to send messages from your phone.")
        case .refused?: return .refused("Your Mac didn't take this message. The agent may be in use somewhere else.")
        case .interrupted?: return .refused("Your Mac restarted while sending this. Check the agent before sending it again.")
        }
    }

    private static func messageDelivery(_ error: Error) -> PhoneMessageDelivery {
        switch error {
        case RelayCommandChannel.Failure.http(let code, _) where code == 400 || code == 404:
            return .refused("The relay needs an update before your phone can send messages.")
        case RelayCommandChannel.Failure.http(403, _):
            return .refused("This iPhone isn't allowed to message agents. Pair it again from your Mac.")
        default:
            return .unreachable("Couldn't reach the relay. Try again.")
        }
    }

    func stopAgent(agentId: UUID) async throws -> AgentStopOutcome {
        guard grantedScope.contains(.agentStop) else { return .unauthorized }
        guard canMutateFromFreshness else { return .stale }
        if let commandChannel {
            let status = try await Self.relayCommand { try await commandChannel.send(
                .init(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agentId),
                waitingUpTo: Self.approvalAckTimeout) }
            return try Self.commandOutcome(status, as: AgentStopOutcome.self)
        }
        guard let demux else { return .stale }
        let request = AgentStopRequest(agentID: agentId)
        let stream = await demux.subscribe()
        let ackTask = Task<AgentStopOutcome, Error> {
            for await message in stream {
                guard case .agentStopAck(let ack) = message,
                      ack.requestID == request.requestID else { continue }
                await MainActor.run { self.lastStopAck = ack }
                return ack.outcome
            }
            throw ApprovalSendError.unavailable
        }
        defer { ackTask.cancel() }
        try await demux.send(.agentStopRequest(request))
        return try await withThrowingTaskGroup(of: AgentStopOutcome.self) { group in
            group.addTask { try await ackTask.value }
            group.addTask {
                try await Task.sleep(for: Self.approvalAckTimeout)
                throw ApprovalSendError.ackTimedOut
            }
            guard let result = try await group.next() else { return .stale }
            group.cancelAll()
            return result
        }
    }

    /// A relay older than the command queue has no status route (404).
    private static func relayCommand(_ body: () async throws -> RelayCommandStatus) async throws -> RelayCommandStatus {
        do { return try await body() } catch RelayCommandChannel.Failure.http(404, _) { throw ApprovalSendError.relayTooOld }
    }

    /// The Mac's word for what it did, or why there is none yet.
    private static func commandOutcome<Outcome: RawRepresentable>(_ status: RelayCommandStatus, as: Outcome.Type) throws -> Outcome where Outcome.RawValue == String {
        switch status.state {
        case .pending: throw ApprovalSendError.awaitingMac
        case .expired: throw ApprovalSendError.expired
        case .completed:
            guard let raw = status.outcome, let outcome = Outcome(rawValue: raw) else { throw ApprovalSendError.unavailable }
            return outcome
        }
    }

    func pairFromURL(_ url: URL) async {
        await pairFromString(url.absoluteString)
    }

    func handleIncomingURL(_ url: URL) async {
        if PairingURL.parsePayload(url) != nil {
            await pairFromURL(url)
        } else {
            pendingDeepLink = url
        }
    }

    func pairFromString(_ rawValue: String) async {
        guard !pairingInProgress else {
            Self.appendFetchLog("pairing: skipped — another pairing in progress")
            return
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.appendFetchLog("pairing: received link (\(trimmed.prefix(28))…)")
        guard let url = URL(string: trimmed),
              let payload = PairingURL.parsePayload(url) else {
            pairingStatusMessage = "That is not a valid Continuum pairing link."
            Self.appendFetchLog("pairing: FAILED — link did not parse")
            return
        }
        let isHostedWebLink = url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "arrayapp.dev"
            && url.path == "/pair"
        let isHostedCustomLink = [PairingURL.scheme, PairingURL.legacyScheme]
            .contains(url.scheme?.lowercased() ?? "")
            && url.host?.lowercased() == PairingURL.host
            && payload.endpoint == nil
        let hostedPairing = isHostedWebLink || isHostedCustomLink
        if let endpoint = payload.endpoint,
           !(endpoint.scheme == "http" && endpoint.path == "/pair") {
            pairingStatusMessage = "Pairing link endpoint is not supported. Generate a new QR code from the Mac."
            Self.appendFetchLog("pairing: FAILED — unsupported endpoint \(endpoint.absoluteString)")
            return
        }
        guard payload.endpoint != nil || hostedPairing else {
            pairingStatusMessage = "Pairing link is missing its exchange endpoint. Generate a new QR code from the Mac."
            Self.appendFetchLog("pairing: FAILED — no exchange endpoint in link")
            return
        }
        pairingInProgress = true
        pairingStatusMessage = "Pairing with your Mac…"
        defer { pairingInProgress = false }
        do {
            let pairedSession: PairedCompanionSession
            let relayHTTPOrigin: URL?
            if hostedPairing {
                let exchange = try await exchangeHostedPairing(payload: payload)
                guard let companionScope = HostedPairingPolicy.companionScope(
                    capabilities: exchange.capabilities,
                    credential: exchange.credential
                ) else {
                    throw LocalPairingUIError.invalidHostedProvisioning
                }
                pairedSession = PairedCompanionSession(
                    instanceId: exchange.instanceID,
                    userId: exchange.instanceID,
                    deviceId: exchange.deviceID,
                    sessionId: exchange.deviceID,
                    token: exchange.credential,
                    scopes: companionScope,
                    issuedAt: .now,
                    expiresAt: .distantFuture,
                    pairingSecret: payload.secret
                )
                relayHTTPOrigin = HostedPairingPolicy.relayHTTPOrigin(
                    advertisedURL: payload.relay,
                    allowLoopback: Self.allowsHostedRelayLoopback
                )
            } else if let endpoint = payload.endpoint {
                Self.appendFetchLog("pairing: exchanging with \(endpoint.absoluteString)")
                let sessionResponse = try await exchangeLocalPairing(payload: payload, endpoint: endpoint)
                pairedSession = sessionResponse.pairedSession
                relayHTTPOrigin = payload.relay.flatMap(Self.relayHTTPOrigin(from:))
            } else {
                throw LocalPairingUIError.exchangeRejected("missing_endpoint")
            }
            if let expectedInstanceId = payload.instanceId,
               expectedInstanceId != pairedSession.instanceId {
                throw LocalPairingUIError.instanceMismatch
            }
            // The Keychain write is the first durable use of the one-time
            // plaintext credential returned by the relay exchange.
            try pairedSessionStore.save(pairedSession)
            pairedSessionState = .paired(pairedSession)
            state = .loading
            pairingStatusMessage = "Paired to your Array Mac. Starting sync…"
            // Ticket 86: pairing is the configuration handoff — adopt the
            // relay URL the Mac advertised, unless one is already set (the
            // sim keeps its loopback override).
            if let relay = relayHTTPOrigin,
               hostedPairing || UserDefaults.standard.string(forKey: RelayClientConfig.urlDefaultsKey) == nil {
                UserDefaults.standard.set(relay.absoluteString, forKey: RelayClientConfig.urlDefaultsKey)
                Self.appendFetchLog("pairing: adopted relay URL from link — \(relay.absoluteString)")
            }
            Self.appendFetchLog("pairing: SUCCESS — session saved, restarting sync")
            // A re-pair while a transport is already running must not no-op
            // on start()'s task-guard: tear down so the fresh token is used.
            await tearDownSyncReceivers()
            await start()
        } catch {
            pairingStatusMessage = Self.pairingMessage(for: error)
            Self.appendFetchLog("pairing: FAILED — \(String(describing: error))")
        }
    }

    private func exchangeHostedPairing(payload: PairingURL.Payload) async throws -> RelayCompanionProvisioning {
        guard let origin = HostedPairingPolicy.relayHTTPOrigin(
            advertisedURL: payload.relay,
            allowLoopback: Self.allowsHostedRelayLoopback
        ) else {
            throw LocalPairingUIError.exchangeRejected("invalid_relay")
        }
        Self.appendFetchLog("pairing: exchanging with hosted Array Relay")
        // Messaging needs the pairing secret to seal the text, so only a link
        // that carries one asks for it.
        return try await HostedRelayAPI(baseURL: origin).exchangePairingGrant(
            code: payload.token,
            deviceLabel: UIDevice.current.name,
            wantsMessages: payload.secret != nil ? true : nil
        )
    }

    private static var allowsHostedRelayLoopback: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func relayHTTPOrigin(from socketURL: URL?) -> URL? {
        guard let socketURL,
              var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        case "https", "http": break
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func exchangeLocalPairing(payload: PairingURL.Payload, endpoint: URL) async throws -> LocalPairingSessionResponse {
        let requestBody = LocalPairingExchangeRequest(
            token: payload.token,
            deviceLabel: UIDevice.current.name,
            requestedScope: (payload.scopes ?? .observer).rawValue
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200 else {
                    let code = (try? JSONDecoder().decode(LocalPairingErrorResponse.self, from: data).error) ?? "HTTP \(statusCode)"
                    throw LocalPairingUIError.exchangeRejected(code)
                }
                return try JSONDecoder().decode(LocalPairingSessionResponse.self, from: data)
            } catch {
                guard Self.shouldRetryLocalPairing(error), attempt < Self.pairingRetryDelays.count else {
                    throw error
                }
                let delay = Self.pairingRetryDelays[attempt]
                attempt += 1
                try? await Task.sleep(for: delay)
            }
        }
    }

    private static func shouldRetryLocalPairing(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }

    private static func pairingMessage(for error: Error) -> String {
        if let error = error as? LocalPairingUIError {
            return error.message
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            if code == .appTransportSecurityRequiresSecureConnection {
                return "iOS blocked the local pairing link. Install the latest TestFlight build and allow Local Network access for Continuum."
            }
            return "Could not reach your Mac (network error \(nsError.code)). Keep both devices on the same Wi-Fi, allow Local Network access for Continuum, and try a fresh QR code."
        }
        return "Pairing failed. Generate a fresh QR code from the Mac and try again."
    }

    private struct LocalPairingErrorResponse: Decodable {
        var error: String
    }

    private enum LocalPairingUIError: Error {
        case exchangeRejected(String)
        case instanceMismatch
        case invalidHostedProvisioning

        var message: String {
            switch self {
            case .exchangeRejected(let code):
                switch code {
                case "alreadyUsed": return "That pairing code was already used. Generate a fresh QR code from the Mac."
                case "expired", "pairingWindowExpired", "pairingWindowStopped": return "That pairing code expired. Generate a fresh QR code from the Mac."
                case "scopeNotGranted": return "The Mac rejected the requested pairing scope. Generate a fresh QR code."
                case "invalidToken": return "The Mac rejected this pairing code. Generate a fresh QR code."
                case "invalid_relay": return "This pairing link does not use Array’s trusted relay. Generate a fresh QR code from Array on your Mac."
                default: return "The Mac rejected pairing (\(code)). Generate a fresh QR code and try again."
                }
            case .instanceMismatch:
                return "Pairing response came from a different Continuum instance. Generate a fresh QR code from this Mac."
            case .invalidHostedProvisioning:
                return "The relay returned an invalid companion profile. Generate a fresh QR code and try again."
            }
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
        Task {
            await SystemSurfaceCoordinator.shared.publish(
                rows: rows,
                attentionCount: attentionCount,
                instanceID: pairedInstanceID
            )
        }
        if let transcriptReceiver, commandChannel == nil {
            let agentIDs = rows.map(\.agentId)
            Task { await transcriptReceiver.connect(agentIDs: agentIDs) }
        }
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
        guard Self.authoritativeCanvasMutationEnabled else {
            canvasEditError = "Canvas editing is read-only until the Mac acknowledges synced changes."
            return
        }
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
        guard Self.authoritativeCanvasMutationEnabled else {
            canvasEditError = "Canvas editing is read-only until the Mac acknowledges synced changes."
            return
        }
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
                    guard let self else { return }
                    self.freshnessNow = Date()
                    if let transcriptReceiver = self.transcriptReceiver, self.commandChannel == nil {
                        let agentIDs = self.rows.map(\.agentId)
                        Task { await transcriptReceiver.connect(agentIDs: agentIDs) }
                    }
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

    private static func diagnosticsSummary(for sample: CompanionFreshnessSample?, fallback: String) -> String {
        guard let sample else { return fallback }
        let metadata = sample.metadata
        let spatial = metadata.spatialWatermark ?? "-"
        let activity = metadata.activityWatermark ?? "-"
        return "seq=\(metadata.sequence) published=\(metadata.publishedAt.ISO8601Format()) spatial=\(spatial) activity=\(activity)"
    }
}

/// Where a phone message stands.
private enum ApprovalSendError: LocalizedError {
    case unavailable
    case ackTimedOut
    case awaitingMac
    case expired
    case relayTooOld
    case freshnessBlocked(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Approval channel is not connected."
        case .ackTimedOut:
            "Approval response timed out."
        case .awaitingMac:
            "Sent. Your Mac hasn't picked it up yet; it will if it comes online in the next 10 minutes."
        case .expired:
            "Your Mac didn't pick this up in time, so nothing happened."
        case .relayTooOld:
            "The relay needs an update before your phone can do this."
        case .freshnessBlocked(let message):
            message
        }
    }
}

private struct AgentsBoardView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @Binding var selectedTab: ContinuumTab

    var body: some View {
        NavigationStack(path: $model.agentNavigationPath) {
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
            .tokenBackground(.canvas, ignoringSafeArea: true)
            .navigationTitle("Agents")
            .alert("Agent link unavailable", isPresented: Binding(get: { model.agentNavigationError != nil }, set: { if !$0 { model.agentNavigationError = nil } })) {
                Button("OK") { model.agentNavigationError = nil }
            } message: { Text(model.agentNavigationError ?? "") }
            .navigationDestination(for: UUID.self) { agentId in
                AgentDetailView(agentId: agentId, selectedTab: $selectedTab)
            }
        }
    }

    private var agentsList: some View {
        List(model.rows) { row in
            NavigationLink(value: row.agentId) {
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
                            .tokenBackground(.canvas, ignoringSafeArea: true)
                    } else {
                        WaitingForMacView(freshness: model.freshness)
                    }
                } else {
                    List(model.approvalRows) { row in
                        NavigationLink(value: row.agentId) {
                            AgentRowView(row: row)
                        }
                        .listRowBackground(Color.orange.opacity(0.12))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .tokenBackground(.canvas, ignoringSafeArea: true)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.freshness.state != .unpaired {
                    FreshnessFooter(freshness: model.freshness)
                }
            }
            .navigationTitle("Approvals")
            .navigationDestination(for: UUID.self) { agentId in
                AgentDetailView(agentId: agentId, selectedTab: $selectedTab)
            }
        }
    }
}

private struct AgentRowView: View {
    let row: AgentsBoardRow

    var body: some View {
        HStack(spacing: 12) {
            if DualPlaneGyroIndicatorModel.isActive(status: row.status) {
                DualPlaneGyroIndicator(isActive: true)
            } else {
                StatusGlyphView(status: row.status)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusChipView(status: row.status, terminalOutcome: row.terminalOutcome)
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
    // P2A.8: the detail view is addressed by AGENT. Its tile, if it has one, is a
    // view hint on the row — which is why "Show on canvas" below is conditional.
    let agentId: UUID
    @Binding var selectedTab: ContinuumTab
    @State private var stopNote: String?
    @State private var stopping = false

    private var row: AgentsBoardRow? {
        model.rows.first { $0.agentId == agentId }
    }

    private var activity: AgentActivity? {
        model.activity(for: agentId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let destination = model.notificationDestination, destination.agentID == agentId {
                    notificationTaskContext(destination)
                }
                if let row, let activity {
                    DetailHeader(row: row)
                    if let parentID = model.parentByChild[agentId] {
                        NavigationLink(value: parentID) {
                            Label("Parent agent", systemImage: "arrow.turn.up.left")
                                .font(.subheadline)
                        }
                    }
                    if let document = model.transcripts[agentId] {
                        MobileSemanticTranscriptView(document: document)
                    } else {
                        TranscriptAvailabilityCard(
                            hasPermission: model.grantedScope.contains(.transcriptRead),
                            needsRepair: model.transcriptsNeedRepair,
                            note: model.transcriptNotes[agentId])
                    }
                    if model.canMessageAgents {
                        PhoneMessageComposer(agentId: agentId)
                    }
                    if row.status == .needsAttention {
                        PendingAttentionCard(activity: activity, grantedScope: model.grantedScope, freshness: model.freshness) { target, decision in
                            try await model.respondToApproval(
                                agentId: target.agentId,
                                requestId: target.approvalRequestId,
                                decision: decision
                            )
                        }
                    }
                    // A headless agent has no tile to show, so the button is ABSENT
                    // rather than present-and-broken (P2A.8).
                    if let tileId = row.tileId {
                        Button {
                            model.requestCanvasFocus(tileId: tileId)
                            selectedTab = .canvas
                        } label: {
                            Label("Show on canvas", systemImage: "square.grid.2x2")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    if model.grantedScope.contains(.agentStop) {
                        Button(role: .destructive) {
                            stopping = true
                            Task {
                                do {
                                    let outcome = try await model.stopAgent(agentId: agentId)
                                    switch outcome {
                                    case .stopped: stopNote = "Stopped this agent."
                                    case .notRunning: stopNote = "Nothing to stop: this agent isn't working on anything."
                                    case .notFound: stopNote = "Your Mac doesn't have this agent any more."
                                    case .unauthorized: stopNote = "This phone isn't allowed to stop agents."
                                    case .stale: stopNote = "Reconnect to your Mac to stop this agent."
                                    case .unsupported: stopNote = "This agent can't be stopped from the phone right now."
                                    }
                                } catch {
                                    stopNote = error.localizedDescription
                                }
                                stopping = false
                            }
                        } label: {
                            Label(stopping ? "Stopping…" : "Stop agent", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(stopping || !model.canMutateFromFreshness)
                    }
                    if let stopNote {
                        Text(stopNote).font(.caption).foregroundStyle(.secondary)
                    }

                    TimelineView(
                        events: AgentsBoardProjection.timelineEvents(for: activity),
                        showsActiveIndicator: DualPlaneGyroIndicatorModel.isActive(status: row.status)
                    )
                } else {
                    Text("Agent activity is no longer available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                }
            }
            .padding()
        }
        .tokenBackground(.canvas, ignoringSafeArea: true)
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { FreshnessFooter(freshness: model.freshness) }
        // Hosted relay: ask for this agent's transcript while it is open. A
        // quiet agent costs one small command per cycle; the Mac sends the
        // transcript only when its version changed.
        .task(id: agentId) {
            while !Task.isCancelled {
                await model.requestTranscript(agentId: agentId)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func notificationTaskContext(_ destination: CompanionAgentDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From your notification").font(.headline)
            if let observation = model.taskObservation, let task = observation.task(for: destination) {
                let detail = CompanionTaskDetail(task: task)
                Text(detail.summary).font(.subheadline)
                Text("\(detail.succeeded) finished · \(detail.running) running · \(detail.queued) queued · \(detail.blocked) need attention")
                    .font(.caption).foregroundStyle(.secondary)
                if detail.uncertain {
                    Text("The Mac has not confirmed all participating work. This is not a completed-task claim.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(task.members.filter { !$0.state.terminal }, id: \.runID) { member in
                    NavigationLink(value: member.agentID) {
                        Label("Agent \(member.agentID.uuidString.prefix(8)) · \(member.state.rawValue)", systemImage: "person.crop.circle")
                            .font(.caption)
                    }
                }
                Text("Last task update: \(observation.publishedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(destination.taskID == nil
                     ? "This older notification identifies the agent, but not its task. The conversation below may include newer work."
                     : "Task context is unavailable. Reconnect to the Mac to check what remains; the agent may have moved to newer work.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tokenBackground(.panel)
    }
}

/// Message an agent from the phone (plan 104 step 3). The draft and its
/// sealed request live in the model (`PhoneMessageDraft`), so leaving the
/// agent and coming back keeps the text, the waiting state and the same key.
private struct PhoneMessageComposer: View {
    @EnvironmentObject private var model: AgentsBoardModel
    let agentId: UUID

    private var draft: PhoneMessageDraft { model.messageDrafts[agentId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message this agent", text: Binding(
                    get: { draft.text },
                    set: { model.messageDrafts[agentId].edit($0) }
                ), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.locked)
                Button {
                    Task { await model.sendMessage(agentId: agentId) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.locked || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
            }
            if let line = statusLine {
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .tokenBackground(.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Restarts on return to this agent while the Mac has not answered.
        .task(id: draft.pollKey) {
            await model.pollMessage(agentId: agentId)
        }
    }

    private var statusLine: String? {
        switch draft.delivery {
        case nil: return draft.sending ? "Sending…" : nil
        case .accepted?: return "Sent to the agent."
        case .waiting?: return "Waiting for your Mac. It sends this when it comes online in the next 10 minutes."
        case .refused(let line)?, .unreachable(let line)?: return line
        }
    }
}

private struct TranscriptAvailabilityCard: View {
    let hasPermission: Bool
    let needsRepair: Bool
    let note: String?

    var body: some View {
        Label(
            !hasPermission
                ? "This paired device has activity-only access. Re-pair with transcript permission to read conversations."
                : needsRepair
                    ? "Pair this iPhone again from your Mac to read transcripts. Activity remains available."
                    : note ?? "Loading the transcript from your Mac…",
            systemImage: hasPermission ? "lock.rotation" : "lock"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tokenBackground(.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MobileSemanticTranscriptView: View {
    let document: AgentDocument

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(document.entries, id: \.id.rawValue) { entry in
                VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 8) {
                    ForEach(entry.blocks, id: \.id.rawValue) { block in
                        MobileSemanticBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
                .padding(entry.role == .user ? 10 : 0)
                .background(entry.role == .user ? Color.secondary.opacity(0.10) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent transcript")
    }
}

private struct MobileSemanticBlockView: View {
    let block: AgentBlock

    var body: some View {
        switch block.payload {
        case .paragraph(let inline), .heading(_, let inline):
            Text(Self.text(inline))
                .font(block.kind == .heading ? .headline : .body)
                .textSelection(.enabled)
        case .agentReference(let reference):
            NavigationLink(value: reference.agentID) {
                Label(reference.displayNameAtSpawn, systemImage: "person.crop.circle.badge.arrow.forward")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Open subagent \(reference.displayNameAtSpawn)")
        case .toolCall(let tool):
            Label(tool.summary ?? tool.name, systemImage: "wrench.and.screwdriver")
                .font(.subheadline).foregroundStyle(.secondary)
        case .commandOutput(let command):
            Text(command.text).font(.caption.monospaced()).textSelection(.enabled)
        case .error(let error):
            Label(error.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .notice(let notice):
            Text(Self.text(notice.message)).font(.subheadline).foregroundStyle(.secondary)
        default:
            if !block.children.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(block.children, id: \.id.rawValue) { child in
                        MobileSemanticBlockView(block: child)
                    }
                }
            }
        }
    }

    private static func text(_ inline: [AgentInline]) -> String {
        inline.map { value in
            switch value {
            case .text(let value), .code(let value): return value
            case .emphasis(let children), .strong(let children): return text(children)
            case .link(_, _, let children): return text(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }
}

private struct DetailHeader: View {
    let row: AgentsBoardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusChipView(status: row.status, terminalOutcome: row.terminalOutcome)
                Spacer()
                Text(row.updatedAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(row.lastSummary.isEmpty ? "No activity yet" : row.lastSummary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(row.agentId.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
        .tokenBackground(.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingAttentionCard: View {
    let activity: AgentActivity
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
            case .sent:
                note = "Sent to the agent"
                isError = false
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
    let showsActiveIndicator: Bool

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
                    .tokenBackground(.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(events, id: \.compositeId) { event in
                    TimelineEventRow(event: event)
                }
            }
            if showsActiveIndicator {
                HStack {
                    DualPlaneGyroIndicator(isActive: true)
                    Spacer(minLength: 0)
                }
                .frame(height: DualPlaneGyroIndicatorModel.side)
                .accessibilityElement(children: .contain)
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

// P1.8: this took an `AgentStatusPresentation` and re-decoded its `colorToken`
// string through `AppColors`. The row's appearance is a pure function of its
// status, so it takes the status and reads the one shared presenter — the same
// one the desktop tile, title bar and sidebar now read.
//
// P1.12: the accent is the presenter's `TokenColor`, resolved for the phone's
// live appearance instead of pinned to `.dark`. `StatusPill` is gone: it was a
// second pill next to `StatusChipView`, which was compiled and referenced
// nowhere, so the shared component is now the one the app actually ships.
private struct StatusGlyphView: View {
    let status: AgentStatus

    var body: some View {
        let display = StatusChipPresenter.display(for: status)
        Text(display.glyph)
            .font(Font(role: .titleL))
            .tokenForeground(display.accent)
            .accessibilityLabel(status.rawValue)
    }
}

private struct LoadingBoardView: View {
    @EnvironmentObject private var model: AgentsBoardModel

    // The local pairing check resolves in milliseconds; if we are still here
    // with a paired session, the honest description of the wait is the remote
    // one — the Mac hasn't published (or the phone hasn't fetched) yet.
    private var message: String {
        if case .unpaired = model.pairedSessionState { return "Checking paired session" }
        return "Waiting for your Mac to publish…"
    }

    var body: some View {
        VStack(spacing: 12) {
            DualPlaneGyroIndicator(isActive: true)
                .scaleEffect(2.35)
                .frame(width: 44, height: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Array is connecting")
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairingRequiredView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @State private var pastedPairingURL = ""
    @State private var showingScanner = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Pair this phone")
                .font(.headline)
            Text("On your Mac, choose Pair Phone, then scan the QR code. If scanning is unavailable, paste the pairing link below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            VStack(spacing: 8) {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pairingInProgress)

                TextField("continuum://pair#…", text: $pastedPairingURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { @MainActor in
                        await model.pairFromString(pastedPairingURL)
                    }
                } label: {
                    if model.pairingInProgress {
                        ProgressView()
                    } else {
                        Text("Pair from Link")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.pairingInProgress || pastedPairingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            if let message = model.pairingStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Paired") ? .green : .orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                PairingQRCodeScannerView { code in
                    pastedPairingURL = code
                    showingScanner = false
                    Task { @MainActor in
                        await model.pairFromString(code)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Pairing QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingScanner = false }
                    }
                }
            }
        }
    }
}

private struct PairingQRCodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> PairingQRCodeScannerViewController {
        PairingQRCodeScannerViewController(onCode: onCode)
    }

    func updateUIViewController(_ uiViewController: PairingQRCodeScannerViewController, context: Context) {}
}

private final class PairingQRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "continuum.pairing.qr-scanner")
    private let onCode: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didConfigureSession = false
    private var didEmitCode = false

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSessionIfConfigured()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func requestCameraAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureSession() : self.showScannerMessage("Camera access is required to scan the pairing QR code.")
                }
            }
        default:
            showScannerMessage("Camera access is required to scan the pairing QR code.")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showScannerMessage("This device does not have an available camera.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showScannerMessage("Could not start the QR scanner.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        didConfigureSession = true
        addScannerHint()
        startSessionIfConfigured()
    }

    private func startSessionIfConfigured() {
        guard didConfigureSession else { return }
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    private func addScannerHint() {
        let label = UILabel()
        label.text = "Point the camera at the Continuum pairing QR code."
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func showScannerMessage(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didEmitCode,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr })?.stringValue else {
            return
        }
        didEmitCode = true
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        onCode(code)
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

    private var copy: (title: String, subtitle: String) {
        if case .offline(_, .transportUnavailable) = freshness.state {
            return ("Pair again from Array", "This pairing uses retired local sync. Unpair in Settings, then scan a new invitation from your relay-connected Mac.")
        }
        return ("Waiting for your Mac", freshness.subtitle)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(copy.title)
                .font(.headline)
            Text(copy.subtitle)
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
        .tokenBackground(.panel)
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
    // The mirror paints shapes (`Shape.fill`, a `ZStack` backdrop) rather than
    // views, so it needs token COLOURS, not the modifiers. One palette resolved
    // from this view's own colour scheme, which is the bridge's single
    // theme-resolution point (hygiene rule 4).
    @Environment(\.colorScheme) private var colorScheme
    private var palette: TokenPalette { TokenPalette(colorScheme) }

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

    private var canEdit: Bool {
        AgentsBoardModel.authoritativeCanvasMutationEnabled
            && model.canMutateFromFreshness
            && CanvasEditIntent.isEditingPermitted(scope: model.grantedScope)
    }
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
                    palette.color(SurfaceToken.canvas).ignoresSafeArea()
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
                .tokenBackground(.panel)
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
                        .tokenBackground(.panel)
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
                .fill(palette.color(SurfaceToken.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        // The resting outline is `LineToken.border` — the token
                        // for "the outline of an object", which is what a mirror
                        // tile is. It was `white@0.15`, which was fine while the
                        // phone only ever painted a dark panel and is invisible
                        // now that this ticket gives iOS a real light appearance:
                        // the same defect (a white hairline on a light surface)
                        // P1.11 measured at 1.68:1 and fixed on the desktop.
                        //
                        // The highlight/drag arm stays `Color.orange`: it is a
                        // selection AFFORDANCE, the class P1.11 deliberately left
                        // off tokens (the desktop paints selection in the user's
                        // own `controlAccentColor`). The two platforms disagree
                        // about it today — flagged for Phase 8, since making them
                        // agree is a decision about which one is right, not a
                        // token lookup.
                        .stroke(
                            isHighlighted ? Color.orange : (activeDragTileId == tile.tileId || activeResizeTileId == tile.tileId ? Color.orange : palette.color(LineToken.border)),
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
                    .background(Circle().fill(palette.color(SurfaceToken.panel)))
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
        let status = model.canvasStatusOverlays[tileId]?.status
        // No status yet is muted-and-faint, not a fresh grey: `textSecondary` is
        // the token the presenter itself uses for the two states that ask nothing
        // of you (idle, stale).
        let fill = status.map { palette.color(token: StatusChipPresenter.display(for: $0).accent) }
            ?? palette.color(TextToken.textSecondary).opacity(0.4)
        return Circle().fill(fill).frame(width: 7, height: 7)
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

// A zone's tint is the persisted `ZonePlacement.color` string the desktop wrote,
// and the desktop renders it through `ZoneChromeNSView.color(named:)`. This is
// deliberately NOT routed to `DesignTokens` even though P1.12 asked for it:
// P1.11 ruled that a zone's colour is USER configuration, not a semantic status,
// so mapping someone's "mint" onto `accentDone` would silently change what they
// picked — and it would make the phone paint a different hue than the Mac for the
// same zone, which is the exact "build once, render twice" failure this ticket
// exists to close.
//
// What WAS private and wrong is the vocabulary: this switch knew "amber",
// "teal", "pink" and "green" (which the desktop registry does not have, so the
// Mac painted them its teal default while the phone painted orange, teal, pink
// and green) and fell back to grey where the desktop falls back to teal. It is
// now name-for-name the desktop's registry, and
// `scripts/check-color-hygiene.sh` rule 5 compares the two switches every run so
// they cannot drift apart again.
private func zoneTint(for token: String) -> Color {
    switch token.lowercased() {
    case "mint": return .mint
    case "blue": return .blue
    case "purple": return .purple
    case "orange": return .orange
    case "red": return .red
    case "yellow": return .yellow
    default: return .teal
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
            .tokenBackground(.panel)
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
            .tokenBackground(.canvas, ignoringSafeArea: true)
            .navigationTitle(title)
        }
    }
}

private struct SettingsDiagnosticsView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @Environment(\.openURL) private var openURL
    @State private var confirmingUnpair = false
    @State private var notificationStatus = "Checking…"
    @State private var relayPushStatus = "Checking…"

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
                    if model.canUnpairThisPhone {
                        Button(role: .destructive) {
                            confirmingUnpair = true
                        } label: {
                            Label("Unpair This Phone", systemImage: "xmark.circle")
                        }
                        .disabled(model.pairingInProgress)
                    }
                }
                Section("Sync Diagnostics") {
                    diagnosticRow("Transport", model.diagnosticsTransportSummary)
                    diagnosticRow("Remote-backed live", model.diagnosticsRemoteBackedLiveSummary)
                    diagnosticRow("Transport mode", model.transportModeSummary)
                    diagnosticRow("Last fetch", model.lastFetchReport)
                    diagnosticRow("Latest activity", model.diagnosticsActivitySummary)
                    diagnosticRow("Latest spatial", model.diagnosticsSpatialSummary)
                    diagnosticRow("Rows / canvas tiles", "agents=\(model.diagnosticsAgentRowCount) canvasTiles=\(model.diagnosticsCanvasTileCount)")
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
                Section("System Surfaces") {
                    diagnosticRow("Notifications", notificationStatus)
                    diagnosticRow(
                        "Live Activities",
                        ActivityAuthorizationInfo().areActivitiesEnabled ? "Allowed" : "Disabled in iOS Settings"
                    )
                    diagnosticRow("Relay push registration", relayPushStatus)
                    let widgetSnapshot = ArrayWidgetSnapshotStore.read()
                    diagnosticRow(
                        "Home Screen widget",
                        widgetSnapshot.generatedAt == .distantPast
                            ? "Waiting for first synced agent snapshot"
                            : "Updated \(widgetSnapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    Button("Open iOS Notification Settings") {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                        openURL(url)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .tokenBackground(.canvas, ignoringSafeArea: true)
            .navigationTitle("Settings")
            .task {
                notificationStatus = await Self.notificationAuthorizationSummary()
                relayPushStatus = SystemSurfaceCoordinator.shared.registrationSummary
            }
            .alert("Unpair this phone?", isPresented: $confirmingUnpair) {
                Button("Unpair", role: .destructive) {
                    Task { @MainActor in
                        await model.unpairThisPhone()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the saved pairing token and stops Continuum sync on this phone. Pair again from the Mac to reconnect.")
            }
        }
    }

    private static func notificationAuthorizationSummary() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return "Not requested"
        case .denied: return "Disabled in iOS Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(nil)
        }
        .padding(.vertical, 4)
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

// P1.12 deleted `AppColors`. Its two dark-only literals were the phone's private
// disagreement with the desktop's surfaces (`SurfaceToken.canvas` / `.panel`
// carry both appearances), and `statusAccent(for:)` pinned every status hue to
// `.dark` — the TODO this ticket closes. The replacement is
// `DesignTokens+SwiftUI.swift`, which is the only place a theme is resolved.
