# Host / RemoteReach model — data layer for remote execution

## What this delivers

After this ticket lands, a `Project` can carry a `RemoteEnvironment` value — a host label,
a human-readable alias, and a `RemoteReach` enum discriminating between `localhost`,
`sshForward`, `tailscale`, and `tunnel`. The canvas and spawner read that value and produce
a correct `LaunchProfile` for whichever host is configured. On `localhost` (the default)
nothing changes. On `sshForward`, the ghostty surface forks an `ssh -t <host> 'tmux …'`
process rather than a bare `tmux` process — the tmux session lives on the remote box,
survives disconnects, and reattaches identically to the local case. Tailscale shares the
`sshForward` argv exactly (a Tailnet peer is just an ssh host by its `100.x`/MagicDNS name).
The `tunnel` case is modelled in the type system so it round-trips through `Codable`, but it
is deliberately unspawnable: `wrap` traps on it (see the tunnel decision in "Watch out for").
The two keepalive flags (`ServerAliveInterval=15` / `ServerAliveCountMax=3`) plus
`ConnectTimeout=10` are user-configurable from day one, persisted to `UserDefaults` under a
dedicated config enum. No remote polling or observer wiring is part of this ticket — those
ride the ssh channel as a later piece. This ticket's job is the pure data model and the
`wrap` change that makes the spawner reach-aware. Rests on **D8** (default reach path =
`localhost` then hardened SSH; model the full menu, wire only `localhost` + `sshForward`
first) and **D9** (ssh-wrap first, no `-L`/`-N`).

## How it fits

This is the first remote ticket and sits in Phase 5 of the build plan. It builds
on project session naming (which established `continuum-proj-<projectId>` as the tmux
session name) because a reach-aware `wrap` composes with that naming: the inner tmux
command that ghostty forks is identical across reach paths, only the outer `ssh` envelope
changes. It also builds on the injectable substrate work, which supplies the `TmuxControl`
fake and `FakeHost` so everything here can be asserted in pure logic tests against no
daemon and no network.

This ticket unblocks the `sshForward` attach wrap, which needs the `SSHTarget` type and
the `RemoteReach` enum to exist before it can issue the resolved ssh command. It also
unblocks Tailscale discovery (which populates `RemoteEnvironment` values automatically)
and the remote observer (which needs the `reach` field to know whether to call tmux
locally or prefix each command with `ssh <host>`). All of those tickets depend on this
one by name.

## The approach

Introduce two new types in `ContinuumRevivedCore`: `RemoteReach` (a `Codable`, `Equatable`,
`Sendable` enum) and `SSHTarget` (a `Codable`, `Equatable`, `Sendable` struct carrying
alias, resolved hostname, optional username, optional port). Wrap them in `RemoteEnvironment`
— the persistent unit that goes on `Project` — modelled as t3code's
`PersistedSavedEnvironmentRecord` principle: a label plus optional revival metadata, not a
live transport handle. `RemoteEnvironment` is `Codable` and `Equatable` so `Project`
serialization requires no schema migration helper beyond a `decodeIfPresent` default.

Extend `TmuxSession.wrap` with exactly two new parameters: `reach: RemoteReach = .localhost`
(default preserves the existing call site without changes) and `defaults: UserDefaults =
.standard` (so the logic tests can inject a fresh in-memory `UserDefaults` and assert config
overrides — see logic test 3). Inside `wrap`, `localhost` produces exactly the existing
argv; `sshForward` and `tailscale` build an `ssh -t` outer command using `sshBaseArgs` (a
new private helper that assembles the hardened flag set from `RemoteReachConfig`, reading
through the injected `defaults`); `tunnel` calls `fatalError("tunnel reach path not yet
wired")` — explicit and unmissable, never silently wrong (tunnel decision below).

Add `RemoteReachConfig` as a `UserDefaults`-backed config enum with keys for
`serverAliveInterval` (default 15), `serverAliveCountMax` (default 3), and
`connectTimeout` (default 10). Every threshold is owner-overridable, never hardcoded.

