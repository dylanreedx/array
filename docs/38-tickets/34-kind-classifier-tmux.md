# Kind classifier: foreground command → agentKind

## What this delivers

Every terminal tile in Continuum can now report what kind of agent — or plain shell — is running in its foreground process. Given a tile's tmux window target, the classifier issues a single `tmux display` query through the injectable control, maps the returned `pane_current_command` string to a value in the `AgentKind` closed enum, and writes that value back to `AgentDescriptor.agentKind`. The rest of the system — the per-project observer, the status-derivation function, the sidebar tree, and ultimately the UX — all consume `AgentDescriptor.agentKind`; this ticket is what gives that field real, detected content rather than a placeholder string. Classification runs occasionally (on tile focus, on window-target resolution, and on a low-frequency background poll), never per-tick.

## How it fits

The classifier is the third piece of the agent-awareness base tier, sitting between the two prerequisites it depends on and the reader chain it unblocks. The **"agentKind closed enum"** ticket (`docs/38-tickets/31-agentkind-closed-enum.md`) must exist first, because the classifier's entire job is to produce a value of that type. The **"Injectable substrates: TmuxControl, fake clock, fake host, fake sync transport"** ticket (`docs/38-tickets/12-injectable-substrates.md`) must exist first, because the classifier issues its one query through that protocol and its logic is proven entirely in-memory against the fake. Once the classifier lands, every subsequent reader — the Pi reader, the Claude reader, the Codex reader — can call `detect(processName:)` on the appropriate reader and trust that the `agentKind` on the descriptor is already accurate. The **"SessionObserver: per-project agent detection, reader dispatch, and status budgets"** ticket (`docs/38-tickets/40-session-observer.md`) drives classification as part of its detection loop; this ticket delivers the pure mapping logic that observer will call.

The classifier also establishes the canonical answer to the `node`-ambiguity problem for Codex: when `pane_current_command` is `node`, the classifier returns `.unknown` rather than guessing `.codex`, and the **"Codex reader — recency-plus-cwd linkage with same-cwd under-claim"** ticket (`docs/38-tickets/38-codex-reader.md`) is responsible for confirming or upgrading the kind through its cwd-probe linkage. That boundary is drawn here and must not drift.

This ticket rests on decisions **D14** (`agentKind` is a closed enum, not a free string) and **D10** (Codex `node`-ambiguity: never guess), and on the detection table in `docs/2026-06-30-orchestration-spikes/AGENT-READERS.md` (§Detection).

## The approach

A `KindClassifier` value type in `ContinuumRevivedCore` exposes a single async function:

```swift
func classify(windowTarget: String, using control: any TmuxControl) async throws -> AgentKind
```

Internally it calls `control.paneCurrentCommand(paneTarget: windowTarget)` — a single tmux query returning a string like `"claude"`, `"zsh"`, `"node"` — and runs the resulting string through a pure mapping function `AgentKind.from(processName:)`. The mapping function is a free function (or static method on `AgentKind`) that contains all classification logic and has no side effects, making it the target of every logic check in the suite.

**This ticket owns the `paneCurrentCommand` query seam.** The **"Injectable substrates"** ticket ships a `TmuxControl` protocol whose query surface is `isAlive`, `paneCurrentPath`, and `listSessions` — it does **not** declare `paneCurrentCommand`, and its `InMemoryTmuxControl.PaneStub` carries a `currentCommand: String` field that no protocol method exposes yet. The classifier is the first consumer that needs foreground-command detection, so **this ticket adds one method to the `TmuxControl` protocol and implements it in both fakes and the real control** — see "Extending the TmuxControl seam" below. This is an additive, non-breaking extension (a new protocol requirement plus its three implementations); it does not change any existing `TmuxControl` method or its "Done when" contract. Nothing in this ticket can compile until that method exists, so adding it is in scope here, not a silent edit to another ticket.

