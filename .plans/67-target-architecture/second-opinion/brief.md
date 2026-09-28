# Second opinion requested: Array stability architecture

You are GPT-6 Astra, asked by the owner (Dylan) for an independent second opinion. A Claude session investigated four stability complaints in his macOS app Array with fifteen agents, then consolidated the findings into five architecture changes. He wants a *different* perspective: the implementation is large and jagged, it never had a target architecture, and he wants to catch what the first pass overlooked before any fix is written. Do not defer to the first pass. Where you agree, say why with evidence; where you disagree, say what you would do instead.

## Read first, in this order
1. `/Users/dylan/Documents/personal/Array/CLAUDE.md` (the repo orientation; hazard 9 and hazard 10 are essential).
2. `/private/tmp/claude-501/-Users-dylan-Documents-personal-Array/2d77d736-b6ba-44ef-b3fc-166115ad956c/scratchpad/design/consolidated-architecture.md` (the consolidated proposal).
3. `/private/tmp/claude-501/-Users-dylan-Documents-personal-Array/2d77d736-b6ba-44ef-b3fc-166115ad956c/scratchpad/board/board-export.md` (the ticket board, with every file:line the first pass cites).
4. The fifteen investigation reports in `/private/tmp/claude-501/-Users-dylan-Documents-personal-Array/2d77d736-b6ba-44ef-b3fc-166115ad956c/scratchpad/reports/` (`s1`..`s11` scouts, `o1`..`o4` deep dives).

The repo is `/Users/dylan/Documents/personal/Array`, branch `array/integration`, HEAD `1451c030`. Swift/AppKit, SwiftPM. Key files: `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`, `Sources/ContinuumRevived/App/ContinuumApp.swift` (huge), `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` (huge), `Sources/ContinuumRevived/App/TileSpawner.swift`, `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`, `Sources/ContinuumRevived/Canvas/CanvasAutoLayoutEngine.swift`, `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`, `WorkspaceStore.swift`, `Registry.swift`, `ZoneMembershipRepair.swift`.

## The owner's four complaints, verbatim
1. "i thought we got rid of the top bar in the MacOS window itself.. i still see it"
2. "zones feel untrustworthy: the zone names often revert as well as the visual of the directory location (project home) -- i create a new one fine, but if i switch workspaces or close and reopen the app it is no longer present"
3. "agent tiles not accept any new project home... i open Array (or open my Mac in the morning from sleeping) and when i create an agent tile in a zone, it is blank (---) and when i try to select a proper home it doesn't do anything... only after restarting (and sometimes having to recreate the zone)"
4. "tiles in zones shift when switching workspaces or after a period of time -- as well as the zones themselves ... zones overlapping each other ... tiles outside the zones but still 'in' the zone -- this is crucial i want my layout to be consistent and not to change without my doing"

Decided policy: zone growth pushes neighbouring zones like a drag does and never overlaps them.

## Hard rules (the owner's, non-negotiable)
- Read-only. Do not edit, build, commit, stash, or reset anything in the repo or any worktree. Do not launch the app. Do not run any `--*-check` flag. Do not touch `/Applications/Array.app`, `~/Documents/personal/.array`, or `~/Library/Application Support/Array`. Never touch the default tmux socket.
- Your only writable location is the current working directory (this brief's folder). Write your report there.
- Cite code as `path:line` at HEAD. If you assert a mechanism, quote the lines. Distinguish what you verified from what you infer.

## Delegation
Use exactly three subagents in parallel, model `gpt-6-sol`, reasoning effort medium (pass those explicitly if your spawn tool accepts model and reasoning parameters; if it does not, say so in the report and state what the children actually ran). Suggested split, adjust if you see a better one:
- **Sub-A: the write path.** Independently enumerate every writer of the workspace document and of `canvas.json`, every save controller instance, every disk→memory read while mounted, and the registry's ownership fields. Confirm or refute: the arming save controller is never rebound on switch; the 200ms snapshot race; `persistLayoutTransaction`'s reload. Then ask: is "one model, one commit path, one save pipeline" the right shape, or is there a simpler/stronger one (event log + replay, actor, CRDT registers the codebase already uses in `ambientTiles`)? What does ARC-1 overlook?
- **Sub-B: the scene.** Independently trace zone materialization (chrome vs `ZoneLayer`), the hydration tiers, the flat `canvasState` model and its remaining reach, `installProjectTile` and its 17 callers, the jelly engine's scene assembly, membership repair. Confirm or refute: ghost zones, the flat fallback, spawn-vs-materialize conflation. Then ask: is "every mounted zone has a layer + delete the flat scene + provenance + commit-time invariants" the right shape? What would a single scene graph look like, and is it worth it? What do ARC-2/ARC-4 overlook?
- **Sub-C: the boundaries and the gate.** Boot order, `mountWorkspaceSceneAtBoot`, `switchWorkspace`, quit, crash paths; registry/document/`.array` store split and the channel split (hazard 10); presentation builders (`ZoneRenderModel`) and the rollup copy-back; the existing witness legs and why the matrix stayed green. Then ask: is a seeded random-sequence invariants harness the right gate, what invariants are missing from the list (ownership, wholeness, derived presentation, provenance/containment/overlap), and what does ARC-3/ARC-5 overlook?

Each child writes its findings to a file in the working directory; you synthesize.

## Deliverable
Write `second-opinion.md` in the working directory with these sections:
1. **Verdict on the diagnosis.** For each of the first pass's five root-cause sentences: confirmed / partly / refuted, with evidence.
2. **What the first pass missed.** Concrete mechanisms, with file:line, that are not on the board. This is the most valuable section.
3. **Target architecture.** If you had to name the shape Array should converge on (the thing it never had), what is it? Name the owners, the boundaries, the frame spaces, the persistence model, and what "a zone" and "a tile" are. Compare it to the five ARCs: which ARCs survive, which change, which are wrong.
4. **Better ideas.** Alternatives to any ARC, with cost and blast radius, honestly weighed.
5. **Sequencing and risk.** The order you would land in, each step shippable, and the witness (outcome assertions, never source-string checks) that guards it.
6. **Questions for the owner.** Decisions only he can make.
7. **What the children ran.** Model and effort each subagent actually used, and what each covered.

Be direct. The owner would rather hear that the plan is wrong than that it is fine.
