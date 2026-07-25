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

print("ContinuumRevivedAgentUIChecks passed")
