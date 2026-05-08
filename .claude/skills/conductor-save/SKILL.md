---
name: conductor-save
description: Save session state — memories, task status, and handoff
---

# Conductor Save

Save current session state with memories, task assessment, and handoff context.

## Usage

/conductor-save <project-name> [end]

## Examples

- `/conductor-save my-backend` — checkpoint: save state, keep working
- `/conductor-save my-backend end` — save state and close session

## Behavior

1. **Reflect** — analyze the conversation for reusable knowledge and save as memories
2. **Assess** — collect in-progress and failed tasks as incomplete work
3. **Save** — prepare handoff (checkpoint) or end session (end mode)

### Phase 1: Reflect (Memories)

1. Call `mcp__conductor__get_memories` and `mcp__conductor__search_memories` to check what's already saved for this project
2. Analyze the current conversation for saveable knowledge across these types:
   - `pattern` — reusable code or architectural patterns
   - `decision` — design choices with rationale
   - `gotcha` — pitfalls encountered and their solutions
   - `convention` — coding conventions discovered
   - `architecture` — structural codebase insights
   - `preference` — user working style or tool preferences observed
3. For each insight, call `mcp__conductor__save_memory` with name, content, memoryType, tags, and projectName
4. Use `relatedTo`, `updates`, or `contradicts` to link to existing memories when applicable

IMPORTANT: Only save memories that are reusable across sessions, non-obvious, and specific enough to be actionable. Session-specific context (current task, files touched, next steps) belongs in the handoff, not in memories. When in doubt, leave it out.

### Phase 2: Assess (Tasks)

1. Call `mcp__conductor__get_task_list` with `status='in_progress'` for active tasks
2. Call `mcp__conductor__get_task_list` with `status='failed'` for recently failed tasks
3. Collect both into an `incompleteWork` list with task IDs and descriptions
4. Do not change any task statuses — this phase is documentation only

### Phase 3: Save (Handoff)

**Checkpoint mode** (default — no `end` argument):
- Call `mcp__conductor__prepare_handoff` with currentTask, nextSteps, blockers, filesModified, and incompleteWork
- Session stays open for continued work

**End mode** (`end` argument provided):
- Call `mcp__conductor__end_work` with projectName, sessionId, currentTask, nextSteps, blockers, filesModified, incompleteWork, shortcutsTaken, testingGaps, technicalDebt, and notes
- Session is closed

IMPORTANT: For end mode, you need an active sessionId. Call `mcp__conductor__start_session` to get one if no session is currently active.

### Output Summary

Print a structured summary:
- Memories saved (count by type)
- Incomplete tasks noted (count with IDs)
- Handoff status (checkpoint or ended)
- Session state (open or closed)

## Implementation

```
projectName = args[0]
mode = "end" if args[1] == "end" else "checkpoint"

# === PHASE 1: REFLECT ===
existingMemories = mcp__conductor__get_memories(projectName=projectName, limit=20)
searchResults = mcp__conductor__search_memories(query=projectName)

# Analyze conversation for saveable knowledge
# Compare against existing memories to avoid duplicates
insights = analyze_conversation_for_insights()
memoriesSaved = {}

for insight in insights:
  # Skip if already captured in existing memories
  if is_duplicate(insight, existingMemories, searchResults):
    continue

  memory = mcp__conductor__save_memory(
    name=insight.name,
    content=insight.content,
    memoryType=insight.type,
    tags=insight.tags,
    projectName=projectName,
    relatedTo=insight.relatedTo,
    updates=insight.updates,
    contradicts=insight.contradicts
  )
  memoriesSaved[insight.type] = memoriesSaved.get(insight.type, 0) + 1

# === PHASE 2: ASSESS ===
inProgress = mcp__conductor__get_task_list(projectName, status='in_progress')
failed = mcp__conductor__get_task_list(projectName, status='failed')
incompleteWork = []
for t in inProgress.tasks + failed.tasks:
  incompleteWork.append(f"{t.id}: {t.description} ({t.status})")

# === PHASE 3: SAVE ===
if mode == "checkpoint":
  mcp__conductor__prepare_handoff(
    projectName=projectName,
    currentTask=summarize_current_task(),
    nextSteps=determine_next_steps(),
    blockers=identify_blockers(),
    filesModified=collect_modified_files(),
    incompleteWork=incompleteWork
  )
  print("Handoff: checkpoint saved (session still open)")

else:  # end mode
  session = mcp__conductor__start_session(projectName)
  mcp__conductor__end_work(
    projectName=projectName,
    sessionId=session.sessionId,
    currentTask=summarize_current_task(),
    nextSteps=determine_next_steps(),
    blockers=identify_blockers(),
    filesModified=collect_modified_files(),
    incompleteWork=incompleteWork,
    shortcutsTaken=note_shortcuts(),
    testingGaps=note_testing_gaps(),
    technicalDebt=note_tech_debt(),
    notes=summarize_session()
  )
  print("Handoff: session ended")

# === SUMMARY ===
print("--- Save Summary ---")
print("Memories saved:", sum(memoriesSaved.values()))
for type, count in memoriesSaved.items():
  print(f"  {type}: {count}")
print("Incomplete tasks:", len(incompleteWork))
for item in incompleteWork:
  print(f"  {item}")
print("Mode:", mode)
```