The mapping table, derived directly from the verified detection data in `AGENT-READERS.md` (§Detection):

| `pane_current_command` | `AgentKind` | Rationale |
|---|---|---|
| `"claude"` | `.claude` | Native Mach-O arm64 binary; `comm` reliably shows `claude` |
| `"pi"` | `.pi` | Node-shim that sets `process.title`; `comm` shows `pi` on confirmed live processes |
| `"codex"` | `.codex` | Tentative; process title may vary by version |
| `"node"` | `.unknown` | Ambiguous: could be Codex (unconfirmed title behavior) or any Node script; the Codex reader resolves this via cwd-probe |
| `"zsh"` / `"bash"` / `"fish"` / `"sh"` | `.shell` | Interactive shells with no agent |
| anything else | `.unknown` | An unrecognized process; shows with no deep status |

The four shell aliases in scope are exactly `zsh`, `bash`, `fish`, `sh`. `AGENT-READERS.md` §Detection groups these as "`zsh`/`bash`/`fish`/login shell", but `pane_current_command` reports the shell binary's `comm`, not the login state — a login `zsh` still reports `zsh`. There is therefore **no `"login"` case**: any process name outside the four aliases falls through to the `default: .unknown` arm, which is the honest result for a wrapper we do not recognize. The table, the mapping code, and the logic checks all agree on exactly this four-alias set; do not add a fifth alias without adding it to all three at once.

The `pane_current_command` value is compared case-insensitively after trimming whitespace. No partial-match or regex logic is used — the match is exact on the trimmed, lowercased string. This keeps the mapping auditable and the logic dead simple.

`KindClassifier.classify` is the public entry point and the only place that issues the tmux query. It does not write to any descriptor; that is the observer's job. It just returns an `AgentKind`. When the pane target is dead or the query throws, the error propagates to the caller — the observer decides whether to mark the tile `.unknown` or suppress the error.

Classification is not called per-tick. The observer calls it on three occasions: when a tile first resolves its `tmuxWindowTarget`, when the observer is explicitly asked to re-detect (e.g. the user relaunches an agent in an existing tile), and at most once per 30 seconds per tile during the background poll — enforced by the observer's budget, not by this ticket. This ticket is purely the mapping logic plus the single-query wrapper (and the protocol method it queries through); budgeting is out of scope here.

## Where it lives

**New file:**

- `Sources/ContinuumRevivedCore/AgentObserver/KindClassifier.swift` — contains the `KindClassifier` struct and the `AgentKind.from(processName:)` static method.

**Seams read but not modified by this ticket:**

- `Sources/ContinuumRevivedCore/TmuxSession.swift:8–33` — `TmuxSession` static functions remain untouched; the classifier goes through the `TmuxControl` protocol, not the raw argv layer.
- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` — the existing `AgentStatusEngine` struct is not changed; the kind classifier is a separate concern that feeds the descriptor before the status engine runs.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:94–95` — `AgentDescriptor.agentKind` is currently `String`. After the **"agentKind closed enum"** ticket replaces it with `AgentKind`, this classifier's output type matches the field directly. This ticket's logic checks must compile against the `AgentKind` enum, not the raw `String` — if that ticket has not landed when this is authored, the check suite must be written against a locally-stubbed `AgentKind` that exactly matches its spec (cases `shell`, `claude`, `codex`, `pi`, `managed`, `unknown`), and the stubs replaced on merge.

**Seams extended by this ticket (additive):**

- `Sources/ContinuumRevivedCore/Substrates/TmuxControl.swift` — add the `paneCurrentCommand(paneTarget:)` protocol requirement, the `TmuxControlError` error type, and the `InMemoryTmuxControl` implementation of both; see the next section. The real `ProcessTmuxControl` from the **"Injectable substrates"** ticket also gains the matching implementation.

## Extending the TmuxControl seam

