# Remote attach real path: gated substrate check for SSH session attach and stale-on-drop

## What this delivers

A gated backend check that proves the `sshForward` reach path works against a real remote tmux session. When the check runs, it opens an SSH connection to a configured remote host, attaches (or creates) a tmux session on that host using `TmuxSession.wrap` extended with a `RemoteReach.sshForward` case, asserts the session is alive and returns the correct window target, then simulates a dropped link and asserts the system degrades to a stale status — never emitting a wrong status, never crashing, never fabricating "working" or "done" when the ssh process is dead.

From the system's perspective, this is the first end-to-end validation that the SSH attach path is wired correctly through `TmuxSession.wrap`, that the `Host` substrate routes the attach command over SSH, and that a failed link drives the observer's status to `.stale` (not `.unknown`, not `.idle`) within the 45-second stale window already specified in the status-derivation function.

From the practitioner's perspective, once this check is green the remote attach path is proven substrate-honest: a future developer cannot accidentally ship a regression to the SSH wrap without this check turning red against a real host.

## How it fits

This ticket builds on three prior pieces of work and is gated entirely on one of them. The injectable substrates work established the `Host` protocol and the `FakeHost` that remote-path logic uses in unit tests; the real `SSHHost` implementation — the concrete type that spawns actual `ssh` processes — is the substrate this ticket requires. Without a real `SSHHost` the check has no real path to drive, so the injectable substrates work is a hard prerequisite.

The `TmuxSession.wrap` extension that accepts a `RemoteReach` parameter (introduced in the work that models `RemoteReach` as a closed enum on the project host field) is the call site this check exercises. That extension must exist and must handle the `.sshForward(SSHTarget)` case by emitting the correct SSH argv before this check can be written.

This check also consumes the status-derivation function — specifically the `.stale` output path, which fires when the last successful observation timestamp is older than the stale window (45 seconds, owner-configurable) and no live session evidence is available. The stale-on-drop assertion only makes sense once `deriveAgentStatus` knows how to emit `.stale`.

What this ticket unblocks is the remote observer path: the session observer work (which currently runs only against local tmux) can extend to remote hosts behind `ssh <host> tmux display` only after this check proves the SSH wrap is correct. It also unblocks the iOS reach story, because an iOS client reaching a VPS over Tailscale is ultimately the same SSH wrap with a different `SSHTarget.hostname` — proving the wrap correct locally validates the model.

## The approach

