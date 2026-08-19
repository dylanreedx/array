import AppKit

extension NSWindow {
    /// Order a CHECK FIXTURE window in without putting it on the user's screen.
    ///
    /// Fixture windows need to be real — a backing store, a valid `visibleRect`,
    /// a genuine AppKit layout and display cycle — but nothing about a check
    /// requires a human to see them. `orderFrontRegardless()` is what made a
    /// matrix run seize the display for 30-45 seconds at unpredictable moments,
    /// on a machine Dylan is working on: the legs are the gate, not a show.
    ///
    /// Every fixture window is `.borderless`, and AppKit does not constrain a
    /// borderless window's frame to a screen, so parking the origin far off every
    /// display keeps all of the rendering real while presenting nothing. Anything
    /// that genuinely needs on-screen pixels — the UI baselines, the Component
    /// Lab — does NOT use this and is unchanged.
    ///
    /// One consequence to know: an off-display window's `occlusionState` does not
    /// contain `.visible`, so a fixture that drives tile-surface residency must
    /// inject `occlusionVisibilityProvider` (the residency `World` already does).
    /// Without that, the production bake guard correctly refuses every bake and
    /// the fixture measures nothing.
    func orderFrontOffscreenForChecks() {
        setFrameOrigin(CGPoint(x: -60_000, y: -60_000))
        orderFrontRegardless()
    }
}