The classifier's one load-bearing call does not exist on the `TmuxControl` protocol yet, so this ticket adds it. Three concrete additions, all in `Substrates/TmuxControl.swift`:

**1. The protocol requirement** — one new query method, alongside the existing `isAlive` / `paneCurrentPath` / `listSessions`:

```swift
// Added to the existing `public protocol TmuxControl: Sendable { … }`
func paneCurrentCommand(paneTarget: String) async throws -> String   // tmux display -p '#{pane_current_command}'
```

**2. A typed error** — the fake must be able to model a dead/absent pane by throwing, so the "error propagates" contract can be checked. The **"Injectable substrates"** ticket defines no `TmuxControl`-scoped error type (it defines only `HostError`), so this ticket introduces one:

```swift
public enum TmuxControlError: Error, Equatable {
    case paneNotFound(target: String)   // no live pane for this %pane_id (dead or never existed)
}
```

**3. The `InMemoryTmuxControl` implementation** — return the stub's existing `currentCommand` for a live pane; throw `TmuxControlError.paneNotFound` for a pane that is absent or marked `isAlive: false`:

```swift
public func paneCurrentCommand(paneTarget: String) async throws -> String {
    guard let stub = livePanes[paneTarget], stub.isAlive else {
        throw TmuxControlError.paneNotFound(target: paneTarget)
    }
    return stub.currentCommand
}
```

This is consistent with the make-or-break invariant the **"Injectable substrates"** ticket already states: a killed pane stays in `livePanes` with `isAlive: false` (it is not removed), so `paneCurrentCommand` on it throws `paneNotFound` — distinguishable from a target that was never seen (also `paneNotFound`, which is the honest answer either way). `ProcessTmuxControl` implements the same method by shelling out to `tmux display -p -t <target> '#{pane_current_command}'` and surfacing a `paneNotFound` when tmux reports the target is missing.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCore/AgentObserver/KindClassifier.swift

public struct KindClassifier: Sendable {

    public init() {}

    /// Issues one tmux query and maps the foreground process name to an AgentKind.
    /// Throws if the pane target is dead or the control layer errors.
    /// The caller (the SessionObserver) is responsible for deciding what to do with a thrown error.
    public func classify(
        windowTarget: String,
        using control: any TmuxControl
    ) async throws -> AgentKind {
        let command = try await control.paneCurrentCommand(paneTarget: windowTarget)
        return AgentKind.from(processName: command)
    }
}

extension AgentKind {

