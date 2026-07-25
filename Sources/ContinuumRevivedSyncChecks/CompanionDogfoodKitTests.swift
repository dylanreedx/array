import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

private func checkCompanionDogfoodHealthJSONSchema() throws {
    let timestamp = Date(timeIntervalSinceReferenceDate: 7_600)
    let diagnostics = DesktopCompanionSyncDiagnostics(
        containerIdentifier: CompanionSyncConfig.cloudKitContainerIdentifier,
        desktopBundleIdentifier: "com.continuum.revived",
        iosBundleIdentifier: "dev.dylanreedx.continuum",
        signedWithICloudEntitlement: true,
        transportAvailability: .available,
        transportIsPairingProof: false,
        isPaired: true,
        pairedDeviceCount: 1,
        authorizedScope: .operator,
        lastHeartbeatAt: timestamp,
        lastSpatialPublishAt: timestamp.addingTimeInterval(-5),
        lastActivityPublishAt: timestamp.addingTimeInterval(-4),
        lastFetchAt: timestamp.addingTimeInterval(-3),
        lastInboundMessageKind: "approvalResponseAck",
        lastApprovalResponseOutcome: .unknownRequest,
        lastError: nil
    )

    let report = CompanionDogfoodHealthReport(
        diagnostics: diagnostics,
        iCloudAccountAvailable: true,
        apnsTopic: "dev.dylanreedx.continuum",
        teamIdentifier: "TEAMID76"
    )
    let data = try CompanionDogfoodJSON.encoder.encode(report)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    expect(object?["desktopSignedWithICloudEntitlement"] as? Bool == true, "ticket76 health: reports signed iCloud entitlement")
    expect(object?["containerIdentifier"] as? String == CompanionSyncConfig.cloudKitContainerIdentifier, "ticket76 health: reports shared CloudKit container")
    expect(object?["iCloudAccountAvailable"] as? Bool == true, "ticket76 health: reports account availability separately from pairing")
    expect(object?["pairedContinuumInstance"] as? Bool == true, "ticket76 health: reports explicit Continuum pairing")
    expect(object?["transportIsPairingProof"] as? Bool == false, "ticket76 health: CloudKit transport is not pairing proof")
    expect(object?["lastApprovalResponseOutcome"] as? String == "unknownRequest", "ticket76 health: approval outcome is terminal and visible")
    expect(object?["apnsTopic"] as? String == "dev.dylanreedx.continuum", "ticket76 health: carries APNS topic when available")
    expect(object?["teamIdentifier"] as? String == "TEAMID76", "ticket76 health: carries team id when available")
}

private func checkCompanionDogfoodFixtureIsExplicitAndI5Safe() throws {
    let fixture = CompanionDogfoodFixture.make(now: Date(timeIntervalSinceReferenceDate: 7_601))

    expect(fixture.label == "Continuum Companion Dogfood Fixture", "ticket76 fixture: label is explicit")
    expect(fixture.canvas.tiles.count == 2, "ticket76 fixture: produces a non-empty canvas")
    expect(fixture.workspace.zones.count == 1, "ticket76 fixture: produces a visible dogfood zone")
    expect(fixture.activity.byAgent.values.contains { $0.lastSummary == "Dogfood Dummy Agent working" }, "ticket76 fixture: includes explicit dummy agent activity")
    expect(fixture.mutationPolicy == .temporaryWorkspaceOnly, "ticket76 fixture: does not silently mutate real workspaces")

    let encoded = try CompanionDogfoodJSON.encoder.encode(fixture)
    let json = String(decoding: encoded, as: UTF8.self)
    for forbidden in ["/Users/", "cwd", "pid", "pane", "tmux", "transcript", "raw-apns-token", "SECRET", "signing.key"] {
        expect(!json.contains(forbidden), "ticket76 fixture I5: fixture JSON must not contain \(forbidden)")
    }
}