The check is a single, gated executable target in `ContinuumRevivedCoreChecks` that runs only when a real remote host is available. It is not a unit test and does not use `XCTest` — it follows the existing `do { … }` block pattern in `main.swift`. It is gated by an environment variable (`CONTINUUM_REMOTE_CHECK_HOST`) whose absence causes the check to print a clear skip message and exit 0. When the variable is set, it must point to an SSH alias or `user@host` that the running machine can reach without a password (key-based auth, with the remote host's key in `~/.ssh/known_hosts`).

The check drives the real `TmuxSession.wrap` extended with `RemoteReach.sshForward`, spawning the resulting `LaunchProfile` command via `Process` (not via ghostty — this is a headless substrate check). It then queries `tmux has-session -t continuum-<tileId>` on the remote to confirm the session exists, extracts the window target via `ssh <host> tmux display-message -p -t <session> '#{window_id}'`, and asserts the returned target is non-empty and matches the session name pattern. It then kills the local `ssh` process (simulating a dropped link), waits 50 seconds (slightly past the 45-second stale window), drives `deriveAgentStatus` with the stale signal active and no live evidence, and asserts the output is `.stale`. It does not assert `.idle`, `.unknown`, or any other status — only `.stale`.

The SSH keepalive arguments are taken verbatim from the t3code pattern (`docs/2026-06-30-t3code-steal/01-remote-reach-paths.md` §2.2): `-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -o ExitOnForwardFailure=yes`. For the attach path specifically, `-N` is omitted (Continuum's tmux attach is an interactive remote command, not a port forward). The `-t` flag is included so the remote `tmux new-session -A -s …` runs as an interactive command on the far side.

Host resolution goes through `ssh -G <alias>` before the attach. The check calls `ssh -G $CONTINUUM_REMOTE_CHECK_HOST`, parses `hostname`, `user`, and `port` from the output, and constructs an `SSHTarget` from those values. This verifies that the `resolveSshTarget` analog works correctly and that the alias picks up the user's real `~/.ssh/config` Host block without any custom parsing.

## Where it lives

**Primary check entry point:** `Sources/ContinuumRevivedCoreChecks/main.swift`. The remote attach check appends a new `do { … }` block after the existing checks, following the established pattern of that file. The block is guarded at its top:

```swift
// Sources/ContinuumRevivedCoreChecks/main.swift — append after existing blocks
guard let remoteHost = ProcessInfo.processInfo.environment["CONTINUUM_REMOTE_CHECK_HOST"] else {
    print("[SKIP] remote-attach-real-path: CONTINUUM_REMOTE_CHECK_HOST not set")
    // continue; does not fail the run
    // (jump to next block)
    let _ = 0  // placeholder to satisfy compiler
    // wrap the rest in an else branch
}
```

Use a labeled block or a helper function rather than a bare guard-at-top-level; match whatever style the existing `main.swift` uses for skippable blocks.

**Core model additions — if not already introduced by the `RemoteReach` model ticket:**

- `Sources/ContinuumRevivedCore/RemoteReach.swift` — `RemoteReach` enum (`localhost | sshForward(SSHTarget) | tailscale(SSHTarget) | tunnel(relayHost: String)`) and `SSHTarget` struct (`alias: String`, `hostname: String`, `username: String?`, `port: Int?`). These are `Equatable, Sendable, Codable`. If this file already exists from the model ticket, do not touch it.

- `Sources/ContinuumRevivedCore/TmuxSession.swift` — extend `TmuxSession.wrap` to accept `reach: RemoteReach`. The existing three-parameter overload stays for backward compatibility; the new overload adds `reach` as a fourth parameter with a default of `.localhost`. The `.localhost` case produces the existing output unchanged. The `.sshForward(let t)` and `.tailscale(let t)` cases produce a `LaunchProfile` whose `command` is the ssh executable (`/usr/bin/ssh`) and whose `arguments` are the SSH keepalive args + `-t` + the resolved host spec + the remote tmux invocation string. The `.tunnel` case is a fatal precondition (`preconditionFailure("tunnel reach not yet wired")`) — it is named in the enum for completeness but is not implemented here.

**SSH host resolution helper:**

- `Sources/ContinuumRevivedCore/SSHHostResolver.swift` — `SSHHostResolver.resolve(alias:) throws -> SSHTarget`. Runs `ssh -G <alias>` via `Process`, captures stdout, and parses `hostname`, `user`, and `port` lines using a simple line-scan (no regex). On failure (non-zero exit or missing `hostname` line) it returns an `SSHTarget` with `hostname = alias` and `username = nil`, `port = nil` (fallback to treating the alias as a literal host). This is the direct analog of `resolveSshTarget` in `packages/ssh/src/command.ts:328-365` of the t3code reference.

**SSH keepalive constants:**

- `Sources/ContinuumRevivedCore/SSHConstants.swift` — a single `enum SSHConstants` with `static let baseArgs: [String]` containing the keepalive and connect-timeout flags. Values are owner-configurable via `UserDefaults` keys (`continuum.ssh.connectTimeout`, default `10`; `continuum.ssh.serverAliveInterval`, default `15`; `continuum.ssh.serverAliveCountMax`, default `3`). The `baseArgs` computed property reads these defaults and builds the `["-o", "ConnectTimeout=\(connectTimeout)", "-o", "ServerAliveInterval=\(serverAliveInterval)", "-o", "ServerAliveCountMax=\(serverAliveCountMax)"]` array. Nothing is hardcoded as a non-configurable literal.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCore/RemoteReach.swift (if not yet present)

public enum RemoteReach: Equatable, Sendable, Codable {
    case localhost
    case sshForward(SSHTarget)   // path 1: interactive ssh -t; no -L, no -N
    case tailscale(SSHTarget)    // path 2: same attach, discovered via tailscale status --json
    case tunnel(relayHost: String)  // path 3: connector/relay (not yet wired)
}

public struct SSHTarget: Equatable, Sendable, Codable {
    public var alias: String           // what the user typed; used for ssh -G resolution
    public var hostname: String        // resolved hostname (from ssh -G or alias fallback)
    public var username: String?
    public var port: Int?

    public var hostSpec: String {
        let h = username.map { "\($0)@\(hostname)" } ?? hostname
        return h
    }
}
```

```swift
// Sources/ContinuumRevivedCore/TmuxSession.swift — new overload, appended after line 34

extension TmuxSession {
    /// Remote-capable wrap. `.localhost` produces the same output as the existing overload.
    public static func wrap(
        profile: LaunchProfile,
        tileId: UUID,
        tmuxPath: String,
        reach: RemoteReach
    ) -> LaunchProfile {
        let name = sessionName(tileId: tileId)
        let innerTmuxArgs = buildInnerArgs(name: name, profile: profile)

        switch reach {
        case .localhost:
            // Unchanged from the existing overload.
            return LaunchProfile(
                command: tmuxPath,
                arguments: innerTmuxArgs,
                cwd: profile.cwd,
                title: profile.title
            )

        case .sshForward(let target), .tailscale(let target):
            // ghostty forks a LOCAL pty (the ssh client).
            // The tmux session lives on the remote host; tmux -A reattaches on reconnect.
            // No -L, no -N: the attach IS the remote command (see 01-remote-reach-paths.md §7).
            let sshArgs = SSHConstants.baseArgs(defaults: .standard)
                + ["-t", target.hostSpec]
                + portArgs(target: target)
                + [remoteTmuxInvocation(tmuxPath: "tmux", innerArgs: innerTmuxArgs)]
            return LaunchProfile(
                command: sshExecutable,
                arguments: sshArgs,
                cwd: profile.cwd,
                title: profile.title
            )

        case .tunnel:
            preconditionFailure("tunnel reach is not yet wired; wire once relay host reachability exists")
        }
    }

    // The inner tmux argv is identical for every reach path.
    // new-session -A reattaches if the session already exists; the tile UUID is the stable key.
    private static func buildInnerArgs(name: String, profile: LaunchProfile) -> [String] {
        var args = ["new-session", "-A", "-s", name, "-c", profile.cwd]
        if shouldPassInnerCommand(profile) {
            args.append(profile.command)
            args.append(contentsOf: profile.arguments)
        }
        return args
    }

    // Serialise the remote tmux invocation as a single shell string so ssh -t passes it correctly.
    private static func remoteTmuxInvocation(tmuxPath: String, innerArgs: [String]) -> String {
        // Shell-quote each arg to survive the ssh quoting layer.
        // In practice session names are UUIDs (no special chars) and cwd comes from the project.
        // Still quote defensively: wrap each token in single quotes, escape embedded single quotes.
        let quoted = ([tmuxPath] + innerArgs).map { shellQuote($0) }.joined(separator: " ")
        return quoted
    }

    private static func portArgs(target: SSHTarget) -> [String] {
        guard let p = target.port else { return [] }
        return ["-p", String(p)]
    }

    private static var sshExecutable: String { "/usr/bin/ssh" }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

```swift
// Sources/ContinuumRevivedCore/SSHHostResolver.swift

public enum SSHHostResolver {
    public enum ResolveError: Error { case sshGFailed(Int32) }

    /// Runs `ssh -G <alias>` and parses hostname/user/port.
    /// Falls back to treating `alias` as a literal hostname on any failure.
    public static func resolve(alias: String) throws -> SSHTarget {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Fallback: the alias might be a literal hostname
            return SSHTarget(alias: alias, hostname: alias, username: nil, port: nil)
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return parse(output: output, alias: alias)
    }

    private static func parse(output: String, alias: String) -> SSHTarget {
        var hostname = alias   // fallback
        var username: String?
        var port: Int?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            switch key {
            case "hostname": hostname = value
            case "user":     username = value
            case "port":     port = Int(value)
            default:         break
            }
        }
        return SSHTarget(alias: alias, hostname: hostname, username: username, port: port)
    }
}
```

```swift
// Sources/ContinuumRevivedCoreChecks/main.swift — append new gated block

// ──────────────────────────────────────────────────────────────────────────────
// REMOTE ATTACH REAL PATH
// Gate: set CONTINUUM_REMOTE_CHECK_HOST to an ssh alias or user@host reachable
// by key auth. Without it this block prints [SKIP] and continues.
// ──────────────────────────────────────────────────────────────────────────────
do {
    guard let alias = ProcessInfo.processInfo.environment["CONTINUUM_REMOTE_CHECK_HOST"] else {
        print("[SKIP] remote-attach-real-path: CONTINUUM_REMOTE_CHECK_HOST not set")
        break
    }

    // 1. Resolve the alias through ssh -G (picks up ~/.ssh/config Host blocks).
    let target = try SSHHostResolver.resolve(alias: alias)
    print("[remote-attach] resolved \(alias) → \(target.hostSpec)")

    // 2. Build the attach LaunchProfile via TmuxSession.wrap with sshForward reach.
    let tileId = UUID()
    let shellProfile = LaunchProfile(command: "/bin/sh", arguments: [], cwd: "/tmp", title: "remote-check")
    let profile = TmuxSession.wrap(
        profile: shellProfile,
        tileId: tileId,
        tmuxPath: "tmux",   // remote; resolved on the far side by PATH
        reach: .sshForward(target)
    )
    assert(profile.command == "/usr/bin/ssh", "wrap must produce ssh as the command")
    assert(profile.arguments.contains("-t"), "wrap must include -t for interactive attach")
    let sessionName = TmuxSession.sessionName(tileId: tileId)
    let remoteInvocation = profile.arguments.last ?? ""
    assert(remoteInvocation.contains(sessionName),
           "remote invocation must reference the tile session name")

    // 3. Spawn the ssh process (headless — no ghostty pty; this is a substrate check).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: profile.command)
    process.arguments = profile.arguments
    process.standardInput = Pipe()   // no stdin; -t will still attach the remote session
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()

    // Give ssh + remote tmux up to 10 seconds to establish the session.
    let deadline = Date().addingTimeInterval(10)
    var sessionAlive = false
    while Date() < deadline {
        // Query remote: tmux has-session -t <name> exits 0 if alive.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        probe.arguments = SSHConstants.baseArgs(defaults: .standard)
            + (target.port.map { ["-p", String($0)] } ?? [])
            + [target.hostSpec, "tmux", "has-session", "-t", sessionName]
        probe.standardOutput = Pipe(); probe.standardError = Pipe()
        try? probe.run(); probe.waitUntilExit()
        if probe.terminationStatus == 0 { sessionAlive = true; break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    assert(sessionAlive, "remote tmux session must exist within 10s of SSH attach")
    print("[remote-attach] session \(sessionName) confirmed alive on \(target.hostSpec)")

    // 4. Also extract the window target to verify the session has a window.
    let displayProbe = Process()
    displayProbe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    displayProbe.arguments = SSHConstants.baseArgs(defaults: .standard)
        + (target.port.map { ["-p", String($0)] } ?? [])
        + [target.hostSpec, "tmux", "display-message", "-p", "-t", sessionName, "#{window_id}"]
    let displayPipe = Pipe()
    displayProbe.standardOutput = displayPipe; displayProbe.standardError = Pipe()
    try displayProbe.run(); displayProbe.waitUntilExit()
    let windowId = String(
        data: displayPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    assert(!windowId.isEmpty, "window_id must be non-empty when session is alive")
    assert(windowId.hasPrefix("@"), "tmux window ids begin with @")
    print("[remote-attach] window target: \(windowId)")

    // 5. Simulate a dropped link: kill the local ssh process.
    process.terminate()
    process.waitUntilExit()
    print("[remote-attach] ssh process killed — simulating dropped link")

    // 6. Wait past the stale window (45 s + 5 s margin = 50 s).
    // During this wait the remote tmux session stays alive; only the local attach is dead.
    // The stale signal fires because the observer can no longer reach the host for a fresh read.
    print("[remote-attach] waiting 50s for stale window to elapse…")
    Thread.sleep(forTimeInterval: 50)

    // 7. Drive deriveAgentStatus with the stale signal active.
    let signals = StatusSignals(
        agentKind: .shell,
        hasPendingApproval: false,
        hasPendingUserInput: false,
        hookBreadcrumbPresent: false,
        hookBreadcrumbAge: nil,
        isError: false,
        isStarting: false,
        isRunning: false,        // ssh is dead; no live observation
        isCompleted: false,
        engineStatus: .stale     // AgentStatusEngine.tick returns .stale after 45s with no evidence
    )
    let derived = deriveAgentStatus(signals: signals)
    assert(derived == .stale,
           "status must be .stale after link drop; got \(derived)")
    assert(derived != .unknown && derived != .idle,
           "status must never be .unknown or .idle when the link was previously live and is now dead")
    print("[remote-attach] ✓ stale-on-drop asserted: \(derived)")

    // 8. Confirm the remote session still exists (tmux survives the client disconnect).
    let survivalProbe = Process()
    survivalProbe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    survivalProbe.arguments = SSHConstants.baseArgs(defaults: .standard)
        + (target.port.map { ["-p", String($0)] } ?? [])
        + [target.hostSpec, "tmux", "has-session", "-t", sessionName]
    survivalProbe.standardOutput = Pipe(); survivalProbe.standardError = Pipe()
    try? survivalProbe.run(); survivalProbe.waitUntilExit()
    assert(survivalProbe.terminationStatus == 0,
           "remote tmux session must survive after the ssh client was killed")
    print("[remote-attach] ✓ remote session persists after client disconnect")

    // 9. Cleanup: kill the remote session to avoid leaving orphans.
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    cleanup.arguments = SSHConstants.baseArgs(defaults: .standard)
        + (target.port.map { ["-p", String($0)] } ?? [])
        + [target.hostSpec, "tmux", "kill-session", "-t", sessionName]
    cleanup.standardOutput = Pipe(); cleanup.standardError = Pipe()
    try? cleanup.run(); cleanup.waitUntilExit()
    print("[remote-attach] cleanup: remote session killed")
}
```

The two assertions that are most load-bearing in this pseudocode are step 7 (`derived == .stale`) and step 8 (remote session survives). Everything else is plumbing. The `AgentStatusEngine.tick(at:)` call that produces `.stale` must receive a `now` that is at least 45 seconds past the last ingested evidence — in the check this is satisfied by the real `Thread.sleep(50)`, but the unit-level stale logic test (see below) uses an injected clock.

## How we test it

### Logic (pure Core checks)

Write `RemoteAttachLogicTests` in `Sources/ContinuumRevivedCoreChecks/main.swift` (inline with the existing check pattern, not in a separate XCTest target). Three sub-checks, each in its own `do { }` block:

**Sub-check 1 — `TmuxSession.wrap` argv shape.** Construct a `LaunchProfile` for a shell, call `TmuxSession.wrap(profile:tileId:tmuxPath:reach:)` with a synthetic `SSHTarget` (alias `"myvps"`, hostname `"1.2.3.4"`, username `"dev"`, port `22`), and assert: `profile.command == "/usr/bin/ssh"`; the arguments contain `"-t"`; the arguments contain `"dev@1.2.3.4"`; the arguments contain the session name `"continuum-<tileId>"`; the arguments contain `"new-session"` and `"-A"` as part of the remote invocation string; the arguments do not contain `"-N"` and do not contain `"-L"` (no port-forward). This is a pure, synchronous assertion on the returned value — no process is spawned.

**Sub-check 2 — `SSHHostResolver` parsing.** Feed `SSHHostResolver.parse(output:alias:)` (exposed as `internal` for test access) a synthetic `ssh -G` output string:

```
hostname mybox.example.com
user alice
port 2222
identityfile /home/alice/.ssh/id_ed25519
```

Assert: `target.hostname == "mybox.example.com"`, `target.username == "alice"`, `target.port == 2222`. Feed it a malformed output (no `hostname` line) and assert the fallback: `target.hostname == alias`.

**Sub-check 3 — stale-on-drop status derivation.** Using `FakeClock` from the injectable substrates work, advance time 50 seconds past the last `AgentStatusEngine.ingest` call with no new evidence, call `engine.tick(at: fakeClock.now)`, assert `engineStatus == .stale`, then call `deriveAgentStatus(signals:)` with that engine status and all other signals false, and assert `derived == .stale`. Assert that if all signals are false but `engineStatus == .idle` (time not yet elapsed), the result is `.idle` — proving the stale window threshold is actually doing work, not always firing.

All three sub-checks run in under 100 ms (no real SSH, no sleep) and can run in any CI environment without network access.

### Backend (real-path / integration, not bypassed)

The real-path check is the full `do { }` block described in the implementation breadcrumbs — gated by `CONTINUUM_REMOTE_CHECK_HOST`. Run it as:

```
CONTINUUM_REMOTE_CHECK_HOST=myvps swift run ContinuumRevivedCoreChecks
```

The check does not use a mocked executor, does not short-circuit the SSH process, and does not bypass the 50-second stale wait. It is the substrate-honest path the verification doctrine requires: a real SSH process, a real remote tmux session, a real killed link, and a real 45-second-plus elapsed time.

The remote host must have `tmux` in its `PATH`. The check does not attempt to install it; if `tmux has-session` returns an error on the remote side that is not `"no server running"`, the check fails with a clear assertion message identifying which step failed. Keep the sentinel session isolated by its tile UUID so it cannot collide with any user's real sessions.

### UX (visual gate + dogfood snippet)

**Visual gate:** After the logic sub-checks pass and before the real-path check is run, open the app, create a project, and verify that the project picker does not show any UI for configuring a remote host (that UI is a later ticket). The absence of broken or blank UI is the gate — this ticket adds no user-visible surface, only model and check infrastructure.

**Dogfood snippet:** Once the real-path check is green, open the app with a terminal tile running on a local `localhost` session. Open Terminal (outside the app), run:

```
CONTINUUM_REMOTE_CHECK_HOST=myvps swift run ContinuumRevivedCoreChecks 2>&1 | grep -E '\[remote-attach\]|SKIP|FAIL'
```

Observe the output:
1. `[remote-attach] resolved myvps → dev@mybox.example.com` (or whatever the real hostname is) — confirms `ssh -G` resolution worked.
2. `[remote-attach] session continuum-<UUID> confirmed alive on dev@mybox.example.com` — confirms the remote tmux session was established.
3. `[remote-attach] window target: @0` (or another `@N` value) — confirms a window exists in the session.
4. `[remote-attach] ssh process killed — simulating dropped link`
5. `[remote-attach] waiting 50s for stale window to elapse…` — a 50-second pause in the terminal.
6. `[remote-attach] ✓ stale-on-drop asserted: stale`
7. `[remote-attach] ✓ remote session persists after client disconnect`
8. `[remote-attach] cleanup: remote session killed`

No `FAIL` lines should appear. The 50-second wait is real and intentional — it is the honest test of the stale window. Do not replace it with a mocked timer for the real-path check; that would be a happy-path bypass.

## Execution mode

**Needs substrate.** The real-path check requires a live remote host reachable over SSH with key-based auth, tmux installed, and no interactive passphrase prompt. These conditions cannot be satisfied in a standard CI environment. The logic sub-checks (argv shape, resolver parsing, stale derivation) are fully autonomous and run without any special environment. The full substrate check must run on a developer machine against a real VPS (Hetzner CX32 or equivalent, as specified in the hosting guide) before the ticket is marked done. The 50-second stale wait cannot be shortened without defeating the purpose of the stale-on-drop assertion; budget for a 2-minute check run end-to-end.

## Done when

- [ ] `Sources/ContinuumRevivedCore/RemoteReach.swift` exists (or was introduced by the reach-menu model ticket) and contains `RemoteReach` and `SSHTarget` as `Equatable, Sendable, Codable` types with the four cases described.
- [ ] `TmuxSession.wrap(profile:tileId:tmuxPath:reach:)` exists in `Sources/ContinuumRevivedCore/TmuxSession.swift` and compiles cleanly alongside the existing three-parameter overload.
- [ ] For `.localhost`, the new overload produces output identical to the existing `TmuxSession.wrap(profile:tileId:tmuxPath:)`.
- [ ] For `.sshForward`, the new overload produces a `LaunchProfile` with `command == "/usr/bin/ssh"`, arguments containing `-t`, the resolved `hostSpec`, and the session name embedded in the remote invocation string; arguments do not contain `-N` or `-L`.
- [ ] `Sources/ContinuumRevivedCore/SSHHostResolver.swift` exists and `SSHHostResolver.resolve(alias:)` calls `ssh -G`, parses `hostname`/`user`/`port`, and falls back to treating the alias as a literal hostname on failure.
- [ ] `Sources/ContinuumRevivedCore/SSHConstants.swift` exists; `SSHConstants.baseArgs(defaults:)` reads `ConnectTimeout`, `ServerAliveInterval`, and `ServerAliveCountMax` from `UserDefaults` with documented keys and correct defaults (10 / 15 / 3 respectively); no value is hardcoded as a non-configurable literal.
- [ ] Logic sub-check 1 (argv shape) passes: `swift run ContinuumRevivedCoreChecks` with no `CONTINUUM_REMOTE_CHECK_HOST` prints `[SKIP] remote-attach-real-path` for the substrate block and passes all logic sub-checks.
- [ ] Logic sub-check 2 (resolver parsing) passes for both well-formed and malformed `ssh -G` output.
- [ ] Logic sub-check 3 (stale-on-drop derivation) passes: `derived == .stale` after 50-second injected clock advance; `derived == .idle` when the clock has not yet advanced past the 45-second window.
- [ ] `swift build` passes with no new warnings. No existing checks are broken.
- [ ] Real-path check passes: with `CONTINUUM_REMOTE_CHECK_HOST` set to a real VPS, the check confirms session alive, window target non-empty and prefixed with `@`, stale-on-drop asserted, remote session survives after kill, cleanup succeeds. All eight log lines appear in the expected order.
- [ ] The remote tmux session does not persist after the check completes (cleanup step ran successfully).

## Depends on / unblocks

This ticket depends on the injectable substrates work being complete: `FakeHost`, `FakeClock`, and the `TmuxControl` protocol must exist before the logic sub-checks can use injected clocks and the real-path check can construct a correctly-typed `SSHTarget`. It also depends on the pure status-derivation function being complete, because the stale-on-drop assertion calls `deriveAgentStatus(signals:)` and asserts on its output. The `RemoteReach` enum itself may be introduced by this ticket if the reach-menu model ticket has not yet landed; if that ticket already exists, do not duplicate it.

This ticket unblocks the remote session observer work: extending the session observer to run `ssh <host> tmux display-message` poll calls against a remote session requires the `sshForward` reach path to be proven correct, which is exactly what this check establishes. It also unblocks any Tailscale reach-path work — a Tailnet peer is modeled as an `sshForward` target with a `100.x` hostname, so proving `sshForward` correct at this substrate level validates the whole `sshForward`-and-`tailscale` branch of the `RemoteReach` switch.

## Watch out for

**The hardest thing to get right is the stale-versus-unknown distinction at the status level.** When the SSH process dies, the system has no fresh evidence — but it also had live evidence moments before. The status must transition to `.stale`, not collapse to `.unknown` (which is the no-evidence-ever state) and not regress to `.idle` (which means "we checked and the agent is not running"). The `AgentStatusEngine` must track that a session was ever live and use that fact to distinguish "stale from live" from "never contacted". If the engine simply resets on link drop — losing its "was live" state — the stale assertion fails. Check `AgentStatusEngine`'s `tick(at:)` logic carefully: it should return `.stale` when `now - lastEvidenceAt > staleWindow` and `lastEvidenceAt` is non-nil, and `.unknown` only when `lastEvidenceAt` is nil entirely.

**Shell quoting of the remote tmux invocation is a failure surface.** The session name is a UUID (safe), but the `cwd` comes from the project and may contain spaces, parentheses, or other shell-significant characters. The `shellQuote` helper must correctly escape single quotes inside cwd strings. Test it with a synthetic cwd of `"/Users/alice/my project (2026)"` in the argv-shape logic sub-check and verify the resulting argument survives one round of shell parsing.

**The `-t` flag and the remote pseudopty interaction.** When `ssh -t` allocates a pseudopty for the remote command and the local process's stdin is a pipe (as in the headless check), some ssh versions emit a warning `Pseudo-terminal will not be allocated because stdin is not a terminal`. This warning goes to stderr and does not affect the exit code or the remote session — but it can confuse log-scraping that watches stderr for errors. Discard stderr from the attach process in the check (redirect to `Pipe()` and ignore) and do not treat a non-empty stderr as a failure.

**Session name collisions are not possible but must be guarded.** The session name is `continuum-<UUID>`, and UUIDs are effectively unique — but if the check crashes mid-run and leaves an orphan session, a subsequent run with a fresh UUID will create a second session on the remote. Add a pre-flight: at the start of the substrate block, run `ssh <host> tmux kill-session -t continuum-check-orphan 2>/dev/null` (a well-known name, distinct from the UUID-keyed session names) to clean up any prior orphan from this specific check. Do not attempt to enumerate and kill all `continuum-*` sessions, which would be destructive to real user sessions.

**The 50-second wait is not negotiable.** The stale window is 45 seconds (owner-configurable, but 45 is the default). The check sleeps 50 seconds to leave a 5-second margin for clock skew between the test process and the engine. Do not shorten this to 10 or 20 seconds in the substrate check — that would assert the stale condition before it can possibly be true and would make the check a happy-path bypass. The unit-level sub-check (sub-check 3) uses an injected clock and completes in milliseconds; the substrate check uses real wall time and is meant to be slow.
