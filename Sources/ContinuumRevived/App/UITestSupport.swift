import AppKit

/// Shared primitives for the app-driving checks: a selector-ish lookup by view
/// identifier, and a wait that does not block the main thread.
///
/// Both existed already, but trapped: `descendant(withIdentifier:)` was a
/// file-private extension inside ComponentLab, and every check hand-rolled its
/// own polling loop.

extension NSView {
    /// The first view in this subtree (self included) whose `identifier` matches
    /// `rawValue`. Depth-first, in subview order.
    func descendant(withIdentifier rawValue: String) -> NSView? {
        if identifier?.rawValue == rawValue { return self }
        for subview in subviews {
            if let match = subview.descendant(withIdentifier: rawValue) {
                return match
            }
        }
        return nil
    }

    /// Every view in this subtree (self included) whose `identifier` starts with
    /// `prefix`, in depth-first subview order — for row collections that are
    /// identified as `some.thing.row.0`, `…row.1`, and so on.
    func descendants(withPrefix prefix: String) -> [NSView] {
        var found: [NSView] = []
        if identifier?.rawValue.hasPrefix(prefix) == true { found.append(self) }
        for subview in subviews {
            found.append(contentsOf: subview.descendants(withPrefix: prefix))
        }
        return found
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses, and
/// returns whether it held. Usable directly from `@MainActor` code — no
/// `assumeIsolated` at the call site.
///
/// It sleeps by *suspending*, never by spinning: `RunLoop.current.run(mode:before:)`
/// — the pattern the other checks use — runs nested on the main thread, so a
/// condition that depends on work dispatched to the main *queue* can be starved by
/// the very wait that is looking for it. That produced a false failure in the
/// managed-agent live check, whose transcript ingests arrive via
/// `DispatchQueue.main.async`. Awaiting here lets the normal main-queue drain
/// happen between polls.
///
/// `condition` is evaluated once more after the deadline, so a condition that
/// becomes true during the final sleep is not reported as a timeout.
@MainActor
func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.5,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return condition() }
        await sleepOnMainQueue(min(pollInterval, max(0, deadline.timeIntervalSinceNow)))
    }
}

/// Suspends for `interval` by resuming off a main-queue timer — the scheduling
/// that finally worked for the managed-agent live check, expressed as an await.
@MainActor
private func sleepOnMainQueue(_ interval: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            continuation.resume()
        }
    }
}

// MARK: - Self-check

/// Flipped from a main-*queue* hop by the self-check below. A global because the
/// flipping closure is `@Sendable`: the point is that the delivery path is
/// `DispatchQueue.main.async`, which is exactly what a nested-RunLoop wait starves.
@MainActor private var mainQueueHopWitness = false

/// Proves both helpers, deterministically, with no network and no window: the
/// lookups find/miss what they should, and `waitUntil` both observes a
/// main-queue-delivered change and reports a timeout.
///
/// This exists because the ticket's own verification — the managed-agent live
/// check — needs Pi auth, network, and a *supervised* GUI session (unattended it
/// blocks in the folder-access `NSAlert`), so it cannot gate the helper headlessly.
@MainActor
func runUITestSupportChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    root.identifier = NSUserInterfaceItemIdentifier("list")
    let container = NSView(frame: root.bounds)
    root.addSubview(container)
    var rows: [NSView] = []
    for index in 0..<3 {
        let row = NSView(frame: NSRect(x: 0, y: index * 20, width: 200, height: 20))
        row.identifier = NSUserInterfaceItemIdentifier("list.row.\(index)")
        container.addSubview(row)
        rows.append(row)
    }
    let decoy = NSView(frame: .zero)
    decoy.identifier = NSUserInterfaceItemIdentifier("list.footer")
    container.addSubview(decoy)

    guard root.descendant(withIdentifier: "list.row.1") === rows[1] else {
        throw fail("descendant(withIdentifier:) did not find the nested row 'list.row.1'")
    }
    guard root.descendant(withIdentifier: "list") === root else {
        throw fail("descendant(withIdentifier:) did not match the receiver itself")
    }
    guard root.descendant(withIdentifier: "list.row.9") == nil else {
        throw fail("descendant(withIdentifier:) matched an identifier that does not exist")
    }
    let prefixed = root.descendants(withPrefix: "list.row.").map { $0.identifier?.rawValue ?? "" }
    guard prefixed == ["list.row.0", "list.row.1", "list.row.2"] else {
        throw fail("descendants(withPrefix:) returned \(prefixed), expected the three rows in subview order")
    }

    // The regression this whole helper exists for: the condition becomes true
    // only when a main-QUEUE block runs. A `RunLoop.current.run(mode:before:)`
    // spin does not drain those, so a wait built that way hangs here.
    mainQueueHopWitness = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        MainActor.assumeIsolated { mainQueueHopWitness = true }
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.05, { mainQueueHopWitness }) else {
        throw fail("waitUntil did not observe a change delivered via DispatchQueue.main (the main queue was starved)")
    }

    let startedTimeout = Date()
    guard await waitUntil(timeout: 0.4, pollInterval: 0.05, { false }) == false else {
        throw fail("waitUntil reported success for a condition that is never true")
    }
    let timeoutElapsed = Date().timeIntervalSince(startedTimeout)
    guard timeoutElapsed >= 0.4 else {
        throw fail("waitUntil gave up after \(timeoutElapsed)s, before its 0.4s timeout")
    }
    // And it returns immediately when the condition already holds.
    let startedImmediate = Date()
    guard await waitUntil(timeout: 5, { true }) else {
        throw fail("waitUntil failed on an already-true condition")
    }
    let immediateElapsed = Date().timeIntervalSince(startedImmediate)
    guard immediateElapsed < 0.4 else {
        throw fail("waitUntil slept \(immediateElapsed)s before checking an already-true condition")
    }

    print("UITestSupport: 3 rows found by prefix, main-queue hop observed, timeout after \(String(format: "%.2f", timeoutElapsed))s")
}