private func checkCompanionDogfoodDryRunScript() throws {
    let script = "scripts/companion-dogfood-start.sh"
    expect(FileManager.default.isExecutableFile(atPath: script), "ticket76 script: companion dogfood script exists and is executable")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bash", script, "--dry-run", "--publish-fixture-if-empty", "--device", "Dry Run iPhone"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    expect(process.terminationStatus == 0, "ticket76 script: dry-run exits 0, output=\(output)")
    expect(output.contains("\"dryRun\": true"), "ticket76 script: dry-run manifest is explicit")
    expect(output.contains("\"pairedInstanceRequired\": true"), "ticket76 script: requires explicit Continuum pairing")
    expect(output.contains("\"freshnessRequired\": true"), "ticket76 script: names freshness/heartbeat gate")
    expect(output.contains("\"willLaunchDevices\": false"), "ticket76 script: dry-run does not launch devices")
    expect(output.contains("iCloud.dev.dylanreedx.continuum"), "ticket76 script: prints shared CloudKit container")
    expect(output.contains("provisioned-cloudkit-app.sh"), "ticket83 script: dry-run points at provisioned app builder")
    expect(output.contains("manual codesign-only entitlement proof: refused"), "ticket83 script: refuses manual-entitlement fake proof")
    expect(output.contains("\"requiresProvisionedDesktopApp\": true"), "ticket83 script: real dogfood requires provisioned desktop app")

    let provisionedDryRun = Process()
    provisionedDryRun.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    provisionedDryRun.arguments = [
        "bash",
        "scripts/provisioned-cloudkit-app.sh",
        "--dry-run",
        "--configuration",
        "release",
        "--output",
        "/tmp/ContinuumRevived-provisioned.app",
        "--identity",
        "Apple Development: Dry Run",
        "--profile",
        "/tmp/DryRun.provisionprofile",
        "--artifacts-dir",
        "/tmp/continuum-provisioned-dry-run-artifacts"
    ]
    let provisionedPipe = Pipe()
    provisionedDryRun.standardOutput = provisionedPipe
    provisionedDryRun.standardError = provisionedPipe
    try provisionedDryRun.run()
    provisionedDryRun.waitUntilExit()
    let provisionedOutput = String(decoding: provisionedPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    expect(provisionedDryRun.terminationStatus == 0, "ticket83 script: provisioned builder dry-run exits 0, output=\(provisionedOutput)")
    expect(provisionedOutput.contains("\"dryRun\": true"), "ticket83 script: provisioned builder dry-run manifest is explicit")
    expect(provisionedOutput.contains("\"mode\": \"build\""), "ticket83 script: provisioned builder dry-run names build mode")
    expect(provisionedOutput.contains("\"plannedLaunchSmoke\": true"), "ticket83 script: provisioned builder plans launch smoke without running it")
    expect(provisionedOutput.contains("\"realCloudKitProof\": false"), "ticket83 script: dry-run does not claim proof")
    expect(provisionedOutput.contains("embedded.provisionprofile"), "ticket83 script: provisioned builder plans embedded profile")
    expect(provisionedOutput.contains("manual codesign-only is not CloudKit proof"), "ticket83 script: provisioned builder refuses manual-entitlement fake proof")

    let realProof = Process()
    realProof.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    realProof.arguments = ["bash", script, "--desktop-app", ".build/debug/continuum-revived"]
    let realPipe = Pipe()
    realProof.standardOutput = realPipe
    realProof.standardError = realPipe
    try realProof.run()
    realProof.waitUntilExit()
    let realOutput = String(decoding: realPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    expect(realProof.terminationStatus != 0, "ticket76 script: real proof refuses SwiftPM executable without --allow-unentitled")
    expect(realOutput.contains("Refusing SwiftPM/raw executable for real CloudKit proof"), "ticket76 script: refusal explains the unentitled path")
}

func runCompanionDogfoodKitChecks() throws {
    try checkCompanionDogfoodHealthJSONSchema()
    try checkCompanionDogfoodFixtureIsExplicitAndI5Safe()
    try checkCompanionDogfoodDryRunScript()
    print("companion dogfood kit: health JSON schema, explicit I5-safe fixture, provisioned CloudKit dry-run, and dogfood script contract all green")
}
