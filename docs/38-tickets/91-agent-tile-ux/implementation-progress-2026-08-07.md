# Managed Agent Tile Polish — Implementation Progress

**Updated:** 2026-08-07 UTC
**Integration branch:** `array/integration`
**Current integrated HEAD:** `3a9e0aa`
**Source plan:** `docs/38-tickets/91-agent-tile-ux/plan-managed-agent-tile-polish.md`

## Evidence labels

- **Integrated:** committed on `array/integration` and checked from the main checkout.
- **Component-complete:** implemented in an isolated branch; not production-wired.
- **Rework:** secondary Sol review found blocking issues; do not merge the original commit.
- **End-to-end:** exercised on the real managed-agent/Pi route. Nothing in this progress report is end-to-end unless explicitly labeled.

## Integrated work

| Commit | Scope | Evidence |
|---|---|---|
| `8128eb9` | Shared thinking-indicator contract | Build passed. |
| `bc41735` | Four throbber candidates and Component Lab motion study | Build, UI probes, geometry, contrast, deterministic snapshot, and supervised screenshot inspection passed. No winner selected or production-wired. |
| `6ee129d` | Remove inert `Next turn`; preserve effort intrinsic width | Build and 320/480/560 geometry checks passed. |
| `23e19d5` | Provider-neutral truthful context telemetry and Pi parsing | Build and Core checks passed. Unknown occupancy remains unknown. |
| `befe4aa` | Image prompt/semantic/Pi argv foundations | Build, AgentContent checks, and focused Core image-contract checks passed. |
| `3a9e0aa` | Bound long-stream reducer and visual-forwarding work | Main build, AgentContent checks, and UI geometry passed. Added a RED→GREEN witness for a single large multibyte provider delta and bounded every streamed text run. |

### Long-stream evidence captured on main

- RED before the final reducer correction: one `8196`-byte multibyte provider delta produced one oversized run above the `4096`-byte cap.
- GREEN after correction: AgentContent checks passed, including the new large-delta witness and existing 10,000-mutation workload.
- `swift build` passed.
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 .build/debug/continuum-revived --ui-geometry-check` passed, including 5,000 semantic deltas coalesced into one visual apply.

## Isolated deliverables and review disposition

### Streamed Markdown and copy

- Original consolidated implementation: `51bf777` in `/Users/dylan/.pi/worktrees/Array-luna-high-implementer-20260807T013334Z-e18e8f`.
- Added streaming buffer/parser projection, semantic `replaceMarkup`, identity reconciliation, response Markdown on public `.string`, and explicit user/plain copy behavior.
- Secondary Sol review: **REWORK**.
- Blockers:
  - A parse request arriving inside the 30 Hz window can remain semantically stale indefinitely if the provider pauses.
  - The frozen-clock 5,000-delta test does not model production cadence or reducer/reconciliation cost.
  - Production assistant/reasoning now bypasses the bounded `appendMarkup` route, so production-path performance needs a direct oracle.
- Rework run: `luna-high-implementer-20260807T031240Z-a0ce13`.
- Required result: consolidated branch based on `3a9e0aa`, one-shot delayed flush wired through the real tile/model lifecycle, realistic cadence/performance checks, and all current reducer/list optimizations preserved.

### Image storage and supervisor transport

- Original storage commit: `74d601c`.
- Original transport commit: `8c9d94f`.
- Secondary Sol review: **REWORK**.
- Blockers:
  - Attachment resolution lacks expected-agent/all-or-nothing ownership validation.
  - Accepted dispatch clears durable recovery before provider/turn acceptance is known.
  - Pi stderr can echo managed `@path` arguments into runtime errors/transcript.
  - Production action adapter does not echo `.sendPrompt(AgentPrompt)` into the semantic transcript.
  - Symlink traversal, manifest rollback, cleanup failure, and fsync claims are insufficiently guarded.
- Rework run: `luna-high-implementer-20260807T031240Z-97edeb`.
- Required result: consolidated storage/transport branch based on `3a9e0aa`; final `.sendPrompt` tile echo remains a serialized coordinator hunk.

### Composer image ingestion, thumbnail service, and attachment rail

- Original component commit: `bba6c96`.
- Secondary Sol review: **REWORK**.
- Blockers:
  - External file adoption was optional instead of requiring managed import.
  - Multiple pasteboard representations of one item could duplicate attachments.
  - Thumbnail cancellation did not reach detached decode work; offscreen cells retained thumbnails/tasks.
  - Cache cost used compressed PNG bytes rather than decoded backing memory and had noncanonical keys.
- Rework run: `luna-high-implementer-20260807T031240Z-4e5321`.
- Production paste/drop/composer wiring remains deferred to a consolidated adapter wave.

### Transcript image/gallery and Quick Preview

- Original component commit: `ce624f3`.
- Secondary Sol review: **REWORK**.
- Blockers:
  - Gallery eagerly rebuilt and resolved all cells/resources.
  - Renderer retained full `NSImage`/file capabilities and actions carried those capabilities instead of opaque identity.
  - Resource transitions lacked revision/invalidation.
  - Display/error text could leak local data.
  - Save As could delete source/destination before successful replacement; Copy could copy a URL instead of image content; Quick Look validation was too weak.
- Rework run: `luna-high-implementer-20260807T031240Z-c33dd3`.
- Production resolver/action wiring remains deferred to the serialized tile coordinator.

### Compact bottom status row and radial context meter

- Original component commit: `60ba955`.
- Secondary Sol review: **REWORK**.
- Blockers:
  - Injected throbber never entered a live lifecycle and the no-op QA spy false-passed.
  - Coarse status mapping could not represent Starting/Thinking/Responding/Reading/Searching/Running/failure/interruption.
  - Tooltip clamped authoritative arithmetic and mishandled invalid negative occupancy.
  - Warning/critical thresholds were hard-coded despite remaining a product decision.
  - Geometry count did not independently prove labels/icons/lifecycle or production-like compression.
  - Unicode icons and AX semantics did not meet the SF Symbol/Home/Where/What contract.
- Rework run: `luna-high-implementer-20260807T031310Z-d20482`.
- Warning policy must remain injected/undecided until approved; no throbber winner may be selected automatically.

## New last-wave foundations in progress

| Run | Scope | Conflict rule |
|---|---|---|
| `luna-high-implementer-20260807T030542Z-2930d4` | Completed-reasoning disclosure presenter/view | New component files only; no list/tile/registry wiring. |
| `luna-high-implementer-20260807T030542Z-d50bb5` | Host-local tool-detail store, redaction, truncation, presenter | New Core/presenter files only; does not widen `AgentRuntimeEvent`. |

## Integration ownership and order

Only the Sol coordinator edits these hotspots on the integration branch:

- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptListView.swift`
- `Sources/ContinuumRevivedAgentContent/AgentDocumentReducer.swift`
- `Sources/ContinuumRevivedAgentContentChecks/DocumentReducerChecks.swift`

