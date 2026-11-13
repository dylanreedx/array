import Foundation

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
let args = CommandLine.arguments
let root = args[1], base = args[2], head = args[5]
let evaluator = URL(fileURLWithPath: args[3])
let support = URL(fileURLWithPath: args[4])
let workerScript = evaluator.deletingLastPathComponent().appendingPathComponent("worker.py")
let candidate = PrepassCandidate(id: UUID(), task: UUID(), checkout: root, base: base, head: head)
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CandidatePrepassOutcome?
    func set(_ result: CandidatePrepassOutcome) { lock.lock(); value = result; lock.unlock() }
    func get() -> CandidatePrepassOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}
func waitResult(_ start: (@escaping @Sendable (CandidatePrepassOutcome) -> Void) -> Void) -> CandidatePrepassOutcome {
    let done = DispatchSemaphore(value: 0)
    let result = OutcomeBox()
    start { result.set($0); done.signal() }
    require(done.wait(timeout: .now() + 35) == .success, "completion")
    return result.get()!
}
let off = CandidatePrepass(support: support)
let disabled = waitResult { callback in
    require(!off.candidateReady(candidate, completion: callback), "default off")
}
require(disabled.state == "disabled", "OFF observable")
require(!FileManager.default.fileExists(atPath: support.path), "OFF did IO")
let worker = CandidatePrepass(support: support, enabled: true, evaluator: evaluator, worker: workerScript)
let start = Date()
let done = DispatchSemaphore(value: 0)
let evaluatedBox = OutcomeBox()
require(worker.candidateReady(candidate) { evaluatedBox.set($0); done.signal() }, "admitted")
require(Date().timeIntervalSince(start) < 0.1, "nonblocking admission")
require(done.wait(timeout: .now() + 35) == .success, "evaluated")
let evaluated = evaluatedBox.get()
require(evaluated?.candidate == candidate, "immutable explicit identity")
require(["clean", "findings"].contains(evaluated!.state), "evaluated")
require(evaluated?.report?.contains("unmapped") == true, "findings/unmapped payload")
require(!worker.outcomeURL(candidate).path.hasPrefix(root + "/"), "host store outside checkout")
let reviewed = waitResult { worker.review(candidate, completion: $0) }
require(reviewed.state == evaluated!.state, "authenticated review consumer")
let oldBytes = try Data(contentsOf: worker.outcomeURL(candidate))
try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: worker.support.path)
let replaceFailed = waitResult { _ = worker.candidateReady(candidate, completion: $0) }
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.support.path)
require(replaceFailed.state == "unavailable:persistence", "atomic replacement failure visible")
let retainedBytes = try Data(contentsOf: worker.outcomeURL(candidate))
require(retainedBytes == oldBytes, "old file retained fixture")
let staleDisk = waitResult { worker.review(candidate, completion: $0) }
require(staleDisk.state == "unavailable:persistence", "retained old success cannot mask write failure")
_ = waitResult { _ = worker.candidateReady(candidate, completion: $0) }
let restart = CandidatePrepass(support: support, enabled: true, evaluator: evaluator, worker: workerScript)
let restarted = waitResult { restart.review(candidate, completion: $0) }
require(restarted.state == "unavailable:evidence", "restart cannot attach old evidence")
let unknown = waitResult { _ = worker.candidateReady(nil, completion: $0) }
require(unknown.state == "unavailable:identity" && unknown.report == nil, "missing identity unknown")
let auditFiles = try FileManager.default.contentsOfDirectory(atPath: worker.support.path)
require(auditFiles.contains { $0.hasPrefix("unidentified-") }, "missing identity durable")
// Helper-forged bytes cannot become authoritative, even in the channel store.
try Data(#"{"candidate":null,"state":"clean","report":"forged"}"#.utf8).write(to: worker.outcomeURL(candidate))
let forged = waitResult { worker.review(candidate, completion: $0) }
require(forged.state == "unavailable:evidence", "forgery rejected")
let impossible = support.appendingPathComponent("file")
try Data().write(to: impossible)
let broken = CandidatePrepass(support: impossible, enabled: true, evaluator: evaluator, worker: workerScript)
let failed = waitResult { _ = broken.candidateReady(candidate, completion: $0) }
require(failed.state == "unavailable:persistence", "persistence failure observable")
let failedReview = waitResult { broken.review(candidate, completion: $0) }
require(failedReview.state == "unavailable:persistence", "persistence failure overrides old file")
// A held evaluator cannot stall admission or admit an unbounded queue.
let heldScript = support.appendingPathComponent("held.py")
try Data("import time\ntime.sleep(0.4)\nraise SystemExit(2)\n".utf8).write(to: heldScript)
let heldWorker = CandidatePrepass(support: support, enabled: true, evaluator: heldScript, worker: workerScript)
let heldDone = DispatchSemaphore(value: 0)
let heldStart = Date()
require(heldWorker.candidateReady(candidate) { outcome in
    require(outcome.state == "unavailable:evaluator", "script error unknown")
    heldDone.signal()
}, "held admitted")
let busy = waitResult { callback in
    require(!heldWorker.candidateReady(candidate, completion: callback), "bounded admission")
}
require(busy.state == "unavailable:busy", "busy observable")
require(Date().timeIntervalSince(heldStart) < 0.1, "held worker nonblocking")
require(heldDone.wait(timeout: .now() + 35) == .success, "held completes")
print("PASS candidate-prepass: OFF, explicit identity, durable authenticated host store, review, restart, forgery, missing identity, persistence failure, nonblocking bounded admission")
