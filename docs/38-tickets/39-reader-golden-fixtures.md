# Reader golden fixtures — capture real stores for shell/claude/codex/pi and replay them through the readers

## What this delivers

After this ticket, the three agent-state readers (Claude, Codex, Pi) are tested against
captured snapshots of real on-disk stores, not against live agents. Every `AgentStatus`
that a reader can emit is proven by a fixture that records the exact bytes (redacted)
that produced it. A new `// MARK: - Invariant I6: Reader status soundness` block in
`ContinuumRevivedCoreChecks` replays each fixture through its reader, asserts the
derived `AgentStatus` matches the expected value, and runs a taint assertion that
confirms no body field was ever read. The check block uses the same `expect(...)` helper
the rest of the harness uses; a failed expectation prints a `FAIL:` line and exits the
process nonzero, so the whole executable fails the build gate on any reader regression.

From the system's perspective: reader logic is now decoupled from live agents
entirely. A future change to the Claude event-stream parser, the Codex rollout
scanner, or the Pi `run.json` mapping can be verified at build time without spawning a
real CLI, without an active tmux session, and without a network call.

## How it fits

The agent-state readers themselves (Claude reader, Codex reader, Pi reader) and the
`AgentSnapshot` type they produce are the dependency this ticket builds on. Those
readers implement the `detect / locate / read` three-step protocol described in the
agent-readers spike and produce an `AgentSnapshot` carrying `{kind, status, title?,
mode?, asOf, detail?, evidence}`.

The invariant spine harness already exists at
`Sources/ContinuumRevivedCoreChecks/main.swift` with an established pattern for named
`do` blocks and the `expect(_:_:)` helper (which prints a `FAIL:` line and exits the
process nonzero on a false condition). That helper and the exit-code-0 contract are the
only harness infrastructure this ticket builds on — the I6 block is one more `do` block
in the same style. This ticket does **not** introduce or depend on any manifest-writing
infrastructure; the pass/fail signal is the process exit code plus the `expect` messages,
exactly as every existing block in the harness works today.

Once this ticket is complete, the activity tree snapshot work and the `SessionObserver`
wiring can trust that the status derivation from files is correct before any of it is
connected to a live pane. The supervisor orchestration layer that eventually multiplexes
multiple readers can be written against the same fixture corpus rather than against live
sessions.

## The approach

The work splits into two separable parts that are implemented together.

**Part 1: Fixture corpus.** Real store files are captured from this machine's `~/.claude`,
`~/.codex`, and `~/.pi` directories (and from the project-local `.pi/agent-runs/`),
redacted per the Privacy spec, and committed under
`Tests/Fixtures/agent-readers/<agent>/<scenario>/`. Redaction keeps the structural
shape, every enum value, every timestamp, and every key name intact; it replaces only
body fields (message content, task prompt text, free-text reasons, tool arguments)
with a fixed placeholder string `"<redacted>"`. The scenario directories and their
expected outcomes are the canonical set listed in the spike's golden-fixture plan —
no more, no less.

**Part 2: Replay check block.** The existing `ContinuumRevivedCoreChecks` executable
gains a `// MARK: - Invariant I6: Reader status soundness` block that iterates every
fixture scenario, instantiates the appropriate reader with the fixture's directory as
its root, calls `reader.read(...)`, and asserts (via the existing `expect(...)` helper):
(1) the derived `AgentSnapshot.status` matches the scenario's expected value; (2) the
`evidence.source` string matches the expected evidence path for that scenario; (3) the
taint assertion passes — no field in the `AgentSnapshot` contains the `"<redacted>"`
placeholder string (proving the reader never surfaced a body field into the snapshot).
Each scenario is one or more `expect(...)` calls; there is no separate artifact to write —
a scenario "passes" iff its `expect` conditions all hold and the process reaches exit 0.

Fixtures that cover a status mapping marked `[GUESS]` in the spike (primarily Codex
status inference and the Codex `turn_aborted` → idle/done decision) are additionally
marked with a `// PIN:` comment in the check block. Pinning means: the expected value
is a deliberate choice, not a derived truth — if a future real-agent observation
contradicts the pin, the fixture and pin are updated together, not silently.

