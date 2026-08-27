import Foundation

/// Admission policy for child agents whose processes Array actually creates.
///
/// Provider-owned children (for example Claude `Agent` and Pi `delegate_agent`)
/// are observations, not admissions, and deliberately do not consult this
/// setting: by the time Array sees them the provider has already started them.
public enum AgentSpawnLimitConfig {
    public static let maximumActiveChildrenKey = "agents.maximumActiveChildren"
    /// Zero means unlimited. Array previously shipped an unconfigurable value of
    /// four and counted durable, completed child records against it forever.
    public static let defaultMaximumActiveChildren = 0
    public static let supportedRange = 0...256

    /// `nil` is the runtime representation of Unlimited.
    public static func maximumActiveChildren(
        defaults: UserDefaults = .standard
    ) -> Int? {
        let raw: Int
        if defaults.object(forKey: maximumActiveChildrenKey) == nil {
            raw = defaultMaximumActiveChildren
        } else {
            raw = defaults.integer(forKey: maximumActiveChildrenKey)
        }
        let bounded = min(max(raw, supportedRange.lowerBound), supportedRange.upperBound)
        return bounded == 0 ? nil : bounded
    }
}
