# 02 — Codex CLI backend + explicit backend toggle

Status: PLAN (not implemented). Follow-up to `.plans/01-provider-cli-backends.md`
(the shipped claude CLI backend). Compliance for local orchestration of `codex`
under a ChatGPT subscription login is already cleared in plan 01 (codex is MORE
permissive than claude). Everything below was captured live against
**codex-cli 0.145.0** on 2026-08-09/10.

---

## 1. Problem / goal

Two things Dylan asked for:

1. **A codex CLI backend** so a future user never needs pi. Codex covers OpenAI
   (`openai-codex/*`) models the same way the claude backend covers Anthropic
   (`anthropic/*`): Array spawns the user's own `codex` binary headlessly, runs
   on their ChatGPT subscription (no pi metering, no API keys), and translates
   its output into the existing `AgentRuntimeEvent` timeline. **This is "the same
   shape" as the claude backend** — the deliverable mirrors
   `ClaudeEventTranslator` / `ClaudeAgentRunner` / `ClaudeAgentBackendChecks`
   file-for-file, with the codex specifics captured verbatim in §3.

2. **An explicit "which CLI" toggle** in Settings ▸ Agents. Today routing is
   automatic by model prefix (`AgentSupervisor.productionRunner`,
   AgentSupervisor.swift:1016). Dylan wants an explicit selector where **Claude
   Code ⇒ Anthropic models only**, **Codex ⇒ OpenAI models only** (mutually
   exclusive), and **pi ⇒ all providers (advanced)**. The model dropdown must
   filter to the selected backend's providers — in Settings AND in the tile
   composer. Design + reconciliation with auto-routing is §4.

### The one hard difference from claude (read this first)

**claude continuity is DERIVED; codex continuity must be STORED.** The claude
backend mints the session UUID itself and passes `--session-id <uuid>`
(ClaudeAgentRunner.swift:143-145), so no state is persisted. **Codex generates
its own `thread_id` and gives no flag to set it** — there is no `--session-id`
on `codex exec`. So Array must **capture** the `thread_id` from the first turn's
`thread.started` line and **persist** it on the record to resume later.

And it cannot smuggle the id out on an event: `AgentSupervisor.send` rebinds
**every** event's threadId to the agent's own derived id before delivery —
`let bound = event.withThreadId(threadId)` at AgentSupervisor.swift:1786. So the
captured `thread_id` must travel on the **observation side channel**
(`observeRuntimeObservations`, wired at AgentSupervisor.swift:1777), exactly like
cwd/tool observations do today. See §3.4 and §4.3.

**Resume verdict: codex CAN resume headlessly across separate `codex exec`
invocations — VERIFIED live** (two-process codeword recall, §3.3). Parity with
claude is achievable; it just needs one persisted field.

---

## 2. New files (mirror the claude trio)

| New file | Claude analogue | Responsibility |
|---|---|---|
| `Sources/ContinuumRevivedCore/AgentProviders/CodexEventTranslator.swift` | `ClaudeEventTranslator.swift` | PURE. `codex exec --json` JSONL line → `[AgentRuntimeEvent]`. I5 by construction: drops `command`, `aggregated_output`, and never puts a command/output/path into an event; paths project only through `onRuntimeObservation`. Fires a NEW observation case carrying the `thread_id` (§3.4). Cross-platform (no `Process`). |
| `Sources/ContinuumRevivedCore/AgentProviders/CodexAgentRunner.swift` | `ClaudeAgentRunner.swift` | Split like claude's: a pure `enum CodexCLIBackend` (routing, model-arg strip, effort mapping, curated catalog, auth parse, failure predicates) that lives in Core and is pinned by the matrix; and an `#if os(macOS)` `final class CodexAgentRunner` that spawns `codex`, streams stdout line-by-line through the translator, drains stderr concurrently, and does the fresh-vs-resume + self-heal dance (§3.5). |
| `Sources/ContinuumRevivedCoreChecks/CodexAgentBackendChecks.swift` | `ClaudeAgentBackendChecks.swift` | The witness. `runCodexAgentBackendChecks()`: mapping (against the real captured JSONL), the gate cases, runner argv (fresh + resume), routing/model-arg/effort/auth policy, and the catalog union. Registered from `main.swift` next to `runClaudeAgentBackendChecks()` (call site: ContinuumRevivedCoreChecks/main.swift:10335). |