The `needsAttention`-from-file path for Claude is deliberately absent from the initial
fixture corpus. The spike documents that this machine runs `bypassPermissions` mode
and no pending-permission event was observable. The check block carries a `// BLOCKED:`
comment for that scenario slot, naming what must be captured before the slot can be
filled.

## Where it lives

**New directory tree — fixture corpus:**

```
Tests/Fixtures/agent-readers/
  claude/
    claude-working/        (sessions/<pid>.json + projects/<encode-cwd>/<sessionId>.jsonl)
    claude-idle/
    claude-done/
    claude-stale/
    claude-encode-cwd/     (just the encode(cwd) transform verification; no jsonl needed)
    claude-needs-attention-BLOCKED/   (placeholder dir; empty; explains the gap)
  codex/
    codex-working/         (rollout-*.jsonl)
    codex-idle/
    codex-aborted/
    codex-linkage/         (two rollouts sharing one cwd + one non-matching)
    codex-index-stale/     (session_index.jsonl predates the rollout)
  pi/
    pi-done/               (run.json + output.json + events.jsonl)
    pi-working/
    pi-runid-link/         (project-local .pi/ + global ~/.pi/ layout)
    pi-overnight-running/  (overnight-runs/<project>/latest + status.json)
    pi-overnight-needshuman/
    pi-latest-symlink/
```

Each scenario directory contains only the files that the reader needs to open for that
scenario — nothing extraneous. The `claude-working` scenario, for example, contains
exactly one `sessions/<pid>.json` and one `projects/<encode-cwd>/<sessionId>.jsonl`
with a tail ending in `assistant(stop_reason=tool_use)` followed by a `user(tool_result)`
pair. The `pi-runid-link` scenario contains a nested `<projectRoot>/.pi/agent-runs/<runId>/`
subtree to confirm the project-local-before-global search order.

**Modified file — check harness:**

```
Sources/ContinuumRevivedCoreChecks/main.swift
```

One new `do` block: `// MARK: - Invariant I6: Reader status soundness`. It bundles all
reader scenario checks as `expect(...)` calls in the harness's established style. There
is no manifest or side-artifact — the pass signal is process exit 0 with no `FAIL:` lines,
identical to every other block in this executable. Blocked and pinned scenario slots are
recorded as `// BLOCKED:` and `// PIN:` comments in the block (see "The approach"), not as
data structures.

**Readers being tested (must already exist in Core):**

- `ClaudeStateReader` — `Sources/ContinuumRevivedCore/ClaudeStateReader.swift`
  - `func detect(processName: String) -> Bool`
  - `func locate(pid: Int, cwd: String) -> URL?` — using the `encode(cwd)` transform
  - `func read(sessionFile: URL, eventStream: URL, fileManager: FileManager, asOf: Date) -> AgentSnapshot`
- `CodexStateReader` — `Sources/ContinuumRevivedCore/CodexStateReader.swift`
  - `func detect(processName: String) -> Bool`
  - `func locate(cwd: String, afterDate: Date, root: URL, fileManager: FileManager) -> URL?`
  - `func read(rollout: URL, fileManager: FileManager, asOf: Date) -> AgentSnapshot`
- `PiStateReader` — `Sources/ContinuumRevivedCore/PiStateReader.swift`
  - `func detect(processName: String) -> Bool`
  - `func locateSingleShot(runId: String, projectRoot: URL, globalRoot: URL, fileManager: FileManager) -> URL?`
  - `func read(runDirectory: URL, fileManager: FileManager, asOf: Date) -> AgentSnapshot`
  - `func readOvernight(projectName: String, root: URL, fileManager: FileManager, asOf: Date) -> AgentSnapshot`
- `AgentSnapshot` — `Sources/ContinuumRevivedCore/AgentSnapshot.swift`
  - `kind: AgentKind`, `status: AgentStatus`, `title: String?`, `mode: String?`,
    `asOf: Date`, `detail: String?`, `evidence: AgentSnapshot.Evidence`
  - `evidence.source: String`, `evidence.lastEventType: String?`, `evidence.mtimeAgeSeconds: Double`

