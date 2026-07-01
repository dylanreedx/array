# agentKind closed enum

**Area:** Agent awareness — Phase 3 foundation  
**Execution mode:** Autonomous  
**Grounding:** `docs/38-locked-decisions.md` (D14), `docs/2026-06-30-orchestration-spikes/AGENT-READERS.md`

---

## What this delivers

Today `AgentDescriptor.agentKind` is a `String`, which means the Claude reader, the Codex reader, the Pi reader, the tile spawner, the launch-profile registry, the sidebar builder, and the checks file can all silently disagree about what values are legal — and the compiler has nothing to say about it. A tile spawned from a harness role uses its `role.id` as the kind string (`TileSpawner.swift:144`); a launch-profile uses `"claude"` or `"codex"` as a literal (`LaunchProfileRegistry.swift:67,74`); a check uses `"qa-reviewer"` (`ContinuumRevivedCoreChecks/main.swift:1357`). None of these are checked against each other.

This ticket replaces the free string with a proper closed enum — `AgentKind` with cases `shell`, `claude`, `codex`, `pi`, `managed`, and `unknown` — and migrates every current call site to speak the enum. Once it lands, the "which agent is this tile?" contract is exhaustively switchable in Swift, adding a new provider is one enum case plus one reader or adapter, and `unknown` has a first-class home so the under-claiming rule (I6: never fabricate a status you cannot prove) is representable as a type, not a convention.

The system-observable outcome: the sidebar, tile status badges, and the CoreChecks invariant spine all consume an `AgentKind` value, not a string, so a future reader that returns the wrong kind is a compile error rather than a silent mismatch.

---

## How it fits

This ticket stands alone — it has no declared dependency on any in-flight work. It is, however, the foundational type that every agent-awareness ticket above it in the queue will build on. The Claude reader, the Codex reader, and the Pi reader each produce an `AgentSnapshot` (the unified shape proposed in AGENT-READERS) whose first field is `kind: AgentKind`; without this enum in place those readers cannot be written correctly. The `SessionObserver` that drives readers and writes `AgentDescriptor.status` also keys dispatch off `kind` — it is the mechanism by which the observer chooses *which* reader to run for a given pane. The managed-agent tile kind (a later ticket, Group B) also has `.managed` as its declared `AgentKind` value; that enum case is introduced here even though nothing populates it yet.

What this ticket builds on: the existing `AgentStatus` enum (`TerminalSessionDescriptor.swift:85`) shows the correct pattern — a `Codable, Equatable, Sendable` enum with string raw values that survives JSON round-trips through the session store. `AgentKind` follows that pattern exactly. The existing `LaunchProfileSpec.agentKind: String?` field (`LaunchProfileSpec.swift:8`) and `LaunchProfileRegistry`'s built-in specs (`LaunchProfileRegistry.swift:67,74`) are the concrete migration targets alongside `AgentDescriptor` itself.

---

## The approach

There is one right path and no forks to decide. Define `AgentKind` as a `public enum` in `TerminalSessionDescriptor.swift` immediately above the existing `AgentStatus` definition. Give it `String` raw values matching the existing free-string literals (`"shell"`, `"claude"`, `"codex"`, `"pi"`, `"managed"`, `"unknown"`) so that on-disk session documents encoded with the old string field deserialize cleanly into the new type without a schema migration.

Change `AgentDescriptor.agentKind` from `String` to `AgentKind`. Update the designated initializer, the `configuring(agentKind:...)` factory, and `restoredForBoot()` accordingly. Update `LaunchProfileSpec.agentKind` from `String?` to `AgentKind?`. Update the two built-in specs in `LaunchProfileRegistry` to use `.claude` and `.codex`.

The three call sites outside the Core layer that write a kind string also need updating:

- `TileSpawner.spawnHarnessRoleRun` (`TileSpawner.swift:144`) passes `role.id` as the kind string. Harness roles identified as Pi agents use `role.id` values like `"code-reviewer"` and `"explorer"` — these are not valid `AgentKind` cases. The correct mapping is: a harness role always produces a `.pi` tile (Continuum's own harness writes to the Pi run store, per `Sources/ContinuumRevivedCore/HarnessRoleRun.swift:108`). Change this site to pass `.pi` directly.
- `TileSpawner.agentDescriptor(for:projectRoot:at:)` (`TileSpawner.swift:233–235`) reads `spec.agentKind` and passes it through; with the type now `AgentKind?` this site compiles cleanly.
- `ContinuumApp.swift` and `ContinuumRevivedCoreChecks/main.swift` use `AgentDescriptor(agentKind: "claude", ...)` and related patterns throughout — all become `AgentDescriptor(agentKind: .claude, ...)`. The compiler will locate every remaining string literal that is a Swift-source constructor argument after the type change. There is one such site that is **not** a clean one-to-one substitution and must be resolved explicitly rather than guessed — see the next bullet.
- `ContinuumApp.swift:5013` — the nested test-helper `saveSession(_:tileId:status:now:root:)` builds `AgentDescriptor(agentKind: "qa", ...)`. `"qa"` is neither a valid enum case nor the `"qa-reviewer"` string used elsewhere; it is a synthetic fixture kind that never corresponds to a real Claude/Codex/Pi/managed agent. **Change this site to `agentKind: .unknown`** (not `.pi`, not `.claude`). It is a status-propagation fixture whose kind is irrelevant to what it exercises, and `.unknown` is the honest case for a synthetic descriptor with no provable provider (I6). Do not invent a new case for it.

Two literal shapes are **not** Swift constructor arguments and the compiler will therefore **not** flag them — do not "fix" them:

- **Raw-JSON `agentKind` string literals inside test fixtures stay as strings.** `ContinuumRevivedCoreChecks/main.swift:1249` has `"agentKind": "qa-reviewer"` as an entry in a hand-built JSON blob (`legacyAgentJSON`) that the unknown-raw-value decode test decodes into an `AgentDescriptor`. This literal is the input the graceful-decode test relies on: it must remain the string `"qa-reviewer"` so the decoder maps it to `.unknown`. Changing it to a valid case (or to `.unknown` as a symbol — which would be invalid JSON) would destroy the very tripwire this ticket adds. Leave it exactly as-is.

For JSON backward-compatibility: because the raw value strings are identical to the literals already in use, any session file that was encoded before this change decodes to the correct enum case. Files that contain an unrecognized string (e.g. `"qa-reviewer"` from a harness-role session encoded before this change) must not crash — implement a custom `init(from:)` on `AgentKind` that maps unrecognized raw values to `.unknown` rather than throwing. This is the I6 under-claiming floor applied at the decoder level.

The `schemaVersion` on `TerminalSessionDescriptor` stays at 2 (no bump needed — the on-disk field name `agentKind` is unchanged and the raw values are identical).

---

## Where it lives

**Primary definitions — both in `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`:**

- `AgentStatus` enum lives at line 85. Add `AgentKind` immediately above it (before line 85), so the two status-related enums are adjacent and easy to find together.
- `AgentDescriptor.agentKind: String` at line 95 — this is the field that changes type to `AgentKind`.
- `AgentDescriptor.init(agentKind: String, ...)` at line 101 — parameter type changes to `AgentKind`.
- `AgentDescriptor.configuring(agentKind: String, ...)` factory at line 109 — parameter type changes to `AgentKind`.

**Secondary migration targets:**

- `Sources/ContinuumRevivedCore/LaunchProfileSpec.swift:8` — `agentKind: String?` becomes `agentKind: AgentKind?`.
- `Sources/ContinuumRevivedCore/LaunchProfileSpec.swift:10` — matching `init` parameter.
- `Sources/ContinuumRevivedCore/LaunchProfileRegistry.swift:67` — `agentKind: "claude"` becomes `agentKind: .claude`.
- `Sources/ContinuumRevivedCore/LaunchProfileRegistry.swift:74` — `agentKind: "codex"` becomes `agentKind: .codex`.
- `Sources/ContinuumRevived/App/TileSpawner.swift:144` — `agentKind: role.id` becomes `agentKind: .pi`.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — all `AgentDescriptor(agentKind: "<literal>", ...)` call sites; the compiler will surface them all as errors after the type change. Most are `"claude"` → `.claude`. The one exception is the test-helper site at **`ContinuumApp.swift:5013`** (`agentKind: "qa"`), which becomes **`.unknown`** per the resolution stated in "The approach" — do not map it to `.pi` or `.claude`.
- `Sources/ContinuumRevivedCoreChecks/main.swift` — the check at line 1194, 1243, 1357, 2003, and the `LaunchProfileRegistry` assertions at lines 3668–3675 that assert `spec.agentKind == "claude"` / `== "codex"` / `== nil` — these become `== .claude` / `== .codex` / `== nil`. **Leave `main.swift:1249` (`"agentKind": "qa-reviewer"` inside the `legacyAgentJSON` raw-JSON blob) unchanged** — it is the decode-test fixture, not a Swift constructor argument, and must stay a string so the graceful decoder rounds it to `.unknown`.

**No other files need changes.** `AgentStatusEngine.swift` is intentionally untouched — it operates on `AgentStatus`, not `AgentKind`, and that relationship stays unchanged. `SidebarTree.swift`, `WorkspaceSidebarView.swift`, and `SidebarTreeBuilder` do not currently read `agentKind` at all; they consume `AgentStatus` through `agentDescriptor?.status`. The sidebar is not a migration target for this ticket.

---

## Implementation breadcrumbs

```swift
// In TerminalSessionDescriptor.swift, before AgentStatus:

public enum AgentKind: String, Codable, Equatable, Sendable {
    case shell
    case claude
    case codex
    case pi
    case managed
    case unknown

    // Graceful decoding: unrecognized raw values from old session files map to .unknown
    // rather than throwing. This is the I6 under-claiming floor at the decoder layer.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw) ?? .unknown
    }
}

// AgentDescriptor field + initializer:
public struct AgentDescriptor: Codable, Equatable, Sendable {
    public var agentKind: AgentKind   // was: String
    // ...
    public static func configuring(
        agentKind: AgentKind,         // was: String
        worktreePath: String?,
        now: Date,
        runId: String? = nil
    ) -> AgentDescriptor { ... }
}

// LaunchProfileSpec:
public let agentKind: AgentKind?      // was: String?

// LaunchProfileRegistry built-ins:
LaunchProfileSpec(id: "claude", ..., agentKind: .claude)
LaunchProfileSpec(id: "codex",  ..., agentKind: .codex)

// TileSpawner.spawnHarnessRoleRun — harness always means Pi:
agentDescriptor: AgentDescriptor.configuring(agentKind: .pi, worktreePath: projectRoot, now: now, runId: runId)

// ContinuumApp fixture sites — representative pattern:
AgentDescriptor(agentKind: .claude, worktreePath: ..., status: .working, statusUpdatedAt: now)

// CoreChecks assertions — representative pattern:
expect(registry.spec(for: "claude")?.agentKind == .claude, "claude spec carries agent kind")
expect(registry.spec(for: "shell")?.agentKind == nil,      "shell spec is not an agent")
```

The custom `init(from:)` on `AgentKind` is the only non-trivial piece. The default synthesized `Codable` conformance would throw on an unrecognized raw value; this implementation silently rounds down to `.unknown`, which is precisely the I6 under-claiming policy applied at the deserialization boundary.

After the type change, build the project. The compiler will enumerate every remaining `String`-typed **constructor/assignment** call site as an error. Fix them all — remembering that `ContinuumApp.swift:5013` (`"qa"`) resolves to `.unknown`, not a guessed provider case. The one literal the compiler will **not** flag, and which must stay a string, is the raw-JSON `"agentKind": "qa-reviewer"` fixture at `main.swift:1249`; it is data, not code, and is the input to the graceful-decode test.

---

## How we test it

### Logic (pure Core checks)

Add a new check function to `Sources/ContinuumRevivedCoreChecks/main.swift` named `runAgentKindChecks()` and call it from the main check runner.

**Round-trip:** For each of the six cases, encode an `AgentDescriptor` with that `agentKind` to JSON via `JSONEncoder`, decode it back via `JSONDecoder`, and assert the round-tripped value equals the original. This proves the `Codable` conformance is correct and the raw-value strings are stable.

**Unknown-raw-value graceful decode:** Manually construct a JSON blob where `agentKind` is `"qa-reviewer"` (a string that was valid before this ticket, present in real on-disk sessions). Decode it into `AgentDescriptor`. Assert `agentKind == .unknown`. Assert that no error is thrown. This is the backward-compatibility gate: if this test fails, real session files from before this change would be corrupted on load.

**LaunchProfileRegistry kind checks:** Assert `LaunchProfileRegistry().spec(for: "claude")?.agentKind == .claude`, `spec(for: "codex")?.agentKind == .codex`, `spec(for: "shell")?.agentKind == nil`, `spec(for: "nvim")?.agentKind == nil`. These replace the string-equality assertions that existed before the migration and serve as regression guards on the built-in spec table.

**Harness-role kind:** Construct the same `AgentDescriptor` that `TileSpawner.spawnHarnessRoleRun` now produces (kind `.pi`, status `.configuring`) and assert `agentKind == .pi`. This pins the harness-role → Pi mapping so it cannot silently revert to a role-id string.

### Backend (real-path / integration)

The existing `runAgentDescriptorRoundTripCheck()` in `ContinuumRevivedCoreChecks` (at line 1357, which exercises `AgentDescriptor` encode/decode through `RegistryStore.saveSession` / `loadSession`) must pass without modification after the type change. No bypass: the check writes a real session file to a temp directory via the real `RegistryStore` code path and reads it back. The decoded `agentKind` must equal the original enum value. If the raw-value strings changed during this migration, this check would fail — that is the intended tripwire.

Additionally: after the migration, build the project with `swift build` and confirm zero errors and zero warnings related to the changed types. The compiler is the integration harness for call-site completeness.

### UX (visual gate + dogfood snippet)

The sidebar and tile status badges do not directly render `agentKind` today — they render `AgentStatus` — so there is no visible UI change to gate. The UX test is therefore a smoke-check that the existing visual contract is unbroken rather than a new screen.

**Dogfood snippet:** Open Continuum. From the command palette (Cmd-Shift-P → "New Claude Agent"), spawn a Claude agent tile. Observe the sidebar: the row for that tile should show the `○ no agent` status (because no reader is wired yet — the tile is in `.configuring` state). Open the Component Lab (menu bar → Developer → Component Lab) and navigate to the Sidebar fixture. The tile rows labeled "Agent · Claude" and "Agent · Codex" should render their status badges exactly as before this change — working amber, needs-attention orange, done green — with no visual regression. The badge rendering path reads `AgentStatus`, not `AgentKind`, so this confirms the status propagation chain is intact through the type migration.

---

## Execution mode

Autonomous. The entire change is a type substitution in pure Swift with no UI behavior change and no new runtime behavior. Correctness is fully proven by: (a) the compiler — every call site is an error until fixed; (b) the round-trip and unknown-raw-value Logic checks; (c) the existing real-path `RegistryStore` encode/decode check. No human eyes are needed during implementation; the dogfood snippet is a final smoke-check that can be run once at the end and passes trivially if the Logic and Backend gates are green.

---

## Done when

- [ ] `AgentKind` enum exists in `TerminalSessionDescriptor.swift` with cases `shell`, `claude`, `codex`, `pi`, `managed`, `unknown`, `Codable`/`Equatable`/`Sendable`, and a custom `init(from:)` that maps unknown raw values to `.unknown`.
- [ ] `AgentDescriptor.agentKind` is typed `AgentKind`, not `String`. The field name and JSON key (`"agentKind"`) are unchanged.
- [ ] `LaunchProfileSpec.agentKind` is typed `AgentKind?`, not `String?`.
- [ ] `LaunchProfileRegistry` built-in specs use `.claude` and `.codex`, not string literals.
- [ ] `TileSpawner.spawnHarnessRoleRun` passes `.pi` (not `role.id`) as `agentKind`.
- [ ] Zero remaining `agentKind: "<string-literal>"` **Swift constructor** call sites anywhere in `Sources/` (the compiler confirms this). The `"qa"` site at `ContinuumApp.swift:5013` is resolved to `.unknown`.
- [ ] The raw-JSON `"agentKind": "qa-reviewer"` fixture at `ContinuumRevivedCoreChecks/main.swift:1249` is left unchanged as a string (it is the graceful-decode test input, not a code call site).
- [ ] `swift build` completes with zero errors and zero warnings on the changed types.
- [ ] New `runAgentKindChecks()` passes: six-case round-trip, unknown-raw-value graceful decode, LaunchProfileRegistry kind assertions, harness-role kind assertion.
- [ ] Existing `RegistryStore` encode/decode integration check passes without modification.
- [ ] Dogfood smoke-check: Component Lab Sidebar fixture renders status badges identically to before this change.

---

## Depends on / unblocks

This ticket has no declared dependency — it is standalone and can be executed against `main` on any day.

It directly unblocks every agent-awareness reader ticket (Claude reader, Codex reader, Pi reader) because those tickets define `AgentSnapshot.kind: AgentKind` and dispatch in `SessionObserver` switches on `AgentKind`. The managed-agent tile ticket (Group B) also depends on `AgentKind.managed` being a valid, compilable case — that case is introduced here.

---

## Watch out for

**The harness-role → Pi mapping is the single most load-bearing judgment call.** `TileSpawner.spawnHarnessRoleRun` currently passes `role.id` (e.g. `"code-reviewer"`, `"explorer"`) as the kind string. These are not valid `AgentKind` cases and must not become `.unknown` — they are genuinely Pi agents, because Continuum's own harness writes its run artifacts under the Pi directory structure (`<projectRoot>/.pi/agent-runs/<runId>/`, per `Sources/ContinuumRevivedCore/HarnessRoleRun.swift:108`) and the Pi reader is the correct reader for them. The mapping to `.pi` is deliberate and must be preserved. If someone later adds a harness role that is not a Pi agent, they will need to add a new `AgentKind` case and update this site explicitly — which is exactly the point of a closed enum.

**On-disk backward compatibility is the other stop condition.** If the raw values of the enum cases ever diverge from the string literals that existing session files contain, every session decoded after this change will silently produce `.unknown` for every tile's `agentKind`. The unknown-raw-value Logic check is written specifically to catch this, but the implementer must also verify that the six raw value strings (`"shell"`, `"claude"`, `"codex"`, `"pi"`, `"managed"`, `"unknown"`) exactly match what appears in real `.json` session files on disk. Check a real session file in `~/Library/Application Support/Continuum/sessions/` before shipping.

**`schemaVersion` must not be bumped.** The `TerminalSessionDescriptor.currentSchemaVersion` is 2. This change does not alter the on-disk shape — the field name is the same, the raw values are the same — so bumping the version would incorrectly invalidate otherwise-valid session files.
