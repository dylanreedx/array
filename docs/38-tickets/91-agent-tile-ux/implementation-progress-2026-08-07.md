# Managed Agent Tile Polish — Implementation Progress

**Updated:** 2026-08-07 UTC, end-of-night wave
**Integration branch:** `array/integration`
**Latest integrated code commit:** `57b16e3`
**Source plan:** `docs/38-tickets/91-agent-tile-ux/plan-managed-agent-tile-polish.md`

## Evidence labels

- **Integrated:** committed on `array/integration` and checked from the main checkout.
- **Component-complete:** integrated reusable code exists, but the real tile route is not wired.
- **Review-gated:** an isolated branch contains useful code, but review blockers remain; do not merge yet.
- **End-to-end:** exercised on the real managed-agent/Pi route. Nothing below is end-to-end unless explicitly labeled.

## Integrated work

| Commit(s) | Scope | Evidence |
|---|---|---|
| `8128eb9` | Shared thinking-indicator contract | Build passed. |
| `bc41735` | Four throbber candidates and Component Lab motion study | Build, UI probes, geometry, contrast, deterministic snapshot, and supervised screenshot inspection passed. No winner selected or production-wired. |
| `6ee129d` | Remove inert `Next turn`; preserve effort intrinsic width | Build and 320/480/560 geometry checks passed. |
| `23e19d5` | Provider-neutral truthful context telemetry and Pi parsing | Build and Core checks passed. Unknown occupancy remains unknown. |
| `befe4aa` | Image prompt/semantic/Pi argv foundations | Build, AgentContent checks, and focused Core image-contract checks passed. |
| `3a9e0aa` | Bound long-stream reducer and visual-forwarding work | Main build, AgentContent checks, and UI geometry passed. RED→GREEN large multibyte-delta witness added. |
| `68ec512` | Source plan, Luna High agent role, and implementation record | Documentation committed without adding STOP/unrelated ticket artifacts. |
| `53a53d5` | Completed-reasoning disclosure foundation | Build and UI geometry passed; 13 deterministic lifecycle/semantic-host assertions. Not routed in production. |
| `ddbf83d` → `494df07` | Transcript image/gallery renderer and Quick Preview/action foundations | Build and UI geometry passed; nine image/gallery states. Uses lazy bounded presentation, revision invalidation, ID-only actions, safe local-file helpers. Production resolver/actions unwired. |
| `9b5b4a0`, `39b8c33`, `48aef37` | Compact status row and radial context meter components | Build, UI probe, geometry, and contrast passed. 13,794 state/layout assertions; manual lifecycle fix covers live↔snapshot transitions and detach/hide. Production composition unwired. |
| `f1050fb`, `7e42483`, `4b6d1f4` | Composer image decoder/import seam, bounded thumbnail service, attachment rail | Build, component checks, and UI geometry passed: 16 ingestion, 30 thumbnail, and 26 rail assertions. Production paste/drop wiring unwired. |
| `258b52a`, `96a4001`, `7056f78`, `57b16e3` | Streamed Markdown, semantic reconciliation, delayed pause flush, Markdown copy | Build, AgentContent, focused Core projection, UI probe, and UI geometry passed. Production timer uses the projection monotonic clock; 5,000-delta full projection path completed in 0.197s at 149 parses. Real Pi/GitHub paste remains unverified. |

## Main-checkout verification from the final wave

Successful commands included:

- `swift build`
- `swift run ContinuumRevivedAgentContentChecks`
- `swift run ContinuumRevivedCoreChecks -- --agent-transcript-projection-check`
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 .build/debug/continuum-revived --ui-probe-check`
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 .build/debug/continuum-revived --ui-geometry-check`
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 .build/debug/continuum-revived --ui-contrast-check`
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 .build/debug/continuum-revived --composer-image-components-check`

### Streamed Markdown evidence

- Assistant and reasoning use the same semantic parser path.
- A delta inside the 30Hz window schedules a one-shot timer; a provider pause no longer leaves the previous semantic prefix indefinitely.
- Completion, interruption, error, ready/stopped session state, stream boundary, reset, detach, and teardown flush/cancel paths are covered.
- Stream accumulation stores chunks rather than copying answer-so-far per delta; final raw source is archived once.
- `replaceMarkup` has direct forest, identity, move, revision, and patch checks.
- Managed transcript equality includes visible raw compatibility state.
- Response/reasoning selection puts normalized Markdown on `.string`; user/mixed/plain paths remain plain.
- Real Pi output and real GitHub/Notion paste are still required before claiming end-to-end behavior.

### Long-stream reducer evidence

- RED before the correction: one `8196`-byte multibyte provider delta produced an oversized text run above the `4096`-byte cap.
- GREEN after correction: all streamed runs remain bounded at valid Unicode-scalar boundaries while preserving exact source.
- The 10,000-mutation reducer workload and 5,000-delta visual coalescing checks pass.

## Integrated but not production-wired

### Composer images

Implemented components now provide:

- PNG/JPEG/TIFF pasteboard decoding and per-item representation deduplication.
- Mandatory injected managed import; no default external-file adoption.
- Managed/readable/regular/ImageIO-supported result validation.
- Canonical backing-pixel keys, decoded-cost cache accounting, request coalescing, cancellation-aware detached decoding, visible leases, offscreen/hide/detach cleanup, and no product count cap.
- Lazy horizontal rail, state presentation, keyboard removal/navigation, and accessibility labels.

Still needed:

- Bind Lane A storage import closures.
- Route real paste/drop events from `ComposerTextView`/`AgentComposerView`.
- Persist draft attachment metadata and construct `AgentPrompt`.
- Measure real RSS with many large originals.