Key type already in Core used by the replay check:
- `AgentStatus` — the existing status enum that the whole UI already consumes
  (`configuring | working | idle | needsAttention | done | stale`), defined in the
  terminal-session-descriptor source in Core. Both the readers and `AgentSnapshot` use
  this same enum.

## Implementation breadcrumbs

```swift
// Tests/Fixtures/agent-readers/ — layout convention
//
// Each scenario dir is read by path. The check block derives the path from
// the bundle resource path (or a relative path from the executable's location
// when running under `swift build` without test infrastructure).
// Use: Bundle.module.resourceURL ?? URL(fileURLWithPath: #file)
//   .deletingLastPathComponent()          // ContinuumRevivedCoreChecks/
//   .deletingLastPathComponent()          // Sources/
//   .deletingLastPathComponent()          // repo root
//   .appendingPathComponent("Tests/Fixtures/agent-readers")
```

```swift
// Sources/ContinuumRevivedCoreChecks/main.swift
// MARK: - Invariant I6: Reader status soundness

do {
    let repoRoot = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()  // main.swift
        .deletingLastPathComponent()  // ContinuumRevivedCoreChecks/
        .deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()  // repo root
    let fixtureRoot = repoRoot.appendingPathComponent("Tests/Fixtures/agent-readers")
    let fm = FileManager.default
    let fakeNow = Date(timeIntervalSince1970: 1_800_000_000)

    // The staleness boundary. This is the reader's configurable stale window; its
    // default is 900 seconds (per the agent-readers spike and the observer-budget
    // locked decision — all reader windows are user-configurable with persisted
    // defaults). The check reads it from the reader's own default constant so the
    // fixture boundary and the reader logic can never drift apart — do NOT hardcode
    // a bare 900 literal here.
    let staleWindow = ClaudeStateReader.defaultStaleWindowSeconds  // == 900 (the shipped default)

    // Each scenario is a (label, closure → AgentSnapshot, expected AgentStatus, expected evidence source prefix)
    // The closure receives the fixture directory URL.

    // --- Claude: working ---
    let claudeWorkingDir = fixtureRoot.appendingPathComponent("claude/claude-working")
    let claudePidFile = claudeWorkingDir.appendingPathComponent("sessions/12345.json")
    let claudeJsonlFile = claudeWorkingDir.appendingPathComponent(
        "projects/-tmp-claude-working/aaaabbbb-0000-4000-8000-000000000001.jsonl")
    let claudeWorkingSnap = ClaudeStateReader().read(
        sessionFile: claudePidFile,
        eventStream: claudeJsonlFile,
        fileManager: fm,
        asOf: fakeNow)
    expect(claudeWorkingSnap.status == .working,
        "I6 claude-working: tool_use tail + busy pid yields .working")
    expect(claudeWorkingSnap.evidence.source.hasPrefix("claude:"),
        "I6 claude-working: evidence.source names the claude reader")
    expect(!claudeWorkingSnap.taintCheck(),
        "I6 claude-working: no redacted placeholder leaks into the snapshot")

    // --- Claude: encode-cwd ---
    // encode(cwd) rule: every '/' and '.' maps to '-'
    let encoded = ClaudeStateReader.encodeCwd("/Users/dylan/.claude/worktrees/foo.bar")
    expect(encoded == "-Users-dylan--claude-worktrees-foo-bar",
        "I6 claude-encode-cwd: '/' → '-' and '.' → '-' (double-dash for /.)")

    // --- Claude: stale (mtime beyond the stale window ⇒ never .working) ---
    // Set the jsonl mtime explicitly to fakeNow - (staleWindow + 1) BEFORE reading,
    // so the boundary is deterministic across machines (git checkout mtime is useless
    // here — see "Watch out for"). setFixtureMtime is a tiny local helper in this
    // block that calls utimes(2) on the file (see the mtime helper breadcrumb below).
    let claudeStaleDir = fixtureRoot.appendingPathComponent("claude/claude-stale")
    let claudeStaleJsonl = claudeStaleDir.appendingPathComponent(
        "projects/-tmp-claude-stale/aaaabbbb-0000-4000-8000-000000000009.jsonl")
    setFixtureMtime(claudeStaleJsonl, to: fakeNow.addingTimeInterval(-(staleWindow + 1)), fm: fm)
    let claudeStaleSnap = ClaudeStateReader().read(
        sessionFile: claudeStaleDir.appendingPathComponent("sessions/99999.json"),
        eventStream: claudeStaleJsonl,
        fileManager: fm,
        asOf: fakeNow)
    expect(claudeStaleSnap.status != .working,
        "I6 claude-stale: mtime beyond staleWindow never yields .working, regardless of jsonl tail")

    // --- Codex: linkage (two rollouts, same cwd, pick newest by mtime) ---
    let codexLinkageDir = fixtureRoot.appendingPathComponent("codex/codex-linkage")
    let codexSession = fixtureRoot.appendingPathComponent("codex/codex-linkage/sessions")
    let located = CodexStateReader().locate(
        cwd: "/tmp/shared-cwd",
        afterDate: Date(timeIntervalSince1970: 1_799_990_000),
        root: codexLinkageDir,
        fileManager: fm)
    expect(located != nil, "I6 codex-linkage: locate finds a matching rollout")
    // fixture has two rollouts for /tmp/shared-cwd; the newest by mtime must win
    expect(located?.lastPathComponent.contains("rollout-newer") == true,
        "I6 codex-linkage: most-recent mtime wins among same-cwd rollouts")

    // --- Codex: index-stale (session_index.jsonl is behind the rollout) ---
    let codexIndexStaleDir = fixtureRoot.appendingPathComponent("codex/codex-index-stale")
    let codexIdleSnap = CodexStateReader().read(
        rollout: codexIndexStaleDir
            .appendingPathComponent("sessions/2026/06/30/rollout-newer.jsonl"),
        fileManager: fm,
        asOf: fakeNow)
    // The reader must not require the index for the active session
    expect(codexIdleSnap.kind == .codex,
        "I6 codex-index-stale: kind is codex even when index is stale")

    // PIN: codex turn_aborted → .idle (deliberate choice; update fixture + pin together if real data contradicts)
    let codexAbortedDir = fixtureRoot.appendingPathComponent("codex/codex-aborted")
    let codexAbortedSnap = CodexStateReader().read(
        rollout: codexAbortedDir.appendingPathComponent("sessions/2026/06/30/rollout-aborted.jsonl"),
        fileManager: fm,
        asOf: fakeNow)
    expect(codexAbortedSnap.status == .idle,
        "I6 codex-aborted: turn_aborted tail maps to .idle (PINNED)")

    // --- Pi: project-local before global ---
    let piRunIdDir = fixtureRoot.appendingPathComponent("pi/pi-runid-link")
    let located2 = PiStateReader().locateSingleShot(
        runId: "code-reviewer-20260611T124657Z-884e9d",
        projectRoot: piRunIdDir.appendingPathComponent("project"),
        globalRoot: piRunIdDir.appendingPathComponent("global"),
        fileManager: fm)
    expect(located2?.path.contains("project/.pi") == true,
        "I6 pi-runid-link: project-local .pi takes priority over global ~/.pi")

    // --- Pi: overnight needsHuman ---
    let piOvernightNHDir = fixtureRoot.appendingPathComponent("pi/pi-overnight-needshuman")
    let piNHSnap = PiStateReader().readOvernight(
        projectName: "continuum-revived",
        root: piOvernightNHDir,
        fileManager: fm,
        asOf: fakeNow)
    expect(piNHSnap.status == .needsAttention,
        "I6 pi-overnight-needsHuman: stopped+matrix-failure-needs-human → .needsAttention")
    // reason must be truncated/allowlisted — the free-text 'W06 matrix failed: …' is scrubbed
    if let detail = piNHSnap.detail {
        expect(!detail.contains("<redacted>"),
            "I6 pi-overnight-needsHuman: detail contains an allowlisted code, not a redacted body")
        expect(detail.count <= 80,
            "I6 pi-overnight-needsHuman: detail is truncated to ≤80 chars")
    }

    // --- Taint assertions across every scenario snapshot ---
    let allSnaps = [claudeWorkingSnap, claudeStaleSnap, codexIdleSnap, codexAbortedSnap, piNHSnap]
    for snap in allSnaps {
        expect(!snap.taintCheck(),
            "I6 taint: no AgentSnapshot field contains the <redacted> placeholder")
    }

    // --- Taint helper must not be vacuously false ---
    // Prove taintCheck() actually catches a tainted field, so a green taint run means
    // "clean", not "the check does nothing".
    let tainted = AgentSnapshot(
        kind: .claude, status: .idle, title: "<redacted>", mode: nil,
        asOf: fakeNow, detail: nil,
        evidence: AgentSnapshot.Evidence(source: "claude:jsonl-tail",
                                         lastEventType: "assistant", mtimeAgeSeconds: 5))
    expect(tainted.taintCheck(),
        "I6 taint-helper: taintCheck() returns true on a snapshot whose title is <redacted>")

    // --- BLOCKED: claude-needs-attention-from-file ---
    // Requires a fixture captured in default (non-bypass) permission mode with a live
    // PermissionRequest. This machine uses bypassPermissions; the scenario is absent.
    // The hook-breadcrumb path (Notification → .needsAttention) is the reliable source
    // until this fixture is captured. Do NOT implement file-derived needsAttention for
    // Claude until the fixture exists.
    //
    // PINNED mappings recorded as comments (no data structure): codex-aborted → .idle.
}
```

