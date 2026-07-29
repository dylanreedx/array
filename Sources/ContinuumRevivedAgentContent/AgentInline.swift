import Foundation

/// Inline meaning. Typography, colors, click handlers, and AppKit values belong
/// to renderers, not this model.
public indirect enum AgentInline: Codable, Equatable, Sendable {
    case text(String)
    case emphasis([AgentInline])
    case strong([AgentInline])
    case code(String)
    case link(destination: String, title: String?, children: [AgentInline])
    case softBreak
    case hardBreak
}
