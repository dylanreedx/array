import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.1-agentui-module.md
//
// Layer-1 check suite for the shared agent-UI module. Its only dependency is
// ContinuumRevivedAgentUI — that is the point: if a token or presenter ever
// reaches back into Core, this executable stops compiling.
//
// `expect` is the same shape as every other checks target's (see
// ContinuumRevivedCoreChecks/main.swift, ContinuumRevivedPaletteChecks): fail
// loud on stderr, exit 1 on the first failure.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
runStatusChipChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.2-tokencolor-light-dark.md
runTokenColorChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.6-token-contrast-gate.md
runTokenContrastChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.3-surface-text-border-tokens.md
runDesignTokenChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.4-type-scale.md
runTypographyChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.5-spacing-radius-scale.md
runMetricsChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
runAgentInboxRowChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.4-frozen-sort.md
runInboxSortChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
runInboxScopeChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
runAgentLifecycleChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.2-effective-settled.md
runEffectiveLifecycleChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.5-snooze-presets.md
runSnoozePresetChecks()

print("ContinuumRevivedAgentUIChecks passed")