```swift
// mtime helper — used only inside the I6 block to make stale/fresh boundaries
// deterministic. Sets a file's modification time via utimes(2). The committed
// git-checkout mtime is wall-clock and cannot be relied on (see "Watch out for").
func setFixtureMtime(_ url: URL, to date: Date, fm: FileManager) {
    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}
```

```swift
// AgentSnapshot.swift — taint helper (add alongside the struct)
extension AgentSnapshot {
    /// Returns true if any string field in the snapshot contains the redaction
    /// placeholder — which would prove the reader surfaced a body field.
    func taintCheck() -> Bool {
        let placeholder = "<redacted>"
        let fields: [String?] = [title, mode, detail, evidence.source, evidence.lastEventType]
        return fields.compactMap { $0 }.contains { $0.contains(placeholder) }
    }
}
```

```swift
// ClaudeStateReader.swift — encode(cwd) must be a static, pure, testable function
extension ClaudeStateReader {
    /// The default staleness window in seconds. A file whose mtime is older than this
    /// (relative to asOf) never yields .working. This is the shipped default (900 s);
    /// it is user-configurable per the configurable-first doctrine, but the check block
    /// and the reader must read the SAME named constant so they can't drift.
    static let defaultStaleWindowSeconds: Double = 900

    /// Encodes a cwd path into the ~/.claude/projects/ directory name.
    /// Rule: every '/' and '.' maps to '-'. No other transform.
    /// Confirmed: '/Users/dylan/.claude/worktrees/foo' → '-Users-dylan--claude-worktrees-foo'
    /// The double dash in '--claude' is '/' (→'-') + '.' (→'-') adjacently.
    static func encodeCwd(_ cwd: String) -> String {
        cwd.map { $0 == "/" || $0 == "." ? "-" : $0 }.joined()  // Swift.Character → String map
    }
}
```

