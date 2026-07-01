# sshForward attach wrap — build the SSH argv for remote tmux attachment

## What this delivers

When a tile is configured for a remote host via the `sshForward` reach path, `TmuxSession.wrap` produces a `LaunchProfile` whose `command` is `ssh` and whose `arguments` form a complete, hardened attach invocation: `ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -o BatchMode=yes -t <user@resolved-hostname[:port]> 'tmux new-session -A -s continuum-<uuid> -c <cwd>'`. Ghostty forks this as a local pty — the SSH client runs on the Mac, the tmux session lives on the VPS — which means the session survives disconnects and reattaches exactly as local sessions do today.

The system-observable outcome: a tile pointing at an `SSHTarget` spawns its ghostty surface with a real `ssh -t` command, the tmux session name is the standard `continuum-<tileId>` format on the remote host, dropped links are detected within 45 seconds (15 s × 3 missed intervals), and `TileSpawner` never needs to know whether a tile is local or remote.

## How it fits

This ticket builds directly on the reach-path model described in `01-remote-reach-paths.md`, translating its §6.2 Swift sketch into production code. It is the first piece of the `sshForward` reach path that actually touches real ssh: the model types (`RemoteReach`, `SSHTarget`) and the `ssh -G` resolver are prerequisites that must land before this work, and the `killSessionCommand` remote variant and the `ssh` observer reads (`ssh <host> tmux display …`) are natural follow-ons unblocked by it. Decision D8 and Decision D9 in the locked decisions doc settle every architectural choice this ticket rests on — no `-L`, no `-N`, hardened-SSH argv, `ssh -G` for host resolution, keepalive flags — so this ticket carries zero open forks.

The `TileSpawner` call site at `Sources/ContinuumRevived/App/TileSpawner.swift:221` today calls `TmuxSession.wrap(profile:tileId:tmuxPath:)` unconditionally for all local tiles. After this ticket, it passes a `reach` parameter drawn from the tile's model, and the `localhost` arm reproduces the existing behavior exactly, keeping the local path a no-op change.

## The approach

`TmuxSession.wrap` gains a `reach: RemoteReach` parameter. The method switches on it. The `localhost` arm is the existing body verbatim. The `sshForward` arm builds the SSH argv in two steps: first run `ssh -G <alias>` to expand the user's `~/.ssh/config` and get the real hostname, user, and port; then assemble the full `ssh` argument list with the keepalive options, `-t`, the host specifier, and the remote tmux invocation as a single quoted shell string.

The `ssh -G` resolution is pure, synchronous, and short-lived — it reads config, writes nothing. It runs at wrap-time, not at connect-time, so the result is captured into the `LaunchProfile` before ghostty forks. If `ssh -G` fails (alias unknown, binary missing), the wrapper falls through to treating the alias as a literal hostname, exactly as t3's `resolveSshTarget` does.

The argv shape — with all options expressed as `-o Key=Value` flags rather than short flags — is intentional: it makes the option set explicit, avoids short-flag parsing ambiguity, and matches the t3 `baseSshArgs` / `startSshTunnel` pattern that has been proven in production.

There is no port forwarding, no `-N`, no `-L`, and no readiness probe. The tmux attach *is* the remote command; forwarding a port is not needed because there is no local HTTP listener to reach. This is the central distinction from t3's SSH tunnel shape, and the locked decisions are emphatic about it.

## Where it lives

**Primary file:** `Sources/ContinuumRevivedCore/TmuxSession.swift`

- `TmuxSession.wrap` — currently at line 12, signature `(profile: LaunchProfile, tileId: UUID, tmuxPath: String) -> LaunchProfile`. Gains a `reach: RemoteReach` parameter; default value of `.localhost` keeps all existing call sites compiling without changes.
- `TmuxSession.sessionName(tileId:)` — line 8, unchanged; the session name format is identical on remote and local.
- `TmuxSession.killSessionCommand(tileId:tmuxPath:)` — line 27, **not modified by this ticket** (the remote variant is a follow-on); this ticket focuses on the attach argv only.

