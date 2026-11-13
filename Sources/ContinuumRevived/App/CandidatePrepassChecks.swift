import AppKit
import Foundation
import ContinuumRevivedCore

@MainActor
enum CandidatePrepassChecks {
    typealias T = WorkspaceAgentReportChecks
    static func git(_ root: URL, _ arguments: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                       "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env; p.standardInput = FileHandle.nullDevice
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try T.expect(p.terminationStatus == 0, "fixture git failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func run() async throws {
        let b = try T.makeBench(label: "candidate-prepass")
        defer { b.tearDown() }
        let s = b.supervisor
        let parentRoot = URL(fileURLWithPath: s.records[b.f.agentId]!.checkoutRoot)
        _ = try git(parentRoot, ["init", "-q"])
        let scripts = parentRoot.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data(#"{"version":1,"mappedLegs":0,"checks":[],"exceptions":[],"targetedOnly":[]}"#.utf8)
            .write(to: scripts.appendingPathComponent("check-coverage-manifest.json"))
        try Data("#!/bin/bash\n".utf8).write(to: scripts.appendingPathComponent("run-matrix.sh"))
        _ = try git(parentRoot, ["add", "scripts"])
        _ = try git(parentRoot, ["commit", "-qm", "test(prepass): base"])
        let base = try git(parentRoot, ["rev-parse", "HEAD"])
        let child = try b.delegate("prepass")
        let root = URL(fileURLWithPath: s.records[child]!.checkoutRoot)
        try T.expect(s.records[child]?.delegationContext?.baseHead == base, "production child host base")
        try Data("candidate".utf8).write(to: root.appendingPathComponent("fixture.swift"))
        _ = try git(root, ["add", "fixture.swift"])
        _ = try git(root, ["commit", "-qm", "test(prepass): candidate"])
        let head = try git(root, ["rev-parse", "HEAD"])
        let report = AgentReport(summary: "Declared prose is not revision identity")
        let task = UUID()
        guard let candidate = s.candidateReady(for: child, task: task, base: base, head: head) else {
            throw T.Failure(description: "host candidate seam refused explicit range")
        }
        let bundled = CandidatePrepass.bundledEvaluator()
        try T.expect(bundled != nil && bundled!.path.contains(".bundle/"), "production bundled lookup")
        try T.expect(CandidatePrepass.bundledResource("worker.py") != nil, "bundled process controller")
        let store = s.candidatePrepassSupportURL
        try T.expect(store.path.hasPrefix(b.binDir.path + "/"), "channel store uses isolated host support")
        // OFF is the production constructor default, not a fixture assertion.
        s.qaCandidatePrepass = CandidatePrepass(support: store)
        try T.expect(s.fileReport(report, for: child), "production fileReport")
        let off = await waitUntil(timeout: 3, pollInterval: 0.02) { s.candidatePrepassOutcomes[child]?.state == "disabled" }
        try T.expect(off, "production fileReport must consume OFF admission/completion")
        try T.expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("candidate-prepass").path), "OFF made no files")
        let worker = CandidatePrepass(support: store, enabled: true)
        s.qaCandidatePrepass = worker
        var changes = 0
        s.onCandidatePrepassChanged = { _ in changes += 1 }
        let begin = Date()
        try T.expect(s.fileReport(report, for: child), "production report enabled")
        try T.expect(Date().timeIntervalSince(begin) < 0.1, "fileReport blocked")
        let completed = await waitUntil(timeout: 30, pollInterval: 0.02) {
            ["clean", "findings"].contains(s.candidatePrepassOutcomes[child]?.state ?? "")
        }
        try T.expect(completed && changes > 0, "host consumer observed evaluator completion")
        try T.expect(s.candidatePrepassOutcomes[child]?.candidate == candidate, "explicit child checkout/base/head/task")
        try T.expect(s.candidatePrepassOutcomes[child]?.report?.contains("unmapped") == true, "review findings")
        try T.expect(!worker.outcomeURL(candidate).path.hasPrefix(root.path + "/"), "channel store outside checkout")
        // The actual existing inspection API consumes the host observation.
        let inspected = b.f.api.dispatch(agentId: child, requestId: "prepass-inspect", op: "agent.inspect",
                                         payload: ["agentId": child.rawValue.uuidString])
        guard case let .result(object) = inspected, let observation = object["candidatePrepass"]?.object else {
            throw T.Failure(description: "production agent.inspect did not expose host outcome: \(inspected)")
        }
        try T.expect(observation["head"]?.string == head, "observable consumer identity")
        let reviewed: CandidatePrepassOutcome = await withCheckedContinuation { continuation in
            s.reviewCandidate(for: child, candidate: candidate) { continuation.resume(returning: $0) }
        }
        try T.expect(["clean", "findings"].contains(reviewed.state), "review consumer authenticates/revalidates")
        // Changing HEAD invalidates the exact previously evaluated candidate.
        _ = try git(root, ["commit", "--allow-empty", "-qm", "test(prepass): changed head"])
        let stale: CandidatePrepassOutcome = await withCheckedContinuation { continuation in
            s.reviewCandidate(for: child, candidate: candidate) { continuation.resume(returning: $0) }
        }
        try T.expect(stale.state == "unavailable:changed-head", "review HEAD revalidation")
        // A new host rejects a previous host's signed file.
        let restarted = CandidatePrepass(support: store, enabled: true)
        let old: CandidatePrepassOutcome = await withCheckedContinuation { continuation in
            restarted.review(candidate) { continuation.resume(returning: $0) }
        }
        try T.expect(old.state == "unavailable:evidence", "restart cannot attach stale evidence")
        // Missing identity and missing resources exercise the real report path.
        let other = try b.delegate("prepass-unknown")
        try T.expect(s.fileReport(report, for: other), "missing-identity report")
        let unknown = await waitUntil(timeout: 5, pollInterval: 0.02) {
            s.candidatePrepassOutcomes[other]?.state == "unavailable:identity"
        }
        try T.expect(unknown, "missing identity unavailable")
        _ = try git(root, ["reset", "--soft", head])
        s.qaCandidatePrepass = CandidatePrepass(support: store, enabled: true, evaluator: nil, useBundledResources: false)
        try T.expect(s.fileReport(report, for: child), "missing-resource report")
        let missing = await waitUntil(timeout: 5, pollInterval: 0.02) {
            s.candidatePrepassOutcomes[child]?.state == "unavailable:resources"
        }
        try T.expect(missing, "missing bundled evaluator unavailable")
        // A deliberately held fixture evaluator exercises the same production
        // report path while the main actor delivers another report/event.
        let held = b.binDir.appendingPathComponent("held.py")
        let heldMarker = b.binDir.appendingPathComponent("held-started")
        let heldProgram = "import pathlib,time\npathlib.Path(" + String(reflecting: heldMarker.path)
            + ").touch()\ntime.sleep(1)\nraise SystemExit(2)\n"
        try Data(heldProgram.utf8).write(to: held)
        s.qaCandidatePrepass = CandidatePrepass(support: store, enabled: true, evaluator: held)
        try T.expect(s.fileReport(report, for: child), "held worker report")
        let started = await waitUntil(timeout: 10, pollInterval: 0.02) {
            FileManager.default.fileExists(atPath: heldMarker.path)
        }
        try T.expect(started, "held evaluator actually started")
        let eventStart = Date()
        try T.expect(s.fileReport(report, for: other), "ordinary report delivered during evaluation")
        let busy = await waitUntil(timeout: 0.5, pollInterval: 0.01) {
            s.candidatePrepassOutcomes[other]?.state == "unavailable:busy"
        }
        try T.expect(busy && Date().timeIntervalSince(eventStart) < 0.5, "held evaluator blocked main/event delivery")
        let heldEnded = await waitUntil(timeout: 10, pollInterval: 0.02) {
            s.candidatePrepassOutcomes[child]?.state == "unavailable:evaluator"
        }
        try T.expect(heldEnded, "held evaluator error observed")
        let blocked = b.binDir.appendingPathComponent("blocked-store")
        try Data().write(to: blocked)
        s.qaCandidatePrepass = CandidatePrepass(support: blocked, enabled: true)
        try T.expect(s.fileReport(report, for: child), "persistence-failure report")
        let failed = await waitUntil(timeout: 20, pollInterval: 0.02) {
            s.candidatePrepassOutcomes[child]?.state == "unavailable:persistence"
        }
        try T.expect(failed, "persistence failure observable through production consumer")
        print("PASS candidate-prepass app: fileReport, actual delegated checkout, bundled lookup, OFF, explicit identity, host store, inspect consumer, review revalidation, restart, missing identity/resources, persistence failure")
    }
}
