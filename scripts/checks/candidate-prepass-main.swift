import Foundation

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
let args = CommandLine.arguments
let root = args[1]
let base = args[2]
let evaluator = URL(fileURLWithPath: args[3])
let destination = URL(fileURLWithPath: args[4])
let off = CandidatePrepass()
require(!off.candidateReady(checkout: root, hostBase: base, destination: destination), "default off")
require(!FileManager.default.fileExists(atPath: destination.path), "off did IO")
let worker = CandidatePrepass(enabled: true, evaluator: evaluator)
let done = DispatchSemaphore(value: 0)
let start = Date()
require(worker.candidateReady(checkout: root, hostBase: base, destination: destination) { outcome in
    require(outcome.candidate?.base == base, "explicit base")
    require(outcome.candidate?.checkout == root, "explicit checkout")
    require(outcome.candidate?.head.count == 40, "host head")
    require(outcome.state == "clean" || outcome.state == "findings", "evaluated")
    require(outcome.report?.contains("unmapped") == true, "review payload")
    done.signal()
}, "admitted")
require(Date().timeIntervalSince(start) < 0.1, "nonblocking admission")
require(done.wait(timeout: .now() + 30) == .success, "completion")
let durable = try JSONDecoder().decode(CandidatePrepassOutcome.self, from: Data(contentsOf: destination))
require(durable.candidate?.base == base, "durable identity")
require(CandidatePrepass.reviewOutcome(at: destination, matching: durable.candidate!) != nil, "restart exact identity")
let changed = PrepassCandidate(checkout: root, base: base, head: String(repeating: "0", count: 40))
require(CandidatePrepass.reviewOutcome(at: destination, matching: changed) == nil, "changed head unavailable")
let unknown = DispatchSemaphore(value: 0)
require(worker.candidateReady(checkout: root, hostBase: nil, destination: destination) { outcome in
    require(outcome.state.hasPrefix("unavailable:"), "missing identity unknown")
    require(outcome.report == nil, "unknown has no clean report")
    unknown.signal()
}, "unknown admitted")
require(unknown.wait(timeout: .now() + 30) == .success, "unknown completes")
print("PASS candidate-prepass: off, nonblocking, explicit range, durable, unknown")
// Hold a trusted fixture evaluator to prove a slow worker cannot hold admission
// or accept another unbounded request. The app never resolves this from checkout.
let heldScript = destination.deletingLastPathComponent().appendingPathComponent("held.py")
try Data("import time\ntime.sleep(0.4)\nraise SystemExit(2)\n".utf8).write(to: heldScript)
let heldWorker = CandidatePrepass(enabled: true, evaluator: heldScript)
let heldDone = DispatchSemaphore(value: 0)
let heldStart = Date()
require(heldWorker.candidateReady(checkout: root, hostBase: base, destination: destination) { outcome in
    require(outcome.state == "unavailable:evaluator", "script error unknown")
    heldDone.signal()
}, "held worker admitted")
require(!heldWorker.candidateReady(checkout: root, hostBase: base, destination: destination), "bounded admission")
require(Date().timeIntervalSince(heldStart) < 0.1, "held worker does not block caller")
require(heldDone.wait(timeout: .now() + 30) == .success, "held error delivered")
print("PASS candidate-prepass: held worker nonblocking, bounded, errors unknown")