**Fixture redaction rules (enforced at capture time, not at read time):**

```
// For each fixture file:
// KEEP: all key names, all enum values (type/status/state/stop_reason/payload.type),
//       all timestamps, all counts (messageCount, iterations), all file/dir names.
// REPLACE with "<redacted>":
//   Claude:  .message.content[*] (text/thinking), toolUseResult bodies,
//            ai-title.aiTitle, agent-name values, last-prompt content
//   Codex:   event_msg.payload.agent_message / user_message bodies,
//            response_item.payload (function_call args, function_call_output, message text),
//            turn_context.payload.summary, session_meta.payload.base_instructions
//   Pi:      run.json .task (truncate to first 40 chars, then append "…<redacted>"),
//            output.json .final .stderr (entire objects), events.jsonl .args
//            overnight status.json .reason (replace with allowlisted code or "<redacted>")
// NEVER include: ~/.codex/auth.json, any credential or token file
```

## How we test it

### Logic (pure Core checks)

The `ContinuumRevivedCoreChecks` executable is the logic test. Running
`swift build` and then the built executable must exit with code 0.

Specific assertions the I6 block covers, beyond what the existing invariant spine harness
checks:

- `ClaudeStateReader.encodeCwd` maps `/` → `-` and `.` → `-` correctly, including the
  double-dash case that arises when `/` and `.` are adjacent (e.g. `/.claude` → `--claude`).
