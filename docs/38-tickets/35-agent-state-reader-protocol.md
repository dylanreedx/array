# AgentStateReader protocol and AgentSnapshot type

## What this delivers

After this ticket, the codebase has a formally typed, I5-clean contract that every
per-agent reader must satisfy: a `detect` predicate, a `locate` function, and a `read`
function returning an `AgentSnapshot`. It also defines `AgentSnapshot` itself — the
metadata-only, body-free transport type that carries a status verdict, a short title,
a permission mode, an evidence record, and nothing else. The `AgentKind` closed enum
lives here too, replacing the free `String` that `AgentDescriptor.agentKind` currently
carries.

No reader is implemented by this ticket (Claude, Pi, and Codex each get their own). No
observer is wired. What ships is the protocol shape, the snapshot type, and the golden
I5 fixture that proves — at test time — that the snapshot cannot physically hold a
message body. Downstream tickets that implement the concrete readers, the kind
classifier, and the session observer all import and conform to exactly what is defined
here.

## How it fits

This ticket sits at the centre of Phase 3 (agent awareness base). It depends on the
`agentKind` closed-enum ticket, which changes `AgentDescriptor.agentKind` from `String`
to the enum and is the only prerequisite. Everything in the reader tier — the Pi reader,
the Claude reader, the Codex reader, the reader golden fixtures, the session observer
with its budgets, the FSEvents push watch, and the hook-consent flow — imports the
protocol and snapshot type defined here. None of those tickets can be written without
this contract.

The snapshot type also has a structural relationship with the activity tree snapshot:
the session observer will stamp `AgentSnapshot.status` into `AgentDescriptor.status`
and `AgentSnapshot.asOf` into `AgentDescriptor.statusUpdatedAt`, so the existing
`AgentStatusEngine` and the fields on `TerminalSessionDescriptor.agentDescriptor`
continue to be the live write target; the snapshot is the evidence bundle that
travels through the reader, not a replacement for those fields.

## The approach

Define two new types and one protocol, all in
`Sources/ContinuumRevivedCore/`, all pure Swift with no runtime dependencies (no
Foundation I/O; `URL` and `Date` are used in signatures but nothing is opened or
read by this code). Keep the types `Codable`, `Equatable`, and `Sendable` throughout
so they slot cleanly into the snapshot-at-every-seam discipline that phase 0 establishes.

`AgentKind` is a closed enum (`shell | claude | codex | pi | managed | unknown`) that
replaces the free `String` currently on `AgentDescriptor.agentKind`. This ticket
defines it; the `agentKind` closed-enum ticket (the dependency) changes `AgentDescriptor`
to use it. You will update `AgentDescriptor` here only to the extent the dependency
ticket has already done so — do not re-open or redefine the enum itself.

`AgentSnapshot` is the body-free metadata bundle a reader returns. Every field is a
deliberate choice grounded in the privacy spec from `AGENT-READERS.md`:

- `kind: AgentKind` — which agent type produced this snapshot.
- `status: AgentStatus` — the status verdict; maps to the existing enum at
  `TerminalSessionDescriptor.swift:85`.
- `title: String?` — short human label (ai-title, run.json.task, thread_name),
  truncated to 80 characters. Display metadata only, never a prompt body.
- `mode: String?` — permission/approval mode string
  (`bypassPermissions | normal | <approval_policy>`). An enum value string, never
  content.
- `asOf: Date` — the evidence clock, always file mtime of the authoritative store
  file, never `Date()`. The reader is handed this value from the observer; it must
  not call `Date()` itself. This enforces the wall-clock ban.
- `detail: String?` — a short, allowlist-only reason string (e.g. Pi's
  `status.json.reason` when it matches a known code). Free-text reasons are dropped,
  not truncated-and-forwarded.
- `evidence: Evidence` — the I6 soundness record: what store file and event type
  backed this verdict.

`AgentStateReader` is a protocol with three requirements:

```swift
public protocol AgentStateReader: Sendable {
    var kind: AgentKind { get }

    func detect(processName: String) -> Bool
    // Returns true if this reader owns the given pane_current_command value.

    func locate(pid: pid_t?, cwd: String, runId: String?) -> URL?
    // Returns the URL of the authoritative store file/directory for this agent,
    // given what the observer knows at locate-time. Returns nil if no store
    // is found — the observer treats nil as "no deep status, show shell/unknown."

    func read(storeURL: URL, asOf: Date) -> AgentSnapshot
    // Reads metadata from the store at storeURL. asOf is the file mtime the
    // observer observed before calling; the reader must use it as the evidence
    // clock and must not open any file not under storeURL's logical tree.
    // Must never block for longer than the observer's per-read budget.
    // Must never return a snapshot whose fields contain message bodies.
}
```

