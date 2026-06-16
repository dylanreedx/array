# T20 — Wire the boot `WorkspaceRuntime`'s real per-project controller factory  ⚠ NEEDS-HUMAN (design)

Status: needs-human (surfaced by the T09 review; captured by the orchestrator mid-sprint — NOT in the original 19-task plan)
Tag: overnight [appkit-checkable] (once the design is confirmed)
Depends on: T06 (WorkspaceRuntime + ZoneRuntimeRegistry), T08 (addZone path)
Blocks (for PRODUCTION liveness, not for checks): the live behavior of T07–T10 + the T16 sidebar switch + T06/T09 visual gates.

## Why this exists (the HIGH risk from T09)
T06 builds `WorkspaceRuntime` + `ZoneRuntimeRegistry` and, at boot (`ContinuumApp.swift` ~1146–1157), constructs the live runtime with a **throwing placeholder registry factory** (`"unexpected acquire on boot registry — T08 wires this"`). The registry is an immutable `let` with no swap-in seam. Consequences (caught by the T09 review):
- `registry.acquire(projectId)` THROWS for any project not already handed in at the `boot:` init.
- So `WorkspaceRuntime.addProjectZone`/`addZone` (T08) and `switchWorkspace` (T09) both throw in the **running app** → caught → no-op.
- T09 removed the `relaunchApplication` fallback, so ⌘K → switch-workspace is now a **silent no-op regression** live.
- The T07–T10 checks all PASS because each **injects a fully-wired registry**; the production wiring is inert.

**Net: the keystone (T06–T10) is built + headlessly verified but does NOT function in the live app until this is wired.** This is the single most important morning item.

## What's needed
Give the boot `WorkspaceRuntime` a registry whose `makeController(projectId:)` constructs a real per-project `ZoneRuntimeController` (project store at the project's root, lock policy, shared `GhosttyRuntimeContext`/`BrowserEngineContext`, etc.), plus a **real-path check** that boots the production wiring (not an injected test registry) and asserts `addProjectZone` and `switchWorkspace` SUCCEED (don't throw) and install live zones.

## Design questions for Dylan (why this is needs-human, not auto-built)
1. Where do per-project controllers get their shared contexts (Ghostty/Browser engine contexts) at construction — passed into the registry factory at boot, or resolved lazily per acquire?
2. Lock policy when acquiring a project already locked by another window/instance — degraded/cold tier? (overlaps the S9 lock-degradation stretch).
3. Is the boot project itself acquired through the registry (uniform) or kept as the special boot controller it is today (the `boot:` init path)?

Once these are settled this is a normal TDD task: check boots the real wiring → asserts add-zone + switch succeed in-process.
