import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import CryptoKit
import Foundation

func runAPNSPushServiceChecks() async throws {
    try runPushPayloadBuilderTableChecks()
    try runPushTaxonomyInvariantChecks()
    try runPushJWTSignerChecks()
    try runAPNSEnvLoaderChecks()
    try await runPushFiringRuleChecks()
    try await runAPNSDedupHTTPChecks()
    try runPushActionScopeGateChecks()
    try runRealAPNSEnvJWTGateCheck()
    print("APNSPushServiceChecks passed: taxonomy=8 payloads<=4KB body<=160 N4-redacted JWT-ES256 env-loader dedup/http scope-gate real-env-gated")
}

private func runPushPayloadBuilderTableChecks() throws {
    let hostile = "HOSTILE-[BODY]-runtimeError transcript content pid pane_id tool output should never cross"
    var measured: [String] = []
    for category in PushCategory.allCases {
        let spec = try expectedPayloadSpec(for: category)
        let payload = try PushPayloadBuilder.fixturePayload(for: category, hostileRuntimeError: hostile)
        let data = try payload.encodedJSON()
        expect(data.count <= 4096, "\(category.rawValue): payload must fit APNS 4KB limit, got \(data.count)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let aps = object?["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        expect((aps?["category"] as? String) == spec.categoryId, "\(category.rawValue): category id encoded per literal spec")
        expect((aps?["interruption-level"] as? String) == spec.interruptionLevel, "\(category.rawValue): interruption encoded per literal spec")
        expect((alert?["body"] as? String ?? "").count <= 160, "\(category.rawValue): body truncated to <=160")
        expect((object?["deepLink"] as? String) == spec.deepLink, "\(category.rawValue): deep link encoded per literal spec")
        expect((object?["target"] as? String) == spec.target, "\(category.rawValue): deep link target encoded per literal spec")
        let actionIds = object?["actionIds"] as? [String] ?? []
        expect(actionIds == spec.actionIds, "\(category.rawValue): action ids encoded per literal spec")
        if category == .approvalRequested {
            expect((object?["approvalRequestId"] as? String) == "approval-fixture", "N1 approvalRequestId encoded")
            expect(actionIds.contains("continuum.push.action.deny"), "N1 deny action id encoded")
        } else {
            expect(object?["approvalRequestId"] == nil, "\(category.rawValue): approvalRequestId omitted")
        }
        let json = String(decoding: data, as: UTF8.self)
        expect(!json.contains(hostile), "\(category.rawValue): hostile runtimeError body redacted")
        let taintValue = try JSONSerialization.jsonObject(with: data)
        expect(taintCheck(taintValue).isEmpty, "\(category.rawValue): SyncPayloadTaintScanner clean")
        measured.append("\(category.rawValue):\(data.count)b:\(spec.interruptionLevel)")
    }
    try runHostileUserInfoReservedKeyChecks()
    print("APNS payload builder table: \(measured.joined(separator: ", "))")
}

private func runHostileUserInfoReservedKeyChecks() throws {
    let payload = PushPayload(
        category: .approvalRequested,
        title: "Approval requested",
        body: "Approve production deploy",
        deepLink: "\(PairingURL.scheme)://approval/approval-real?agentId=00000000-0000-4000-8000-000000000063",
        approvalRequestId: "approval-real",
        userInfo: [
            "aps": "hostile-aps",
            "category": "N8",
            "deepLink": "hostile://deep-link",
            "actionIds": "hostile-actions",
            "target": "devices",
            "approvalRequestId": "hostile-approval"
        ]
    )
    let object = try JSONSerialization.jsonObject(with: payload.encodedJSON()) as? [String: Any]
    let aps = object?["aps"] as? [String: Any]
    let alert = aps?["alert"] as? [String: Any]
    expect((alert?["title"] as? String) == "Approval requested", "hostile userInfo cannot clobber aps.alert.title")
    expect((alert?["body"] as? String) == "Approve production deploy", "hostile userInfo cannot clobber aps.alert.body")
    expect((aps?["category"] as? String) == "continuum.push.N1", "hostile userInfo cannot clobber aps.category")
    expect((aps?["interruption-level"] as? String) == "time-sensitive", "hostile userInfo cannot clobber interruption level")
    expect((object?["deepLink"] as? String) == "\(PairingURL.scheme)://approval/approval-real?agentId=00000000-0000-4000-8000-000000000063", "hostile userInfo cannot clobber deep link")
}

private struct PayloadSpec: Equatable {
    var categoryId: String
    var interruptionLevel: String
    var actionIds: [String]
    var target: String
    var deepLink: String
}

private func expectedPayloadSpec(for category: PushCategory) throws -> PayloadSpec {
    let agent = "00000000-0000-4000-8000-000000000063"
    switch category {
    case .approvalRequested:
        return PayloadSpec(categoryId: "continuum.push.N1", interruptionLevel: "time-sensitive", actionIds: ["continuum.push.action.approve", "continuum.push.action.deny"], target: "approvalCard", deepLink: "\(PairingURL.scheme)://approval/approval-fixture?agentId=\(agent)")
    case .agentWaitingForInput:
        return PayloadSpec(categoryId: "continuum.push.N2", interruptionLevel: "time-sensitive", actionIds: ["continuum.push.action.open"], target: "agentDetail", deepLink: "\(PairingURL.scheme)://agent/\(agent)")
    case .agentFinished:
        return PayloadSpec(categoryId: "continuum.push.N3", interruptionLevel: "active", actionIds: [], target: "agentDetail", deepLink: "\(PairingURL.scheme)://agent/\(agent)")
    case .agentFailed:
        return PayloadSpec(categoryId: "continuum.push.N4", interruptionLevel: "active", actionIds: [], target: "agentDetail", deepLink: "\(PairingURL.scheme)://agent/\(agent)")
    case .stillWorkingDigest:
        return PayloadSpec(categoryId: "continuum.push.N5", interruptionLevel: "passive", actionIds: [], target: "agentsBoard", deepLink: "\(PairingURL.scheme)://agents")
    case .desktopConnectionChanged:
        return PayloadSpec(categoryId: "continuum.push.N6", interruptionLevel: "passive", actionIds: [], target: "statusFooter", deepLink: "\(PairingURL.scheme)://status")
    case .deviceSecurityChanged:
        return PayloadSpec(categoryId: "continuum.push.N7", interruptionLevel: "time-sensitive", actionIds: [], target: "devices", deepLink: "\(PairingURL.scheme)://devices")
    case .sessionReapedOrRevived:
        return PayloadSpec(categoryId: "continuum.push.N8", interruptionLevel: "passive", actionIds: [], target: "agentDetail", deepLink: "\(PairingURL.scheme)://agent/\(agent)")
    }
}

private func runPushTaxonomyInvariantChecks() throws {
    let ids = PushCategory.allCases.map(\.identifier)
    expect(Set(ids).count == PushCategory.allCases.count, "push category ids unique")
    expect(ids.allSatisfy { !$0.isEmpty }, "push category ids non-empty")
    expect(PushCategory.allCases.filter(\.defaultEnabled) == [.approvalRequested, .agentWaitingForInput, .agentFinished, .agentFailed, .stillWorkingDigest], "push defaults N1-N5 on, N6/N8 off")
    expect(!PushCategory.deviceSecurityChanged.isMuteable, "N7 is unmuteable")
    let config = APNSConfig(keyPath: "/tmp/missing.p8", keyId: "KID", teamId: "TEAM", deviceToken: "token", environment: .sandbox)
    try runPersistedPushCategoryPreferenceChecks(config: config)
    final class RecordingOffPrefs: PushCategoryPreferences, @unchecked Sendable {
        var queried: [PushCategory] = []
        func isEnabled(_ category: PushCategory) -> Bool {
            queried.append(category)
            return false
        }
    }
    let n3Prefs = RecordingOffPrefs()
    let n3HTTP = RecordingAPNSHTTPClient(statuses: [200])
    let n3Service = APNSPushService(config: config, httpClient: n3HTTP, preferences: n3Prefs, signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let n3Payload = try PushPayloadBuilder.fixturePayload(for: .agentFinished)
    let n3Outcome = try awaitSync { try await n3Service.publish(payload: n3Payload) }
    expect(n3Outcome == .categoryDisabled && n3HTTP.requests.isEmpty, "N3 muteable category suppressed by false preference")
    expect(n3Prefs.queried == [.agentFinished], "preference gate keys off payload category N3")

    let n7Prefs = RecordingOffPrefs()
    let n7Service = APNSPushService(config: config, httpClient: RecordingAPNSHTTPClient(statuses: [200]), preferences: n7Prefs, signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let payload = try PushPayloadBuilder.fixturePayload(for: .deviceSecurityChanged)
    let outcome = try awaitSync { try await n7Service.publish(payload: payload) }
    expect(outcome == .sent(statusCode: 200), "N7 sends even when preference seam returns false")
    expect(n7Prefs.queried.isEmpty, "N7 locked-on category does not consult preference seam")
    let allEnabledHTTP = RecordingAPNSHTTPClient(statuses: Array(repeating: 200, count: PushCategory.allCases.count))
    let allEnabledService = APNSPushService(config: config, httpClient: allEnabledHTTP, preferences: AllEnabledPushCategoryPreferences(), signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    for category in PushCategory.allCases {
        let payload = try PushPayloadBuilder.fixturePayload(for: category)
        let sent = try awaitSync { try await allEnabledService.publish(payload: payload) }
        expect(sent == .sent(statusCode: 200), "\(category.rawValue): all-enabled preferences allow real sender path")
    }
    expect(allEnabledHTTP.requests.count == PushCategory.allCases.count, "all-enabled preferences sent all N1-N8 through HTTP seam")
    print("APNS taxonomy invariants: ids=\(ids.joined(separator: ",")) defaults=\(PushCategory.allCases.filter(\.defaultEnabled).map(\.rawValue)) n3Suppressed=\(n3Outcome) n7Muteable=\(PushCategory.deviceSecurityChanged.isMuteable)")
}

private func runPersistedPushCategoryPreferenceChecks(config: APNSConfig) throws {
    let defaults = cleanDefaultsSuite(named: "ContinuumRevivedCoreChecks.NotifyCategories")
    let preferences = PersistedPushCategoryPreferences(defaults: defaults)
    for category in PushCategory.allCases {
        expect(preferences.isEnabled(category) == category.defaultEnabled, "\(category.rawValue): blank persisted preference mirrors defaultEnabled")
    }

    defaults.set(false, forKey: PersistedPushCategoryPreferences.key(for: .agentFinished))
    for category in PushCategory.allCases {
        let expected = category == .agentFinished ? false : category.defaultEnabled
        expect(preferences.isEnabled(category) == expected, "\(category.rawValue): single N3 off write does not affect other categories")
    }
    defaults.set(true, forKey: PersistedPushCategoryPreferences.key(for: .agentFinished))
    expect(preferences.isEnabled(.agentFinished), "N3 persisted preference round-trips off->on")

    for category in PushCategory.allCases {
        defaults.set(false, forKey: PersistedPushCategoryPreferences.key(for: category))
        expect(!preferences.isEnabled(category), "\(category.rawValue): persisted false wins")
        defaults.set(true, forKey: PersistedPushCategoryPreferences.key(for: category))
        expect(preferences.isEnabled(category), "\(category.rawValue): persisted true wins")
    }

    guard let agents = SettingsSchema.sections().first(where: { $0.id == "agents" }) else {
        throw NSError(domain: "PersistedPushCategoryPreferencesChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing agents settings section"])
    }
    let toggleFields = agents.fields.compactMap { field -> SettingsField? in
        if case .toggle = field { return field }
        return nil
    }
    let muteableCategories = PushCategory.allCases.filter(\.isMuteable)
    expect(toggleFields.count == 7, "agents section exposes exactly 7 muteable category toggles")
    expect(toggleFields.map(\.key) == muteableCategories.map { PersistedPushCategoryPreferences.key(for: $0) }, "agents section toggle keys match muteable push category order")
    for (field, category) in zip(toggleFields, muteableCategories) {
        expect(field.currentValue(in: defaults) == .bool(preferences.isEnabled(category)), "\(category.rawValue): settings currentValue reads fixture defaults")
        field.setValue(.bool(false), in: defaults)
        expect(field.currentValue(in: defaults) == .bool(false) && !preferences.isEnabled(category), "\(category.rawValue): settings toggle writes false to persisted preference")
        field.setValue(.bool(true), in: defaults)
        expect(field.currentValue(in: defaults) == .bool(true) && preferences.isEnabled(category), "\(category.rawValue): settings toggle writes true to persisted preference")
    }

    let sendDefaults = cleanDefaultsSuite(named: "ContinuumRevivedCoreChecks.NotifyCategories.SendPath")
    sendDefaults.set(false, forKey: PersistedPushCategoryPreferences.key(for: .agentFinished))
    sendDefaults.set(false, forKey: PersistedPushCategoryPreferences.key(for: .deviceSecurityChanged))
    let n3HTTP = RecordingAPNSHTTPClient(statuses: [200])
    let n3Service = APNSPushService(config: config, httpClient: n3HTTP, preferences: PersistedPushCategoryPreferences(defaults: sendDefaults), signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let n3Outcome = try awaitSync { try await n3Service.publish(payload: PushPayloadBuilder.fixturePayload(for: .agentFinished)) }
    expect(n3Outcome == .categoryDisabled && n3HTTP.requests.isEmpty, "persisted N3 off suppresses real APNS send before HTTP")

    let n1HTTP = RecordingAPNSHTTPClient(statuses: [200])
    let n1Service = APNSPushService(config: config, httpClient: n1HTTP, preferences: PersistedPushCategoryPreferences(defaults: sendDefaults), signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let n1Outcome = try awaitSync { try await n1Service.publish(payload: PushPayloadBuilder.fixturePayload(for: .approvalRequested)) }
    expect(n1Outcome == .sent(statusCode: 200) && n1HTTP.requests.count == 1, "untouched N1 default sends through real APNS service")

    let n7HTTP = RecordingAPNSHTTPClient(statuses: [200])
    let n7Service = APNSPushService(config: config, httpClient: n7HTTP, preferences: PersistedPushCategoryPreferences(defaults: sendDefaults), signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let n7Outcome = try awaitSync { try await n7Service.publish(payload: PushPayloadBuilder.fixturePayload(for: .deviceSecurityChanged)) }
    expect(n7Outcome == .sent(statusCode: 200) && n7HTTP.requests.count == 1, "N7 sends even when persisted key is forced false")

    print("Persisted push preferences: blankDefaults=defaultEnabled toggles=\(toggleFields.count) n3=\(n3Outcome) n1=\(n1Outcome) n7=\(n7Outcome)")
}

private func cleanDefaultsSuite(named suiteName: String) -> UserDefaults {
    UserDefaults().removePersistentDomain(forName: suiteName)
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create UserDefaults suite \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func runPushJWTSignerChecks() throws {
    let privateKey = P256.Signing.PrivateKey()
    let signer = APNSJWTSigner(teamId: "TEAMID", keyId: "KEYID", privateKey: privateKey)
    let issuedAt = Date()
    let jwt = try signer.sign(issuedAt: issuedAt)
    let parts = jwt.split(separator: ".").map(String.init)
    expect(parts.count == 3, "JWT has header.claims.signature")
    let header = try decodeJWTPart(parts[0])
    let claims = try decodeJWTPart(parts[1])
    expect(header["alg"] as? String == "ES256", "JWT alg ES256")
    expect(header["kid"] as? String == "KEYID", "JWT kid")
    expect(claims["iss"] as? String == "TEAMID", "JWT iss")
    let iat = claims["iat"] as? Int ?? -1
    expect(abs(iat - Int(issuedAt.timeIntervalSince1970)) <= 5, "JWT iat within +/-5s")
    let signed = Data((parts[0] + "." + parts[1]).utf8)
    let sig = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
    expect(privateKey.publicKey.isValidSignature(sig, for: signed), "JWT signature verifies with public key")
    print("APNS JWT signer: alg=ES256 kid=\(header["kid"] ?? "?") iss=\(claims["iss"] ?? "?") iatDelta=\(abs(iat - Int(issuedAt.timeIntervalSince1970)))")
}

private func runAPNSEnvLoaderChecks() throws {
    let home = "/Users/fixture"
    let fixture = """
    CONTINUUM_APNS_KEY_PATH=$HOME/.continuum/secrets/AuthKey_TEST.p8
    CONTINUUM_APNS_KEY_ID=KEY123
    CONTINUUM_APPLE_TEAM_ID=TEAM456
    CONTINUUM_APNS_DEVICE_TOKEN=TOKEN789
    """
    let parsed = APNSEnvLoader.parse(fixture, homeDirectory: home, defaultEnvironment: .sandbox)
    expect(parsed?.keyPath == "\(home)/.continuum/secrets/AuthKey_TEST.p8", "apns.env expands $HOME in key path")
    expect(parsed?.keyId == "KEY123" && parsed?.teamId == "TEAM456" && parsed?.deviceToken == "TOKEN789", "apns.env parses required and optional keys")
    expect(APNSEnvLoader.parse("CONTINUUM_APNS_KEY_ID=KEY123\n", homeDirectory: home) == nil, "missing required apns.env keys return nil config")
    let noConfig = APNSPushService(config: nil, httpClient: RecordingAPNSHTTPClient(statuses: [200]))
    let outcome = try awaitSync { try await noConfig.publish(payload: PushPayloadBuilder.fixturePayload(for: .agentFinished)) }
    expect(outcome == .noConfig, "nil config publish no-ops honestly")
    print("APNS env loader: fixtureKeyId=\(parsed?.keyId ?? "nil") fixtureTeamId=\(parsed?.teamId ?? "nil") missingKeys=nil noConfig=\(outcome)")
}

private func runPushFiringRuleChecks() async throws {
    let table = PushFiringRuleTable()
    let tile = UUID()
    let approval = makePushEvent(tile: tile, status: .needsAttention, tone: .approval, summary: "Approve?", approvalRequestId: "approval-1")
    let input = makePushEvent(tile: tile, status: .needsAttention, tone: .info, summary: "Need input", approvalRequestId: nil)
    let done = makePushEvent(tile: tile, status: .done, tone: .info, summary: "Done", approvalRequestId: nil)
    let error = makePushEvent(tile: tile, status: .working, tone: .error, summary: "HOSTILE-[BODY]-runtimeError", approvalRequestId: nil)
    expect(table.classify(previous: .working, event: approval)?.category == .approvalRequested, "working->needsAttention with approval id fires N1")
    expect(table.classify(previous: .working, event: input)?.category == .agentWaitingForInput, "working->needsAttention without approval id fires N2")
    expect(table.classify(previous: .working, event: done)?.category == .agentFinished, "working->done non-error fires N3")
    let errorCandidate = table.classify(previous: .working, event: error)
    expect(errorCandidate?.category == .agentFailed, "error tone fires N4 regardless of status")
    let errorJSON = try errorCandidate?.payload.encodedJSONString() ?? ""
    expect(errorJSON.contains("The agent run failed."), "N4 body fixed string")
    let service = APNSPushService(config: APNSConfig(keyPath: "/tmp/missing", keyId: "KID", teamId: "TEAM", deviceToken: "token", environment: .sandbox), httpClient: RecordingAPNSHTTPClient(statuses: [200, 200, 200, 200]), signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let first = try await service.publish(payload: table.classify(previous: .working, event: approval)!.payload)
    let dup = try await service.publish(payload: table.classify(previous: .needsAttention, event: approval)!.payload)
    let refire = try await service.publish(payload: table.classify(previous: .needsAttention, event: input)!.payload)
    let doneFirst = try await service.publish(payload: table.classify(previous: .working, event: done)!.payload)
    let doneDup = table.classify(previous: .done, event: done)
    expect(first.isSent && dup == .deduplicated && refire.isSent && doneFirst.isSent && doneDup == nil, "firing/dedup table sends, suppresses same identity, refires on approval->input")
    print("APNS firing table: N1=\(first) sameNeedsAttention=\(dup) inputRefire=\(refire) done=\(doneFirst) doneDupCandidate=\(doneDup == nil ? "nil" : "unexpected")")
}

private func runAPNSDedupHTTPChecks() async throws {
    let parsedExpired = APNSHTTPResponse(statusCode: 403, body: Data(#"{"reason":"ExpiredProviderToken"}"#.utf8))
    expect(parsedExpired.reason == "ExpiredProviderToken", "URLSession APNS response parser surfaces ExpiredProviderToken reason from JSON body")
    let parsedPlain403 = APNSHTTPResponse(statusCode: 403, body: Data())
    expect(parsedPlain403.reason == nil, "URLSession APNS response parser does not synthesize 403 reasons")

    let http = RecordingAPNSHTTPClient(responses: [
        APNSHTTPResponse(statusCode: 200),
        APNSHTTPResponse(statusCode: 200),
        APNSHTTPResponse(statusCode: 410),
        APNSHTTPResponse(statusCode: 403, reason: "ExpiredProviderToken"),
        APNSHTTPResponse(statusCode: 403)
    ])
    let service = APNSPushService(config: APNSConfig(keyPath: "/tmp/missing", keyId: "KID", teamId: "TEAM", deviceToken: "device-token", environment: .sandbox), httpClient: http, signer: .ephemeralForChecks(teamId: "TEAM", keyId: "KID"))
    let tile = UUID()
    let payload = PushPayload(category: .agentFinished, title: "Agent finished", body: "done", deepLink: "\(PairingURL.scheme)://agent/\(tile.uuidString)", userInfo: ["agentId": tile.uuidString])
    let changedPayload = PushPayload(category: .agentFinished, title: "Agent finished", body: "done again", deepLink: "\(PairingURL.scheme)://agent/\(tile.uuidString)", userInfo: ["agentId": tile.uuidString])
    let failedPayload = PushPayload(category: .agentFinished, title: "Agent finished", body: "failed", deepLink: "\(PairingURL.scheme)://agent/\(tile.uuidString)", userInfo: ["agentId": tile.uuidString])
    let first = try await service.publish(payload: payload)
    let second = try await service.publish(payload: payload)
    let changed = try await service.publish(payload: changedPayload)
    let expired = try await service.publish(payload: failedPayload)
    let expiredRetry = try await service.publish(payload: failedPayload)
    let plain403Retry = try await service.publish(payload: failedPayload)
    expect(first.isSent && second == .deduplicated && changed.isSent, "dedup sends once for identical identity and refires changed identity")
    expect(expired == .tokenExpired && expiredRetry == .providerTokenExpired && plain403Retry == .failed(statusCode: 403), "410 and explicit 403 ExpiredProviderToken do not update identity; plain 403 remains failed")
    expect(http.requests.count == 5, "HTTP seam request count: got \(http.requests.count), expected 5")
    let request = http.requests[0].request
    expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/device-token", "APNS sandbox URL shape")
    expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true, "APNS authorization bearer header")
    expect(request.value(forHTTPHeaderField: "apns-topic") == "dev.dylanreedx.continuum", "APNS topic header")
    expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert", "APNS push type alert")
    print("APNS dedup/http: requests=\(http.requests.count) url=\(request.url?.host ?? "?") first=\(first) dup=\(second) changed=\(changed) 410=\(expired) 403Expired=\(expiredRetry) 403Plain=\(plain403Retry)")
}

private func runPushActionScopeGateChecks() throws {
    let agent = UUID()
    let intent = handlePushAction(actionId: PushCategory.approveActionId, userInfo: ["approvalRequestId": "approval-1", "agentId": agent.uuidString], grantedScope: .operator)
    expect(intent?.requestId == "approval-1" && intent?.decision == .accept && intent?.agentId == agent, "approve action returns respond intent with operator scope")
    let denied = handlePushAction(actionId: PushCategory.approveActionId, userInfo: ["approvalRequestId": "approval-1", "agentId": UUID().uuidString], grantedScope: .observer)
    expect(denied == nil, "approve action denied for observer scope")
    // P2A.8: a notification posted before the key moved still acts — its id rode
    // under `tileId`, and the two were the same value then.
    let legacyIntent = handlePushAction(actionId: PushCategory.approveActionId, userInfo: ["approvalRequestId": "approval-1", "tileId": agent.uuidString], grantedScope: .operator)
    expect(legacyIntent?.agentId == agent, "P2A.8: a legacy tileId-keyed push action still resolves an agentId")
    expect(handlePushAction(actionId: PushCategory.approveActionId, userInfo: ["approvalRequestId": "approval-1"], grantedScope: .operator) == nil,
           "P2A.8: a push action with neither agentId nor tileId is refused")
    print("APNS push action scope gate: operatorIntent=\(intent != nil) observerIntent=\(denied != nil) legacyKeyIntent=\(legacyIntent != nil)")
}

private func runRealAPNSEnvJWTGateCheck() throws {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".continuum/apns.env")
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("APNS real-env check SKIPPED: ~/.continuum/apns.env absent")
        return
    }
    guard let config = APNSEnvLoader.load(from: url, homeDirectory: NSHomeDirectory()) else {
        throw NSError(domain: "APNSRealEnv", code: 1, userInfo: [NSLocalizedDescriptionKey: "real apns.env exists but is incomplete"])
    }
    let signer = try APNSJWTSigner(config: config)
    let jwt = try signer.sign(issuedAt: Date())
    expect(jwt.split(separator: ".").count == 3, "real APNS key signs JWT")
    let verifies = try signer.verifies(jwt)
    expect(verifies, "real APNS key JWT signature verifies with public key")
    print("APNS real-env check: keyId=\(config.keyId) teamId=\(config.teamId)")
}

private func makePushEvent(tile: UUID, status: AgentStatus, tone: ActivityEventTone, summary: String, approvalRequestId: String?) -> AgentActivityEvent {
    AgentActivityEvent(
        stamping: AgentActivityEventDraft(agentId: tile, runId: "run", tone: tone, kind: tone == .error ? "runtimeError" : "status", status: status, summary: summary, occurredAt: Date(), approvalRequestId: approvalRequestId),
        sequence: UInt64.random(in: 1...1000),
        replicaId: UUID()
    )
}

private final class AnyResultBox: @unchecked Sendable {
    var result: Result<Any, Error>?
}

private func awaitSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AnyResultBox()
    Task {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get() as! T
}

private func decodeJWTPart(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: base64URLDecode(text)) as? [String: Any] ?? [:]
}
