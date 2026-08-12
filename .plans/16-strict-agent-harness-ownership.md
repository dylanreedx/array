# 16 — Strict agent harness ownership

Status: **PLAN — owner direction captured; implementation not started**

## Outcome

Array exposes exactly three managed-agent harnesses, in this order:

1. **Claude Code** — the default for newly created agents.
2. **Codex**
3. **Pi**

The selected harness is authoritative. Choosing Pi runs `PiAgentRunner`;
choosing Codex runs `CodexAgentRunner`; choosing Claude Code runs
`ClaudeAgentRunner`. Array never silently substitutes another installed CLI and
does not retain an unlabeled automatic-routing mode.

Done means the selected harness predicts all of the following for the next
turn:

- executable and arguments;
- CLI-owned authentication and configuration;
- session and transcript storage;
- event translation and telemetry;
- tool surface and provider-specific side channels;
- the model catalogue used for selection and validation.

## Product contract

| User action | Required result |
|---|---|
| Create an agent without changing defaults | Claude Code runs it with the default Claude model. |
| Select Claude Code | The agent uses the user's Claude Code login, config, session, and transcript. |
| Select Codex | The agent uses the user's Codex login, config, sandbox, thread, and transcript. |
| Select Pi | The agent uses the user's Pi login, config, extensions, session, model catalogue, role tools, and event/spawn side channels. |
| Selected harness is missing or logged out | Spawn/send is refused with an actionable Environment Setup route. No fallback runner is created. |
| Change Settings later | Existing agents keep their persisted harness. The setting seeds new agents only. |
| Change one agent's harness | The change applies to that agent's next turn after a compatible model is selected. Other agents do not move. |

The UI label remains **Agent Harness** because, after this work, it truthfully
selects the harness. Settings must identify it as a default for newly created
agents. An existing agent's composer must show its persisted harness beside its
model and effort.

## Findings — where the behavior drifted

### 1. An explicit “which CLI” request became automatic routing

The recorded request in `.plans/02-codex-backend-and-toggle.md` asked for an
explicit selector:

- Claude Code → Anthropic models;
- Codex → OpenAI models;
- Pi → all providers.

That plan then added a discretionary “reconciliation”: make `pi (all
providers)` prefer native Claude/Codex CLIs and use Pi only as the fallback. A
true force-Pi option was left under **DECISION NEEDED** with a recommendation to
defer it.

Commit `203d2b2` implemented the automatic behavior on 2026-08-09 at 23:32.
Commit `fc21096`, its direct child, committed the plan containing the unresolved
decision two minutes later. The recommendation was therefore implemented before
the unresolved plan itself landed.

Current behavior in `AgentBackendConfig.route` is:

```text
pi selected + anthropic/* + claude installed      → ClaudeAgentRunner
pi selected + openai-codex/* + codex installed   → CodexAgentRunner
pi selected + anything else                      → PiAgentRunner
```

This is automatic routing under a Pi label.

### 2. The UI strengthened the wrong promise

Commit `e867680` renamed the user-facing control from “Backend” to **Agent
Harness**. `SettingsSchema` describes it as the CLI that runs managed agents,
and onboarding describes Claude Code, Codex, and Pi as switchable harnesses.
Those words describe strict selection; production routing does not.

### 3. A new-agent default became live global policy

Model and effort are persisted per `AgentRecord`. Harness is not.
`AgentSupervisor.productionRunner(for:)` reads
`AgentBackendConfig.resolved()` every time it constructs a runner, so changing
Settings can move every existing agent's next turn to a different CLI.
`rehydrationInputs(for:)` repeats the same global decision when choosing a
transcript reader.

This contradicts the introduction in Settings: “Defaults for newly created
agents.”

### 4. Pi-specific behavior is bypassed

Native-routing an OpenAI model to Codex bypasses:

