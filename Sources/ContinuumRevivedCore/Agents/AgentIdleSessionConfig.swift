import Foundation

/// How long a managed agent's CLI session stays alive after its turn ends.
///
/// When it runs out, Array stops the idle CLI to free its memory (about 200 MB
/// per Claude session); the next message resumes the same conversation. A
/// session with background work (a shell job, a child, a schedule) is kept.
public enum AgentIdleSessionConfig {
    public static let minutesKey = "agents.idleSessionMinutes"
    public static let defaultMinutes: Double = 10
    public static let supportedRange: ClosedRange<Double> = 1...120

    /// Read at every turn end, so a change applies from the next idle period.
    /// Any positive stored value is honoured; nothing else falls back to the
    /// default.
    public static func timeout(defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = defaults.object(forKey: minutesKey) == nil ? defaultMinutes : defaults.double(forKey: minutesKey)
        return (minutes > 0 && minutes.isFinite ? minutes : defaultMinutes) * 60
    }
}
