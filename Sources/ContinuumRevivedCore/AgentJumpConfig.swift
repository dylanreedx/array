import Foundation

/// Whether jumping to an agent tile lands on its composer (Settings > Canvas).
///
/// On (the default): a jump keeps a readable zoom and, when the agent's tile is
/// taller than the screen, frames its BOTTOM so the composer sits in view with the
/// latest transcript above it, and the tile's header stays pinned at the top edge
/// while its own header is scrolled away (the sticky head). Off: today's jump —
/// the tile's top is framed and no head is pinned.
public enum AgentJumpConfig {
    public static let composerFirstKey = "array.agentJump.composerFirst"
    public static let defaultComposerFirst = true

    public static func composerFirst(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: composerFirstKey) != nil
            ? defaults.bool(forKey: composerFirstKey)
            : defaultComposerFirst
    }
}