- the user's Pi authentication and configuration;
- `PiAgentRunner`'s exact `pi -p --mode json --model … --thinking …
  --session-id …` invocation;
- `.pi/agents` role-derived `--tools` arguments from
  `AgentSupervisor.runnerConfig(for:)`;
- Pi's spawn-request observation side channel;
- Pi session and transcript storage;
- Pi event translation and telemetry semantics.

The model ID may be identical, but the harness contract is not.

### 5. The “smart” route checks installation, not authentication

Production routing calls `liveCLIAvailable()`, which proves executable presence.
Catalogue and onboarding probes separately establish login readiness. An
installed-but-logged-out Codex CLI can therefore take an OpenAI turn away from
an authenticated Pi harness and then fail.

### 6. Catalogue provenance is flattened away

`AgentModelCatalog.options()` unions:

- the live Pi `--list-models` result;
- curated Claude Code models;
- curated Codex models.

`AgentModelConfig.modelOptions(for:)` filters that union only by provider
prefix. This answers which provider owns an ID, but not which harness proved it
can run that exact model.

Strict ownership requires per-harness catalogue snapshots. Pi must select from
Pi's own successful `--list-models` result. Claude Code and Codex must select
from their own authenticated catalogues. An empty or unready selected harness
must not borrow the union.

### 7. Existing checks protect the drift

`CodexAgentBackendChecks` explicitly asserts that `.pi + openai-codex + codex
installed` resolves to Codex. App live-check comments also rely on the default
Pi value native-routing to Codex. These witnesses must be replaced rather than
supplemented.

## Target ownership model

Introduce one persisted, user-meaningful harness value:

```swift
public enum AgentHarness: String, Codable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case pi = "Pi"
}