Add `shellEscape` as a new `private static` helper on `TmuxSession` (its exact location and
semantics are spelled out under "Where it lives" — this is the make-or-break helper the
inner-command quoting depends on).

Wire the reach parameter through `TileSpawner.tmuxWrappedProfileIfAvailable` so the
existing call site (`TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath)`)
gains the `reach` argument drawn from `project.remoteEnvironment?.reach ?? .localhost`.

Do not touch `killSessionCommand`, the observer, or any live-network code. This ticket
is pure model and pure argv construction.

## Where it lives

**New file — `Sources/ContinuumRevivedCore/RemoteReach.swift`.**
Defines `RemoteReach`, `SSHTarget`, `RemoteEnvironment`, and `RemoteReachConfig`. No
dependencies outside Foundation.

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** (three seams).
- `TmuxSession.wrap` at line 12: adds **exactly two** parameters —
  `reach: RemoteReach = .localhost` and `defaults: UserDefaults = .standard` — and a
  `switch reach` block that produces either the existing local argv or an ssh-wrapped one.
  This is the authoritative public contract; the breadcrumb below matches it byte-for-byte.
  (No `reachConfig` metatype parameter: `RemoteReachConfig` is a concrete enum, not a
  protocol, so passing its type would buy nothing — dropped per simplicity.)
- New `private static func sshBaseArgs(target: SSHTarget, defaults: UserDefaults) -> [String]`
  helper, below `killSessionCommand`. It takes `defaults` (not a `config` value) because it
  reads each threshold through `RemoteReachConfig.<threshold>(defaults:)`; there is no
  intermediate config struct.
- New `private static func shellEscape(_ token: String) -> String` helper, below
  `sshBaseArgs`. **Exact semantics:** wrap the token in single quotes and escape any
  embedded single quote by the POSIX close-quote/escaped-quote/reopen-quote idiom, i.e.
  replace each `'` with `'\''` and surround the whole with single quotes:
  `"'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"`. This matches the escape
  rule the codebase already uses in the test-local `shellSingleQuoted` closure
  (`TileSpawner.swift:3384`) — deliberately the same rule so behavior is consistent — but it
  is a **new, separately-tested Core helper**, not a reuse of that closure (that closure is
  scoped inside a check function and is not callable from Core, and it is not exported). Do
  not delete or refactor the existing closure; it is pre-existing and out of scope.

**`Sources/ContinuumRevivedCore/Project.swift`** at line 3 (`Project` struct).
- New `public let remoteEnvironment: RemoteEnvironment?` property, `nil` by default.
- `currentSchemaVersion` bumped to `2`.
- `init` gains `remoteEnvironment: RemoteEnvironment? = nil`.
- `CodingKeys` and `init(from:)` use `decodeIfPresent` so all existing persisted projects
  decode cleanly without migration.

**`Sources/ContinuumRevived/App/TileSpawner.swift`** at line 221
(`tmuxWrappedProfileIfAvailable`).
- Reads `project.remoteEnvironment?.reach ?? .localhost` and passes it to `TmuxSession.wrap`.

**New test file — `Tests/ContinuumRevivedCoreTests/RemoteReachTests.swift`.**
All logic tests live here: argv assertions, `Codable` round-trips, config defaults,
key-string constants, `shellEscape`, and the `wrap(.tunnel)` trap test.

## Implementation breadcrumbs

