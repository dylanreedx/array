---
name: conductor-start
description: Start an autonomous coding session for a project
---

# Conductor Start

Start an autonomous coding session.

## Usage

/conductor-start <project-name> [workspace-path]

## Examples

- `/conductor-start my-backend`
- `/conductor-start my-ui ./my-workspace`

## Behavior

1. Check if conductor MCP service is connected
2. Call `mcp__conductor__get_project_config` to check if maestro is enabled
3. **If maestro enabled**: run the maestro orchestration loop (see below)
4. **If classic mode**: run the classic serial loop below

### Classic Mode

1. Call `mcp__conductor__check_dependencies` to verify dependencies
2. Call `mcp__conductor__begin_work` to start session and get first task with coding prompt
3. Spawn conductor-coder subagent for each task
4. After each task, call `mcp__conductor__complete_work` to mark done and get next
5. When finished, call `mcp__conductor__end_work` to save handoff state
6. Report progress after each task

### Maestro Mode

IMPORTANT: Subagents cannot spawn other subagents. The skill itself IS the orchestrator.
Do NOT spawn conductor-maestro as a subagent. Instead, run the orchestration loop directly.

Phase → Agent mapping:
- analyze → conductor-analyzer (haiku)
- design → conductor-designer (sonnet)
- implement → conductor-coder (inherit)
- test → conductor-tester (sonnet)
- review → conductor-reviewer (haiku)

1. Call `mcp__conductor__check_dependencies` to verify dependencies
2. Call `mcp__conductor__begin_maestro_work` → get task + first phase + prompt
3. For each phase, dispatch the phase agent (see Subagent Dispatch below)
4. Read the agent's output
5. Call `mcp__conductor__advance_task_phase` with the agent's output
6. If more phases remain: dispatch the next phase agent with the returned prompt
7. If review returns REWORK: call `mcp__conductor__request_rework` and re-dispatch
8. If task complete: loop gets next task via `mcp__conductor__complete_maestro_work`
9. When all tasks done: call `mcp__conductor__end_work`

### Subagent Dispatch

When dispatching a phase agent, inject this preamble before the phase prompt:

```
You are being dispatched by the conductor orchestrator.
Complete your phase work and return your output.
Do NOT call advance_task_phase or complete_maestro_work — the orchestrator handles phase transitions.
For review phase: End your response with DECISION: APPROVE or DECISION: REWORK <target_phase> <reason>
```

### Escalation Policy

- On first failure: retry with same model
- On second failure: escalate model (haiku→sonnet, sonnet→opus)
- On third failure for same phase: mark task blocked via record_task_error

## Implementation

```
# Check maestro config
config = mcp__conductor__get_project_config(projectName)

if config.maestroEnabled:
  # === MAESTRO MODE ===
  # The skill itself is the orchestrator — dispatch phase agents directly
  deps = mcp__conductor__check_dependencies(projectName)
  result = mcp__conductor__begin_maestro_work(projectName, workspacePath)
  sessionId = result.session.sessionId

  PHASE_AGENTS = {
    "analyze":   { agent: "conductor-analyzer",  model: "haiku" },
    "design":    { agent: "conductor-designer",  model: "sonnet" },
    "implement": { agent: "conductor-coder",     model: "sonnet" },
    "test":      { agent: "conductor-tester",    model: "sonnet" },
    "review":    { agent: "conductor-reviewer",  model: "haiku" },
  }

  PREAMBLE = """
  You are being dispatched by the conductor orchestrator.
  Complete your phase work and return your output.
  Do NOT call advance_task_phase, complete_maestro_work, or request_rework.
  The orchestrator handles all phase transitions.
  For review phase: End your response with DECISION: APPROVE or DECISION: REWORK <target_phase> <reason>
  """

  while result.nextTask:
    taskId = result.nextTask.id
    phasePrompt = result.phasePrompt or result.codingPrompt
    currentPhase = result.currentPhase

    taskDone = false
    while not taskDone:
      agent = PHASE_AGENTS[currentPhase]

      # Dispatch phase agent
      agentOutput = Task({
        subagent_type: agent.agent,
        model: agent.model,
        description: "{currentPhase} phase: {taskId}",
        prompt: PREAMBLE + "\n\n" + phasePrompt
      })

      # Handle review decisions
      if currentPhase == "review":
        if "DECISION: REWORK" in agentOutput:
          targetPhase, reason = parse_rework_decision(agentOutput)
          reworkResult = mcp__conductor__request_rework(taskId, sessionId, targetPhase, reason, agentOutput)
          currentPhase = targetPhase
          phasePrompt = reworkResult.phasePrompt
          continue
        # else: APPROVE — advance will complete the task

      # Advance phase
      advanceResult = mcp__conductor__advance_task_phase(taskId, sessionId, {
        output: agentOutput,
        status: "passed"
      })

      if advanceResult.taskComplete:
        taskDone = true
        # Get next task
        result = mcp__conductor__complete_maestro_work(taskId, sessionId)
      else:
        currentPhase = advanceResult.nextPhase
        phasePrompt = advanceResult.phasePrompt

    print("Task complete:", taskId)
    print("Progress:", get_project_status)

  mcp__conductor__end_work(projectName, sessionId, {
    currentTask, nextSteps, filesModified
  })

else:
  # === CLASSIC MODE ===
  deps = mcp__conductor__check_dependencies(projectName)
  result = mcp__conductor__begin_work(projectName, workspacePath)
  sessionId = result.session.sessionId

  while true:
    task = result.nextTask
    prompt = result.codingPrompt

    if no task:
      break

    Task({
      subagent_type: "conductor-coder",
      prompt: prompt
    })

    result = mcp__conductor__complete_work(taskId, sessionId)

  mcp__conductor__end_work(projectName, sessionId, {
    currentTask, nextSteps, filesModified, blockers
  })
```