public struct AgentLaunchSelection: Equatable, Sendable {
    public let harness: AgentHarness
    public let model: String
    public let thinking: String
}
```

`AgentLaunchSelection` is resolved exactly once before tile or record
construction. This extends the atomic-spawn invariant introduced by
`.plans/14-atomic-agent-model-spawn.md`: tile title, composer controls,
persisted record, first runner, and transcript source derive from one selection.

`AgentRecord` gains an optional persisted `harness` field using the existing
`decodeIfPresent` compatibility convention. It remains host-local and never
enters companion sync.

Runner construction becomes a total switch over the record:

```swift
switch record.harness {
case .claudeCode: return claudeRunner(for: record)
case .codex:      return codexRunner(for: record)
case .pi:         return piRunner(for: record)
}
```

Availability and authentication become validation facts, not routing inputs.
An unavailable selected harness produces a structured refusal naming that
harness and pointing to Environment Setup.

## Defaults and migration

### New defaults

- Harness order: Claude Code, Codex, Pi.
- Default harness: Claude Code.
- Default Claude model: `anthropic/opus` (“Claude Opus (latest)”).
- The existing `continuum.agents.backend` defaults key may remain for preference
  compatibility, but its values gain strict semantics. Internal names should
  move from “backend” to “harness” only where doing so reduces ambiguity; no
  module or historical-path renames.

### Existing Settings values

- Stored `Claude Code` remains strict Claude Code.
- Stored `Codex` remains strict Codex.
- Stored `pi (all providers)` migrates to strict Pi. This respects the visible
  choice the user made.
- No stored value resolves to the new Claude Code default.
- There is no Automatic option.

### Existing agent records

Existing sessions must not silently move because changing harness changes
conversation storage and tool behavior.

Migration inference, in order:

1. A record with `codexThreadId` is pinned to Codex.
2. An Anthropic record is pinned to Claude Code when its derived Claude
   conversation exists; otherwise it is pinned to Pi when its derived Pi
   session exists.
3. A non-Anthropic record with a Pi session is pinned to Pi.
4. A record with no session evidence uses the strict stored Settings choice if
   one exists; otherwise it uses the new Claude Code default, subject to an
   explicit compatible-model selection before its first turn.

The migration resolver must be pure and fixture-driven. It writes the inferred
harness once so future launches never repeat filesystem inference. Ambiguous
evidence fails closed and asks the user to choose; it never invokes
native-preferring routing.

Changing an existing agent's harness preserves each provider's existing
session reference. Switching back to Codex can resume the stored
`codexThreadId`; Pi and Claude retain their stable derived IDs. The UI must warn
that different harnesses do not share conversation context.

## Harness-owned catalogue and readiness

Refactor `AgentModelCatalog` to retain provenance:

```swift
struct AgentHarnessCatalogSnapshot: Sendable {
    let harness: AgentHarness
    let readiness: HarnessReadiness
    let models: [String]
    let displayNames: [String: String]
    let contextWindows: [String: Int]
    let refreshedAt: Date?
}
```

Rules:

- `models(for: .pi)` comes only from a successful bounded Pi
  `--list-models` result. The frozen Pi fixture remains a deterministic
  QA/offline seed, not evidence that an unauthenticated production Pi can run a
  model.
- `models(for: .claudeCode)` comes from the validated Claude CLI
  catalogue/aliases after Claude auth readiness.
- `models(for: .codex)` comes from the validated Codex catalogue after Codex
  login readiness.
- A selected harness that is checking renders “Checking…” and retains its prior
  immutable snapshot until the new result is ready.
- Missing, logged-out, and error states preserve diagnostics and offer
  Environment Setup. They do not borrow another harness's models.
- Model validation accepts an `AgentLaunchSelection` and validates the model
  against that selection's harness snapshot.
- Changing harness with an incompatible current model requires an explicit
  compatible model choice. Array never substitutes one silently.

## Implementation

### 1. Replace routing policy with strict harness identity

Change `Sources/ContinuumRevivedCore/AgentBackendConfig.swift` into strict
harness configuration:

- default to `.claudeCode`;
- order options Claude Code, Codex, Pi;
- remove availability-dependent routing;
- add pure harness/model compatibility validation;
- add a migration parser for the old `pi (all providers)` literal.

Change `AgentSupervisor.productionRunner(for:)` to switch only on the persisted
record harness. Remove every Pi/native fallback branch.

### 2. Persist harness and resolve spawn atomically

Update:

- `Sources/ContinuumRevivedCore/Agents/AgentRecord.swift`
- `Sources/ContinuumRevivedCore/AgentModelConfig.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`

Thread `AgentLaunchSelection` through
`spawnManagedAgentForSelectedModel`, tile creation,
`wireManagedAgentTile`, supervised-agent creation, the persisted record, and
the initial composer state. Remove post-construction harness lookup.

Extend the existing per-agent provider-settings seam so a
harness/model/effort update is one validated write. Disable the harness control
during an in-flight turn, matching the current model/effort behavior.

This work must use `CanvasNSView.installProjectTile` and
`TileSpawner.makeProjectTilePlacement` if it touches managed-agent tile
installation. It must not perpetuate the stale flat-canvas spawn path described
in repository hazard 9.

### 3. Preserve catalogue provenance

Refactor `AgentModelCatalog` without adding synchronous work:

- retain separate Pi, Claude, and Codex snapshots instead of flattening to one
  union;
- expose `snapshot(for:)` and `models(for:)`;
- retain display-name and context-window provenance with the owning harness;
- keep the background utility queue, 15-second throttle, and no-overlap guard;
- publish immutable snapshots only after a probe completes;
- never launch a CLI process from rendering, runner construction, spawn
  validation, or transcript rehydration.

Settings, the command-center model step, and `ProviderModelPicker` consume the
selected harness snapshot directly.

### 4. Make transcript and session ownership record-based

Update `AgentSupervisor.rehydrationInputs(for:)` and
`ManagedTranscriptRehydrator.Inputs` to use `record.harness`. Remove live global
route selection from rehydration.

Retain all provider-specific resume behavior:

- Claude derived conversation UUID;
- Codex stored `codexThreadId`;
- Pi derived `array-agent-<uuid>` session ID.

Do not alter `CodexRolloutLocator`'s filename-first, bounded-chunk lookup.

### 5. Align Settings, onboarding, and composer copy

Update `SettingsSchema`, `SettingsPanel`, `OnboardingPanel`, and the composer
footer:

- show Agent Harness choices in the order Claude Code, Codex, Pi;
- mark/default Claude Code as the new-agent default;
- say explicitly that Settings seeds newly created agents;
- show and edit the current agent's persisted harness in the composer;
- show harness-specific, actionable readiness errors;
- remove claims that Pi is an optional “luxury” fallback;
- remove any claim that a missing selected harness transparently uses another
  CLI.

### 6. Replace witnesses that encode automatic routing

Update `CodexAgentBackendChecks`, Claude/Pi backend checks, app live checks,
Settings/picker checks, agent-supervisor checks, and the matrix inventory.

Required deterministic behavioral witnesses:

- each harness creates only its own runner even when all three executables are
  reported available;
- Pi + `openai-codex/gpt-5.6-sol` constructs `PiAgentRunner` with exact Pi
  arguments;
- installed-but-logged-out Codex cannot steal a Pi turn;
- an unavailable explicit harness refuses and points to setup;
- changing Settings does not move an existing agent record;
- changing one agent's harness moves only that agent's next turn;
- spawn persists harness/model/effort before attach and before the first runner;
- rehydration reads the persisted harness rather than global Settings;
- catalogue snapshots never leak models across harnesses;
- role `--tools` and Pi spawn observation remain present under strict Pi;
- legacy records migrate once from session evidence;
- an ambiguous migration refuses instead of guessing.

Register any new check in `scripts/run-matrix.sh` early enough that a KNOWN-RED
leg cannot hide it, and update the literal matrix inventory. The witness must
drive production behavior rather than assert that source contains a string.

## Performance constraints

Recent performance and consistency fixes are part of this contract, not
incidental implementation detail.

### Preserve atomic spawn resolution (`f6e895d`)

The atomic model-spawn work resolves the model once before construction to
prevent disagreement among the tile, composer, record, and runner and to close
a catalogue-refresh race. Harness must join that same immutable selection.

Do not add a second Settings or catalogue read after attach or at runner
construction.

Acceptance: a spawn witness captures one `AgentLaunchSelection`; every
downstream surface and the first runner receive that exact value.

### Preserve bounded, off-main catalogue refresh

Current catalogue refresh is opt-in, backgrounded, throttled, and single-flight.
Separating snapshots by harness must not probe on picker rendering or spawn and
must not repeat three auth/model probes for every surface.

Acceptance:

- an injected counter proves repeated picker opens within the throttle window
  start no additional process;
- overlapping refresh remains impossible;
- spawn and runner construction perform zero probes;
- UI consumes cached immutable snapshots on the main thread.

### Preserve fast Codex transcript lookup (`d167372`)

The Codex transcript optimization replaced byte-at-a-time reads and
full-corpus-first scanning after a measured 97% CPU, 90-second production
failure. Persisted harness routing should prevent unnecessary transcript-source
work, while retaining:

- filename-first candidate filtering;
- file-content confirmation;
- bounded chunk reads;
- the existing 401 padded-rollout budget under one second;
- whole-file bounded reading of `session_index.jsonl` rather than per-byte
  polling.

### Avoid main-thread readiness work

The existing onboarding backlog records synchronous Pi auth checks as a
main-thread hitch. This correction must not add new synchronous auth or model
checks. Readiness comes from cached snapshots and updates UI asynchronously.

### Preserve canvas repaint isolation (`0ceb0d8`)

The camera-chrome optimization prevents camera movement from repainting tile
chrome. Adding a harness control to the composer/footer must remain inside
existing tile state updates and must not add harness/catalogue state to
camera-driven repaint paths.

## Verification and rollout

1. Build the Core checks product before trusting it:
   `swift build --product ContinuumRevivedCoreChecks`.
2. Run targeted Core checks for strict harness routing, catalogue provenance,
   migration, runner arguments, and probe coalescing.
3. Enumerate actual app flags from `ContinuumApp.swift`, then run the existing
   Settings, provider picker, atomic managed-agent spawn, supervisor,
   restore/rehydration, and onboarding legs that the changes affect.
4. Run the Codex 401-rollout performance witness unchanged.
5. Add and run a catalogue probe-count/coalescing performance witness.
6. Run `scripts/run-matrix.sh` and judge the final summary, confirming the new
   strict-harness witness actually ran and introduced no new real failures.
7. Rebuild only `~/Desktop/Array Dev.app` using `scripts/dev-app.sh`, pinned to
   `~/array-scratch`.
8. Manually smoke-test in Array Dev:
   - create a default agent and confirm Claude Code owns its process/session;
   - create Codex and Pi agents with the same OpenAI model where both harnesses
     report it;
   - verify their transcript/session artifacts land under the selected harness;
   - switch one agent's harness for its next turn and confirm neighboring
     agents do not move;
   - log Codex out while Pi remains authenticated and confirm Pi selection still
     runs Pi;
   - verify picker open/close and canvas movement remain responsive.
9. Do not touch `/Applications/Array.app`, production application state, or the
   active `~/Documents/personal` project during implementation QA.

## Documentation closeout

- Keep `.plans/02-codex-backend-and-toggle.md` as history. At most, add a short
  pointer to this superseding forward plan.
- Update `.plans/backlog.md` when implementation starts and when it ships.
- Update `docs/internals/providers.md`, onboarding copy, and any architecture
  document that still describes automatic/native-preferring routing.
- Correct the `AGENTS.md` managed-agent glossary after implementation; its
  current two-backend description is already stale relative to the three
  runners in code.

## Non-goals

- No fourth Automatic mode.
- No API keys or Array-owned provider credentials.
- No changes to provider CLI login flows.
- No shared conversation migration between Claude, Codex, and Pi.
- No rewrite of runner or event translators.
- No release, production app rebuild, or production-state mutation as part of
  planning.

## Owner decisions captured

- Claude Code is the default.
- The only alternatives are Codex and Pi.
- Harness selection is strict and literal.
- Pi means the Pi backend and Pi harness, including the user's Pi config.
- Existing agents retain harness ownership across Settings changes and relaunch.
- There is no automatic native-preferring mode.

