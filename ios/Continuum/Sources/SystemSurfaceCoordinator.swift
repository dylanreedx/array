import ActivityKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedRelayClient
import ContinuumRevivedRelayProtocol
import Foundation
import UIKit
import WidgetKit

@MainActor
final class SystemSurfaceCoordinator {
    static let shared = SystemSurfaceCoordinator()

    private var liveActivity: Activity<ArrayAgentActivityAttributes>?
    private var pushTokenTask: Task<Void, Never>?
    private var pushToStartTokenTask: Task<Void, Never>?
    private var relayAPI: HostedRelayAPI?
    private var relayCredential: String?
    private(set) var registrationSummary = "Waiting for hosted relay pairing"

    private init() {
        liveActivity = Activity<ArrayAgentActivityAttributes>.activities.first
        observePushTokenIfNeeded()
        observePushToStartTokenIfSupported()
    }

    func publish(rows: [AgentsBoardRow], attentionCount: Int, instanceID: UUID?) async {
        let snapshot = Self.snapshot(rows: rows, attentionCount: attentionCount, instanceID: instanceID)
        do {
            try ArrayWidgetSnapshotStore.write(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: "ArrayAgentStatusWidget")
        } catch {
            print("system surfaces: widget snapshot write failed: \(error.localizedDescription)")
        }

        try? await UNUserNotificationCenter.current().setBadgeCount(attentionCount)
        await updateLiveActivity(from: snapshot)
    }

    func configureRelayPushRegistration(baseURL: URL, credential: String) async {
        relayAPI = HostedRelayAPI(baseURL: baseURL)
        relayCredential = credential
        observePushToStartTokenIfSupported()
        var registered: [String] = []
        if let token = ArrayWidgetSnapshotStore.apnsPushToken(),
           await registerPushToken(token, kind: .apns) {
            registered.append("banners")
        }
        if let token = ArrayWidgetSnapshotStore.activityPushToken(),
           await registerPushToken(token, kind: .liveActivity) {
            registered.append("Live Activity")
        }
        if let token = ArrayWidgetSnapshotStore.activityPushToStartToken(),
           await registerPushToken(token, kind: .liveActivityStart) {
            registered.append("remote Live Activity starts")
        }
        registrationSummary = registered.isEmpty
            ? "Connected; waiting for Apple push tokens"
            : "Registered: \(registered.joined(separator: ", "))"
    }

    @discardableResult
    func registerPushToken(_ token: Data, kind: RelayPushRegistrationKind) async -> Bool {
        guard !token.isEmpty else { return false }
        guard let relayAPI, let relayCredential else {
            registrationSummary = "Token saved; waiting for hosted relay pairing"
            return false
        }
        do {
            let response = try await relayAPI.registerPushToken(token, kind: kind, credential: relayCredential)
            guard response.registered, response.kind == kind else {
                registrationSummary = "Relay rejected \(kind.rawValue) registration"
                return false
            }
            registrationSummary = "\(kind.displayName) registered with relay"
            return true
        } catch {
            registrationSummary = "\(kind.displayName) registration pending: \(error.localizedDescription)"
            return false
        }
    }

    func unregisterRelayPushTokens() async {
        defer {
            pushToStartTokenTask?.cancel()
            pushToStartTokenTask = nil
            relayAPI = nil
            relayCredential = nil
            ArrayWidgetSnapshotStore.clearPushTokens()
            registrationSummary = "Unpaired"
        }
        guard let relayAPI, let relayCredential else { return }
        for kind in RelayPushRegistrationKind.allCases {
            do {
                _ = try await relayAPI.unregisterPushToken(kind: kind, credential: relayCredential)
            } catch {
                print("system surfaces: \(kind.rawValue) unregister failed: \(error.localizedDescription)")
            }
        }
    }

    func clear() async {
        try? ArrayWidgetSnapshotStore.write(.empty)
        WidgetCenter.shared.reloadTimelines(ofKind: "ArrayAgentStatusWidget")
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        if let activity = liveActivity {
            await activity.end(nil, dismissalPolicy: .immediate)
            liveActivity = nil
            pushTokenTask?.cancel()
            pushTokenTask = nil
        }
    }