The `AgentSnapshot.Evidence` nested type carries:

```swift
public struct Evidence: Codable, Equatable, Sendable {
    public var source: String
    // One of: "claude:sessions/pid.json", "claude:jsonl-tail",
    //         "codex:rollout-tail", "pi:run.json", "pi:status.json", "hook"
    public var lastEventType: String?
    // The enum value string of the last meaningful event (e.g. "assistant",
    // "finished", "task_started"). Never a content field.
    public var mtimeAgeSeconds: Double
    // How stale the store was at read time: observer's wall-clock minus asOf,
    // in seconds. Used by the derivation function for freshness windows.
}
```

The I5 invariant (sync-boundary purity) is enforced structurally by `AgentSnapshot`'s
type: there is no field that can hold a pid, a pane target, a host-local handle, or a
transcript body. The taint scan for I5 (a separate ticket) confirms this at the
type-system level. This ticket's test contribution is a golden fixture proving the
snapshot cannot be constructed with any body-adjacent content without a deliberate
truncation/allowlist step.

## Where it lives

New file: `Sources/ContinuumRevivedCore/AgentStateReader.swift` — holds `AgentKind`
(if the closed-enum ticket has not already placed it elsewhere), `AgentSnapshot`,
`AgentSnapshot.Evidence`, and the `AgentStateReader` protocol.

Seam 1: `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:94` —
`AgentDescriptor.agentKind` is currently `String`; once the closed-enum dependency
lands it becomes `AgentKind`. This ticket does not touch `AgentDescriptor` itself but
its types must be consistent with it.

Seam 2: `Sources/ContinuumRevivedCore/AgentStatusEngine.swift:1–112` — the engine's
`Signal` and `Configuration` types are not changed here, but the session observer
(a later ticket) will feed `AgentSnapshot.status` into the engine as an `.explicit`
signal. Understanding the engine's contract is necessary context for designing the
snapshot's `status` field correctly.

Seam 3: `Sources/ContinuumRevivedCore/RunArtifactsReader.swift:78–89` —
`RunArtifactsReader.read(runDirectory:)` is the existing pattern for a pure, no-I/O
reader function. `AgentStateReader.read(storeURL:asOf:)` follows the same discipline:
no side effects, no state mutation, returns a value type. The Pi reader (a later ticket)
will largely be `RunArtifactsReader` generalised to return an `AgentSnapshot`.

New test file: `Tests/ContinuumRevivedCoreTests/AgentStateReaderTests.swift`.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCore/AgentStateReader.swift

import Foundation

// AgentKind: defined here OR imported from the closed-enum ticket's file.
// Confirm with the dependency before duplicating.
public enum AgentKind: String, Codable, Equatable, Sendable, CaseIterable {
    case shell
    case claude
    case codex
    case pi
    case managed
    case unknown
}

public struct AgentSnapshot: Codable, Equatable, Sendable {

    public struct Evidence: Codable, Equatable, Sendable {
        public var source: String          // e.g. "pi:run.json"
        public var lastEventType: String?  // enum value only, never content
        public var mtimeAgeSeconds: Double

        public init(source: String, lastEventType: String?, mtimeAgeSeconds: Double) { … }
    }

    public var kind: AgentKind
    public var status: AgentStatus         // the existing enum from TerminalSessionDescriptor.swift
    public var title: String?              // truncated to 80 chars; nil if unavailable
    public var mode: String?               // enum-value string; nil if unavailable
    public var asOf: Date                  // file mtime; set by the observer, echoed by the reader
    public var detail: String?             // allowlisted code string only
    public var evidence: Evidence

    public init(kind: AgentKind, status: AgentStatus, title: String?,
                mode: String?, asOf: Date, detail: String?, evidence: Evidence) {
        self.kind = kind
        self.status = status
        // Enforce truncation at construction time — never let a caller sneak in a long string.
        self.title = title.map { String($0.prefix(80)) }
        self.mode = mode
        self.asOf = asOf
        // detail must be a known-safe code; callers pass nil when the raw value is not allowlisted.
        self.detail = detail
        self.evidence = evidence
    }
}