- `ClaudeStateReader.read(...)` on the `claude-working` fixture yields `status == .working`
  and `evidence.source` starting with `"claude:"`.
- `ClaudeStateReader.read(...)` on the `claude-stale` fixture (mtime set explicitly to
  `fakeNow - (staleWindow + 1)`, where `staleWindow` is `ClaudeStateReader.defaultStaleWindowSeconds`
  == 900 s, the shipped configurable default) yields `status != .working` regardless of the
  jsonl tail. The fresh scenarios set mtime to `fakeNow - 5`.
- `CodexStateReader.locate(cwd:afterDate:root:fileManager:)` on the two-rollout fixture
  returns the rollout whose file mtime is newest, not the first alphabetically.
- `CodexStateReader.locate(...)` on the `codex-linkage` fixture with `afterDate` set
  to before both rollouts returns the newer by mtime; with `afterDate` set to after
  the newer rollout's creation, it returns `nil` (no rollout created after tile spawn).
- `PiStateReader.locateSingleShot(runId:projectRoot:globalRoot:fileManager:)` on the
  `pi-runid-link` fixture prefers the project-local `.pi/agent-runs/<runId>/` directory
  over the global `~/.pi/agent-runs/<runId>/` directory.
- `PiStateReader.readOvernight(...)` on the `pi-overnight-needshuman` fixture resolves
  the `latest` symlink, reads `status.json`, maps `state=stopped` +
  `reason=matrix-failure-needs-human` to `.needsAttention`, and truncates `detail` to
  an allowlisted code (not the raw free-text reason).
- Taint assertion passes for every scenario snapshot: no `AgentSnapshot` field
  contains the `"<redacted>"` placeholder string.
- `AgentSnapshot.taintCheck()` returns `true` when a snapshot is artificially
  constructed with `title: "<redacted>"` and `false` when all fields are clean —
  proving the taint helper is not vacuously false.

### Backend (real-path / integration)

The fixture-replay check is pure: it reads files from the committed fixture corpus,
not from live agent processes. There is no network, no tmux daemon, and no spawned
agent in the logic-check path.

The one real-path check is the filesystem round-trip of the `InvariantManifest`: the
I6 block writes the manifest to a temp directory, reads it back, and asserts the
decoded manifest equals the original — a real filesystem write/read on the CI runner.
This is the same pattern established by the invariant spine harness ticket.

The `pi-latest-symlink` scenario creates a real symlink within the fixture directory
at fixture-preparation time (committed as a symlink via `git`). The check reads through
it using `FileManager.default` without resolving manually, confirming the reader handles
`latest → run-<ts>` correctly on the real filesystem.

### UX (visual gate + dogfood snippet)

The readers themselves have no direct canvas UI in this ticket — their output reaches
the UI through `AgentDescriptor.status` which the sidebar tree and tile rollup badges
already consume. This ticket is deliberately decoupled from that wiring. There is no
visual gate for the fixture check alone.

The dogfood snippet for the logic path is:

Open Terminal at the project root and run:
```
swift build 2>&1 | grep -E "(error:|warning:|Build complete)"
.build/debug/ContinuumRevivedCoreChecks 2>&1 | grep -E "^(FAIL|MARK)"
echo "exit: $?"
```

