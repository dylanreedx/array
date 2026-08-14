# 96 — Ledger

Append-only record of witnesses, in the order they were observed. Every entry
records what was RUN and what it PRINTED, not what was intended.

Source commit: `d334f019ac3aa855ffda40402f6dfb9ed8550247` (`array/integration`).
Worktree: `~/array-worktrees/sidebar-96`, branch `array/sidebar-96`, clean at start
(`## array/sidebar-96` with no modified paths). The uncommitted canvas-performance
changes in the main checkout belong to `array/canvas-perf` and are deliberately
absent from this worktree.

---

## P0 baseline — 2026-08-14

All green before any edit, so a later red is attributable to this program:

| leg | result |
|---|---|
| `swift build --product Array` | GREEN, 76.23s |
| `.build/debug/Array --sidebar-ux-check` | GREEN — `ContinuumRevivedSidebarUXChecks passed` |
| `swift run ContinuumRevivedAgentUIChecks` | GREEN — includes `SidebarDefectCorpus checks passed: 11 declared shapes ↔ 11 corpus arms…` |
| `.build/debug/Array --agent-inbox-check` | GREEN — `ContinuumRevivedAgentInboxChecks passed` |

**Measured current geometry, harvested from `--agent-inbox-check`'s own output** (so
S0's reference anchor is measured rather than quoted from prose): parked/slim rows
`35.0pt`, full cards `79.0pt`, and the lifecycle crossfade holds the outgoing card at
`(0.0, 83.0, 303.0, 83.0)` — i.e. **79 pt card on an 83 pt pitch**, at a 303 pt
content width. This is consistent with `performance`-style prose in the design
(§2.2's "79 pt card + 4 pt gap = 83 pt pitch") and is now witnessed.

---

## P0.1 — entry witness, RED — 2026-08-14

### Half 1: the existing corpus passes

`.build/debug/Array --sidebar-ux-check` → GREEN (above). The queue-94 corpus,
`LabFixtures.sidebarDefectRows`, covers 11 declared shapes with two-way parity and
full state/attention/lifecycle/variant/depth coverage — and it is all hand-written
`AgentInboxRow` literals.

### Half 2: the product still renders the owner-screenshot row

New leg `.build/debug/Array --sidebar-production-corpus-check`, **exit 1**:

```
FAIL: P0.1 inventory missing at …/96-agent-sidebar-product-redesign/P0.1-fixture-inventory.md
      — every declared flow must map to its resulting row and surface in a committed document
SidebarProductionCorpus: observed rows per flow
  blankCmdKDraft: title='New agent' state='Unconfirmed' meta='' branch='' elapsed='' providerGlyph='◈'
```

That row was produced by driving the real writer the ⌘K path reaches
(`AgentSupervisor.spawn(role: nil, prompt: nil, …)`, AgentSupervisor.swift:1458 →
`makeAgent` :1545 → `persist` :1618) against real on-disk stores, then read off the
**rendered cell** through the real join (`refreshAgentSurfaces` →
`buildAgentInboxRows` → `AgentContextIndex.build` → `AgentInboxRowBuilder.rows` →
`AgentInboxView`). Nothing in the flow constructs an `AgentInboxRow`.

So both halves of §6/P0.1's stated entry witness are observed together: the current
corpus passes while an owner-screenshot-equivalent row renders a sentinel subject,
three empty detail bands, and an unexplained Unicode mark. Specifically:

- `title='New agent'` — a durable record exists before the user typed anything
  (design §2.4). The sentinel beats the model-named tile title.
- `meta=''`, `branch=''`, `elapsed=''` — **every** detail band is empty. This is the
  measurable form of "mostly empty 83 pt rows" (§2.2): of the row's bands, only the
  subject and a glyph carry anything.
- `providerGlyph='◈'` — the `AgentProviderGlyph` map's OpenAI arm. The design's
  complaint is the class of mark, not one codepoint; the unknown-provider arm of the
  same map returns `'◇'` and is covered by the `unknownProvider` flow.
- `state='Unconfirmed'` — a never-observed record is frozen as unconfirmed
  (`UnconfirmedElapsedFreeze`, ContinuumApp.swift:7861), so even the state word is
  about Array's own bookkeeping rather than the agent's work.

### Declared fence deviation

The plan's fence did not include `AgentInboxView.swift`. Witnessing the provider mark
requires four QA-only additions there, declared here per §7.1:

1. `AgentInboxRowCell.qaProviderGlyph` (protocol requirement);
2. `AgentInboxCellView.qaProviderGlyph` — reads `providerGlyphLabel`;
3. `AgentInboxSlimCellView.qaProviderGlyph` — `""`, because a slim row draws no
   provider mark (its one glyph is the status glyph);
4. `AgentInboxView.providerGlyphsForQA`.

Why it is necessary rather than convenient: the card cell's existing `qaGlyph`
deliberately returns `""` (it means the STATUS glyph, and a card carries state as a
word), and the provider diamond lives on `providerGlyphLabel`, which had no accessor
at all. The alternative — asserting on `AgentProviderGlyph.glyph(for:)` — would
re-derive what production derives and would stay green if the row painted something
else entirely. No behaviour changed; no existing accessor changed meaning.

## P0.1 — GREEN — 2026-08-14

`.build/debug/Array --sidebar-production-corpus-check`, **exit 0**:

```
SidebarProductionCorpus checks passed: 26 production flows drove real writers and were
read off rendered cells, 26 inventory rows in two-way parity
```

Focused legs re-run after the change, all still green: `--sidebar-ux-check`,
`swift run ContinuumRevivedAgentUIChecks` (including the queue-94
`SidebarDefectCorpus` gate), `--agent-inbox-check`. `git diff` shows **no change** to
`ComponentLab.swift`, so the queue-94 marker region and its text-scanning gate are
untouched.

The observed rows are tabulated in `P0.1-fixture-inventory.md`. The product facts they
establish, each from a rendered cell rather than a fixture:

1. **The row carries two facts and a glyph.** Of six painted bands, `meta` and `branch`
   are empty in **every one of 26 flows**, and the placement band never holds more than a
   project name. "Too sparse" is now a measurement.
2. **`Project › Zone` never renders.** Not even for `exactPlacement`, whose tile really is
   on the project canvas and geometrically inside the zone (`SidebarTree.tiles(for:)`
   assigns by tile centre). The Zone half of §4.3's first line does not exist today.
3. **The placement band is the FIRST casualty of width.** `firstSendTitleFallback`,
   `generatedTitleLanded` and `longUnicodeRTL` render no project at all — all three are
   the long-title rows, and the measured-fit tier (`tier.drawsProject`) drops placement at
   the DEFAULT 280 pt width. §4.3 puts placement fourth in the sacrifice order and
   requires it to survive in tooltip/AX.
4. **Three of five terminal outcomes render no state at all.** `succeeded`, `interrupted`
   and `cancelled` all paint `state=''`; `failed` and `runtimeError` both paint `Failed`.
   Success, interruption and cancellation are pixel-identical.
5. **No row anywhere carries a completion time.**
6. **Approval and input are the same word** (`Needs attention`).
7. **Provider identity is one of three Unicode glyphs** — `◈` / `✦` / `◇` — with no model
   text; the unknown-provider arm is the bare diamond the owner rejected.
8. **A blank ⌘K is durable work** (`New agent` / `Unconfirmed` / `array-scratch` / three
   empty bands — the owner screenshot verbatim), and an accepted image-only send keeps the
   sentinel.

### A wrong claim caught before it was published

The first version of the inventory recorded `meta` as the placement band and therefore
asserted "placement is empty in every flow". That was **false**: `metaLabel` composes
isolation and child rollup, while placement is a separate `projectLabel` that had no QA
accessor at all, so it was never observed. Adding `qaProject` showed every row painting
`array-scratch` — which is what the owner screenshot shows, and a materially different
finding from "empty". The inventory now names all six bands and what each composes. The
lesson is the design's own: a band you have not read is not a band you know.

### Two harness defects found and fixed before they could produce false evidence

Recorded because each would have made a green run mean nothing:

1. **Index-paired observation.** The first version zipped `rowIdsForQA` (the whole row
   model) against `titlesForQA` (only MATERIALIZED cells). Once rows outnumbered the
   viewport those lists had different lengths, so it attributed one agent's paint to
   another agent's id. Now every fact is read off one cell, keyed by that cell's own
   `qaAgentID`.
2. **Vacuous rendering.** Observing through the sidebar's own table returned **zero**
   cells for 23 of 24 flows while the table reported 24 rows — the shipped push is
   incremental and, as `AgentInboxView.rebuildRowsForQA`'s own comment records, an
   offscreen window defers that reload indefinitely. Rows are now rendered for
   observation in a sized, frame-pinned `AgentInboxView` (the arrangement
   `--sidebar-ux-check` already relies on). The VALUES are still production's, read back
   via `qaAllRowsForQA`; only the reload strategy and viewport belong to the probe.

### A product behaviour confirmed as correct, not a defect

`claudeAnthropic` and `unknownProvider` initially rendered the sentinel title after a
send. That looked like a naming defect; it was `sendPrepared` **correctly refusing**
(`IntentRefusal.invalidAttachment`) a model that does not belong to the harness's own
catalogue — AGENTS.md non-negotiable #5, exact model ids and no cross-CLI fallback.
Those flows now spawn and `rename` instead, so they isolate provider identity from send
admission. `FlowResult.acceptance` exists so a future refusal can never again be
mistaken for a row defect.

### Additional declared fence deviations (QA-only, no behaviour change)

Beyond the four provider-glyph accessors above, two more additions to
`AgentInboxView.swift`, both forced by the vacuity defect:

5. `qaAllRowsForQA` — the rows the last production push handed the view, so the corpus
   can render exactly those values.
6. `fullReloadForQA()` and `qaTableGeometryForQA` — the second was the diagnostic that
   located the deferred-reload defect (table reporting 24 rows, 1 column, a 548 pt
   visible rect, and zero built cells). `fullReloadForQA` is retained as the documented
   escape from the incremental path.

### Not yet covered

Five §6/P0.1 shapes remain, listed at the foot of the inventory rather than quietly
omitted: `restoredPendingRequest` (needs a relaunch world), `exactPlacement` /
`ambiguousPlacement` (needs real canvas tiles — also the only way `meta` becomes
non-empty), `piAnthropic` / `piOpenAI`, a dedicated `unconfirmed` flow, and
`fiftyActiveWithHistory`. The packet is not done until these exist.

---

Also required, and declared: `AppDelegate.makeSidebarCorpusWorld(now:)` lives in
`ContinuumApp.swift` rather than beside the corpus, because the wiring it performs
touches `private` members of `AppDelegate` (Swift grants that only to same-file
extensions) and `configureWorkspaceSidebar`'s declaration is pinned verbatim by a
program source-scan at ContinuumApp.swift:26751 — widening it would break that gate.
Every flow, expectation, and the inventory gate stay in
`SidebarProductionCorpus.swift`.