No module renames (non-negotiable #4): these are new files inside the existing
`ContinuumRevived*` modules.

---

## 3. Captured codex reality (verbatim — do NOT re-investigate)

### 3.1 Invocation / argv

`codex --version` → `codex-cli 0.145.0`. Headless entry point: `codex exec`
(alias `codex e`), resume: `codex exec resume [SESSION_ID] [PROMPT]`.

Flags that matter (from `codex exec --help` / `codex exec resume --help`):

- `--json` — print events to stdout as JSONL. (Required; this is the schema.)
- `-m, --model <MODEL>` — model (bare slug, e.g. `gpt-5.6-sol`).
- `-C, --cd <DIR>` — working root. **Only on `exec`, NOT on `exec resume`.**
- `-s, --sandbox <read-only|workspace-write|danger-full-access>` — **Only on
  `exec`, NOT on `exec resume`** (resume rejects `-s`: "unexpected argument '-s'").
- `-c, --config <key=value>` — TOML override; **works on BOTH exec and resume.**
  This is how Array sets sandbox/approval/effort deterministically regardless of
  the user's `~/.codex/config.toml`. Value parses as TOML; a bareword that fails
  TOML parse is used as a literal string, so `-c sandbox_mode=workspace-write`
  (no quotes) sets the string `"workspace-write"`. VERIFIED: `codex exec -c
  sandbox_mode=workspace-write -c approval_policy=never` parses (exit 0).
- `--skip-git-repo-check` — allow running outside a git repo (agent cwds are not
  always repos).
- `--dangerously-bypass-approvals-and-sandbox` — the sledgehammer (disables the
  sandbox entirely). **Do NOT use.** Prefer `-c sandbox_mode=... -c
  approval_policy=never`, which works on resume too and is deterministic.

Config keys (confirmed present in `~/.codex/config.toml`): `model`,
`model_reasoning_effort`, `approval_policy`, `sandbox_mode`.

**`CodexCLIBackend.processArguments` (recommended, mirrors
`ClaudeAgentRunner.processArguments`):**

```
enum SessionMode { case fresh; case resume }   // fresh == start (claude's naming)

// fresh (threadId nil):
["exec",
 "--json", "--skip-git-repo-check",
 "-c", "approval_policy=never",
 "-c", "sandbox_mode=workspace-write",
 "-m", model]                               // model already prefix-stripped
 + (effort.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
 + ["-C", cwdPath]                          // exec only
 + extraArgs
 + [prompt]                                 // ONE positional prompt, last

// resume (threadId non-nil):
["exec", "resume", threadId,
 "--json", "--skip-git-repo-check",
 "-c", "approval_policy=never",
 "-c", "sandbox_mode=workspace-write",
 "-m", model]
 + (effort.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
 // NO -C on resume; the runner sets process.currentDirectoryURL = cwd instead
 + extraArgs
 + [prompt]
```

Notes for the runner:
- Set `process.currentDirectoryURL = cwd` on both paths (resume can't take `-C`).
- **Set `process.standardInput = FileHandle.nullDevice`.** Live turns printed
  "Reading additional input from stdin..." even with a positional prompt; a null
  stdin removes any chance of a block.
- Sandbox choice: `workspace-write` is the recommended default (agent may edit
  its workspace + run commands; network restricted). It is SAFER than claude's
  `--dangerously-skip-permissions` posture while still functional. See §7 open
  question if Dylan wants exact parity (`danger-full-access`).
- Effort mapping: `-c model_reasoning_effort=<level>` for **exact** matches in
  `{minimal, low, medium, high}` (codex's set; the shipped default is `medium`);
  omit for pi-only levels (`off`, `xhigh`, `max`) and take codex's default —
  the same exact-match-or-omit rule as `ClaudeCLIBackend.effortArgument`.
- PATH/executable resolution: reuse `PiAgentRunner`'s GUI-thin-PATH strategy
  exactly as `ClaudeAgentRunner.resolvedCommand` does (locate absolute `codex`,
  fall back to `/usr/bin/env codex`). `codex` here is a node script under nvm
  (`~/.nvm/.../bin/codex`), so PATH augmentation with node's dir is needed — the
  same `PiAgentRunner.augmentedPath` / `liveExtraDirs` the claude runner uses.

### 3.2 Event stream schema (`codex exec --json`) — REAL capture

A full turn with a shell tool call + a file write, captured live (throwaway dir,
`codex exec --json -s workspace-write --skip-git-repo-check "…"`). This is the
**exec** schema — a clean, high-level event vocabulary, different from and much
simpler than claude's raw stream-json (and different from the internal
`~/.codex/sessions/**/rollout-*.jsonl` schema, which Array does NOT parse):

```jsonl
{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I’ll run the command, then create and verify the requested file."}}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi-from-codex'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi-from-codex'","aggregated_output":"hi-from-codex\n","exit_code":0,"status":"completed"}}
{"type":"item.started","item":{"id":"item_2","type":"file_change","changes":[{"path":"/Users/…/note.txt","kind":"add"}],"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/Users/…/note.txt","kind":"add"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"Ran the command and created `note.txt` containing only the codeword."}}
{"type":"turn.completed","usage":{"input_tokens":46162,"cached_input_tokens":41216,"cache_write_input_tokens":0,"output_tokens":231,"reasoning_output_tokens":0}}
```

Directly-observed `item.type` values: **`agent_message`, `command_execution`,
`file_change`**. The internal rollout schema also carries `reasoning`,
`web_search_end`, `patch_apply_end`, `function_call`/`custom_tool_call` — the
exec wrapper surfaces the analogues as additional `item.type`s (very likely
`reasoning`, `web_search`, `mcp_tool_call`, `todo_list`). **Action for the
implementer:** capture ONE reasoning turn and one error turn to pin those two
before finalizing the fixture — command below (§6 step 0). Map unknown item
types to `[]` (drop) the same way claude's translator drops unrecognised lines,
so an unmapped type is inert, never a crash.

### 3.2.1 Event → `AgentRuntimeEvent` mapping (target vocabulary at
`AgentStatusEngine.swift:469`; `ItemKind` at `AgentStatusEngine.swift:223`)

| codex line | emit | notes |
|---|---|---|
| `thread.started {thread_id}` | `[.sessionStateChanged(.ready), .sessionStateChanged(.running)]` + **fire `onRuntimeObservation(.threadId(thread_id))`** | capture the id here; set translator's internal threadId. Re-fires with the same id on resume (VERIFIED). |
| `turn.started` | `[.turnStarted(threadId, turnId)]` | bump a turn counter; `turnId = "\(threadId)#\(runToken)-t\(n)"` (salt with a per-process `runToken`, same reason claude salts — id is stable across processes). |
| `item.completed {agent_message, text}` | `[.contentDelta(threadId, turnId, .assistant, text)]` | **Whole reply arrives at once** (no token streaming in exec --json). Emit the full text as one delta. `agent_message` is atomic — no `item.started` for it. It IS the user-facing reply (I5-safe to surface, like claude's text_delta). |
| `item.completed {reasoning, text}` (verify) | `[.contentDelta(threadId, turnId, .reasoning, text)]` | analogous to claude thinking_delta. |
| `item.started {command_execution}` | `[.itemStarted(threadId, saltedItemId, .commandExecution, title:"Shell")]` | **DROP `command` + `aggregated_output` (I5).** Title is a generic literal — the command itself is the sensitive payload, so it must NOT become the title (this differs from claude, where the tool NAME is the safe title). |
| `item.completed {command_execution, exit_code}` | `[.itemCompleted(threadId, saltedItemId, .commandExecution, status: exit_code==0 ? .completed : .failed)]` | |
| `item.started {file_change, changes}` | `[.itemStarted(threadId, saltedItemId, .fileChange, title:"Edit")]` + observation `.toolActivity(itemId, .editing, targetPath: changes[0].path)` | path projects out of band only. |
| `item.completed {file_change, status}` | `[.itemCompleted(threadId, saltedItemId, .fileChange, status)]` | |
| `turn.completed {usage}` | token + context events (§3.2.2) then `[.turnCompleted(threadId, turnId, .completed, nil), .sessionStateChanged(.ready)]` | |
| `turn.failed {error}` (verify shape) | `[.turnCompleted(threadId, turnId, .failed, errorMessage: <code/subtype only, NEVER the body>), .sessionStateChanged(.ready)]` | launch/auth failures come from exit+stderr in the runner, not here — same as claude. |

**Item-id salting (important):** codex item ids restart at `item_0` every
process, so across turns (each a separate process) `item_0` would collide.
Salt: `saltedItemId = "\(runToken)-\(rawItemId)"` (or fold in the turn counter).
Claude did not need this for item ids (its tool ids are globally unique) but did
salt turn ids for the same underlying reason — do it for codex item ids.

### 3.2.2 Usage / telemetry — DIFFERENT from claude, get this right

`turn.completed.usage` shape (real):
`{input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
reasoning_output_tokens}`. **There is NO cost field** (subscription, not
metered) → `totalCostUsd = nil` everywhere.

**Token semantics differ from claude.** Claude reports `input_tokens` as the
uncached remainder and SUMS it with cache_read + cache_write
(ClaudeEventTranslator.swift:216-222). **Codex `input_tokens` is already the
TOTAL prompt tokens; `cached_input_tokens` is a SUBSET of it (OpenAI
convention). Do NOT sum.** Otherwise you double-count.

- `tokenUsageUpdated`: `TokenUsageSnapshot(inputTokens: input_tokens,
  outputTokens: output_tokens, totalCostUsd: nil)`.
- `contextWindowUpdated`: `AgentContextWindowSnapshot(inputTokens: input_tokens,
  outputTokens: output_tokens, cacheReadTokens: cached_input_tokens,
  cacheWriteTokens: cache_write_input_tokens, totalProcessedTokens:
  input_tokens + output_tokens, totalCostUsd: nil, source: .codexTurnUsage,
  freshness: .live, …)`.
- Guard `total > 0` before publishing, same as claude (don't clobber real
  telemetry with a zero block).

**New telemetry source case.** Add `.codexTurnUsage` to
`AgentContextWindowTelemetrySource` (AgentStatusEngine.swift:282), following
`.claudeResultUsage` exactly: add to `encodedValue` (302), the `init(from:)`
switch (312), and `isAuthoritativeForContextOccupancy` (returns `false`, in the
same arm as `.piMessageUsage, .claudeResultUsage`). It is a per-turn aggregate,
not authoritative occupancy.

### 3.3 Session / resume — VERIFIED

- Sessions persist as `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl`;
  the `<uuid>` is the `thread_id`.
- `codex exec resume <thread_id> --json --skip-git-repo-check "<prompt>"` resumes
  across a **separate process**. **VERIFIED end-to-end:** turn 1 (fresh
  `codex exec`) planted codeword `PLATYPUS42` + `thread.started` gave
  `019fe980-21f0-7df1-b2a0-49d7839c7937`; turn 2 (`codex exec resume 019fe980-…`)
  replied `PLATYPUS42` and re-emitted the SAME `thread.started` thread_id.
- Codex GENERATES the thread_id (no flag to set it) ⇒ **continuity is STORED**
  (§1, §3.4).
- **Failure predicate (unknown/stale session):** `codex exec resume <bad-uuid>`
  → exit **1**, empty stdout, stderr:
  `Error: thread/resume: thread/resume failed: no rollout found for thread id
  <uuid> (code -32600)`. `CodexCLIBackend.isUnknownSessionFailure(stderr:)`
  matches `"no rollout found for thread id"` (or `"code -32600"`). Trigger for
  the self-heal in §3.5.

### 3.4 Persisting the captured thread_id

- **New `AgentRecord` field** (AgentRecord.swift:156): `public var codexThreadId:
  String?`. Add it as an OPTIONAL field decoded with `decodeIfPresent` and **do
  NOT bump `currentSchemaVersion`** — this is exactly the precedent set by
  `snoozedAt` (AgentRecord.swift:267, and the rationale comment at 261-266),
  `sourceItemId`, and `lastContextWindow`. Host-bound, never in a sync payload.
- **New observation case** in `AgentRuntimeObservation`
  (AgentLocationProjector.swift:12): `case threadId(String)`. The translator
  fires it on `thread.started`; the supervisor's existing
  `observeRuntimeObservations` handler (AgentSupervisor.swift:1777 →
  `ingestRuntimeObservation`) persists it to `record.codexThreadId`. **This is
  the only clean path** because events get their threadId rebound at
  AgentSupervisor.swift:1786 (`event.withThreadId(threadId)`), so the id cannot
  ride out on `turnStarted`.
- Read it back in `codexRunnerConfig(for:)` (§4.3): `threadId:
  record.codexThreadId` (nil ⇒ fresh turn).

### 3.5 Runner control flow (fresh / resume / self-heal)

Simpler than claude's (we KNOW from stored state which mode to use):

```
if config.threadId == nil {
    // fresh
    let r = runOnce(mode: .fresh, …)
    if r.exitCode != 0 { throw codexFailed(r) }
} else {
    let r = runOnce(mode: .resume, threadId: config.threadId!, …)
    if r.exitCode != 0 {
        // self-heal: a stored id whose rollout was deleted/archived/cleaned
        if CodexCLIBackend.isUnknownSessionFailure(stderr: r.stderr), !stopRequested {
            let fresh = runOnce(mode: .fresh, …)   // starts a NEW thread; thread.started
            if fresh.exitCode != 0 { throw codexFailed(fresh) }   // → observation persists new id
        } else {
            throw codexFailed(r)
        }
    }
}
```

This is the inverse of claude's resume-first/`--session-id`-retry
(ClaudeAgentRunner.swift:230-242): claude always tries resume then falls back to
create; codex chooses up front from stored state and only falls back to fresh
when the stored id is stale. The translator gates the same way (a `thread.started`
on the retry re-arms the turn counter; a failed resume that never emitted
`turn.started` paints no spurious turn — mirror the `turnCounter > 0` guard at
ClaudeEventTranslator.swift:209).

Concurrency/plumbing: copy `ClaudeAgentRunner` verbatim — serial queue,
newline-framed stdout buffer, **concurrently drained stderr** (the pi/claude
deadlock lesson, ClaudeAgentRunner.swift:311), `waitUntilExit`, flush remainder,
`RunError` with `SecretRedactor.redactLocalDiagnostics`. `observeSpawnRequests`
is a no-op (codex has no `spawn_agent` side channel, same as claude,
ClaudeAgentRunner.swift:259).

### 3.6 Auth readiness

- `codex login status` → exit **0**, stdout `Logged in using ChatGPT`. **There is
  NO `--json`** (`codex login status --json` → "unexpected argument").
- `CodexCLIBackend.isLoggedIn(statusOutput:exitCode:)` (pure, pinned): logged in
  iff `exitCode == 0 && output.contains("Logged in")`. (Text-based, unlike
  claude's JSON parse — that's the real shape.)
- The catalog probe (§3.7) and the onboarding row (§4.5) both use this.

### 3.7 Model ids / catalogue

- Codex model slugs (from `~/.codex/models_cache.json`): `gpt-5.6-sol`,
  `gpt-5.6-sol-wm`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`,
  `gpt-5.4-mini`, `gpt-5.3-codex-spark`, `codex-auto-review`.
- **Prefix confirmed:** Array/pi already namespace these as `openai-codex/<slug>`
  (`AgentModelConfig.fallbackModelOptions`, AgentModelConfig.swift:29-37;
  `ProviderModelGrouping` display name "OpenAI Codex", ProviderModelPicker.swift:26).
  So `CodexCLIBackend.modelArgument(forCatalogId: "openai-codex/gpt-5.6-sol")`
  strips the prefix → `gpt-5.6-sol` for `-m` (identical logic to
  `ClaudeCLIBackend.modelArgument`, ClaudeAgentRunner.swift:33). Routing/dedup
  works because the prefix already matches pi's.
- **Catalog contribution (mirror claude):** `CodexCLIBackend.curatedCatalogModels`
  (a frozen `openai-codex/*` list + display names), applied via a new
  `AgentModelCatalog.apply(codexBackendAvailable:)` (mirror
  `apply(claudeBackendAvailable:)`, AgentModelCatalog.swift:114) and a new
  `probeCodexBackend` in the `#if os(macOS)` block (mirror `probeClaudeBackend`,
  AgentModelCatalog.swift:210, gated on `codex` installed AND `login status`
  logged-in). Keep a separate `codexBackendModels` store so a pi probe can't wipe
  it and vice-versa, and union it in `options()` (AgentModelCatalog.swift:39-47).
  Note: the frozen `fallbackModelOptions` already lists `openai-codex/*`, so on a
  pi-less machine these show anyway; the gated contribution is what makes the
  **Codex toggle** truthfully available only when codex is usable (§4). Probe
  MUST stay macOS-gated (iOS shares Core, no `Process`) — same discipline as the
  claude probe.

---

## 4. The backend toggle

### 4.1 Decision

Add a **global** three-way selector in Settings ▸ Agents (it is a default that
governs the agents UI, alongside the existing Default Model / Default Effort in
that section, SettingsSchema.swift:206-243):

| Option | Dropdown shows | Routes to |
|---|---|---|
| **pi (all providers)** — DEFAULT | all providers | auto: `anthropic/*`→claude if installed, `openai-codex/*`→codex if installed, else pi |
| **Claude Code** | `anthropic/*` only | claude runner (pi fallback if claude missing) |
| **Codex** | `openai-codex/*` only | codex runner (pi fallback if codex missing) |

**How pi fits (the reconciliation Dylan asked for):** pi is the multi-provider
"advanced / all providers" option AND the default. Its routing is the *current
shipped behavior* — prefer the native subscription CLI per provider, fall back to
pi — extended with codex as a second native backend. The two explicit options
are narrowing modes: they hide every other provider (mutual exclusivity) and
pin the native backend for the one provider they expose. This satisfies "Codex ⇒
OpenAI only, Claude Code ⇒ Anthropic only, mutually exclusive" while keeping the
shipped default and QA behavior identical (default shows all providers, so no
existing check changes its expected model set).

Rationale for pi-as-default rather than a separate "Automatic": one fewer
concept. The default already does the smart native-preferring routing; calling it
"pi (all providers)" matches Dylan's framing ("pi becomes the multi-provider
option") without inventing an "auto" the user has to reason about. If Dylan wants
a distinct "force everything through pi even when claude/codex are installed"
mode, that's the §7 open question.

### 4.2 Storage + a pure policy type

New `Sources/ContinuumRevivedCore/AgentBackendConfig.swift` (mirrors
`AgentModelConfig` / `FocusBorderConfig` — a UserDefaults-backed resolver + pure
functions the matrix pins):

```swift
public enum AgentBackend: String, CaseIterable, Sendable { case pi, claudeCode, codex }

public enum AgentBackendConfig {
    public static let key = "continuum.agents.backend"
    public static let defaultBackend: AgentBackend = .pi   // = current behavior

    public static func resolved(defaults: UserDefaults = .standard) -> AgentBackend {
        AgentBackend(rawValue: defaults.string(forKey: key) ?? "") ?? defaultBackend
    }

    /// Providers visible for a backend. .pi ⇒ nil (no filter / all).
    public static func allowedProviders(for b: AgentBackend) -> Set<String>? {
        switch b {
        case .pi: return nil
        case .claudeCode: return ["anthropic"]
        case .codex: return ["openai-codex"]
        }
    }

    /// Pure dropdown filter, pinned in the matrix.
    public static func filter(_ ids: [String], for b: AgentBackend) -> [String] {
        guard let allow = allowedProviders(for: b) else { return ids }
        return ids.filter { allow.contains(ProviderModelGrouping.provider(forID: $0)) }
        // ProviderModelGrouping.provider(forID:) is at ProviderModelPicker.swift:36 (app target).
        // If Core can't see it, inline the same split-on-"/" here (keep one copy tested).
    }

    public enum Route: Equatable { case claude, codex, pi }

    /// Pure routing, pinned in the matrix. Replaces the ad-hoc check in
    /// productionRunner.
    public static func route(model: String, backend: AgentBackend,
                             claudeAvailable: Bool, codexAvailable: Bool) -> Route {
        switch backend {
        case .claudeCode:
            return claudeAvailable && model.hasPrefix("anthropic/") ? .claude : .pi
        case .codex:
            return codexAvailable && model.hasPrefix("openai-codex/") ? .codex : .pi
        case .pi:
            if claudeAvailable, model.hasPrefix("anthropic/")   { return .claude }
            if codexAvailable,  model.hasPrefix("openai-codex/") { return .codex }
            return .pi
        }
    }
}
```

Note: `provider(forID:)` currently lives in the app target
(ProviderModelPicker.swift:36); Core cannot import it. Simplest: add a tiny
provider-prefix helper in Core (or inline the `split(separator:"/")` in `filter`)
and have `ProviderModelGrouping.provider(forID:)` delegate to it, so the split
rule stays defined once and is the version the checks pin.

### 4.3 Routing — the one edit in `productionRunner`

`AgentSupervisor.productionRunner(for:)` (AgentSupervisor.swift:1016) today only
knows claude. Rewrite its body to consult the policy:

```swift
nonisolated static func productionRunner(for record: AgentRecord) -> AgentRunning {
    switch AgentBackendConfig.route(
        model: record.model,
        backend: AgentBackendConfig.resolved(),
        claudeAvailable: ClaudeAgentRunner.liveCLIAvailable(),
        codexAvailable: CodexAgentRunner.liveCLIAvailable()) {
    case .claude: return claudeRunner(for: record)
    case .codex:  return codexRunner(for: record)
    case .pi:     return piRunner(for: record)
    }
}
```

Add, mirroring claudeRunner/claudeRunnerConfig (AgentSupervisor.swift:1032-1048):

```swift
nonisolated static func codexRunner(for record: AgentRecord) -> AgentRunning {
    CodexAgentRunner(config: codexRunnerConfig(for: record))
}
nonisolated static func codexRunnerConfig(for record: AgentRecord) -> CodexAgentRunner.Config {
    CodexAgentRunner.Config(
        model: CodexCLIBackend.modelArgument(forCatalogId: record.model),
        effort: CodexCLIBackend.effortArgument(forThinking: record.thinking),
        cwd: URL(fileURLWithPath: record.cwd, isDirectory: true),
        threadId: record.codexThreadId)      // nil ⇒ fresh
}
```

And `extension CodexAgentRunner: AgentRunning {}` beside the claude one
(AgentSupervisor.swift:69). The single-owner scan
(`runnerConstructionSites(typeName:)`, AgentSupervisor.swift:11010) must gain a
codex leg in the supervisor check (AgentSupervisor.swift:5099-5102): assert
`CodexAgentRunner` is constructed only in `App/AgentSupervisor.swift`.

Persisting the captured id: extend `ingestRuntimeObservation` (called from the
handler wired at AgentSupervisor.swift:1777) to handle the new
`.threadId(String)` case → `records[id]?.codexThreadId = value` + persist through
the store, exactly as `.workingDirectory` is persisted today.

### 4.4 Dropdown filtering — the two consumers

Both read `AgentModelConfig.modelOptions` (= `AgentModelCatalog.shared.options()`):

1. **Settings** — `SettingsSchema` agents section passes
   `AgentModelConfig.modelOptions` as the `.choice` options
   (SettingsSchema.swift:216-221) → `SettingsPanel.modelPickerRow`
   (SettingsPanel.swift:239). 
2. **Composer** — `AgentComposerFooterView.rebuildChoices`
   (AgentComposerFooterView.swift:164-165).

Make the filter apply to BOTH with one change: add
`AgentModelConfig.modelOptions(for backend:)` and route both consumers through
it, OR (simplest, fewest signatures touched) make the existing
`AgentModelConfig.modelOptions` computed property apply
`AgentBackendConfig.filter(_, for: AgentBackendConfig.resolved())`. The latter
auto-filters everywhere `modelOptions` is read, including the settings `.choice`
and the composer, with zero call-site edits.

Guard rails when filtering:
- **Never blank the picker.** If the filtered list is empty (e.g. Codex selected
  but the catalog union hasn't added `openai-codex/*` yet), fall back to the
  unfiltered list — mirror the "picker must never go blank" rule already in
  `AgentModelCatalog.apply` (AgentModelCatalog.swift:99-104) and
  `resolvedFromDefaults`' first-usable fallback (AgentModelConfig.swift:62-69).
- **Keep an off-catalog current value visible.** `rebuildChoices` already appends
  `settings.model` if absent (AgentComposerFooterView.swift:166); preserve that
  after filtering so a record whose model is hidden by the current backend still
  shows its own value rather than silently switching.
- The `.choice`/`ProviderModelButton` re-renders when settings change — the
  panel rebuilds sections on `notifySettingsChanged` (SettingsPanel.swift:251),
  so flipping the backend re-runs `sections()` → re-reads the filtered
  `modelOptions`. Verify the composer footer re-runs `rebuildChoices` when the
  global backend changes (it rebuilds on `apply`; if the backend can change while
  a composer is open, post/observe a settings-changed notification to rebuild —
  low risk, note in §7).

### 4.5 Onboarding row

`OnboardingPanel` already has a `codex` install probe (OnboardingPanel.swift:111)
but no codex AUTH row. Add a `codex-auth` probe mirroring `claude-auth`
(OnboardingPanel.swift:103-110 + `claudeAuthStatus()` at 81-92): locate `codex`,
run `codex login status`, and use `CodexCLIBackend.isLoggedIn(...)` →
"signed in (ChatGPT)". Update the codex install probe's `detail` to say managed
agents run OpenAI models through the user's own Codex sign-in — no API keys
(the CLI-owns-auth non-negotiable #3).

---

## 5. Witnesses (non-negotiable #2)

### 5.1 CoreChecks (offline, deterministic — the main witness)

New `CodexAgentBackendChecks.swift`, `runCodexAgentBackendChecks()` registered in
`ContinuumRevivedCoreChecks/main.swift` beside line 10335. Mirror
`ClaudeAgentBackendChecks` section-for-section:

1. **Mapping** — feed the REAL captured JSONL (§3.2) with the command,
   aggregated_output, and file paths planted as `SECRET-*` sentinels; assert the
   exact `[AgentRuntimeEvent]` sequence, that `agent_message` text surfaces once,
   the salted item ids, and the summed-vs-not usage (`input_tokens` NOT summed
   with cached). Encode the events to JSON and assert **no** `SECRET-COMMAND`,
   `SECRET-OUTPUT`, `SECRET-PATH` leaked; assert generic titles ("Shell",
   "Edit") survive. (Mirror ClaudeAgentBackendChecks.swift:24-133.)
2. **Observation side channel** — assert `file_change` path and the `thread.started`
   thread_id project through `onRuntimeObservation` (`.toolActivity` +
   `.threadId`) and ONLY there. (Mirror :104-131.)
3. **Gate** — a `turn.completed`/`turn.failed` before any `turn.started` emits
   nothing (stale-resume shape); an error turn completes as `.failed` with a
   code/subtype, never the body; a zero-usage block publishes no telemetry.
   (Mirror :136-159.)
4. **Runner argv** (`#if os(macOS)`) — pin `processArguments` for `.fresh` and
   `.resume`, incl. `-c` flags, effort omission for pi-only levels, `-C` only on
   fresh, prompt last. Pin `resolvedCommand` (absolute vs `/usr/bin/env codex`).
   Pin `isUnknownSessionFailure("… no rollout found for thread id … (code -32600)")`.
   (Mirror :162-224.)
5. **Policy** — `AgentBackendConfig.route(...)` truth table for all three
   backends × availability; `modelArgument` prefix strip; `effortArgument`
   exact-match/omit; `isLoggedIn` (exit0+"Logged in" true; nonzero/garbage
   false); `filter(...)` per backend. (Mirror :227-253.)
6. **Catalog union** — `apply(codexBackendAvailable:)` appends `openai-codex/*`
   without dup, clears on false, pi names win, `resetForQA` clears. (Mirror
   :256-292.)

### 5.2 App self-check flags (mind the footgun)

Enumerate real flags before adding
(`grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift`);
an unknown `--*-check` falls through and boots the full app.

- **New supervised live leg `--codex-agent-live-check`** — twin of
  `--claude-agent-live-check` (ContinuumApp.swift:3949; dispatched at
  ContinuumApp.swift:3627). Same two-turn codeword continuity proof through the
  real tile: move the spawned agent onto an `openai-codex/*` model, assert
  `productionRunner` returns a `CodexAgentRunner` (set backend to `.codex` or
  `.pi` + codex available), plant a codeword turn 1 (fresh `codex exec` → captures
  + persists thread_id), recall turn 2 (`codex exec resume` in a fresh process),
  assert the recall AND that `record.codexThreadId` was persisted. Guard on
  `CodexAgentRunner.liveCLIAvailable()` and skip if absent (like the claude leg
  at ContinuumApp.swift:3956). **Supervised only** (spends real subscription,
  needs codex login) — NOT a default matrix leg, exactly like the claude/pi
  twins. Add the `else if CommandLine.arguments.contains("--codex-agent-live-check")`
  arm at ContinuumApp.swift:3627-3628.
- **No new flag for the toggle UI.** Extend the EXISTING
  `--provider-model-picker-check` (ProviderModelPicker.swift:478) and
  `--settings-panel-check` to cover backend filtering: with the backend set to
  `.codex`, assert the picker/settings model list contains only `openai-codex/*`;
  with `.claudeCode`, only `anthropic/*`; with `.pi`, the full set. Reuse the
  fixture-catalog + `resetForQA` pattern already there. Reason: fewer new
  boot-path flags = fewer footguns, and the pure filter is already pinned in
  CoreChecks (§5.1.5).

### 5.3 Matrix inventory re-bless

Adding a CoreChecks section grows the inventory floor
(`scripts/check-matrix-inventory.sh`, run from `scripts/run-matrix.sh:126`). After
`runCodexAgentBackendChecks()` lands, re-bless and commit the updated file in the
SAME commit:
`CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh`
(regenerates `docs/38-tickets/90-agent-ux/matrix-inventory.txt`; see the tool's
own message at check-matrix-inventory.sh:113/185). Do NOT let the leg count
shrink; the two documented KNOWN-RED legs stay untouched.

### 5.4 `TokenThemed` discipline

The toggle adds one `.choice` row via the existing generic settings renderer —
no new `TokenThemed` view, so the ui-probe census (non-negotiable #8) is not
triggered. If the design instead introduces a custom control, register it per
that rule. (The recommendation avoids it.)

---

## 6. Implementation sequence (ordered; each step has its verify)

**Step 0 — enrich the fixture (5 min, optional but recommended).**
Capture a reasoning turn and an error turn so the mapping fixture is complete:
```
D=/Users/dylan/.claude/jobs/<job>/tmp/codexcap; mkdir -p "$D"; cd "$D"
codex exec --json -s workspace-write --skip-git-repo-check \
  -c model_reasoning_effort=high \
  "Think step by step about why 17 is prime, then say DONE." | tee reasoning.jsonl
```
Verify: inspect the `item.type` values for `reasoning` (and any `turn.failed`
shape). Fold into the §3.2 table.

**Step 1 — Core: pure `CodexCLIBackend` + telemetry source.**
Add `CodexCLIBackend` (in CodexAgentRunner.swift, the pure top half) and
`.codexTurnUsage` to `AgentContextWindowTelemetrySource`.
Verify: `swift build --product ContinuumRevivedCore` compiles.

**Step 2 — Core: `CodexEventTranslator`.**
Verify: rebuild `ContinuumRevivedCoreChecks`; a scratch call maps the §3.2
fixture. (Real verify comes in Step 6.)

**Step 3 — Core: `AgentRecord.codexThreadId`, `AgentRuntimeObservation.threadId`,
`AgentBackendConfig`, catalog `codexBackendModels` + `apply(codexBackendAvailable:)`.**
Verify: `swift build` (Core + iOS build leg — no `Process` reached on iOS; the
probe is macOS-gated).

**Step 4 — macOS runner: `CodexAgentRunner` (impure half) + `probeCodexBackend`.**
Verify: `swift build --product Array` (or the app) compiles.

**Step 5 — Supervisor wiring:** `extension CodexAgentRunner: AgentRunning`,
`codexRunner`/`codexRunnerConfig`, rewrite `productionRunner` via
`AgentBackendConfig.route`, persist `.threadId` in `ingestRuntimeObservation`,
add the codex construction-site assertion.
Verify: `.build/debug/Array --agent-supervisor-check` GREEN.

**Step 6 — CoreChecks: `CodexAgentBackendChecks.swift` + register in main.swift.**
Verify: `swift build --product ContinuumRevivedCoreChecks && swift run
ContinuumRevivedCoreChecks` — the new section prints its pass lines (RED first if
you stub the translator, GREEN after).

**Step 7 — UI: backend `.choice` in SettingsSchema agents section, filter
`modelOptions`, codex-auth onboarding row.**
Verify: `.build/debug/Array --settings-panel-check` and
`--provider-model-picker-check` GREEN with the new filtering assertions;
`--onboarding-panel-check` GREEN.

**Step 8 — Supervised live leg `--codex-agent-live-check`.**
Verify (manual, needs codex login): `.build/debug/Array --codex-agent-live-check`
prints `PASS: turn 2 recalled …` and confirms `codexThreadId` persisted.

**Step 9 — Re-bless matrix inventory + full gate.**
`CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh`, commit the updated
`matrix-inventory.txt` in the same commit. Confirm only the two documented
KNOWN-RED legs are red.

Commits land on `array/integration` (per CLAUDE.md); Dylan's identity only, no
AI-attribution trailers.

---

## 7. Open questions / risks

1. **Sandbox posture.** Recommended `-c sandbox_mode=workspace-write` (safer than
   claude's no-restriction `--dangerously-skip-permissions`). If Dylan wants
   exact claude/pi parity (agent can touch anything, run anywhere), use
   `danger-full-access`. Either is one string in `processArguments`. DECISION
   NEEDED from Dylan; recommend `workspace-write`.
2. **Streaming granularity.** `codex exec --json` delivers each `agent_message`
   whole (no token deltas), so the codex tile won't stream text the way the
   claude tile does — the reply appears at once when the item completes. Honest
   parity gap; acceptable for v1. Follow-up: check whether an `item.updated`
   streaming mode exists in a later codex, or whether the internal app-server
   protocol streams (out of scope here).
3. **Continuity is stored, not derived.** New `codexThreadId` record field + a new
   observation case. The self-heal (stale id → fresh exec) covers deleted/archived
   rollouts, but a user who runs `codex delete`/`archive` mid-life still starts a
   NEW thread (loses prior context) — same practical outcome as any lost session;
   surfaced as a normal new turn, not an error.
4. **"pi (all providers)" vs a separate "force pi".** The recommended default
   prefers native CLIs even under the pi option. If Dylan wants a mode that runs
   EVERYTHING through pi even when claude/codex are installed (e.g. to use pi's
   role tooling), add a 4th option; trivial (`AgentBackend.forcePi` → route
   always `.pi`). DECISION NEEDED; recommend deferring.
5. **Composer live re-filter.** If the backend can be changed while an agent
   composer is open, the footer must rebuild its model list. Cheap to wire via a
   settings-changed observation; verify during Step 7.
6. **Effort value set.** `{minimal, low, medium, high}` assumed from OpenAI
   conventions + the shipped `model_reasoning_effort=medium`. Confirm codex
   rejects/ignores unknowns gracefully; the exact-match-or-omit rule means we
   never pass an out-of-set value anyway.
7. **`provider(forID:)` location.** Lives in the app target
   (ProviderModelPicker.swift:36) but `AgentBackendConfig.filter` needs it in
   Core. Add a one-line prefix helper in Core and delegate, so the split rule is
   defined once and pinned in CoreChecks.