A passing run prints no `FAIL:` lines on stderr and exits with code 0. The `MARK:` lines
confirm each invariant block ran. The manifest file path is printed by the I6 block;
opening it shows entries like:
```json
{
  "invariantId": "I6-reader-status-soundness",
  "measurements": {
    "claude_working": "pass",
    "codex_aborted": "pass",
    "blocked_scenarios": ["claude-needs-attention-from-file"],
    "taint_checks_passed": true,
    ...
  },
  "outcome": "pass"
}
```

Once the reader wiring into `SessionObserver` is complete (in a subsequent ticket), the
full dogfood path becomes: open Continuum → activate a tile running `claude` → observe
the sidebar badge transition from grey (configuring) to blue (working) within two poll
cycles (at most 1 second with default debounce). That verification lives in the wiring
ticket, not here.

## Execution mode

**Autonomous.** Every check in this ticket is a pure file-read against the committed
fixture corpus. There are no live agents, no tmux sessions, no clock-sensitive paths
(all mtimes in the fixtures are fixed relative to `fakeNow`), and no network calls. The
matrix runs the `ContinuumRevivedCoreChecks` executable and checks the exit code. The
fixture files are committed to the repo, so the check is reproducible on any machine
and on any CI runner. The `pi-latest-symlink` case uses a real filesystem symlink
committed via git, which macOS and Linux CI runners handle natively. No human eyes are
needed to verify the result; the manifest file provides the audit trail.

## Done when

- [ ] `Tests/Fixtures/agent-readers/` directory tree exists with all scenario
  directories listed in "Where it lives", each containing the minimum files the
  corresponding reader needs for that scenario.
- [ ] Every fixture file has been redacted per the rules in "Implementation breadcrumbs":
  no body field, no message content, no tool arguments, no credential appears verbatim;
  only the `"<redacted>"` placeholder appears in body-field positions.
- [ ] `Tests/Fixtures/agent-readers/pi/pi-latest-symlink/overnight-runs/continuum-revived/latest`
  is a committed git symlink pointing to a sibling `run-<ts>` directory.
- [ ] `AgentSnapshot.taintCheck() -> Bool` is defined on `AgentSnapshot` and returns
  `true` if any string field contains `"<redacted>"`, `false` otherwise. A test in the
  I6 block proves the helper is not vacuously false by asserting it returns `true` on a
  hand-crafted tainted snapshot.
- [ ] `ClaudeStateReader.encodeCwd(_:) -> String` is a `static` function and the I6
  block asserts the `/` + `.` → `-` double-dash case specifically.
- [ ] The `// MARK: - Invariant I6: Reader status soundness` block exists in
  `Sources/ContinuumRevivedCoreChecks/main.swift` and covers all non-blocked scenarios.
- [ ] The blocked scenario (`claude-needs-attention-from-file`) has a `// BLOCKED:`
  comment in the check block explaining why and what precondition must be met before
  the slot can be filled.
- [ ] The `codex-aborted` scenario outcome is pinned with a `// PIN:` comment
  documenting that `turn_aborted` → `.idle` is a deliberate choice, not a verified
  mapping, and that the fixture and pin must be updated together if real-agent
  observation contradicts it.
- [ ] `swift build` succeeds with no warnings in `ContinuumRevivedCore` and
  `ContinuumRevivedCoreChecks`.
- [ ] Running `.build/debug/ContinuumRevivedCoreChecks` exits with code 0.
- [ ] The I6 manifest written to the temp directory has `outcome: "pass"` and a
  `measurements` entry for every non-blocked scenario with value `"pass"`.
- [ ] The I6 block round-trips its own `InvariantManifest` through
  `InvariantManifestWriter` + `JSONDecoder` and asserts equality, confirming real
  filesystem write/read.

## Depends on / unblocks

