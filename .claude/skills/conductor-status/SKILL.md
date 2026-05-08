---
name: conductor-status
description: Show progress status for all projects
---

# Conductor Status

Display current progress for all projects.

## Usage

/conductor-status [project-name]

## Output

- Progress percentage per project
- Current phase for maestro tasks
- Tasks passed/total
- Active agent assignments (maestro mode)
- Recent session activity
- Any blocked tasks
- Unresolved quality issues

## Implementation

```
if projectName:
  status = mcp__conductor__get_project_status(projectName)
  issues = mcp__conductor__get_quality_issues(projectName)
  config = mcp__conductor__get_project_config(projectName)
  print_project_details(status)
  if config.maestroEnabled:
    agents = mcp__conductor__get_active_agents(projectName)
    print("Maestro mode: enabled")
    print("Active agents:", len(agents))
    for agent in agents:
      print("  ", agent.phase, "→", agent.agent_type, "(", agent.model, ")")
  if issues:
    print("Quality issues:", len(issues))
else:
  status = mcp__conductor__get_project_status()
  for project in status:
    print(project.name, ":", project.progress.percentage, "%")
    print("  ", project.progress.passed, "/", project.progress.total, "tasks")
```