```swift
// RemoteReach.swift — new file in ContinuumRevivedCore

public struct SSHTarget: Equatable, Sendable, Codable {
    public var alias: String       // what the user typed, e.g. "myvps"
    public var hostname: String    // resolved via `ssh -G`; alias until resolved
    public var username: String?   // nil means ssh picks from config
    public var port: Int?          // nil means default 22
}

public enum RemoteReach: Equatable, Sendable, Codable {
    case localhost
    case sshForward(SSHTarget)
    case tailscale(SSHTarget)      // modelled; same argv as sshForward
    case tunnel(relayHost: String) // modelled + Codable; NOT spawnable (see wrap)
}

public struct RemoteEnvironment: Equatable, Sendable, Codable {
    public var id: UUID
    public var label: String                  // e.g. "Hetzner VPS"
    public var reach: RemoteReach
    public var lastConnectedAt: Date?
}

// RemoteReachConfig — UserDefaults-backed, owner-overridable thresholds.
// The three key strings below are the LOCKED wire contract: a later Settings-UI
// ticket must bind these exact keys (asserted by logic test 10) so no drift can
// enter when the UI lands.
public enum RemoteReachConfig {
    public static let serverAliveIntervalKey  = "continuum.remote.ssh.serverAliveInterval"
    public static let serverAliveCountMaxKey  = "continuum.remote.ssh.serverAliveCountMax"
    public static let connectTimeoutKey       = "continuum.remote.ssh.connectTimeout"

    public static let defaultServerAliveInterval  = 15
    public static let defaultServerAliveCountMax  = 3
    public static let defaultConnectTimeout       = 10

    public static func serverAliveInterval(defaults: UserDefaults = .standard) -> Int { ... }
    public static func serverAliveCountMax(defaults: UserDefaults = .standard) -> Int { ... }
    public static func connectTimeout(defaults: UserDefaults = .standard) -> Int { ... }
}
```

```swift
// TmuxSession.swift — extend wrap
// AUTHORITATIVE SIGNATURE: exactly two new params (reach, defaults). Matches
// "Where it lives" exactly.

public static func wrap(
    profile: LaunchProfile,
    tileId: UUID,
    tmuxPath: String,
    reach: RemoteReach = .localhost,
    defaults: UserDefaults = .standard
) -> LaunchProfile {
    let name = sessionName(tileId: tileId)
    // The inner tmux argv is identical on every reach path.
    var inner = ["new-session", "-A", "-s", name, "-c", profile.cwd]
    if shouldPassInnerCommand(profile) {
        inner.append(profile.command)
        inner.append(contentsOf: profile.arguments)
    }

    switch reach {
    case .localhost:
        return LaunchProfile(command: tmuxPath, arguments: inner,
                             cwd: profile.cwd, title: profile.title)

    case .sshForward(let target), .tailscale(let target):
        // ghostty forks a LOCAL pty — the ssh client.
        // The tmux session lives on the remote host; -A reattaches on reconnect.
        // No -L, no -N: the attach IS the remote command (D9).
        let host = [target.username, target.hostname]
            .compactMap { $0 }.joined(separator: "@")
        let remoteInvocation = ([tmuxPath.isEmpty ? "tmux" : tmuxPath] + inner)
            .map { shellEscape($0) }.joined(separator: " ")
        var args = sshBaseArgs(target: target, defaults: defaults)
        args += ["-t", host, remoteInvocation]
        return LaunchProfile(command: "/usr/bin/ssh", arguments: args,
                             cwd: profile.cwd, title: profile.title)

    case .tunnel:
        // DECIDED: truly crash. A tunnel value can be decoded from disk (Codable),
        // so this arm IS reachable on real user data — that is intentional. Reaching
        // it means a tunnel-reach project was spawned before the tunnel path was wired,
        // which is a programming/config error we want loud and immediately actionable,
        // never a silent fallback to localhost. See "Watch out for" for why no guard
        // is added at model construction or spawn.
        fatalError("tunnel reach path not yet wired — add once relay provisioning exists")
    }
}

private static func sshBaseArgs(target: SSHTarget, defaults: UserDefaults) -> [String] {
    var args = [
        "-o", "ConnectTimeout=\(RemoteReachConfig.connectTimeout(defaults: defaults))",
        "-o", "ServerAliveInterval=\(RemoteReachConfig.serverAliveInterval(defaults: defaults))",
        "-o", "ServerAliveCountMax=\(RemoteReachConfig.serverAliveCountMax(defaults: defaults))",
        "-o", "BatchMode=no",
    ]
    if let port = target.port {
        args += ["-p", String(port)]
    }
    return args
}

// New Core helper — same escape rule as TileSpawner.swift:3384's test-local
// shellSingleQuoted closure, but a real, separately-tested Core function.
private static func shellEscape(_ token: String) -> String {
    "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

```swift
// Project.swift — add remoteEnvironment