Planned order after rework review:

1. Integrate corrected Markdown/copy branch and rerun main build/content/core/UI checks.
2. Integrate corrected storage/transport contracts.
3. Integrate corrected shared thumbnail/import components.
4. Integrate corrected lazy transcript image/gallery/action components.
5. Integrate corrected status row/meter components.
6. Build separate composer, transcript-media, and status adapters without editing the tile composition root in parallel.
7. Perform one controlled `ManagedAgentTileNSView` composition pass.
8. Integrate reasoning/tool disclosures, then overflow consolidation.
9. Dylan selects a throbber from Component Lab; only then wire it.
10. Run real managed-agent/Pi acceptance.

## Real-route work still required

Do not claim the overall feature is working until these are observed:

- Real Pi streamed Markdown displays completed syntax semantically and a paused stream flushes promptly.
- GitHub/browser `.string` paste receives Markdown; explicit plain-text copy remains available.
- Paste/drop images appear in the composer, survive relaunch, send as Pi image input, and echo into the transcript without local paths.
- Large/many-image behavior uses bounded decoded thumbnail memory and lazy visible-cell work.
- Transcript gallery transitions, Quick Preview, Copy Image, Save As, Reveal, missing-file recovery, and cleanup work on the live route.
- Bottom status row occupies the specified location, reports truthful context state, drives the selected indicator correctly, and passes Reduced Motion/VoiceOver.
- Reasoning and tool disclosures remeasure correctly and never widen sync/privacy boundaries.
- Exactly one generic overflow remains.

## Scope decisions retained

- Persistent image tiles remain deferred from the first image release.
- Remote Markdown images never auto-load.
- No product-level image-count cap.
- No inferred context percentage from message token totals.
- Warning/critical context thresholds remain configurable and unapproved.
- No production throbber selection without Dylan's motion review.