    private func updateLiveActivity(from snapshot: ArrayWidgetSnapshot) async {
        let state = Self.contentState(from: snapshot)
        if snapshot.runningCount == 0, snapshot.attentionCount == 0 {
            guard let activity = liveActivity else { return }
            let finalContent = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
            await activity.end(finalContent, dismissalPolicy: .after(Date().addingTimeInterval(20)))
            liveActivity = nil
            pushTokenTask?.cancel()
            pushTokenTask = nil
            return
        }

        if let activity = liveActivity {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(5 * 60)))
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let instanceID = snapshot.instanceID else { return }
        do {
            liveActivity = try Activity.request(
                attributes: ArrayAgentActivityAttributes(instanceID: instanceID, macName: "Mac"),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(5 * 60)),
                pushType: .token
            )
            observePushTokenIfNeeded()
        } catch {
            print("system surfaces: live activity start failed: \(error.localizedDescription)")
        }
    }

    private func observePushTokenIfNeeded() {
        guard pushTokenTask == nil, let liveActivity else { return }
        pushTokenTask = Task {
            for await tokenData in liveActivity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                ArrayWidgetSnapshotStore.storeActivityPushToken(token)
                _ = await self.registerPushToken(tokenData, kind: .liveActivity)
            }
        }
    }

    private func observePushToStartTokenIfSupported() {
        guard pushToStartTokenTask == nil else { return }
        if #available(iOS 17.2, *) {
            pushToStartTokenTask = Task {
                for await tokenData in Activity<ArrayAgentActivityAttributes>.pushToStartTokenUpdates {
                    guard !Task.isCancelled else { return }
                    let token = tokenData.map { String(format: "%02x", $0) }.joined()
                    ArrayWidgetSnapshotStore.storeActivityPushToStartToken(token)
                    _ = await self.registerPushToken(tokenData, kind: .liveActivityStart)
                }
            }
        }
    }

    private static func snapshot(rows: [AgentsBoardRow], attentionCount: Int, instanceID: UUID?) -> ArrayWidgetSnapshot {
        let running = rows.filter { $0.status == .configuring || $0.status == .working }
        let highlighted = rows.sorted(by: priority).first
        let phase: DualPlaneGyroPresentationPhase
        if let highlighted {
            phase = .resolve(status: highlighted.status, failed: highlighted.terminalOutcome == .failed || highlighted.terminalOutcome == .runtimeError)
        } else {
            phase = .idle
        }
        return ArrayWidgetSnapshot(
            generatedAt: .now,
            instanceID: instanceID,
            runningCount: running.count,
            attentionCount: attentionCount,
            phase: phase,
            highlightedAgent: highlighted.map { row in
                ArrayWidgetAgent(
                    id: row.agentId,
                    name: row.context?.displayName ?? row.context?.tileTitle ?? "Agent",
                    workspaceName: row.context?.workspaceName,
                    status: row.status,
                    startedAt: row.context?.createdAt ?? row.updatedAt
                )
            }
        )
    }

    private static func priority(_ lhs: AgentsBoardRow, _ rhs: AgentsBoardRow) -> Bool {
        func score(_ row: AgentsBoardRow) -> Int {
            if row.status == .needsAttention { return 0 }
            if row.terminalOutcome == .failed || row.terminalOutcome == .runtimeError { return 1 }
            if row.status == .working || row.status == .configuring { return 2 }
            if row.status == .done { return 3 }
            if row.status == .stale { return 4 }
            return 5
        }
        let left = score(lhs), right = score(rhs)
        return left == right ? lhs.updatedAt > rhs.updatedAt : left < right
    }

    private static func contentState(from snapshot: ArrayWidgetSnapshot) -> ArrayAgentActivityAttributes.ContentState {
        let agent = snapshot.highlightedAgent
        let status: String
        switch snapshot.phase {
        case .needsAttention: status = "Needs attention"
        case .failed: status = "Failed"
        case .working: status = snapshot.runningCount > 1 ? "\(snapshot.runningCount) agents running" : "Working"
        case .completed: status = "Completed"
        case .stale: status = "Mac offline"
        case .idle: status = "Idle"
        }
        return ArrayAgentActivityAttributes.ContentState(
            runningCount: snapshot.runningCount,
            attentionCount: snapshot.attentionCount,
            phase: snapshot.phase,
            agentID: agent?.id,
            agentName: agent?.name,
            workspaceName: agent?.workspaceName,
            startedAt: agent?.startedAt,
            statusText: status
        )
    }
}

private extension RelayPushRegistrationKind {
    var displayName: String {
        switch self {
        case .apns: return "Notification token"
        case .widget: return "Widget token"
        case .liveActivity: return "Live Activity token"
        case .liveActivityStart: return "Live Activity push-to-start token"
        }
    }
}