**Model types** (prerequisite, must exist before this ticket runs):

- `RemoteReach` enum: `localhost | sshForward(SSHTarget) | tailscale(SSHTarget) | tunnel(relayHost: String)` — in `Sources/ContinuumRevivedCore/RemoteReach.swift` (new file from the model ticket).
- `SSHTarget` struct: `alias: String`, `hostname: String`, `username: String?`, `port: Int?` — same file.

**Call site that gains the parameter:**

- `Sources/ContinuumRevived/App/TileSpawner.swift:221` — `tmuxWrappedProfileIfAvailable(_:tileId:)`. This private helper calls `TmuxSession.wrap`; it gains a `reach` argument threaded down from the tile's model. For the current codebase, where no tile yet has a `reach` field, the helper defaults to `.localhost` and behavior is unchanged.

**Test file:**

- `Tests/ContinuumRevivedCoreTests/TmuxSessionSSHTests.swift` (new) — all logic and backend tests for this ticket live here.

## Implementation breadcrumbs

```swift
// RemoteReach.swift (prerequisite — must exist before this ticket)
public enum RemoteReach: Equatable, Sendable, Codable {
    case localhost
    case sshForward(SSHTarget)
    case tailscale(SSHTarget)      // discovered; modeled as sshForward at wrap time
    case tunnel(relayHost: String) // deferred — fatal if reached
}

public struct SSHTarget: Equatable, Sendable, Codable {
    public var alias: String       // what the user typed; fed to ssh -G
    public var hostname: String    // resolved from ssh -G output
    public var username: String?
    public var port: Int?
}

// TmuxSession.swift — new overload
public static func wrap(
    profile: LaunchProfile,
    tileId: UUID,
    tmuxPath: String,
    reach: RemoteReach = .localhost   // default preserves all existing call sites
) -> LaunchProfile {
    switch reach {
    case .localhost:
        // Existing body verbatim — no behavioral change.
        let name = sessionName(tileId: tileId)
        var arguments = ["new-session", "-A", "-s", name, "-c", profile.cwd]
        if shouldPassInnerCommand(profile) {
            arguments.append(profile.command)
            arguments.append(contentsOf: profile.arguments)
        }
        return LaunchProfile(command: tmuxPath, arguments: arguments,
                             cwd: profile.cwd, title: profile.title)

    case .sshForward(let target), .tailscale(let target):
        let name = sessionName(tileId: tileId)
        // The inner tmux argv is identical to the localhost case: reattach or create,
        // pinned session name, correct cwd. It runs on the remote host.
        var innerArgs = ["new-session", "-A", "-s", name, "-c", profile.cwd]
        if shouldPassInnerCommand(profile) {
            innerArgs.append(profile.command)
            innerArgs.append(contentsOf: profile.arguments)
        }
        // Shell-quote the remote command so it arrives as one argument to the remote sh.
        // tmuxPath on remote is always "tmux" — the remote's PATH resolves it.
        let remoteTmux = "tmux"
        let remoteCommand = ([remoteTmux] + innerArgs)
            .map { shellQuote($0) }
            .joined(separator: " ")

        // Assemble the ssh argv.
        // All options as -o Key=Value — explicit, unambiguous, matches t3 baseSshArgs shape.
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",   // detect a dropped link within 45 s (15×3)
            "-o", "ServerAliveCountMax=3",
        ]
        if let port = target.port {
            args += ["-p", String(port)]
        }
        args.append("-t")                     // allocate a pty — required for interactive tmux attach
        let hostSpec = target.username.map { "\($0)@\(target.hostname)" } ?? target.hostname
        args.append(hostSpec)
        args.append(remoteCommand)            // remote shell runs: tmux new-session -A -s … -c …

        return LaunchProfile(command: sshExecutablePath(), arguments: args,
                             cwd: profile.cwd, title: profile.title)

    case .tunnel:
        // Deferred. The tunnel path requires host reachability established by the
        // tunnel-provisioning work, which does not exist yet.
        fatalError("tunnel reach not yet wired: establish host reachability first")
    }
}

// ssh -G resolution — runs at wrap time, result captured into LaunchProfile.
// Returns a resolved SSHTarget; on failure falls through to alias-as-hostname.
public static func resolveSSHTarget(alias: String) -> SSHTarget {
    // Run: ssh -G <alias>
    // Parse stdout for lines: "hostname <value>", "user <value>", "port <value>".
    // t3 reference: command.ts:328-365, parseSshResolveOutput :45-70.
    guard let output = runSSHG(alias: alias) else {
        return SSHTarget(alias: alias, hostname: alias, username: nil, port: nil)
    }
    var hostname = alias
    var username: String? = nil
    var port: Int? = nil
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { continue }
        switch parts[0].lowercased() {
        case "hostname": hostname = String(parts[1])
        case "user":     username = String(parts[1])
        case "port":     port = Int(parts[1])
        default:         break
        }
    }
    return SSHTarget(alias: alias, hostname: hostname, username: username, port: port)
}

// Shell-quoting helper — single-quote with embedded single-quote escaping.
// Needed to pass the remote tmux command as one argument through the ssh argv.
private static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Locate the ssh binary. Prefer the PATH-resolved one; fall back to /usr/bin/ssh.
private static func sshExecutablePath() -> String {
    // On macOS /usr/bin/ssh is always present. PATH lookup first in case the user
    // has a configured override (e.g. a jump-host wrapper).
    let env = ProcessInfo.processInfo.environment
    let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in pathDirs {
        let candidate = (dir as NSString).appendingPathComponent("ssh")
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/usr/bin/ssh"
}
```

