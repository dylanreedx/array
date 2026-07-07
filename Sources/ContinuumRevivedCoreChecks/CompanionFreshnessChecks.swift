import Foundation
import ContinuumRevivedCore

func runCompanionFreshnessChecks() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let policy = CompanionFreshnessPolicy(
        liveWindow: 90,
        sleepingWindow: 300
    )
    let paired = PairedCompanionSessionState.paired(sampleCompanionSession(scopes: .operator))
    let cachedCanvas = CompanionFreshnessSample(
        metadata: CompanionFreshnessMetadata(
            instanceId: UUID(uuidString: "A0000000-0000-4000-8000-000000008001")!,
            desktopReplicaId: "desktop-a",
            bootId: "boot-a",
            sequence: 4,
            publishedAt: now.addingTimeInterval(-150),
            receivedAt: now.addingTimeInterval(-145),
            powerHint: .active,
            spatialWatermark: "spatial-4",
            activityWatermark: nil
        )
    )

    let unpaired = CompanionFreshness.derive(
        CompanionFreshnessInput(sessionState: .unpaired, now: now),
        policy: policy
    )
    expect(unpaired.state == .unpaired, "CompanionFreshness: unpaired state wins")
    expect(unpaired.title == "Pair this phone", "CompanionFreshness: unpaired title token")
    expect(unpaired.allowsMutations == false, "CompanionFreshness: unpaired blocks mutations")

    let syncing = CompanionFreshness.derive(
        CompanionFreshnessInput(sessionState: paired, now: now),
        policy: policy
    )
    expect(syncing.state == .syncing, "CompanionFreshness: paired/no data is syncing")
    expect(syncing.showsCachedCanvas == false, "CompanionFreshness: no-data syncing has no cached canvas")
    expect(syncing.subtitle == "Waiting for your Mac", "CompanionFreshness: syncing subtitle")

    let recentHeartbeat = CompanionFreshnessSample(
        metadata: CompanionFreshnessMetadata(
            instanceId: cachedCanvas.metadata.instanceId,
            desktopReplicaId: "desktop-a",
            bootId: "boot-a",
            sequence: 5,
            publishedAt: now.addingTimeInterval(-20),
            receivedAt: now.addingTimeInterval(-18),
            powerHint: .active,
            spatialWatermark: nil,
            activityWatermark: nil
        )
    )
    let live = CompanionFreshness.derive(
        CompanionFreshnessInput(
            sessionState: paired,
            spatialSnapshot: cachedCanvas,
            latestHeartbeat: recentHeartbeat,
            transportAvailability: .available,
            now: now
        ),
        policy: policy
    )
    expect(live.state == .live(lastFreshAt: recentHeartbeat.metadata.publishedAt), "CompanionFreshness: recent heartbeat is live")
    expect(live.allowsMutations == true, "CompanionFreshness: live operator session can mutate")
    expect(live.deliveryLag == 2, "CompanionFreshness: delivery lag is desktop published vs local received")

    let stale = CompanionFreshness.derive(
        CompanionFreshnessInput(
            sessionState: paired,
            spatialSnapshot: cachedCanvas,
            transportAvailability: .available,
            now: now
        ),
        policy: policy
    )
    expect(stale.state == .stale(lastFreshAt: cachedCanvas.metadata.publishedAt), "CompanionFreshness: old cached canvas is stale before sleeping window")
    expect(stale.showsCachedCanvas == true, "CompanionFreshness: stale cached canvas remains visible")
    expect(stale.allowsMutations == false, "CompanionFreshness: stale state blocks mutations")
    expect(stale.actionBlocker == "Reconnect to act", "CompanionFreshness: freshness blocker precedes scope copy")

    let sleepingHint = CompanionFreshnessSample(
        metadata: CompanionFreshnessMetadata(
            instanceId: cachedCanvas.metadata.instanceId,
            desktopReplicaId: "desktop-a",
            bootId: "boot-a",
            sequence: 6,
            publishedAt: now.addingTimeInterval(-20),
            receivedAt: now.addingTimeInterval(-19),
            powerHint: .willSleep,
            spatialWatermark: "spatial-6",
            activityWatermark: "activity-6"
        )
    )
    let sleeping = CompanionFreshness.derive(
        CompanionFreshnessInput(
            sessionState: paired,
            spatialSnapshot: sleepingHint,
            latestHeartbeat: sleepingHint,
            transportAvailability: .available,
            now: now
        ),
        policy: policy
    )
    expect(sleeping.state == .desktopSleeping(lastFreshAt: sleepingHint.metadata.publishedAt), "CompanionFreshness: explicit willSleep hint is desktopSleeping")
    expect(sleeping.title == "Mac asleep", "CompanionFreshness: explicit sleep copy")
    expect(sleeping.allowsMutations == false, "CompanionFreshness: sleeping blocks mutations")

    let offline = CompanionFreshness.derive(
        CompanionFreshnessInput(
            sessionState: paired,
            spatialSnapshot: cachedCanvas,
            transportAvailability: .accountUnavailable,
            now: now
        ),
        policy: policy
    )
    expect(offline.state == .offline(lastFreshAt: cachedCanvas.metadata.publishedAt, reason: .accountUnavailable), "CompanionFreshness: account unavailable is offline")
    expect(offline.subtitle == "Mac offline/asleep — showing last canvas", "CompanionFreshness: offline cached canvas copy")
    expect(offline.showsCachedCanvas == true, "CompanionFreshness: offline cached canvas remains visible")

    let observerLive = CompanionFreshness.derive(
        CompanionFreshnessInput(
            sessionState: .paired(sampleCompanionSession(scopes: .observer)),
            spatialSnapshot: cachedCanvas,
            latestHeartbeat: recentHeartbeat,
            transportAvailability: .available,
            now: now
        ),
        policy: policy
    )
    expect(observerLive.state == .live(lastFreshAt: recentHeartbeat.metadata.publishedAt), "CompanionFreshness: observer can still be live")
    expect(observerLive.allowsMutations == false, "CompanionFreshness: live observer remains scope-gated")
    expect(observerLive.actionBlocker == "Observer scope", "CompanionFreshness: scope blocker appears only after freshness is live")

    print("CompanionFreshnessChecks passed")
}

private func sampleCompanionSession(scopes: Scope) -> PairedCompanionSession {
    PairedCompanionSession(
        instanceId: UUID(uuidString: "A0000000-0000-4000-8000-000000008001")!,
        userId: UUID(uuidString: "A0000000-0000-4000-8000-000000008002")!,
        deviceId: UUID(uuidString: "A0000000-0000-4000-8000-000000008003")!,
        sessionId: UUID(uuidString: "A0000000-0000-4000-8000-000000008004")!,
        token: "fixture-token",
        scopes: scopes,
        issuedAt: Date(timeIntervalSince1970: 1_899_990_000),
        expiresAt: Date(timeIntervalSince1970: 1_910_000_000)
    )
}