This ticket depends on the three readers — the Claude state reader, the Codex state
reader, and the Pi state reader — being implemented and callable with a filesystem root
parameter. It also depends on the `AgentSnapshot` type being defined and the
`AgentStatus` enum at `TerminalSessionDescriptor.swift:85` being the enum both readers
and the snapshot use. The invariant spine harness must exist (the `InvariantManifest`
type, `InvariantManifestWriter`, and the `expect(...)` helper pattern in
`ContinuumRevivedCoreChecks`).

What this ticket unblocks: the `SessionObserver` wiring work can proceed knowing that
every status derivation path has been proven against a real fixture before it is
connected to a live pane. The activity tree snapshot, which aggregates `AgentSnapshot`
values into a per-tile status summary for the sidebar and canvas rollup badges, can
be written against the same fixture corpus rather than against live sessions. Any future
reader for an additional agent (a managed-agent tier, for example) has a clear fixture
convention and taint check pattern to follow from day one.

## Watch out for

**The hardest thing to get right is fixture mtime handling.** The readers use file
mtime as the evidence clock (`asOf = file mtime`). Committed fixture files have their
mtime set by `git checkout`, which uses the current wall-clock time — not the timestamp
embedded in the file's content. This means a `claude-stale` fixture whose jsonl tail
ends in a "fresh" event will have a fresh mtime on checkout, and the reader will not
see it as stale. The correct fix is to set mtime explicitly in the check block using
`FileManager` extended attributes or a `utimes(2)` call on the fixture file, not to
rely on the committed mtime. The check block must set the fixture files' mtimes to
`fakeNow - (staleWindow + 1)` for stale scenarios and to `fakeNow - 5` for fresh
scenarios, immediately before passing the URLs to the reader. Do not omit this step —
it is the only way to make the stale/fresh boundary assertions deterministic across
machines.

**Codex's `locate` function must not open any file except `session_meta` (line 1) of
each rollout.** The scan iterates newest-mtime-first and opens rollouts until it finds
one whose `session_meta.payload.cwd` matches. Opening subsequent lines of each rollout
to search for additional metadata violates the budget discipline and the Privacy spec
(later lines may contain body events). The fixture corpus for `codex-linkage` includes
a rollout file where the `session_meta` is line 1 and lines 2–N contain body events
with `"<redacted>"` placeholders; the taint assertion confirms the reader never surfaced
those lines.

**The `pi-runid-link` fixture must reproduce the real run-directory naming format
exactly.** The format is `<roleId>-yyyyMMdd'T'HHmmss'Z'-<6-char-suffix>` (from
`HarnessRoleRun.swift:73`). A fixture directory named with a different format (e.g.
lowercase T or a different separator) will silently cause `locateSingleShot` to not
find the directory, and the check will fail with a confusing nil-assertion rather than
a clear name-format mismatch. Use `code-reviewer-20260611T124657Z-884e9d` verbatim as
the runId in the fixture, matching the real example from the spike.

**`ClaudeStateReader` must use `.cwd` from the pid file, not the tmux pane cwd, to
build the `encode(cwd)` project path.** The spike is explicit: OSC-7 drift can desync
the pane cwd from the cwd the Claude process was actually started in. The pid file's
`.cwd` field is authoritative. The fixture for `claude-working` must include a pid file
whose `.cwd` differs slightly from the `projects/` directory name to make this path
observable — e.g. a trailing `/` that the encode strips — so the check proves the
reader is reading `.cwd` from the pid file and not guessing from somewhere else.

**Do not implement file-derived `needsAttention` for Claude until the blocked fixture
exists.** The spike documents that `needsAttention` from the jsonl for Claude is
`[GUESS]` — unconfirmed because this machine runs `bypassPermissions`. The check block
carries a `// BLOCKED:` comment for this scenario. Shipping an unproven
`needsAttention` path without the fixture risks the reader emitting false attention
signals on real users' sessions, which is a worse outcome than under-claiming to
`working` or `idle`. The hook-breadcrumb path (`Notification` and `PermissionRequest`
hook events writing a breadcrumb file) is the reliable path and must be the only source
of `needsAttention` for Claude until the blocked fixture is captured in
non-bypass-permissions mode.