    /// Pure mapping from a pane_current_command value to an AgentKind.
    /// Case-insensitive, whitespace-trimmed. No partial matching.
    public static func from(processName raw: String) -> AgentKind {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "claude":                   return .claude
        case "pi":                       return .pi
        case "codex":                    return .codex
        case "node":                     return .unknown  // ambiguous: could be codex or any Node script
        case "zsh", "bash", "fish", "sh":
                                         return .shell
        default:                         return .unknown
        }
    }
}
```

The observer calls the classifier and writes to the descriptor like this:

```swift
// Inside the SessionObserver — not implemented in this ticket, shown for orientation
let kind = try await KindClassifier().classify(windowTarget: tile.tmuxWindowTarget, using: tmuxControl)
descriptor.agentKind = kind
// Then drive the appropriate reader based on kind
```

## How we test it

### Logic (pure Core checks)

All logic checks live in `ContinuumRevivedCoreChecks`, following the existing `do { … }` block pattern.

**Mapping table exhaustion.** Call `AgentKind.from(processName:)` for every entry in the mapping table and assert the exact expected return value. Concrete cases — this list is exactly the four-alias shell set plus the agent and fallback cases, matching the table above with no `"login"` case:

- `"claude"` → `.claude`
- `"pi"` → `.pi`
- `"codex"` → `.codex`
- `"node"` → `.unknown` (the ambiguity rule, not `.codex`)
- `"zsh"` → `.shell`
- `"bash"` → `.shell`
- `"fish"` → `.shell`
- `"sh"` → `.shell`
- `"login"` → `.unknown` (proves `login` is **not** a shell alias — it falls through to the default arm)
- `"vim"` → `.unknown`
- `"python3"` → `.unknown`
- `""` (empty string) → `.unknown`

**Case and whitespace normalization.** Assert that `"Claude"`, `"CLAUDE"`, and `"  claude  "` (with leading/trailing spaces) all produce `.claude`. This proves the trim-and-lowercase path is exercised.

**`KindClassifier.classify` through the fake.** Construct an `InMemoryTmuxControl`. Seed two pane stubs:

```swift
fake.livePanes["%1"] = InMemoryTmuxControl.PaneStub(cwd: "/tmp/proj", currentCommand: "claude", isAlive: true)
fake.livePanes["%2"] = InMemoryTmuxControl.PaneStub(cwd: "/tmp/proj", currentCommand: "zsh",    isAlive: true)
```

Call `KindClassifier().classify(windowTarget: "%1", using: fake)` and assert `.claude`. Call with `"%2"` and assert `.shell`. This confirms the classifier issues its query through the newly-added `paneCurrentCommand` method and maps the returned stub value correctly, with no subprocess involved.

**Dead-pane behavior.** Seed a pane stub with `isAlive: false` (per the **"Injectable substrates"** invariant, a killed pane stays in `livePanes` marked dead rather than being removed). Call `classify` on that target and assert it throws `TmuxControlError.paneNotFound(target:)` — asserting the exact associated value (the target string), not merely that *some* error was thrown — and that `classify` does not swallow it or return a default. Also call `classify` on a target that was never seeded (`"%99"`) and assert the same `paneNotFound` throw. This confirms the caller, not the classifier, is responsible for error handling, and that both "dead" and "never existed" surface identically. Both the error type and this throwing behavior are defined by this ticket in "Extending the TmuxControl seam" above.

**No-side-effects proof.** Call `AgentKind.from(processName: "claude")` one hundred times and assert the result is identical each time and that no global state changed. This is cheap and proves the function is truly pure, which is a prerequisite for the observer calling it on every tile in a tight loop.

### Backend (real-path integration)

The real-path check proves that `paneCurrentCommand` works through `ProcessTmuxControl` against a live tmux daemon, and that the kind classifier correctly classifies a real foreground process.

If `TmuxLocator.resolve()` returns `nil`, record `tmux_absent=true` in the manifest and skip. If tmux is present:

1. Use `ProcessTmuxControl` to create a session running a shell: `newSession(name: "continuum-kind-check", cwd: "/tmp", innerCommand: nil)` → returns `paneTarget`.
2. Call `paneCurrentCommand(paneTarget: paneTarget)` and assert the result is `"zsh"` (or begins with `"zsh"` — some versions include the binary path).
3. Call `KindClassifier().classify(windowTarget: paneTarget, using: realControl)` and assert `.shell`.
4. Kill the session: `killSession(name: "continuum-kind-check")`.
5. Record `pane_current_command`, `classified_kind`, and elapsed time in the manifest. Never record `{passed: true}`.

This check runs in `ContinuumRevivedCoreChecks` behind the `TmuxLocator.resolve() != nil` guard, exactly as the substrate check in the **"Injectable substrates"** ticket does.

### UX (visual gate + dogfood snippet)

The kind classifier has no direct UX surface in this ticket — it writes to `AgentDescriptor.agentKind` but nothing renders that value visually until the sidebar tree is fed by the observer (a later ticket). However, the dogfood path must confirm the field is being populated correctly.

After this ticket lands, open the app and start a terminal tile running `claude` (or any shell). Open the Component Lab (via Command Palette → "Component Lab") and navigate to the agent-status inspector section. The tile's `agentKind` field must show `claude` (not the placeholder string it previously held). For a plain shell tile, it must show `shell`. For a tile running `pi`, it must show `pi`.

Concrete dogfood snippet: Open the app → launch a terminal tile → in that tile's shell, run `claude` to start an agent session → in the Component Lab, select the tile's status row → confirm the "Kind" label reads `claude` (not `unknown`, not a raw string). The Component Lab's affordance inspector tile must be wired to show `AgentDescriptor.agentKind` as its human label for this gate to be meaningful. If the affordance inspector does not yet surface `agentKind`, add a single `Text` row there as part of this ticket's deliverable — it is a one-line addition and is necessary for the visual gate to be non-degenerate.

## Execution mode

**Autonomous.** The logic checks are pure, deterministic, and cover the complete mapping table (including the `"login"` case that proves login is out of scope), the case/whitespace normalization, and the fake-substrate integration plus the newly-added `paneCurrentCommand` throw path. The real-path check runs against a local tmux daemon with a graceful skip when tmux is absent. The UX gate (Component Lab kind label) is verifiable by running the app — no cloud account, no iOS device, no human judgment call about aesthetics. The check matrix is sufficient to prove the ticket's behavior without any human eyes.

## Done when

- [ ] `TmuxControl` gains a `paneCurrentCommand(paneTarget:) async throws -> String` requirement; `InMemoryTmuxControl` implements it (returns the live stub's `currentCommand`, throws `TmuxControlError.paneNotFound(target:)` for an absent or `isAlive: false` pane); `ProcessTmuxControl` implements it via `tmux display -p '#{pane_current_command}'`. This is an additive extension — no existing `TmuxControl` method changes.
- [ ] `TmuxControlError` is defined in `ContinuumRevivedCore` with a `.paneNotFound(target:)` case, `Error` + `Equatable`.
- [ ] `AgentKind.from(processName:)` is a public static method (or free function) in `ContinuumRevivedCore` that maps the string values in the table above to the correct `AgentKind` cases, case-insensitively, with whitespace trimming.
- [ ] The shell-alias set is exactly `zsh`, `bash`, `fish`, `sh`; `"login"` maps to `.unknown`, and the table, the mapping code, and the logic checks agree on this set with no divergence.
- [ ] `"node"` maps to `.unknown`, not `.codex`. This is a load-bearing invariant (D10); any future change requires a matching revision to the Codex reader's ambiguity-handling.
- [ ] `KindClassifier` is a `Sendable` value type with a single async `classify(windowTarget:using:)` method that issues exactly one `paneCurrentCommand` call and returns the mapped kind.
- [ ] `KindClassifier.classify` propagates errors from the `TmuxControl` without swallowing them; it does not return a default on error.
- [ ] All mapping-table logic checks pass, including the `"login"` case, the case/whitespace normalization cases, and the empty-string case.
- [ ] The dead-pane check confirms `classify` throws `TmuxControlError.paneNotFound(target:)` (exact associated value) for both a dead pane and a never-seeded target.
- [ ] The real-path check passes when tmux is present (manifest records `pane_current_command`, `classified_kind`, elapsed ms) and skips cleanly when absent (`tmux_absent=true`).
- [ ] The Component Lab affordance inspector surfaces `AgentDescriptor.agentKind` as a labeled row, and a `claude` tile shows `claude` in the dogfood pass.
- [ ] The app builds and all existing checks pass after the addition.

## Depends on / unblocks

This ticket depends on the **"agentKind closed enum"** ticket (`docs/38-tickets/31-agentkind-closed-enum.md`) being merged first — the classifier's return type and the whole mapping table assume that enum exists with cases `shell`, `claude`, `codex`, `pi`, `managed`, `unknown`. It also depends on the **"Injectable substrates: TmuxControl, fake clock, fake host, fake sync transport"** ticket (`docs/38-tickets/12-injectable-substrates.md`) being merged first, because this ticket extends that ticket's `TmuxControl` protocol (adding `paneCurrentCommand`) and its logic checks are written entirely against `InMemoryTmuxControl` while the real-path check uses `ProcessTmuxControl`. Do not begin until both are merged and compiling.

It directly unblocks the **"AgentStateReader protocol and AgentSnapshot type"** ticket (`docs/38-tickets/35-agent-state-reader-protocol.md`), because that protocol's `detect(processName:)` requirement is the per-reader confirmation that a given `AgentKind` is actually running — a thin layer that delegates to or complements `AgentKind.from(processName:)`. It also unblocks the **"Pi reader: locate by runId and read status.json"** ticket (`docs/38-tickets/36-pi-reader.md`), the **"Claude reader — link pane pid to session store and derive status from events"** ticket (`docs/38-tickets/37-claude-reader.md`), and the **"Codex reader — recency-plus-cwd linkage with same-cwd under-claim"** ticket (`docs/38-tickets/38-codex-reader.md`), all of which consume the kind classifier's output to decide whether to activate their linkage logic. The **"SessionObserver: per-project agent detection, reader dispatch, and status budgets"** ticket (`docs/38-tickets/40-session-observer.md`) calls `KindClassifier.classify` as its first detection step.

## Watch out for

**The `node`-ambiguity rule is the single hardest invariant to hold.** The temptation to map `"node"` to `.codex` is high — Codex is a Node script and the common path — but the spike confirmed that Codex's `process.title` behavior is unverified for the Codex process (only `pi`'s title behavior was confirmed live). If `"node"` maps to `.codex`, a tile running any other Node script (a custom build tool, a language server, a different agent) will be silently misclassified and handed to the Codex reader, which will then run a cwd-probe on the wrong process. The safe rule — `"node"` → `.unknown`, let the Codex reader upgrade via cwd-probe — is more honest and is the exact rule locked in decision **D10** and the AGENT-READERS spike. Do not change this without a verified Codex golden fixture showing `comm == "codex"` (not `"node"`) on the actual process.

**Do not add a `"login"` shell alias.** `AGENT-READERS.md` §Detection writes the shell group as "`zsh`/`bash`/`fish`/login shell", but that is describing *login shells of those four kinds*, not a process named `login`. `pane_current_command` returns the shell's `comm` (`zsh`, `bash`, …), not `login`. Adding a `"login"` case to the switch would create a fifth alias the mapping table and the logic checks do not list, which is exactly the table/code/tests divergence this ticket exists to avoid. If a real deployment ever surfaces a `pane_current_command` of `login`, add it to the table, the switch, **and** the logic checks in the same change — never to just one.

**Stop if the `AgentKind` enum from the "agentKind closed enum" ticket does not include all six cases (`shell | claude | codex | pi | managed | unknown`).** The classifier's mapping table is written against that exact set. If the enum is missing `managed` or has renamed cases, the mapping table will produce compile errors or silently fall into the `default: .unknown` arm — diagnose the enum definition and align before proceeding.

**Do not add budgeting or debounce logic to this ticket.** The classifier is a pure query-and-map function. Rate-limiting, per-tile counters, and 30-second poll cadence all belong to the SessionObserver (decision **D13**). Mixing them here would make the logic checks harder to write and the function harder to reuse.

**Keep the `paneCurrentCommand` extension additive.** You are adding one protocol requirement plus its three implementations and one error type — you are not touching any existing `TmuxControl` method, its fake behavior, or the **"Injectable substrates"** ticket's "Done when" contract. If implementing this seems to require changing an existing method signature, stop: the extension is meant to be purely additive.

**The Component Lab gate must be non-degenerate.** Confirming that `agentKind` is a non-empty string is not sufficient. The gate must show that a `claude` process produces the value `claude` — not `unknown`, not the old placeholder string. If the affordance inspector does not yet have a `Kind` row, add one as part of this ticket's scope. A visual gate that only confirms "the label exists" is a bypassed check per the verification doctrine.
