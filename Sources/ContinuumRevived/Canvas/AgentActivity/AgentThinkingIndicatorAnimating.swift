import AppKit

@MainActor
protocol AgentThinkingIndicatorAnimating: AnyObject {
    func startAnimating()
    func stopAnimating()
    func setReducedMotion(_ enabled: Bool)
    func setSnapshotPhase(_ phase: CGFloat)
}