public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    // ... existing fields ...
    public let remoteEnvironment: RemoteEnvironment?   // nil = localhost, no migration needed

    public init(
        // ... existing params ...
        remoteEnvironment: RemoteEnvironment? = nil
    ) { ... }
}

// CodingKeys and init(from:) use decodeIfPresent so schema v1 projects decode cleanly.
// No explicit migration step needed — nil is the correct default.
```

```swift
// TileSpawner.swift — line 221, tmuxWrappedProfileIfAvailable

private func tmuxWrappedProfileIfAvailable(_ profile: LaunchProfile, tileId: UUID) -> LaunchProfile {
    guard TmuxPersistenceConfig.enabled(defaults: defaults),
          let tmuxPath = tmuxPathResolver(defaults) else {
        return profile
    }
    let reach = project.remoteEnvironment?.reach ?? .localhost
    return TmuxSession.wrap(profile: profile, tileId: tileId,
                            tmuxPath: tmuxPath, reach: reach)
}
```

## How we test it

### Logic (pure Core checks)

All tests in `RemoteReachTests.swift` run with no daemon, no network, no `UserDefaults`
side effects (pass a fresh in-memory `UserDefaults` instance to every call that reads
config).

1. **`wrap(.localhost)` produces unchanged argv** — assert the result command is the tmux
   path and arguments begin with `["new-session", "-A", "-s", "continuum-<uuid>"]`.
2. **`wrap(.sshForward)` produces the correct outer command** — assert `command == "/usr/bin/ssh"`,
   that arguments contain `-t`, that the host spec is `user@hostname` when username is set
   and `hostname` when it is nil, that the remote invocation string ends with the tmux
   session name, and that `-o ServerAliveInterval=15` / `-o ServerAliveCountMax=3` /
   `-o ConnectTimeout=10` are all present in order.
3. **Config overrides propagate** — inject a `UserDefaults` with
   `continuum.remote.ssh.serverAliveInterval = 30` and pass it as the `defaults:` argument
   to `wrap`; assert the arg reads `30`. (This is why `wrap` takes `defaults:` — the test
   must be able to inject config without touching `.standard`.)
4. **`wrap(.tailscale)` produces the same argv shape as `sshForward`** — the two cases
   share the same arm; confirm no regression by running the same shape check against a
   tailscale target with a `100.x` hostname.
5. **`wrap` with inner command vs shell title** — exercise both the "pass inner command"
   and "shell title" branches to assert the inner argv stays correct across reach paths.
6. **`RemoteEnvironment` round-trips through `Codable`** — encode, decode, assert equal.
   Cover **all four** `RemoteReach` cases **including `tunnel(relayHost:)`** (the tunnel
   case must survive serialization even though it cannot be spawned), a nil
   `lastConnectedAt`, and a non-nil one.
7. **`Project` with `remoteEnvironment: nil` decodes from a schema-v1 JSON fixture** —
   paste a raw v1 project JSON blob (no `remoteEnvironment` key), decode, assert
   `remoteEnvironment == nil` and all other fields intact. This is the migration regression
   test — it must pass before merging.
8. **`RemoteReachConfig` defaults** — assert that a fresh `UserDefaults` returns 15, 3, 10
   for the three thresholds.
9. **`shellEscape` handles embedded single quotes** — assert
   `shellEscape("a'b")` equals `'a'\''b'` exactly (the `'\''` idiom), and assert a
   plain token `shellEscape("foo")` equals `'foo'`. At least these two cases, one with an
   embedded single quote.
10. **`RemoteReachConfig` key constants are the locked strings** — assert
    `serverAliveIntervalKey == "continuum.remote.ssh.serverAliveInterval"`,
    `serverAliveCountMaxKey == "continuum.remote.ssh.serverAliveCountMax"`,
    `connectTimeoutKey == "continuum.remote.ssh.connectTimeout"`. This is the falsifiable
    replacement for a vague "Settings-wiring note": a future Settings ticket binds these
    exact keys, and this test fails if anyone renames one, so no drift can enter.
11. **`wrap(.tunnel)` traps** — assert that calling
    `wrap(profile:tileId:tmuxPath:reach: .tunnel(relayHost: "relay.example"))` terminates
    the process. Use the test framework's death-test facility (`XCTExpectFailure` is *not*
    right here; use a spawned-subprocess assertion or the project's existing fatalError-trap
    check helper — the phase-0 harness provides a `expectFatalError`/subprocess pattern; if
    none exists, run the call in a child process via the `ContinuumRevivedCoreChecks`
    harness and assert non-zero exit with the message substring `tunnel reach path`). This
    proves the "loud crash on persisted tunnel data" decision is real, not aspirational.

### Backend (real-path / integration)

These run against a live ssh daemon. They are explicitly marked with a custom
`XCTestCase` tag or run only in CI environments with a known `localhost` ssh target
configured under `~/.ssh/config` as alias `continuum-test-local`.

1. **`wrap(.sshForward(localSshTarget))` launches and a tmux session appears** — spawn the
   `LaunchProfile` that `wrap` returns, wait up to 5 s, run `tmux has-session -t <name>`,
   assert exit code 0. Then `tmux kill-session` and confirm the session is gone.
2. **Keepalive flags survive a short inactivity period** — attach via the wrapped profile,
   sleep 2 s, assert the child process is still alive (pid still in process list), confirming
   the `ServerAliveInterval` is not so short it triggers a premature kill.
3. **`wrap(.localhost)` still passes the existing `TmuxSession` real-path contract** —
   the existing session-survival real-path check from the injectable substrates ticket must
   still pass with the new signature (`reach` defaults to `.localhost`, no regression).
4. **Spawn of a PERSISTED `tunnel` project crashes loudly** — write a project JSON with
   `"reach": {"tunnel": {"relayHost": "relay.example"}}` to a temp store, decode it into a
   `Project`, drive the spawn path (via the `ContinuumRevivedCoreChecks` harness so the
   trap is captured in a child process), and assert the process aborts with the
   `tunnel reach path` message rather than silently spawning a bare `tmux` or falling back
   to localhost. This is the real-data companion to logic test 11 — it proves that a
   tunnel value which round-trips through `Codable` (test 6) and reaches the spawner does
   *not* degrade to a silent localhost spawn.

### UX (visual gate + dogfood snippet)

This ticket produces no new UI surface — the `RemoteEnvironment` field on `Project` is
data-layer only. The reach menu that lets a user pick a host is a later supervised ticket.
Accordingly the UX gate is a **developer dogfood check** rather than a canvas visual:

Open a project's persisted JSON in the app's Application Support directory and manually
inject `"remoteEnvironment": {"id": "<uuid>", "label": "local-ssh-test", "reach": {"sshForward": {"alias": "localhost", "hostname": "127.0.0.1", "username": null, "port": null}}, "lastConnectedAt": null}`.
Relaunch the app. Spawn a new terminal tile in that project. Observe in Activity Monitor
that the tile's process is `/usr/bin/ssh` with arguments matching
`-o ServerAliveInterval=15 … -t 127.0.0.1 tmux new-session -A -s continuum-<uuid> …`.
The tile should display a shell prompt exactly as a local tile does. Revert the JSON
to remove `remoteEnvironment` and confirm the next spawn reverts to a bare `tmux` process.

## Execution mode

**Autonomous.** Every correctness property is proven by the logic test suite (pure argv
construction against no daemon), by the backend real-path check against a loopback
ssh target, and by the two `tunnel`-trap checks (logic test 11 + backend check 4) which run
the fatalError in a child process and assert the abort message. There is no new UI surface
requiring a human eye, no real VPS, no real cloud account, and no interactive UX judgment.
The backend check uses `localhost` ssh (the machine's own `sshd`) which is available in the
CI environment. All thresholds are configurable so there are no magic numbers to eyeball.
The migration regression test (schema-v1 decode) is deterministic and byte-level. This
ticket is fully provable without human intervention.

## Done when

- [ ] `RemoteReach`, `SSHTarget`, `RemoteEnvironment`, and `RemoteReachConfig` exist in
  `Sources/ContinuumRevivedCore/RemoteReach.swift`, compile, and are exported from the
  module.
- [ ] `TmuxSession.wrap` accepts exactly two new parameters —
  `reach: RemoteReach = .localhost` and `defaults: UserDefaults = .standard`, in that order,
  with those defaults — and no others; existing call sites compile unchanged; the new
  `sshForward` and `tailscale` arms produce the expected argv with all three hardened flags;
  the `tunnel` arm traps via `fatalError`.
- [ ] `sshBaseArgs` has the signature
  `private static func sshBaseArgs(target: SSHTarget, defaults: UserDefaults) -> [String]`
  (a `defaults` parameter, not a `config` parameter) and reads each threshold through
  `RemoteReachConfig.<threshold>(defaults:)`.
- [ ] `shellEscape` exists as `private static func shellEscape(_ token: String) -> String`
  on `TmuxSession`, escapes embedded single quotes with the `'\''` idiom, and is applied to
  every token of the inner tmux argv before it is joined into the ssh remote-invocation
  string.
- [ ] `Project` carries `remoteEnvironment: RemoteEnvironment?`; schema version is `2`;
  all existing persisted projects (schema v1, no `remoteEnvironment` key) decode to
  `remoteEnvironment == nil` without a migration step.
- [ ] `TileSpawner.tmuxWrappedProfileIfAvailable` passes `project.remoteEnvironment?.reach ?? .localhost`
  to `TmuxSession.wrap`; the call compiles; no other call sites are changed.
- [ ] All eleven logic tests pass green, including the four-case `Codable` round-trip
  (tunnel included), the key-constant assertion (test 10), and the `wrap(.tunnel)` trap
  (test 11).
- [ ] All four backend real-path checks pass green (loopback ssh target; CI must have `sshd`
  reachable on `127.0.0.1`), including the persisted-`tunnel`-spawn-crashes check (check 4).
- [ ] `RemoteReachConfig` has three `UserDefaults`-backed entries, each with its default and
  its key constant; the three key constants equal exactly
  `continuum.remote.ssh.serverAliveInterval`, `continuum.remote.ssh.serverAliveCountMax`,
  and `continuum.remote.ssh.connectTimeout` (asserted by logic test 10 — this is the locked
  contract a future Settings ticket binds against; there is no separate "note" artifact).
- [ ] No existing tests regress. The pre-existing test-local `shellSingleQuoted` closure in
  `TileSpawner.swift` is left untouched.

## Depends on / unblocks

This ticket depends on project session naming (which settled `continuum-proj-<projectId>`
as the session identity, confirming that a tmux session name is derivable from the project
model without touching the tile) and on the injectable substrates work (which provides the
fake host and fake `UserDefaults` plumbing that keeps the logic tests free of real daemons,
and the child-process fatalError-trap harness that logic test 11 and backend check 4 rely
on).

It directly unblocks three subsequent pieces. The `sshForward` attach wrap extends the
reach-aware `wrap` with the `ssh -G` resolution step that turns an alias into a confirmed
`SSHTarget`. Tailscale discovery populates `RemoteEnvironment` values by reading
`tailscale status --json` and creating `sshForward` targets with `100.x` hostnames, folding
into the same enum arm. The remote observer extension reads `project.remoteEnvironment?.reach`
to decide whether to run `tmux display` locally or prefix it with `ssh <host>`, which is
only possible once `RemoteReach` exists.

The bootstrap auth ticket (which seeds a grant for every reach path including loopback) also
depends on this model because it needs the `RemoteReach` enum to pattern-match on the path
type.

## Watch out for

**The make-or-break pitfall is the inner command quoting.** When ghostty forks
`/usr/bin/ssh -t host "tmux new-session -A -s continuum-<uuid> -c /some/path /bin/zsh"`,
the entire tmux invocation is a single argument to ssh, which means any path, session name,
or inner command containing whitespace or shell metacharacters must be escaped before
being concatenated. The `shellEscape` helper (new `private static` on `TmuxSession`, exact
location and rule under "Where it lives") must be applied to every token of the inner
argv. If this is wrong, the remote tmux session spawns with the wrong cwd, the wrong
command, or silently launches into a bare shell with no session name — all of which
*appear* to work locally but are incorrect under inspection. Verify `shellEscape` exhaustively
in unit tests (logic test 9) before trusting it in the integration path.

**Stop if `Project.decode` regresses for schema-v1 fixtures.** The `decodeIfPresent`
path is critical. If any existing persisted project fails to decode after this change,
the schema bump is broken and no further work should proceed until the migration test
passes.

**The `tunnel` decision — decided, not open.** The behavior is: **model construction is NOT
guarded, and spawn is NOT guarded with a recoverable error — `wrap(.tunnel)` truly crashes
via `fatalError`.** The reasoning, and why the alternatives were rejected:
- *Why not guard at model construction?* Because `RemoteReach` is `Codable` and a
  `tunnel` value must round-trip through `Project` serialization intact (logic test 6
  asserts this). A construction-time guard would either make the enum non-`Codable` for one
  case (breaking round-trip) or throw on decode of otherwise-valid persisted data (breaking
  the migration/decode contract). So the model deliberately accepts and preserves `tunnel`.
- *Why not a user-facing recoverable error at spawn?* Because per **D8** only
  `localhost` + `sshForward` (+ `tailscale`, same arm) are wired in this phase; a `tunnel`
  project can only exist on disk if it was hand-authored or written by unreleased code.
  Silently falling back to `localhost`, or surfacing a soft "not supported" toast, would let
  a mis-configured project *appear* to work and hide the missing wiring. There is no UI in
  this ticket to author a tunnel reach in the first place, so any tunnel value that reaches
  the spawner is a genuine error state we want loud.
- *Therefore: crash.* The crash is the correct behavior — it is loud and immediately
  actionable. This decision is covered by **logic test 11** (`wrap(.tunnel)` traps) and
  **backend check 4** (a *persisted* tunnel project, decoded from disk and driven through
  the spawn path, aborts with the `tunnel reach path` message rather than degrading). When
  the tunnel path is actually wired (a later ticket, gated on relay provisioning), that
  ticket replaces the `fatalError` arm and deletes these two crash-asserting checks.

**Do not resolve the ssh alias during model construction.** `SSHTarget.hostname` is
populated by `ssh -G` resolution, which is a process spawn and must happen at attach time
in the spawner, not when the model is decoded from disk. The model stores `alias` as the
canonical user-facing key and `hostname` as the last-resolved value. If resolution has
not yet happened (first use after deserialization), `hostname` may equal `alias` as a
bootstrap value — that is fine. The actual `ssh -G` resolution step lives in the
`sshForward` attach wrap ticket, not here.

**`tailscale` is a distinct enum case for labelling reasons, not a distinct transport.**
The `tailscale` arm must produce the same argv as `sshForward` — a Tailnet peer is
accessed by its `100.x` or MagicDNS name over ordinary ssh. The distinction is in how the
`SSHTarget` was discovered (from `tailscale status --json` rather than from user input),
which matters for the UI's labelling and for future Tailscale-specific policies. Do not
introduce a distinct code path in `wrap` for the two cases.
