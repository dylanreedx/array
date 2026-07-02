# Idea: agent-to-agent coordination over the op log

The op log can become a typed coordination bus, not just persistence/sync.

Sketch:

```text
agent A observes world
agent A appends typed intent/fact op
sync transports op
agent B derives inbox/projection
agent B policy-checks + executes allowed action
agent B appends result/status op
agent A observes result
```

Important guardrail: do not blindly replay arbitrary ops as side effects. Replay log into projections/inboxes, then adapters execute only capability-scoped, policy-approved requests.

Potential op vocabulary:

- `AgentTaskRequested`
- `AgentTaskClaimed`
- `AgentTaskProgressed`
- `AgentTaskCompleted`
- `AgentTaskFailed`
- `AgentQuestionAsked`
- `AgentAnswerProvided`
- `ApprovalRequested`
- `ApprovalGranted`

This fits the emerging planes:

- observation: readers/watchers/status derivation
- state: op log/snapshots/sync transport
- control: scopes/approvals/adapters/requested actions
- UI: sidebar/status/approval surface

Killer use case: agents coordinate without sharing a giant prompt context. Example: Fable/Opus appends a review task for GPT-5.5; GPT-5.5 claims it, reviews a commit, and appends findings; orchestrator observes the result through the same log/projection.
