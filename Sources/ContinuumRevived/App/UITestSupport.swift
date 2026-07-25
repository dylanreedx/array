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