### Transcript images

Implemented components now provide:

- `.image`/`.imageGallery` renderer registration.
- Opaque-ID state/revision snapshots and bounded thumbnail requests.
- Lazy/reused per-occurrence presentation, including duplicate attachment IDs.
- Processing/available/missing/failure transitions with measurement invalidation.
- ID-only Preview/Copy/Save/Reveal intents; owner must re-resolve at click time.
- Safe label/error presentation and local readable regular image validation.
- Non-destructive Save As and actual image-content copy helpers.

Still needed:

- Bind the shared composer thumbnail service through `AgentImageResourceProvider`.
- Inject the host-local resolver into the live tile render context.
- Handle actions in the live tile and manually verify Quick Look/Finder/Save Panel/VoiceOver.

### Bottom status/context row

Implemented components now provide:

- Explicit Starting/Thinking/Responding/Reading/Searching/Editing/Running/Waiting/Ready/Failed/Interrupted phase model.
- SF Symbol location/activity icons and Home/Where/Activity/Context accessibility semantics without visible prefixes.
- Injected indicator lifecycle with Reduced Motion, deterministic QA snapshot mode, hide/detach stop, and live restart.
- Raw authoritative used/max tooltip arithmetic, render-only arc clamping, truthful unknown/stale state, and invalid-negative rejection.
- Injected warning/critical policy; production default remains disabled until Dylan approves thresholds.

Still needed:

- Derive live phase/timestamps from provider/tool events.
- Place row below composer and above provider controls.
- Replace rather than duplicate the top location row.
- Select and inject a throbber after human motion review.

### Completed reasoning

Implemented foundation uses finished `.reasoning` entries only, keeps active reasoning in live activity, renders every semantic block through the existing role-aware host/registry (including code and safe unknown fallback), persists entry-keyed disclosure state, and exposes remeasurement.

Still needed: route reasoning entries at the transcript entry-row layer and supply authoritative duration.

## Review-gated branches — do not merge yet

### Image storage and supervisor transport

Worktree: `/Users/dylan/.pi/worktrees/Array-luna-high-implementer-20260807T031240Z-97edeb`

Commits through `08bfc91` include expected-agent all-or-nothing preparation, ownership journals, durable submission states, Pi path redaction, image-only supervisor transport, and stronger AtomicWriter checks. The latest implementation final was corrupted by a watch/coordinator response, so the branch did not receive a clean final review.

Remaining review concerns:

- Prove import rollback failures leave durable discoverable cleanup state, not only an error containing a path.
- Recheck crash recovery around `confirming` ownership with a missing/removed journal.
- Re-run fresh build/Core/supervisor checks from a clean artifact path.
- Wire `.sendPrompt(AgentPrompt)` transcript echo and pre-start restore only after approval.

### Host-local tool detail foundation

Worktree: `/Users/dylan/.pi/worktrees/Array-luna-high-implementer-20260807T030542Z-d50bb5`

Commits `a80868b` + `76e8db5` add a non-Codable actor store, sanitization, truncation, expiry, ordering, affected-file tracking, and pure summaries. It remains review-gated because the security-sensitive rework has not received a final independent approval.

Specific review concerns:

- Secret equality fingerprints currently use predictable SHA-256; evaluate keyed per-store HMAC to avoid low-entropy dictionary leakage.
- Secret-bearing affected paths should probably be omitted rather than rewritten into fabricated local paths.
- Bound compact command/query summaries to a single short line.
- Decide deterministic ordering for same-ID updates with identical/missing provider timestamps.
- Replace remaining source-scan boundary evidence if a stronger compile-negative seam is practical.

## Integration ownership and next order

Only the Sol coordinator edits these hotspots:

- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptListView.swift`
- `Sources/ContinuumRevivedAgentContent/AgentDocumentReducer.swift`
- `Sources/ContinuumRevivedAgentContentChecks/DocumentReducerChecks.swift`

Next session:

1. Final-review and either fix or reject the storage/transport branch.
2. Build a composer adapter from approved storage + integrated rail/thumbnail contracts.
3. Build a transcript media resolver/action adapter.
4. Build a live status-phase adapter.
5. Perform one controlled `ManagedAgentTileNSView` composition pass.
6. Route completed reasoning disclosures.
7. Final-review/integrate the host-local tool-detail foundation, then adapter and renderer.
8. Consolidate overflow ownership.
9. Dylan selects a throbber; wire only that candidate.
10. Run real managed-agent/Pi acceptance.

## Real-route acceptance still required

Do not claim the overall feature is working until these are observed:

- Real Pi streamed Markdown displays completed syntax semantically and a paused stream flushes promptly.
- GitHub/browser `.string` paste receives Markdown; explicit plain-text copy remains available.
- Paste/drop images appear in the composer, survive relaunch, send to Pi, and echo into the transcript without local paths.
- Many-image behavior maintains bounded decoded thumbnail memory.
- Transcript gallery transitions, Quick Preview, Copy Image, Save As, Reveal, missing-file recovery, and cleanup work live.
- Bottom row appears in the required position and passes Reduced Motion/VoiceOver on the real tile.
- Reasoning and tool disclosures remeasure correctly and preserve privacy boundaries.
- Exactly one generic overflow remains.

## Scope decisions retained

- Persistent image tiles remain deferred from the first image release.
- Remote Markdown images never auto-load.
- No product-level image-count cap.
- No inferred context percentage from message token totals.
- Warning/critical context thresholds remain configurable and unapproved.
- No production throbber selection without Dylan's motion review.