The `runSSHG` helper spawns `ssh -G <alias>` synchronously with a short timeout (2 seconds is sufficient — it reads config, never connects). Use `Process` + `Pipe`; capture stdout; ignore stderr. If the process does not exit within 2 s or exits non-zero, return `nil` and let `resolveSSHTarget` fall back to alias-as-hostname.

## How we test it

### Logic (pure Core checks)

These tests live in `TmuxSessionSSHTests.swift` and exercise the pure argument-building logic using pre-resolved `SSHTarget` values — no real ssh process, no network.

- **Localhost arm is unchanged.** Construct a `LaunchProfile` with a non-shell command. Call `wrap` with `reach: .localhost`. Assert the returned `command` equals `tmuxPath`, `arguments[0]` is `new-session`, the session name contains the tile UUID, and the inner command is appended. This is the regression check that proves the default arm is untouched.
- **sshForward produces the correct argv shape.** Call `wrap` with a fully-populated `SSHTarget` (username "alice", hostname "vps.example.com", port 2222). Assert: `command` is the ssh path; `arguments` contains `-o BatchMode=yes`, `-o ConnectTimeout=10`, `-o ServerAliveInterval=15`, `-o ServerAliveCountMax=3`, `-p 2222`, `-t`, `alice@vps.example.com` (in that order); the final argument is a shell string beginning with `tmux new-session` and containing the expected session name and cwd.
- **Port omitted when nil.** Call `wrap` with `port: nil`. Assert `-p` does not appear anywhere in `arguments`.
- **Username omitted when nil.** Assert the host specifier is bare `hostname`, not `@hostname`.
- **Session name is stable.** Fix a UUID; assert the session name in both the local and remote argv is identical (`continuum-<fixedUUID>`).
- **Shell quoting round-trips.** Unit-test `shellQuote` directly: an argument containing spaces becomes `'foo bar'`; an argument containing a single quote becomes `'it'\''s'`.
- **ssh -G parse.** Feed a synthetic `ssh -G` stdout string (multi-line `hostname vps.internal\nuser deploy\nport 22`) into the parser and assert the `SSHTarget` fields.
- **ssh -G fallback.** When the parser receives empty output or a non-zero exit, the returned `SSHTarget.hostname` equals the original alias.

