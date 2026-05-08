---
name: conductor-resume
description: Resume an autonomous coding session from the last handoff
---

# Conductor Resume

Resume work from where the last session left off.

## Usage

/conductor-resume [project-name]

## Note

This skill is also invoked automatically by the autonomous mode wrapper (`conductor-mcp autonomous`)
between context rotations. The existing flow handles the `noHandoff` case correctly by falling
back to `begin_work`.

## Behavior

1. Call `mcp__conductor__resume_from_handoff` to get last session context
2. Display last session summary (progress, last task, next steps, blockers)
3. Address any unresolved quality issues
4. Check `mcp__conductor__get_project_config` for maestro mode
5. **If maestro enabled**: run the maestro orchestration loop inline
6. **If classic mode**: continue the classic implementation loop

## Implementation

```
# Get handoff context
context = mcp__conductor__resume_from_handoff(projectName)

print("Resuming project:", context.project)
print("Progress:", context.progress.passed, "/", context.progress.total)
print("Last task:", context.handoff.currentTask)
print("Next steps:", context.handoff.nextSteps)
print("Blockers:", context.handoff.blockers)

# Review quality issues if any
if context.qualityIssues.count > 0:
  print("Unresolved quality issues:", context.qualityIssues)
  # Address or resolve as appropriate

# Check maestro config
config = mcp__conductor__get_project_config(projectName)

if config.maestroEnabled:
  # === MAESTRO MODE ===
  # The skill itself is the orchestrator — dispatch phase agents directly
  # IMPORTANT: Subagents cannot spawn other subagents. Do NOT spawn conductor-maestro.
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

      agentOutput = Task({
        subagent_type: agent.agent,
        model: agent.model,
        description: "{currentPhase} phase: {taskId}",
        prompt: PREAMBLE + "\n\n" + phasePrompt
      })

      if currentPhase == "review":
        if "DECISION: REWORK" in agentOutput:
          targetPhase, reason = parse_rework_decision(agentOutput)
          reworkResult = mcp__conductor__request_rework(taskId, sessionId, targetPhase, reason, agentOutput)
          currentPhase = targetPhase
          phasePrompt = reworkResult.phasePrompt
          continue

      advanceResult = mcp__conductor__advance_task_phase(taskId, sessionId, {
        output: agentOutput,
        status: "passed"
      })

      if advanceResult.taskComplete:
        taskDone = true
        result = mcp__conductor__complete_maestro_work(taskId, sessionId)
      else:
        currentPhase = advanceResult.nextPhase
        phasePrompt = advanceResult.phasePrompt

    print("Task complete:", taskId)

  mcp__conductor__end_work(projectName, sessionId, {
    currentTask, nextSteps, filesModified
  })

else:
  # === CLASSIC MODE ===
  session = mcp__conductor__start_session(projectName)
  sessionId = session.sessionId
  result = mcp__conductor__get_next_task(projectName)

  while result.task:
    prompt = mcp__conductor__get_coding_prompt(projectName, result.task.id)

    Task({
      subagent_type: "conductor-coder",
      prompt: prompt
    })

    result = mcp__conductor__complete_work(result.task.id, sessionId)

  mcp__conductor__end_work(projectName, sessionId, {
    currentTask, nextSteps, filesModified, blockers
  })
```