public protocol AgentStateReader: Sendable {
    var kind: AgentKind { get }
    func detect(processName: String) -> Bool
    func locate(pid: pid_t?, cwd: String, runId: String?) -> URL?
    func read(storeURL: URL, asOf: Date) -> AgentSnapshot
}
```

When implementing a concrete reader later, the pattern is:
1. `detect` returns `true` for the exact `pane_current_command` values this reader owns
   (e.g. `"claude"` for the Claude reader, `"pi"` for the Pi reader).
2. `locate` looks at the filesystem synchronously and returns the store URL, or `nil`.
   It does not read any file content — it only constructs and probes paths.
3. `read` opens only the files under `storeURL` that are enumerated in the `AGENT-READERS.md`
   per-agent section. It extracts metadata fields only. It returns a snapshot with
   `asOf` set to the `asOf` parameter it received — it does not call `Date()` or
   `FileManager.attributesOfItem` for the clock; that clock is the observer's job.

The `unknown` fallback: if `detect` returns false for all registered readers, the
observer synthesises a snapshot directly without calling any reader:

```swift
AgentSnapshot(
    kind: .shell,     // or .unknown if processName is not a shell
    status: processIsAlive ? .idle : .done,
    title: nil, mode: nil,
    asOf: paneMtimeProxy,
    detail: nil,
    evidence: Evidence(source: "tmux:pane_current_command",
                       lastEventType: processName,
                       mtimeAgeSeconds: 0)
)
```

This preserves the I6 rule: unknown ⇒ never `working`, never `needsAttention`.

## How we test it

### Logic (pure Core checks)

All tests run against the types alone — no filesystem, no process, no clock
(`Date()` is never called in this code).

**Round-trip (I7).** Encode an `AgentSnapshot` to JSON, decode it back, assert equal.
Cover every `AgentStatus` case and both nil/non-nil optionals.

**Title truncation.** Construct a snapshot with a 200-character title; assert
`snapshot.title!.count == 80`.

**I5 structural proof.** Write a compile-time-enforced test: iterate all stored
properties of `AgentSnapshot` via `Mirror`, confirm none is named `pid`, `paneTarget`,
`body`, `content`, `message`, `toolInput`, `toolOutput`, `prompt`, or `credential`.
This is the reader-layer contribution to the I5 taint scan: the type cannot hold a
body field by name. (The full I5 scan over the synced payload is a separate ticket.)

**Protocol conformance.** Write a `MockReader: AgentStateReader` with configurable
return values; assert `detect`, `locate`, and `read` satisfy the protocol — no crash,
correct return types. Assert that a reader returning `status: .working` with
`evidence.mtimeAgeSeconds > 900` is flagged as stale by the caller
(`AgentSnapshot` itself does not enforce staleness — that is the derivation function's
job — but the test documents that `mtimeAgeSeconds` is the correct signal for callers
to inspect).

**AgentKind exhaustiveness.** Assert `AgentKind.allCases.count == 6` and that each
case round-trips its `rawValue`. If a case is added without updating the golden count,
this test fails — a cheap invariant for the closed-enum contract.

### Backend (real-path integration)

The reader protocol itself has no I/O, so there is no real-path check at this layer.
The real-path checks live in the concrete reader tickets (Pi reader, Claude reader,
Codex reader) and in the session observer ticket, which calls into the registry on a
real tmux pane. This ticket's backend contribution is a compilation-only build check:
`xcodebuild build -scheme ContinuumRevived` must pass with the new protocol in place
before any reader is implemented, confirming no seam breakage.

### UX (visual gate + dogfood snippet)

There is no UI change in this ticket — it is a pure protocol and type definition.
The UX gate lives in the session observer ticket and the mock-rollup replacement, which
feed the sidebar and canvas chrome with real `AgentSnapshot` data.

The dogfood snippet therefore covers the post-condition an implementer should confirm
once the first concrete reader (Pi reader) is wired through the observer: open the app,
focus a tile that was spawned by Continuum's harness and has a completed pi run on
disk, navigate to the sidebar or the tile chrome, and confirm the status badge reads
"done" with a green check and the title shows the run's task label — not a mock value
and not "unknown". This snippet belongs in the observer and Pi reader tickets; it is
documented here so the implementer knows what the full chain looks like.

## Execution mode

Autonomous. The entire ticket is a type and protocol definition with pure-logic tests.
Nothing opens a file, talks to tmux, or touches the UI. Every check is a core check
assertable in the standard XCTest matrix with no human eyes and no real cloud or device.
The one build-pass check is also machine-verifiable. The UX gate is deferred to the
concrete reader and observer tickets that actually produce visible output.

## Done when

- [ ] `AgentSnapshot`, `AgentSnapshot.Evidence`, and `AgentStateReader` compile cleanly
  in `ContinuumRevivedCore` with no warnings.
- [ ] `AgentDescriptor.agentKind` is `AgentKind` (not `String`) — confirmed by the
  closed-enum dependency having landed; this ticket's code compiles against it.
- [ ] Round-trip test passes: every `AgentStatus` case survives JSON encode → decode →
  equal with an `AgentSnapshot` wrapping it.
- [ ] Title-truncation test passes: a 200-character title is silently clamped to 80.
- [ ] I5 structural test passes: `Mirror` scan finds no body-adjacent field names on
  `AgentSnapshot`.
- [ ] `AgentKind.allCases.count == 6` test passes.
- [ ] `MockReader: AgentStateReader` compiles and all `detect`/`locate`/`read` tests pass.
- [ ] Full `xcodebuild build -scheme ContinuumRevived` passes (no regressions from
  adding the new file).
- [ ] No `Date()` call appears anywhere in `AgentStateReader.swift` (grep confirms).
- [ ] No `FileManager` or file-read call appears anywhere in `AgentStateReader.swift`
  (grep confirms; the protocol is a shape, not an implementation).

## Depends on / unblocks

Depends on the `agentKind` closed-enum ticket, which must have landed and changed
`AgentDescriptor.agentKind` to `AgentKind` before this ticket can compile cleanly.
It also implicitly depends on the existing `AgentStatus` enum at
`TerminalSessionDescriptor.swift:85` remaining stable — which is true, as no Phase 3
ticket changes that enum.

Directly unblocks: the Pi reader, the Claude reader, the Codex reader, the reader golden
fixtures, and the kind classifier from tmux. All of those tickets open with "import and
conform to `AgentStateReader`." The session observer depends on all the readers, so it
is transitively unblocked here too. The mock-rollup replacement and the sidebar feed
sit further downstream and depend on the observer.

## Watch out for

**The `asOf` clock discipline is the hardest thing to get right.** The `read` function
receives `asOf` from the observer — the mtime the observer measured before handing
off to the reader. The reader must echo this value into `AgentSnapshot.asOf` unchanged
and must not call `Date()` or re-stat the file. If a reader sets `asOf = Date()`, it
breaks the staleness window calculation (the derivation function computes
`mtimeAgeSeconds = now − asOf`; if `asOf` is always "just now", nothing ever goes stale).
The wall-clock ban is enforced in the invariant spine; the `no Date() call` grep in the
Done criteria is the local gate.

**`AgentKind` must not be defined twice.** The closed-enum ticket defines the enum;
this ticket uses it. If both files declare `enum AgentKind`, you get a duplicate-type
error. Confirm where the closed-enum ticket placed it and import from there — do not
re-declare.

**The `detect` contract for `node`-shimmed agents.** The AGENT-READERS spike confirmed
that Codex may report `pane_current_command == "node"` rather than `"codex"`, and that
`pi` sets `process.title` so it reliably reports `"pi"`. The `AgentStateReader`
protocol does not solve this ambiguity — it hands the raw `pane_current_command` string
to `detect` and each reader decides. The Codex reader ticket must handle the
`"node"`-ambiguity rule. Document this in `detect`'s contract comment so the Codex
reader implementer does not miss it.

**Do not leak `rawJSON` into `AgentSnapshot`.** `RunArtifactsReader` stores raw JSON
strings on its artifacts (`RunArtifact.rawJSON`). `AgentSnapshot` must have no
equivalent — once a raw JSON string is on the snapshot, it is one `String(describing:)`
away from a body leak. Every field on `AgentSnapshot` is a typed, named extraction.

**Stop if `AgentStatus` changes out from under you.** `AgentSnapshot.status` is
`AgentStatus` — the existing enum. If any concurrent ticket adds or removes a case
from that enum, re-verify the round-trip test covers all cases. The
`AgentKind.allCases.count` pattern is the model to follow if you want to catch this
early.