### Backend (real-path / integration)

These tests require a real `ssh` binary (always present on macOS at `/usr/bin/ssh`) but must not require a real remote host. They validate the argument-building path against the actual tool.

- **`ssh -G localhost` round-trip.** Call `resolveSSHTarget(alias: "localhost")`. The test machine always has `localhost` in its known-hosts or at minimum as a resolvable name; the returned `SSHTarget.hostname` is either `localhost` or `127.0.0.1`. This confirms the `Process`-spawn + stdout-parse path works end-to-end with a real binary.
- **`ssh -G` on a fabricated `~/.ssh/config` alias.** Write a temp `~/.ssh/config` block (in a temp directory, overriding `HOME` for the subprocess) with a `Host testalias` stanza setting `HostName 10.0.0.99` and `User deploy`. Call `resolveSSHTarget(alias: "testalias")` with the modified environment. Assert `hostname == "10.0.0.99"` and `username == "deploy"`. This proves config expansion works for the real case users depend on.
- **LaunchProfile command is executable.** After calling `wrap` with a pre-resolved `SSHTarget`, assert that `FileManager.default.isExecutableFile(atPath: profile.command)` is true. This catches broken `sshExecutablePath()` fallback logic before it reaches ghostty.
- **No `-L`/`-N` flags anywhere in the argv.** Assert the arguments array contains neither `-L` nor `-N`. This is a stop-condition check that enforces the architectural decision; it should fail loudly if someone cargo-cults the port-forwarding pattern from t3 in a future edit.

### UX (visual gate + dogfood snippet)

This ticket's output is a `LaunchProfile`, not a rendered view, so the visual gate is a verification run in the live app rather than a screenshot diff. It is still a first-class gate — the backend tests prove the argv is correct; this confirms ghostty actually forks it and the session appears on the remote host.

**Dogfood snippet.** Prerequisites: a remote host reachable by SSH (a Hetzner CX32 or any box with tmux installed, configured as an entry in `~/.ssh/config` — e.g. `Host myvps`). Continuum must have the tile model extended with a `reach` field set to `.sshForward(SSHTarget(alias: "myvps", hostname: <resolved>, …))`.

Open Continuum. With the tile model patched to use `sshForward`, spawn a new terminal tile for that tile's project. In the tile's ghostty surface you should see the remote shell prompt (the prompt will show the VPS hostname or username, not your local machine name). In a second terminal (local), run `ssh myvps tmux list-sessions`. You should see `continuum-<tileId>: 1 windows` in the output — confirming the session lives on the remote host under the expected name. Close the tile and reconnect (spawn again); the `-A` flag reattaches rather than creating a duplicate session. If at any point you see "tmux: command not found" in the tile, the remote PATH resolution failed; check that tmux is on the remote's default PATH. If you see the connection immediately drop, the `ServerAlive` keepalives are not firing — check the `-o` flags in the spawned process's argv by adding a temporary `print(profile.arguments)` at the call site.

## Execution mode

**Supervised.** The logic and argv-construction tests are fully autonomous (pure Core, no real ssh connection). The `ssh -G localhost` and temp-config backend tests require a real `ssh` binary but no network beyond the loopback — these can run on any dev machine. However, the UX gate requires a real remote host with tmux installed and a configured `~/.ssh/config` alias, which is not available in a CI matrix without a substrate. The overall ticket is therefore supervised: an implementer must run the dogfood snippet against a real VPS to confirm the full attach path before marking this done.

## Done when

