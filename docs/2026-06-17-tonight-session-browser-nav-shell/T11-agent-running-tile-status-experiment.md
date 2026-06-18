# T11 — Agent-running tile status/title experiment

Status: draft / design spike
Tag: tonight [terminal] [agents]
Depends on: T09

## Goal
Explore how a terminal tile should render when an agent is running. Can the tile bar show the current action, run id, or task state rather than only cwd?

## Questions
- Can we detect Pi/agent sessions reliably from terminal process state or logs?
- Should status be explicit metadata from the agent runtime instead of shell scraping?
- What title is most useful: agent role, current step, branch/worktree, or task summary?
- How often can status update without causing visual noise?

## Scope
- Design only unless an obvious low-risk integration exists.
- Produce a recommended model for terminal-associated activities.
- Include privacy/logging concerns.

## Acceptance criteria
- [ ] Design note proposes display states: idle shell, running command, running agent, failed/done agent.
- [ ] Recommendation identifies data source and fallback.
- [ ] Follow-up implementation ticket is created if feasible.

## TDD sketch
Even for a design spike, prototype a classifier with fixtures.

```swift
let running = AgentTileStatusClassifier.classify(processTitle: "pi", lastLogLine: "Running tests", exitCode: nil)
expect(running == .agentRunning(summary: "Running tests"))

let failed = AgentTileStatusClassifier.classify(processTitle: "pi", lastLogLine: "FAILED swift test", exitCode: 1)
expect(failed == .agentFailed(summary: "FAILED swift test"))

let shell = AgentTileStatusClassifier.classify(processTitle: "zsh", lastLogLine: nil, exitCode: nil)
expect(shell == .plainShell)
```
