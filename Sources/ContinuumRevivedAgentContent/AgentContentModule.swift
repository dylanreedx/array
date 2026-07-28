import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.2-agent-content-target.md
//
// The platform-neutral home for the agent transcript's semantic document.
// Everything that lands here — the document/block/inline model, the mutation
// vocabulary, the reducer, the Markdown parser — describes MEANING. It never
// describes a view, a colour, a font, or a runner.
//
// The invariant this module exists to hold, restated so a future ticket cannot
// mistake it for a style preference:
//
//   * Foundation (plus, from P2.1, Apple's swift-markdown) and nothing else.
//   * No AppKit, SwiftUI, or UIKit — not even behind a canImport.
//   * No ContinuumRevivedCore / Sync / AgentUI / FileTree / GhosttyKit / GRDB:
//     the dependency direction is Core → AgentContent, never the reverse.
//
// `ContinuumRevivedAgentContentChecks` enforces both halves: it links this
// target alone (so a reverse dependency fails to compile), and it scans these
// sources and the package manifest for a forbidden import or target dependency.

/// Identity of the platform-neutral agent-content module.
///
/// Deliberately thin: P0.2 stands the module and its check leg up: the semantic
/// types arrive in P1.1 onward.
public enum AgentContentModule {
    /// The target name, as declared in `Package.swift`.
    public static let name = "ContinuumRevivedAgentContent"
}