- [ ] `TmuxSession.wrap` accepts `reach: RemoteReach` with a default of `.localhost`; the `localhost` arm is bytewise identical to the previous implementation and all existing unit tests continue to pass without modification.
- [ ] The `sshForward` arm produces an argv containing `-o BatchMode=yes`, `-o ConnectTimeout=10`, `-o ServerAliveInterval=15`, `-o ServerAliveCountMax=3`, `-t`, and the correctly formatted host specifier, with no `-L` or `-N` flags present.
- [ ] `resolveSSHTarget(alias:)` shells out to `ssh -G`, parses `hostname` / `user` / `port` lines, and falls back to alias-as-hostname on any failure.
- [ ] All Logic tests pass (session name stability, shell quoting, argv shape, port/username omission, `-G` parse, fallback).
- [ ] Both Backend tests pass on a developer machine: `ssh -G localhost` round-trip and the temp-config alias expansion.
- [ ] The no-`-L`/no-`-N` assertion test passes and is part of the permanent test suite.
- [ ] The dogfood snippet has been executed: a tile using `sshForward` shows the remote shell prompt in ghostty, and `ssh myvps tmux list-sessions` confirms the session exists on the remote host with the expected `continuum-<tileId>` name.
- [ ] The `tunnel` arm triggers a `fatalError` with a message naming what must be built first; this is not dead code — it is an intentional stop condition.

## Depends on / unblocks

This ticket depends on the **reach-path model ticket** that introduces `RemoteReach` and `SSHTarget` as Codable Core types, and on `TileSpawner` threading a `reach` value down to `tmuxWrappedProfileIfAvailable`. Those two prerequisites are the only blockers; `TmuxSession.wrap` itself has no other dependencies.

It directly unblocks the **remote kill-session wrap** (the analogous change to `killSessionCommand` to produce `ssh <host> tmux kill-session -t …`), the **ssh observer reads** (all `ssh <host> tmux display …` calls the SessionObserver will need for remote status polling, per Decision D9), and the **Tailscale discovery ticket** (which contributes `SSHTarget` values via the `.tailscale` arm, which is already handled here because it resolves to the same argv shape as `sshForward`).

## Watch out for

**The remote tmux path.** The local arm passes the result of `TmuxLocator.resolve()` as `tmuxPath`, which is an absolute path on the Mac. The remote arm must use the bare string `"tmux"` and let the remote shell's `PATH` resolve it — never forward a local absolute path like `/opt/homebrew/bin/tmux` as the remote command. If `tmux` is not on the remote's default PATH, the attach will fail with "command not found"; this is a user configuration problem (they should add tmux to their remote PATH), not a Continuum bug to paper over.

**Shell quoting correctness.** The remote tmux invocation is passed as a single argument to ssh, which then hands it to the remote shell for evaluation. Every component — the tmux binary name, all flags, the session name (which contains a UUID with hyphens), and the `cwd` (which may contain spaces) — must be individually shell-quoted before joining with spaces. A missing quote around a path with spaces will silently mangle the cwd. The unit test for `shellQuote` is mandatory, not optional.

**`-t` is non-negotiable.** Without `-t`, ssh does not allocate a pseudo-tty, tmux cannot attach to an interactive session, and the attach command exits immediately with a "not a terminal" error. The presence of `-t` must be asserted in the Logic tests; if it is absent, ghostty will show a brief flash and close.

**`ssh -G` blocks on DNS in edge cases.** The 2-second timeout on `runSSHG` is a hard ceiling. If `ssh -G` stalls (e.g. the alias has a `ProxyJump` that triggers a DNS lookup), the timeout must fire and return `nil` rather than blocking `wrap`. Use `Process` with an explicit `terminationHandler` and a `DispatchSemaphore` with a timeout, not a simple synchronous `waitUntilExit()` call.

**The `tailscale` arm uses the same SSH shape.** A tailnet peer is just an SSH host reachable by its `100.x` or MagicDNS name — the locked decisions are explicit that `tailscale` is modeled as a discovered `sshForward` target, not a distinct transport. The `case .sshForward(let target), .tailscale(let target):` binding in the switch is intentional and correct; do not add a separate `tailscale` argv branch.
