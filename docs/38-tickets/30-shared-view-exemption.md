# Deliberate shared-view exemption

**Area:** De-mirror — Phase 2
**Depends on:** No-mirror real-path check (ticket 29), Capture tmuxWindowTarget at spawn (ticket 16)
**Execution mode:** Autonomous (logic + pure real-path helper); the live-daemon proof it extends is needs-substrate and owned by ticket 29
**Grounding:** `docs/38-locked-decisions.md` (D20 — "two tiles viewing the same window: allowed, as a deliberate shared view"; D19 — grouped view sessions; D25 — bind via `tmuxWindowTarget`)

---

## What this delivers

After this ticket, the system can distinguish between two tiles that accidentally land on the same tmux window — the bug the no-mirror invariant exists to prevent — and two tiles that deliberately share a window because the user pointed them there on purpose. The accidental case is still prohibited; the deliberate case is explicitly blessed and remains stable across restarts.

From the user's perspective: it is possible to have two canvas tiles rendering the same terminal session window — like two macOS windows showing the same document — and the system treats this as a feature, not a malfunction. The tiles show identical content (one pty, one process, one scrollback), and neither the invariant check nor any future automated tooling flags the pair as an error or tries to "resolve" the collision. Resize events from both tiles reach the surface; the last writer wins, which is the correct behavior for a shared view.

From the system's perspective: the no-mirror check (the I2 check block built by ticket 29) gets a clean exemption path. Rather than weakening the invariant by silently ignoring same-window pairs, we model the exemption explicitly — a boolean field on `TerminalSessionDescriptor` that marks the tile as a voluntary shared-view participant. The check's already-existing exemption parameter reads this field, and any pair where both tiles carry it is treated as a deliberate shared view rather than a violation. The default for every newly spawned tile is `false`, so the default-spawn path is unchanged and the no-mirror invariant is as strict as ever for the common case.

---

## How it fits

This ticket is the final piece of Phase 2 (de-mirror). The grouped-view-session work (ticket 27) established the `continuum-view-<tileId>` grouped session that pins each tile to a window via `select-window`. Ticket 16 captured and persisted each tile's `tmuxWindowTarget` (`%pane_id`) at spawn — the field the exemption logic pairs on. Ticket 29 (the no-mirror real-path check) built the I2 check block: a pure exemption function `i2Holds(activeA:activeB:isSharedView:)` plus a live-tmux `do { … }` block that reads back each view session's active window and asserts distinctness. **This ticket builds one layer above those three.** It does not invent the I2 check, the `tmuxWindowTarget` field, or the grouped-session mechanism — those already exist by the time it runs. It supplies the one missing piece: a persisted, per-tile flag that lets the exemption fire for a *deliberate* pair and not for an accidental one.

Two hard, real dependencies — both already ticketed, so there is nothing to guess about who owns each seam:

- **`tmuxWindowTarget` does not exist in the current tree.** It is added to `TerminalSessionDescriptor` by ticket 16 ("Capture tmuxWindowTarget at spawn"), as `public var tmuxWindowTarget: String?` placed after `scrollback`, with a `CodingKeys` entry, a `decodeIfPresent` decode, and a bump of `currentSchemaVersion` from 2 to 3. This ticket adds `isSharedView` **immediately alongside** that field, using the identical pattern. If ticket 16 has not landed, stop: this ticket has no field to pair on and must not add `tmuxWindowTarget` itself (that is 16's scope, and duplicating it would produce two conflicting schema bumps).
- **The I2 check does not exist in the current tree.** The check harness scaffolding (`InvariantManifest`, `JSONValue`, `InvariantOutcome`, `writeAndVerify`) is built by ticket 13. The real I2 check — the pure `i2Holds(activeA: String, activeB: String, isSharedView: Bool) -> Bool` function, its three pure logic assertions, the `NoMirrorCheckManifest` Codable struct, and the live-daemon `// MARK: - I2 No-mirror real-path check` block — is built by ticket 29. This ticket **extends ticket 29's block and function**; it does not create them. If ticket 29 has not landed, stop: there is no I2 block to extend, and scaffolding one is 29's scope, not this ticket's.

Nothing downstream depends on this ticket except conceptually: any future "open this tile alongside the focused tile" gesture that a user might trigger to compare two agent outputs side-by-side will use the `isSharedView` flag this ticket introduces. That gesture is not built here.

---

## The approach

The exemption is modeled as a single boolean field, `isSharedView: Bool`, added to `TerminalSessionDescriptor` in `ContinuumRevivedCore`, **directly after the `tmuxWindowTarget` field that ticket 16 added**. It is `false` by default and is persisted as part of the existing `Codable` implementation via `decodeIfPresent` — so existing session files (which have no `isSharedView` key) decode cleanly with the correct default. No schema bump is needed beyond the one ticket 16 already made: a missing key is handled by `decodeIfPresent`, exactly as `scrollback` and `tmuxWindowTarget` are.

The field is deliberately not on `AgentDescriptor` or any other sub-type — it describes the tile's view-binding intent, which is a property of how the tile is attached to the session topology, not anything about the agent running inside it. It lives at the top level of the descriptor, next to `tmuxWindowTarget`, because the two are read together: a shared-view pair is exactly two live descriptors with the *same* `tmuxWindowTarget` that *both* carry `isSharedView == true`.

The I2 check that ticket 29 built already takes an `isSharedView` boolean as the third parameter of its pure `i2Holds(activeA:activeB:isSharedView:)` function; ticket 29 exercises it with literal booleans in its three logic cases. This ticket does two things to that check:

1. **Wire the flag into the pairing decision.** Add a small pure helper that, given two live descriptors that share a `tmuxWindowTarget`, decides whether the pair is (a) a deliberate shared view (both flags true → exempt), (b) a one-sided flag (exactly one true → a distinct bug category), or (c) an accidental mirror (neither true → the I2 violation). This helper is the descriptor-level companion to `i2Holds`, which operates on already-read window ids. Both are pure and testable without a daemon.

2. **Add three new logic assertions and two new manifest fields** to the I2 block, covering deliberate-pair, one-sided, and default-spawn cases (see "How we test it").

The one-sided case is called out explicitly because it is a real, distinct failure mode: if only one of the two tiles in a same-window pair carries the flag, the check still fails — a one-sided flag is a sign of a bug (a tile that was marked shared but whose partner was not, perhaps after a partial state write), not a legitimate shared view. Both tiles in a shared pair must agree.

The implementation has three parts, all small:

**Part 1 — Add `isSharedView` to `TerminalSessionDescriptor`.** One new `Bool` property with a default of `false`, placed directly after `tmuxWindowTarget`. Add it to the memberwise initializer with a default argument so no existing call site needs updating. Add it to `CodingKeys` and decode with `decodeIfPresent` so old session files remain readable.

**Part 2 — Extend the I2 block in `ContinuumRevivedCoreChecks/main.swift`.** Add a pure descriptor-level exemption classifier alongside ticket 29's `i2Holds`, add three new logic assertions (deliberate pair passes, one-sided fails, default-spawn still fails), and extend the existing `NoMirrorCheckManifest` with counted fields recording each category. Do not create a new manifest type; extend 29's.

**Part 3 — Confirm `restoredForBoot()` passes `isSharedView` through unchanged.** `TerminalSessionDescriptor.restoredForBoot()` copies `self` and only resets `agentDescriptor`; `isSharedView` therefore survives the round-trip untouched. Add an assertion confirming a descriptor with `isSharedView: true` still carries it after `restoredForBoot()`, and a one-line comment at the `restoredForBoot()` site making the pass-through explicit. No behavior change.

There is no UI surface in this ticket. The mechanism by which a user would mark two tiles as a shared pair deliberately is a future gesture that lives in a later ticket. This ticket purely establishes the model field and the exemption contract so future work has a clean seam to write to.

---

## Where it lives

**Primary seam — `TerminalSessionDescriptor` (the model):**

`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`

The file today (before ticket 16 lands) declares, in order: `schemaVersion`, `id`, `tileId`, `launchProfileId`, `command`, `args`, `cwd`, `env`, `title`, `createdAt`, `lastStartedAt`, `lastExit`, `agentDescriptor`, `scrollback`. There is **no** window-target field and **no** other binding property yet — those arrive with ticket 16. Do not describe or assume a binding-property cluster that is not there.

After ticket 16 lands, the file additionally declares `public var tmuxWindowTarget: String?` right after `scrollback` (see ticket 16's "Where it lives"), and `currentSchemaVersion` is `3`. This ticket edits that post-16 file:

- **The new field.** Add `public var isSharedView: Bool` **immediately after `tmuxWindowTarget`** (i.e. after `scrollback` + `tmuxWindowTarget`, as the last stored property). It is the descriptor's second view-binding property, sitting next to the target it pairs on.
- **The initializer.** Add `isSharedView: Bool = false` as a new trailing parameter after `tmuxWindowTarget: String? = nil` in the memberwise `init`, and store `self.isSharedView = isSharedView`. Because the parameter has a default, no existing call site changes.
- **`CodingKeys`.** Add `.isSharedView` to the `CodingKeys` enum (which today ends `…, agentDescriptor, scrollback` and, post-16, `…, scrollback, tmuxWindowTarget`).
- **`init(from decoder:)`.** Add `isSharedView = try container.decodeIfPresent(Bool.self, forKey: .isSharedView) ?? false`, matching the exact pattern already used for `scrollback`, `lastExit`, and (post-16) `tmuxWindowTarget`.
- **`restoredForBoot()`.** Confirm it copies `isSharedView` through unchanged. It already does implicitly — `restoredForBoot()` starts with `var restored = self` and only reassigns `agentDescriptor` — so no code change is required beyond one clarifying comment noting that `isSharedView` (like `tmuxWindowTarget`) survives the copy.
- **No schema bump here.** `currentSchemaVersion` stays at whatever ticket 16 set it to (3). A missing `isSharedView` key is handled by `decodeIfPresent`, so an added optional-with-default does not require a version change (the same reason `scrollback` did not force one for its own addition).

**Primary seam — the I2 check block (built by ticket 29):**

`Sources/ContinuumRevivedCoreChecks/main.swift`

Ticket 29 introduces the I2 check in this file: a `// MARK: - I2 No-mirror real-path check` block, a pure function `func i2Holds(activeA: String, activeB: String, isSharedView: Bool) -> Bool`, three pure logic assertions, and a `NoMirrorCheckManifest` Codable struct. **Locate ticket 29's work by searching for `i2Holds` and `NoMirrorCheckManifest` — those are the real symbols in the tree after 29 lands** (not "the invariant spine harness" and not a `// I2 — No-mirror` comment; those strings do not exist). This ticket appends to that block and extends that struct. It does **not** introduce `SnapshotStub`, `makeDescriptor`, `SessionTopologySnapshot`, `snapshot.tiles`, or `isTombstoned` — none of those symbols exist in the codebase or in tickets 13/16/29, and this ticket does not create them.

**Supporting seam (read-only, confirmed unchanged):**

`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`

`GhosttyTerminalView` creates one `ghostty_surface_t` per view and does not read the descriptor's binding fields — it receives a `LaunchProfile` and runs. A shared view means two separate `GhosttyTerminalView` instances each attach to the same underlying pty via the grouped tmux session mechanism; libghostty handles the multi-client case at the surface level. No changes are needed here. This file is named only so the implementer can confirm, during implementation, that nothing in surface creation or resize would misbehave when two surfaces share a pty (see "Watch out for"). Treat the exact line numbers as approximate and confirm by reading the file — do not edit it.

---

## Implementation breadcrumbs

**The descriptor change** (shown against the post-ticket-16 file, where `tmuxWindowTarget` already exists):

```swift
// TerminalSessionDescriptor.swift

public struct TerminalSessionDescriptor: Codable, Equatable, Sendable {
    // ... existing fields ...
    public var scrollback: String?
    public var tmuxWindowTarget: String?   // added by ticket 16
    /// True when this tile deliberately shares its tmuxWindowTarget with another
    /// tile. Exempt from the no-mirror invariant only when BOTH tiles in the pair
    /// carry this flag. Defaults to false — every spawned tile is distinct unless
    /// the user explicitly opts into shared-view. Persisted; survives restarts.
    public var isSharedView: Bool

    public init(
        // ... existing params ...
        scrollback: String? = nil,
        tmuxWindowTarget: String? = nil,   // added by ticket 16
        isSharedView: Bool = false
    ) {
        // ...
        self.tmuxWindowTarget = tmuxWindowTarget
        self.isSharedView = isSharedView
    }

    // CodingKeys: add .isSharedView (after .tmuxWindowTarget)
    // init(from decoder:):
    //   isSharedView = try container.decodeIfPresent(Bool.self, forKey: .isSharedView) ?? false
    // restoredForBoot(): `var restored = self` already carries isSharedView through unchanged.
}
```

**The exemption classifier — a pure descriptor-level helper added next to ticket 29's `i2Holds`:**

```swift
// In ContinuumRevivedCoreChecks/main.swift, in/near the I2 check block that ticket 29 built.
// This is the descriptor-level companion to ticket 29's
//   func i2Holds(activeA: String, activeB: String, isSharedView: Bool) -> Bool
// i2Holds decides on already-read window ids; this classifies a descriptor pair.

enum SharedViewVerdict {
    case exemptDeliberatePair   // both flags true — a blessed shared view, not a violation
    case oneSidedFlag           // exactly one flag true — a distinct bug category
    case accidentalMirror       // neither flag true — the classic I2 violation
    case notSameWindow          // different (or nil) targets — not a pair at all
}

func classifySharedView(_ a: TerminalSessionDescriptor,
                        _ b: TerminalSessionDescriptor) -> SharedViewVerdict {
    guard let ta = a.tmuxWindowTarget, let tb = b.tmuxWindowTarget, ta == tb else {
        return .notSameWindow
    }
    switch (a.isSharedView, b.isSharedView) {
    case (true, true):   return .exemptDeliberatePair
    case (false, false): return .accidentalMirror
    default:             return .oneSidedFlag
    }
}
```

**The three new logic assertions** (added to ticket 29's pure-logic suite, using the real `expect(...)` helper already in the file — no `SnapshotStub`, no `makeDescriptor`):

```swift
// Build three same-window descriptor pairs with a shared %pane_id and vary the flags.
// makeI2FixtureDescriptor is a tiny local factory this ticket defines in the block; it
// is NOT the fictional `makeDescriptor(tileId:windowTarget:isSharedView:)` — define it
// here explicitly so the block is self-contained.
func makeI2FixtureDescriptor(target: String, shared: Bool) -> TerminalSessionDescriptor {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return TerminalSessionDescriptor(
        id: UUID(), tileId: UUID(),
        launchProfileId: "default", command: "/bin/zsh", args: [],
        cwd: "/tmp/i2-shared", env: [:], title: "i2 fixture",
        createdAt: now, lastStartedAt: now, lastExit: nil,
        agentDescriptor: nil, scrollback: nil,
        tmuxWindowTarget: target, isSharedView: shared
    )
}

let target = "%42"

// 1. Deliberate pair — both opt in → exempt, not a violation.
let pairBoth = classifySharedView(
    makeI2FixtureDescriptor(target: target, shared: true),
    makeI2FixtureDescriptor(target: target, shared: true))
expect(pairBoth == .exemptDeliberatePair,
    "I2: two tiles on one window that both opt in are a deliberate shared view, not a mirror")
// Cross-check against ticket 29's window-id function: same window + shared flag = holds.
expect(i2Holds(activeA: "@7", activeB: "@7", isSharedView: true),
    "I2: i2Holds accepts identical windows when the pair is a deliberate shared view")

// 2. One-sided flag — exactly one opts in → its own bug category, still fails.
let pairOneSided = classifySharedView(
    makeI2FixtureDescriptor(target: target, shared: true),
    makeI2FixtureDescriptor(target: target, shared: false))
expect(pairOneSided == .oneSidedFlag,
    "I2: a one-sided isSharedView flag is a distinct bug, never folded into the mirror bucket")

// 3. Default spawn — neither opts in → still an accidental mirror (invariant not weakened).
let pairNeither = classifySharedView(
    makeI2FixtureDescriptor(target: target, shared: false),
    makeI2FixtureDescriptor(target: target, shared: false))
expect(pairNeither == .accidentalMirror,
    "I2: two default (non-shared) tiles on one window are still an accidental mirror")
expect(!i2Holds(activeA: "@7", activeB: "@7", isSharedView: false),
    "I2: i2Holds still rejects identical windows for a non-exempt pair")
```

**The manifest extension** — extend ticket 29's `NoMirrorCheckManifest` with counted `Int` fields. Do not use tuple-typed stored properties: Swift tuples are not `Codable`, so a `[(UUID, UUID)]` property will not compile. Record counts (and, if a pair listing is wanted, a small `Codable` `TilePair` struct — never a tuple):

```swift
// Extend the existing NoMirrorCheckManifest (from ticket 29) — do not define a new type.
// New fields, all Codable-legal Ints (and an optional Codable pair struct):
struct TilePair: Codable { var a: String; var b: String }   // tileId strings, NOT a tuple

// added to NoMirrorCheckManifest:
//   var deliberateSharedViewExemptions: Int   // fixture: 1
//   var oneSidedFlagViolations: Int           // fixture: 1
//   var accidentalMirrorViolations: Int       // fixture: 1 (default-spawn negative case)
//   var exemptedPairs: [TilePair]             // Codable; empty in a normal production run
```

---

## How we test it

### Logic — pure Core checks

Three new assertions run inside `ContinuumRevivedCoreChecks`, in ticket 29's I2 block, using the real `expect(...)` helper and the `classifySharedView` / `i2Holds` pure functions — no daemon, no real tmux, no `SnapshotStub`:

1. **Default-spawn is still blocked.** Two descriptors with the same `tmuxWindowTarget` and both `isSharedView == false` classify as `.accidentalMirror`, and `i2Holds(activeA:activeB:isSharedView: false)` returns `false` for identical windows. The manifest records `accidentalMirrorViolations: 1`.

2. **Deliberate pair — both opt in.** Two descriptors with the same target and both `isSharedView == true` classify as `.exemptDeliberatePair`, and `i2Holds(..., isSharedView: true)` returns `true` for identical windows. The manifest records `deliberateSharedViewExemptions: 1` and names the exempted pair by `tileId` string in `exemptedPairs`.

3. **One-sided flag.** One descriptor `isSharedView == true`, its partner `false`, same target → classifies as `.oneSidedFlag` — not a mirror violation but a distinct category, recorded separately so implementers know exactly what broke. The manifest records `oneSidedFlagViolations: 1`.

Additionally, a round-trip check confirms a descriptor with `isSharedView: true` serializes and deserializes correctly, and that a descriptor whose JSON has no `isSharedView` key (a legacy session file) decodes with `isSharedView == false`, and that a descriptor whose JSON has `"isSharedView": null` also decodes with `false` (the `decodeIfPresent ?? false` path). These reuse the exact JSON round-trip pattern already present in this file (see the I7 block from ticket 13 for the encode/decode idiom). The manifest records `roundTripPreservesTrue: true`, `legacyKeyMissingDefaultsFalse: true`, and `nullValueDefaultsFalse: true`.

### Backend — real-path integration (owned and gated by ticket 29)

There is no separate "needs-substrate SessionTopologySnapshot" tier for this ticket — that type and tier do not exist. The real-path proof is **ticket 29's live-daemon block**, which already spawns a real project session, attaches two grouped view sessions via `ProcessTmuxControl`, pins them with `select-window`, reads back each active window with `tmux display`, and exercises a deliberate shared-view session pointed at the same window as tile A. That block already asserts `sharedViewExemptionCorrect: true` for the intentional-mirror case.

What this ticket contributes to the backend proof is verification that the *descriptor flag* drives that acceptance, not an incidental tautology. Concretely: in ticket 29's real-path block, when the two default (non-shared) view sessions are read back with distinct windows, assert `classifySharedView` over the two real descriptors (both `isSharedView == false`, distinct `tmuxWindowTarget`) returns `.notSameWindow` and the manifest shows `accidentalMirrorViolations: 0` — confirming the exemption path does not fire for normal tiles. This runs only where tmux is present; on a host without tmux it skips exactly as ticket 29's block does (recorded as `tmux_absent: true`), and the skip is not counted as a pass. No new daemon behavior is introduced by this ticket — it extends assertions inside an existing needs-substrate block.

### UX — visual gate and dogfood snippet

Because this ticket adds no user-visible UI, the visual gate is a behavioral observation in the running app using a manually-crafted shared-view scenario; it reuses the two-tile Component Lab fixture that ticket 29 added rather than building a new one.

**Dogfood snippet:** Open the app. In any project zone, spawn one terminal tile running a long-lived process (`watch date`). Find that tile's `tileId` and its captured `tmuxWindowTarget` in the debug inspector (Settings → Debug → Show tile IDs, or the affordance inspector in the Component Lab). Then, at a breakpoint on `TerminalSessionDescriptor.init` (or in the Xcode debugger), construct a second descriptor for the *same* `tmuxWindowTarget` with `isSharedView: true`, and run the I2 logic over the pair. Expected: `classifySharedView` returns `.exemptDeliberatePair`, and the check output (run `ContinuumRevivedCoreChecks` with the shared-view fixtures) shows `"deliberateSharedViewExemptions": 1, "accidentalMirrorViolations": 0`. If it instead shows `accidentalMirrorViolations: 1`, the exemption did not apply — the flag is not being read on the pairing path. If it shows `oneSidedFlagViolations: 1`, only one of the two descriptors carries the flag.

---

## Execution mode

**Autonomous for everything this ticket adds.** The `TerminalSessionDescriptor` change is a pure value-type addition (`Bool` with a default, `decodeIfPresent`) with no runtime behavior. The `classifySharedView` classifier and the three logic assertions are deterministic pure functions over synthetic descriptors — no tmux daemon, no ghostty surface, no real filesystem beyond the temp-dir manifest write the harness already does. The full matrix — new field decodes correctly for old files (missing key and `null`), the exemption fires only for mutual opt-in, the one-sided case is caught as a distinct category, the default-spawn case still fails — is provable without human eyes.

The one part that touches a real daemon is the *extension of ticket 29's real-path block*, which is **needs-substrate** — but that tier already exists and is owned by ticket 29; this ticket only adds assertions inside it and inherits its skip-when-tmux-absent behavior. This ticket introduces no new needs-substrate infrastructure of its own.

---

## Done when

- [ ] `TerminalSessionDescriptor` in `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` has a new `isSharedView: Bool` field defaulting to `false`, placed immediately after `tmuxWindowTarget` (added by ticket 16), with a `CodingKeys` entry, `decodeIfPresent(Bool.self, …) ?? false` in the custom decoder, and a default argument in the memberwise initializer — all existing call sites still compiling unchanged. No new `currentSchemaVersion` bump beyond ticket 16's.
- [ ] A session-file JSON with no `isSharedView` key decodes with `isSharedView == false`; one with `"isSharedView": true` decodes `true`; one with `"isSharedView": null` decodes `false`. All three asserted in the check manifest as `legacyKeyMissingDefaultsFalse: true`, `roundTripPreservesTrue: true`, `nullValueDefaultsFalse: true`.
- [ ] The I2 block in `ContinuumRevivedCoreChecks/main.swift` (the one built by ticket 29, locatable via `i2Holds` / `NoMirrorCheckManifest`) gains a pure `classifySharedView(_:_:)` helper that distinguishes `.accidentalMirror`, `.oneSidedFlag`, `.exemptDeliberatePair`, and `.notSameWindow`, plus three new `expect(...)` assertions covering those first three cases.
- [ ] The deliberate-pair fixture (both `isSharedView: true`, same target) yields `deliberateSharedViewExemptions: 1`, `oneSidedFlagViolations: 0`, `accidentalMirrorViolations: 0` in the manifest, and `i2Holds(activeA:activeB:isSharedView: true)` returns `true` for identical windows.
- [ ] The one-sided fixture (one `true`, one `false`, same target) yields `oneSidedFlagViolations: 1` and `deliberateSharedViewExemptions: 0`.
- [ ] The default-spawn negative fixture (both `false`, same target) yields `accidentalMirrorViolations: 1`, confirming the invariant is not weakened for ordinary tiles.
- [ ] The extended `NoMirrorCheckManifest` uses only `Codable`-legal fields (Ints and, if pairs are listed, a `Codable` `TilePair` struct) — **no tuple-typed stored properties** (`[(UUID, UUID)]` would not compile).
- [ ] `restoredForBoot()` on a descriptor with `isSharedView: true` returns a descriptor still carrying `isSharedView: true` — confirmed by a check assertion and a clarifying comment at the `restoredForBoot()` site.
- [ ] No existing call site for `TerminalSessionDescriptor.init(...)` requires modification (the new parameter has a default).
- [ ] A grep confirms `isSharedView` is never set to `true` in any production spawn path — only in check fixtures. The default spawn stays `false` throughout.
- [ ] `swift build` succeeds with no new warnings; `.build/debug/ContinuumRevivedCoreChecks` exits with code 0.

---

## Depends on / unblocks

**Depends on (both hard, both already ticketed):**

- **Ticket 16 — Capture tmuxWindowTarget at spawn.** Adds `tmuxWindowTarget: String?` to the descriptor (after `scrollback`, `decodeIfPresent`, schema bump 2→3). This ticket adds `isSharedView` alongside it and pairs on it. Building `isSharedView` first would leave nothing to pair on and risk a duplicate schema bump.
- **Ticket 29 — No-mirror real-path check (I2).** Builds the I2 check block: the pure `i2Holds(activeA:activeB:isSharedView:)` function, its logic assertions, the live-daemon block, and `NoMirrorCheckManifest`. This ticket extends that block and struct. Building the exemption before the check exists would be extending code that does not compile yet. (Ticket 29 in turn rests on ticket 13's harness scaffolding and ticket 27's grouped-session helpers.)

**Unblocks:** any future gesture that lets a user deliberately share a tile's view — "open alongside," "mirror to second display," or a compare-pane interaction. That gesture needs a persisted model field to write to; this ticket provides it. It also completes Phase 2 (de-mirror), making it safe to begin Phase 3 (agent-awareness readers) with no open view-binding correctness question.

---

## Watch out for

**The one-sided flag is a distinct failure mode, not a mirror.** Resist folding the one-sided case into the mirror bucket. They mean different things: a mirror means neither tile opted in (a spawn bug); a one-sided flag means state diverged after opt-in (a persistence bug or a race during close). `classifySharedView` keeps them as separate enum cases and the manifest keeps their counts separate so debugging is unambiguous. If a future change conflates them, the manifest becomes misleading.

**`decodeIfPresent` with a `Bool` has a subtle trap.** A missing `Bool` key with `decode(Bool.self, …)` throws `keyNotFound`; `decodeIfPresent(Bool.self, …) ?? false` returns `false` for a *missing* key and also `false` for a key whose JSON value is `null` (`decodeIfPresent` yields `nil`, which falls through `?? false`). This is the correct behavior — a `null` is treated the same as a missing key — but confirm it with the explicit `"isSharedView": null` fixture required in "Done when."

**`tmuxWindowTarget` must exist before this ticket runs.** If you find no `tmuxWindowTarget` field on the descriptor and no `i2Holds` / `NoMirrorCheckManifest` in `main.swift`, tickets 16 and/or 29 have not landed. Do not add `tmuxWindowTarget` yourself and do not scaffold the I2 check — those are 16's and 29's scope, and duplicating them causes conflicting schema bumps and duplicate check blocks. Stop and let the prerequisites land first.

**Do not invent `SnapshotStub` / `makeDescriptor` / `SessionTopologySnapshot` / `isTombstoned`.** None of these exist in the codebase or in tickets 13/16/29. The real seam is descriptor pairs classified by the pure `classifySharedView` and window-id pairs decided by ticket 29's `i2Holds`; construct fixtures with the descriptor's own initializer (a small local `makeI2FixtureDescriptor` factory defined in the block), not a fictional snapshot type.

**`GhosttyTerminalView` resize behavior under shared view.** When two surfaces share a pty, each independently sets its surface pixel size on resize; libghostty processes both and the last writer wins, so the pty grid resizes to the most recently focused tile's dimensions. This is correct and intentional (it mirrors resizing either of two OS windows on one document). If the tiles differ in size, the pty resizes as focus alternates — acceptable. Confirm during implementation that the surface-size path already deduplicates same-size calls (so two identically-sized tiles do not double-fire); this is a verification step only, no code change. Read the file to find the current method and line — do not trust a hardcoded line number.

**Do not set `isSharedView` on the tmux view-session name or any tmux command.** The `continuum-view-<tileId>` grouped session is named by `tileId` alone (D19). Two tiles that share a view are still two separate view sessions, both grouped onto the same project session, both pinned by `select-window` to the same window target. The `isSharedView` flag lives only on the descriptor and only feeds the check's pairing decision; it never changes a tmux command sequence. If you see any code that reads `isSharedView` to alter a tmux call, that is a bug.

**Stop conditions.** Do not mark this ticket done if: (1) any existing `TerminalSessionDescriptor.init` call site was changed to pass `isSharedView` explicitly (the default must cover all existing sites); (2) the deliberate-pair fixture shows `accidentalMirrorViolations > 0` (the exemption is not firing); (3) the one-sided fixture shows `oneSidedFlagViolations: 0` (the one-sided detection is not firing); (4) `isSharedView: true` appears anywhere in production spawn code rather than only in check fixtures; (5) the manifest uses any tuple-typed stored property (it will not compile).
