# t3code steal — 01: Remote reach-paths & the Environment abstraction

**Author:** research agent (2026-06-30). **Audience:** a future implementing agent for Continuum's remote/VPS story.
**Scope (mine):** connectivity *establishment* + the reach-path menu + the `Environment` abstraction.
**Not mine (agent #2):** auth/pairing/tokens and RPC/transport semantics. I mark every seam where #2 hooks in but do not spec it.

Clone read at `…/scratchpad/t3code` (read-only). Every t3 claim is `file:line`. I separate **[VERIFIED from code]** from **[INFERRED]**.

---

## 0. TL;DR of the shape

t3code is the **inverse** of Continuum: one **T3 server** owns *all* runtime (terminals, git, fs, providers); thin clients (desktop/mobile/web) speak **one WebSocket/HTTP** to it. "Remote" is expressed *only at the connection layer* — never by splitting the runtime. Their governing doc says it outright:

> "remoteness is expressed at the environment connection layer, not by splitting the T3 runtime itself." — `docs/architecture/remote.md:59`

They separate two orthogonal axes, and this separation is the single most stealable idea:

- **Launch method** — *how does a server come to exist on the target machine?* (pre-existing / SSH-launched / locally-published-via-tunnel) — `remote.md:257-317`
- **Access method** — *how does the client speak to it?* (direct ws/wss / tunneled / SSH-forwarded-loopback) — `remote.md:190-255`

All four reach-paths **converge on one thing**: a `wsBaseUrl` (+ `httpBaseUrl`) the client connects to. The client does not know or care which path produced the URL. That convergence point is their `AccessEndpoint` / saved-environment record.

The four paths (what the prompt asked me to extract):

| # | Path | Server bind | How client reaches it | Inbound port needed? |
|---|------|-------------|------------------------|----------------------|
| 1 | **SSH-launch + loopback forward** | remote `127.0.0.1:<remotePort>` | `ssh -L localPort:127.0.0.1:remotePort`; client hits `ws://127.0.0.1:localPort` | **No** (rides ssh) |
| 2 | **Tailscale** | `0.0.0.0` or Tailnet IP; optional `tailscale serve` HTTPS | direct to `100.x.y.z:port` or `https://host.tailnet.ts.net/` | No (Tailnet mesh) |
| 3 | **Cloudflare Tunnel** | local loopback; `cloudflared tunnel run` dials **out** | client hits the CF edge hostname → relay → connector → server | **No** (outbound only) |
| 4 | **Direct `0.0.0.0` bind** | `0.0.0.0:port` | direct `ws://<LAN-ip>:port` | Yes (LAN/router) |

Path 1 is the one for Continuum. Read §2 first.

---

## 1. The unifying abstraction (steal this whole)

### 1.1 One saved record, discriminated by *how to reach it*

`PersistedSavedEnvironmentRecord` — `packages/contracts/src/ipc.ts:389-403` **[VERIFIED]**:

```ts
PersistedSavedEnvironmentRecord = Schema.Struct({
  environmentId: EnvironmentId,
  label: Schema.String,
  wsBaseUrl: Schema.String,          // ← the convergence point every path produces
  httpBaseUrl: Schema.String,
  createdAt: Schema.String,
  lastConnectedAt: Schema.NullOr(Schema.String),
  desktopSsh:   Schema.optionalKey(DesktopSshEnvironmentTargetSchema), // present ⇒ path 1
  relayManaged: Schema.optionalKey(Schema.Struct({ relayUrl: Schema.String })), // present ⇒ path 3
})
```

Note the design: the record is **not** a tagged union of transports. It is *always* a `wsBaseUrl` plus **optional reconnect metadata**. `desktopSsh` present means "to rebuild this URL, re-run the SSH launch+forward first." `relayManaged` means "this is served through a relay." A plain LAN/Tailscale entry has neither — the `wsBaseUrl` is directly dialable. The doc is explicit that this metadata is *for reconnect/lifecycle UX only* and must not change identity or protocol — `remote.md:299`, `remote.md:255`.

**This is the `RemoteEnvironment` enum the prompt wants** — but t3 models it as "URL + optional revival recipe," not "enum of live transports." Steal that framing.

### 1.2 Access vs. Launch (the mental model to copy)

- **Launch** (`remote.md:257`): `pre-existing | ssh-managed-remote-launch | client-managed-local-publish`.
- **Access** (`remote.md:190`): `direct-ws | tunneled-ws | ssh-forwarded-loopback`.

Why keep them separate (`remote.md:319-333`): the *same* server can be reached by direct wss AND a tunnel AND an ssh forward — it's one `ExecutionEnvironment`, only the path differs. If you fuse launch+access into one enum you get combinatorial drift.

### 1.3 Endpoint *discovery* is a provider plug-in, not core

`AdvertisedEndpoint` — `packages/contracts/src/remoteAccess.ts:55-68` **[VERIFIED]**. A backend/desktop-authored *candidate* URL carrying **hints**:

```ts
AdvertisedEndpoint = {
  id, label, provider,
  httpBaseUrl, wsBaseUrl,
  reachability: "loopback" | "lan" | "private-network" | "public",   // :13-19
  compatibility: { hostedHttpsApp: "compatible"|"mixed-content-blocked"|"requires-configuration"|"unknown", desktopApp: ... }, // :21-53
  source: "desktop-core"|"desktop-addon"|"server"|"user",
  status: "available"|"unavailable"|"unknown",
  isDefault?, description?,
}
```

Providers contribute endpoints; the UI/pairing picks from them without knowing provider commands (`remote.md:139-153`). First provider is Tailscale (`apps/desktop/src/backend/tailscaleEndpointProvider.ts:19-24`, `kind: "private-network", isAddon: true`). Crucial doctrine: **a provider hint is not proof** — the real connection attempt decides reachability (`remote.md:124`, `remote.md:152`). This is the **reach-path menu**: `getAdvertisedEndpoints` returns core endpoints + addon endpoints, UI shows one default + `+N` expandable list (`remote-access.md:25`, `DesktopServerExposure.ts:524-551`).

Continuum's "reach-path menu" = the same: enumerate candidate `Host` reach-paths, show one default, verify on connect.

---

## 2. Path 1 — SSH launch + remote-loopback forward (THE valuable one)

This is the exact trick for Continuum: **run the runtime on the remote host bound to its own loopback, forward that loopback port back over ssh, and let the client connect to `127.0.0.1` as if it were local.** t3 forwards a *WebSocket*; Continuum will forward a *tmux control/attach pty* — but the establishment machinery is identical.

### 2.1 Orchestration (top-level flow) — `packages/ssh/src/tunnel.ts`

`ensureEnvironment` (`tunnel.ts:1489-1551`) **[VERIFIED]** is the entry point. Flow (via `createTunnelEntry`, `tunnel.ts:1304-1415`):

```
1. resolveSshTarget(alias)            → run `ssh -G <alias>` to expand ~/.ssh/config (:328-365)
2. launchOrReuseRemoteServer(target)  → ssh in, run a bootstrap sh script, get {remotePort} (:690-745)
3. localPort = reserveLoopbackPort()  → pick a free local 127.0.0.1 port (:915-918)
4. startSshTunnel(local→remote)       → spawn `ssh -N -L local:127.0.0.1:remote` (:920-1140)
5. wait until http://127.0.0.1:localPort is ready (races against ssh-process-exit)
6. return { httpBaseUrl:"http://127.0.0.1:localPort/", wsBaseUrl:"ws://127.0.0.1:localPort/", ... }
```

Step 6 result becomes the saved record's `wsBaseUrl`. The renderer then connects to that loopback URL with **no ssh-awareness** (`remote.md:251-255`).

### 2.2 The port-forward spawn — the core primitive

`startSshTunnel` — `tunnel.ts:959-1012` **[VERIFIED]**. This is the argv you steal:

```ts
const args = [
  ...baseSshArgs(target, { batchMode }),   // -o BatchMode=… -o ConnectTimeout=10 [-p port]
  "-o", "ExitOnForwardFailure=yes",        // fail loudly if the -L bind can't be established
  "-o", "ServerAliveInterval=15",          // keepalive so dropped links are detected
  "-o", "ServerAliveCountMax=3",
  "-n",                                     // no stdin
  "-N",                                     // no remote command — forward only
  "-L", `${localPort}:127.0.0.1:${remotePort}`,   // ← THE TRICK
  hostSpec,                                 // user@host
];
// spawn ssh as a long-lived child; stdin = Stream.empty, endOnDone
```

Readiness + liveness are **raced** (`tunnel.ts:1071-1077`): `waitForHttpReady(httpBaseUrl, 20s)` vs. a fiber watching `child.exitCode`+stderr. Whichever wins decides. On failure it collects diagnostics — is the process still running? is the local port now listening? — and tails the remote server log (`tunnel.ts:1088-1126`). On any non-success it kills the child (`SIGTERM`, force-kill after 2s) (`tunnel.ts:1128-1137`).

`baseSshArgs` — `packages/ssh/src/command.ts:102-113` **[VERIFIED]**:
```ts
["-o", `BatchMode=${batchMode ?? "no"}`, "-o", "ConnectTimeout=10", ...(port ? ["-p", String(port)] : [])]
```

### 2.3 Remote launch: the bootstrap-over-stdin pattern (very stealable)

t3 does **not** assume the runtime is installed remotely. It ships a POSIX `sh` script over **ssh stdin** and runs `sh -s -- <stateKey>`:

`launchOrReuseRemoteServer` — `tunnel.ts:690-745` **[VERIFIED]**:
```ts
runSshCommand(target, {
  remoteCommandArgs: ["sh", "-s", "--", remoteStateKey(target)],
  stdin: buildRemoteLaunchScript(runner),   // the whole launcher script piped in
})
// parses last stdout line as JSON: {"remotePort":N,"serverKind":"managed"|"external"}
```

The launcher script `REMOTE_LAUNCH_SCRIPT` (`tunnel.ts:438-591`) **[VERIFIED]** does, on the remote host:
- **State dir** `~/.t3/ssh-launch/<sha256(target)[:16]>/` holding `pid`, `port`, `managed`, `server.log`, `run-t3.sh` (`tunnel.ts:441-449`; `remoteStateKey` at `command.ts:76-81`).
- **Reuse-or-launch:** if a prior server's pid is alive AND its port answers a readiness probe within 2s, reuse it; else pick a fresh port and `nohup … serve --host 127.0.0.1 --port $PORT … &`, disown, record pid/port (`tunnel.ts:508-589`). Note `--host 127.0.0.1` — **the remote server binds loopback only**; it's never exposed on the remote's network, only reachable through the ssh forward.
- **Port picking** (`REMOTE_PICK_PORT_SCRIPT`, `tunnel.ts:239-270`): tries to `net.createServer().listen(port,"127.0.0.1")` from a preferred port across a 200-port window (default base `3773`, `tunnel.ts:52-53`).
- **Readiness** (`REMOTE_WAIT_READY_SCRIPT`, `tunnel.ts:272-318`): loops `http.get 127.0.0.1:port/` until 2xx or deadline.
- **Node bootstrap** (`REMOTE_NODE_ENV_SCRIPT`, `tunnel.ts:320-411`): the big one — non-interactive ssh shells lack version-manager PATHs, so it probes volta/asdf/mise/fnm/nodenv/nvm shim dirs and activation hooks before giving up. (Continuum's analog: locating `tmux` + the agent CLI on the remote — Continuum already has `TmuxLocator`.)

Reconnect discipline (`remote-access.md:153`, `tunnel.ts:458-462`): the launcher diffs its generated `run-t3.sh` against the stored one; if changed (e.g. app updated) it kills the stale managed server and starts fresh. Steal this — it's why reconnect-after-update "just works."

### 2.4 `~/.ssh/config` expansion — free host resolution

`resolveSshTarget` — `command.ts:328-365` **[VERIFIED]**: runs `ssh -G <alias>` (preHostArgs `["-G"]`) and parses `hostname`/`user`/`port` out of the output (`parseSshResolveOutput`, `command.ts:45-70`). So a user typing `myvps` picks up their `~/.ssh/config` Host block (real hostname, key, port, jump host) for free. Falls back to treating the alias as a literal hostname on failure. **Continuum should do exactly this** — never reimplement ssh config parsing.

### 2.5 Lifecycle: reuse, dedupe, teardown

`SshEnvironmentManager` (`tunnel.ts:1142-1600`) **[VERIFIED]** keeps a `Map<key, SshTunnelEntry>` (`key` = `alias\0hostname\0user\0port`, `command.ts:72-74`):
- **Reuse:** `ensureTunnelEntry` (`:1417`) probes the existing entry's `httpBaseUrl` (2s); reuse if healthy, else close and rebuild.
- **Dedupe concurrent connects:** in-flight builds tracked by a `Deferred` per key so two callers share one tunnel (`:1455-1465`).
- **Teardown finalizer** (`:1360-1407`): kills the local `ssh -L` child **and** runs `REMOTE_STOP_SCRIPT` over a fresh ssh (`tunnel.ts:606-623`) to stop the managed remote server (skipped if `external`/reused).

### 2.6 Where agent #2 (auth) hooks into path 1

- **SSH auth itself** (askpass/password prompt retry) — `tunnel.ts:1193-1302`, `packages/ssh/src/auth.ts`. This is ssh-level, arguably shared, but the *interactive prompt UX* is #2-adjacent.
- **App-level pairing token:** after the forward is up, `issueRemotePairingToken` (`tunnel.ts:747-798`) runs `run-t3.sh auth pairing create --json` on the remote to mint a `credential`, returned in the bootstrap (`DesktopSshEnvironmentBootstrap.pairingToken`, `ipc.ts:315-322`). **That token → #2.** Connectivity's job ends at "loopback URL is up + a pairing token was fetched"; #2 owns exchanging it.

---

## 3. Path 2 — Tailscale (discovery + `serve` HTTPS)

Endpoint-*discovery* provider, not a t3-managed tunnel (`remote.md:238`). `packages/tailscale/src/tailscale.ts` **[VERIFIED]**.

### 3.1 Discovery via `tailscale status --json`

`readTailscaleStatus` — `tailscale.ts:183-232`:
```ts
spawn("tailscale", ["status", "--json"])          // "tailscale.exe" on win32 (:17-18)
// timeout 1.5s (:11); parse Self.DNSName + Self.TailscaleIPs
```
Parse helpers **[VERIFIED]**:
- `parseTailscaleStatus` (`:160-181`) → `{ magicDnsName, tailnetIpv4Addresses[] }`; strips trailing `.` from DNSName (`:124-132`).
- `isTailscaleIpv4Address` (`:142-158`): the `100.64.0.0/10` CGNAT test — `first===100 && 64<=second<=127`. This is how it recognizes a Tailnet IP among all local interfaces.

`resolveTailscaleAdvertisedEndpoints` (`tailscaleEndpointProvider.ts:101-146`) walks local network interfaces, keeps only Tailnet IPs, emits `http://100.x.y.z:port` endpoints (`:26-59`), plus optionally a MagicDNS HTTPS endpoint.

Perf note worth stealing (`DesktopServerExposure.ts:415-425`, `:533-538`): **cache the `tailscale status` spawn** (60s TTL) and **don't spawn it at all** unless the user opted into network exposure — on Mac App Store Tailscale each spawn triggers a macOS TCC "Other apps" prompt.

### 3.2 `tailscale serve` for clean HTTPS

`ensureTailscaleServe` — `tailscale.ts:296-305` **[VERIFIED]**:
```ts
spawn("tailscale", ["serve", "--bg", `--https=${servePort}`, `http://${localHost}:${localPort}`])
// default servePort 443 (:10); asks Tailscale to terminate TLS at host.tailnet.ts.net and proxy → local backend
```
`disableTailscaleServe` (`:307-318`): `["serve", "--https=443", "off"]`. HTTPS URL built by `buildTailscaleHttpsBaseUrl` (`:234-245`) → `https://<magicDnsName>[:port]/`. The endpoint is marked `unavailable`/`requires-configuration` until `probeTailscaleHttpsEndpoint` (`:320-336`, GETs `/.well-known/t3/environment`, 2.5s) confirms the URL actually reaches *this* backend (`tailscaleEndpointProvider.ts:82-97`). Server-side wiring: `serve --tailscale-serve` (`apps/server/src/server.ts:397-424`).

Why HTTPS matters here: the **hosted web app** at `app.t3.codes` can only connect to `wss://` (browser mixed-content), so a Tailnet HTTPS endpoint is what makes web pairing work (`remote-access.md:57-58`). Continuum is native, so this constraint is largely moot for us — but the **discovery** (`status --json` → CGNAT-IP filter) is directly useful.

---

## 4. Path 3 — Cloudflare Tunnel (`cloudflared` connector, dials out)

**[VERIFIED]** and a genuinely distinct 4th path (the prompt suspected it existed). This is the NAT-punching path: the server never binds a public port — it spawns `cloudflared` which establishes an **outbound** connection to Cloudflare's edge, and clients reach a CF hostname that routes back through the connector.

### 4.1 Download + manage the binary — `packages/shared/src/relayClient.ts`

`makeCloudflaredRelayClient` (`relayClient.ts:172-473`):
- **Pinned version** `CLOUDFLARED_VERSION = "2026.5.2"` (`:22`), per-platform release assets **with SHA-256** (`:71-99`).
- `resolve` (`:224-261`): prefer `T3CODE_CLOUDFLARED_PATH` override → managed copy under `<baseDir>/tools/cloudflared/<version>/<platform>-<arch>/cloudflared` → PATH lookup → else `missing`/`unsupported`.
- `install` (`:355-460`): download → **verify checksum** (`:319`, refuse on mismatch) → extract (tgz) → `chmod 755` → `--version` smoke test → atomic rename into place, guarded by a stale-aware file lock (`:328-353`). Progress events for UI.

### 4.2 Spawn the connector — `apps/server/src/cloud/ManagedEndpointRuntime.ts`

`reconcileConfig` (`ManagedEndpointRuntime.ts:184-294`) **[VERIFIED]**:
```ts
spawn(executablePath, ["tunnel", "run"], {
  env: { ...process.env, TUNNEL_TOKEN: config.connectorToken },  // ← token = the tunnel identity
  shell: false, stdout: "pipe", stderr: "pipe",
})
```
- **Connected signal by log-scraping:** `classifyRelayClientOutput` (`:71-76`) watches stderr for `Registered tunnel connection` → "connected"; `ERR|WRN` → warning. Output redacts the connector token (`:158`).
- **Supervision:** `superviseConnector` (`:112-149`) watches `child.exitCode`; if it dies and the desired config is unchanged, **auto-restart**. Reconciler is a desired-state loop guarded by a semaphore (`:296-301`) — apply a config, it converges (`disabled`/`running`/`failed`/`unsupported`, `:32-53`).

### 4.3 Where agent #2 owns this path

`config.connectorToken`, `tunnelId`, `tunnelName` (`RelayManagedEndpointRuntimeConfig`) come from the **relay provisioning flow** — `apps/server/src/cli/connect.ts` talks to `relayUrl/v1/client/environment-links/...` with a bearer token (`connect.ts:239-247`, `:414-429`). **All of that — token issuance, relay accounts, `relayManaged.relayUrl` on the saved record — is #2's territory.** Connectivity's slice here is only: *have a verified binary → spawn it with a token → detect "connected" → supervise/restart.*

---

## 5. Path 4 — direct `0.0.0.0` bind toggle

**[VERIFIED]** `apps/desktop/src/backend/DesktopServerExposure.ts`. Two-mode toggle `DesktopServerExposureMode = "local-only" | "network-accessible"` (`ipc.ts:405-410`):

`resolveDesktopServerExposure` (`DesktopServerExposure.ts:101-134`):
```ts
if mode === "local-only":       bindHost = "127.0.0.1" (:30, :113); no external endpoint
else /* network-accessible */:  bindHost = "0.0.0.0"  (:31, :128)
                                 advertisedHost = first non-internal, non-127/169.254 IPv4 (:78-99)
                                 endpointUrl = `http://${advertisedHost}:${port}`
```
Flipping the mode **requires a backend relaunch** if the bind host changed (`requiresBackendRelaunch`, `:402-405`; UI copy "This will restart the app and run the backend on all network interfaces," `remote-access.md:24`). Headless CLI defaults differ: `serve` leaves `host` unset (→ binds broadly) whereas desktop defaults `127.0.0.1` (`apps/server/src/cli/config.ts:326-333`); the `--host` flag literally documents `127.0.0.1, 0.0.0.0, or a Tailnet IP` (`config.ts:30`). This path needs a real inbound route (LAN/router), unlike 1/2/3.

---

## 6. Swift / Continuum sketch

Continuum runs `tmux` locally and attaches ghostty to a **local pty** (`TmuxSession.wrap` → `tmux new-session -A -s continuum-<uuid> …`, `Sources/ContinuumRevivedCore/TmuxSession.swift:12-25`; ghostty forks that as a local pty). Decision D already proposes the whole move: add a `Host`, make the wrap `ssh <host> -t 'tmux …'`, ghostty still forks a *local* pty (the ssh client), the session lives on the VPS (`docs/38-agent-orchestration-architecture.md:324-333`).

**What t3 adds to Decision D: turn "just ssh-wrap" into the 4-path menu, and split launch from access.** For Continuum, tmux over ssh is *simpler* than t3's forward-a-WebSocket because a tmux attach is an interactive ssh command — you often don't even need `-L` (§7). Two viable shapes:

### 6.1 The model — a reach-path enum on the Host

```swift
// New in Core, mirrors t3's PersistedSavedEnvironmentRecord: identity + optional revival recipe.
public enum RemoteReach: Equatable, Sendable, Codable {
    case localhost
    /// Path 1-analog: tmux lives on host; ghostty attaches over an ssh pty.
    /// Optionally forward a control port if we later add a tmux control-mode socket.
    case sshForward(SSHTarget)               // user@host (+~/.ssh/config), optional -L
    /// Path 2-analog: host is a Tailnet node; ssh target is a 100.x/ MagicDNS name.
    case tailscale(SSHTarget)                // discovered, not a distinct transport
    /// Path 3-analog: reach the host through a relay/tunnel connector.
    case tunnel(relayHost: String)           // token/provisioning = agent #2
}

public struct SSHTarget: Equatable, Sendable, Codable {
    public var alias: String                 // what the user typed
    public var hostname: String              // from `ssh -G` (t3: command.ts:328)
    public var username: String?
    public var port: Int?
    // resolved lazily; alias alone is enough to start (picks up ~/.ssh/config)
}

// The saved unit — t3's PersistedSavedEnvironmentRecord (ipc.ts:389).
// Continuum equivalent: a field on Project/Workspace (Decision D says "a host field on the model").
public struct RemoteEnvironment: Equatable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var reach: RemoteReach            // discriminator = HOW to reach, not a live socket
    public var lastConnectedAt: Date?
}
```

### 6.2 tmux + ghostty riding each path — the wrap layer

The whole point of Decision D: this is **almost entirely a `TmuxSession.wrap` change** plus the model field. `LaunchProfile` (`Sources/ContinuumRevivedCore/LaunchProfile.swift:3-15`) already carries `command/arguments/cwd/title`; ghostty forks whatever `command` we hand it. So:

```swift
extension TmuxSession {
    /// Existing local wrap is the localhost case; this generalizes over reach.
    public static func wrap(profile: LaunchProfile, tileId: UUID,
                            tmuxPath: String, reach: RemoteReach) -> LaunchProfile {
        let name = sessionName(tileId: tileId)   // continuum-<uuid>, unchanged (:8-9)
        // The inner tmux argv is IDENTICAL for every path — the session lives wherever it runs.
        let inner = ["new-session", "-A", "-s", name, "-c", profile.cwd] + innerCommand(profile)

        switch reach {
        case .localhost:
            return LaunchProfile(command: tmuxPath, arguments: inner, cwd: profile.cwd, title: profile.title)

        case .sshForward(let t), .tailscale(let t):
            // ghostty forks a LOCAL pty = the ssh client. The tmux session lives on the VPS,
            // survives disconnects (tmux -A reattaches). This is Decision D verbatim + t3's -G resolution.
            let host = t.username.map { "\($0)@\(t.hostname)" } ?? t.hostname
            var ssh = sshBaseArgs(port: t.port)          // -o ConnectTimeout=10, -o ServerAliveInterval=15,
                                                          // -o ServerAliveCountMax=3  (steal from t3 command.ts:102, tunnel.ts:964-968)
            ssh += ["-t", host, remoteTmuxInvocation(tmuxPath: "tmux", inner: inner)]
            // Note: NO -N here. Unlike t3 (which forwards a WS with -N), Continuum's attach IS the
            // remote command. -L is only needed if we later add a tmux control-mode socket (§7).
            return LaunchProfile(command: sshExecutable(), arguments: ssh, cwd: profile.cwd, title: profile.title)

        case .tunnel:
            // Reaching the host is the same ssh attach; only the *route* to the host differs
            // (connector/relay stands up host reachability first). Left for the tunnel-provisioning work.
            fatalError("wire once tunnel host reachability exists")
        }
    }
}
```

Kill/observe follow the same substitution: `killSessionCommand` (`TmuxSession.swift:27-29`) becomes `ssh <host> tmux kill-session -t …`; Decision C's observer (`tmux display …` / `capture-pane`) becomes `ssh <host> tmux display …` — same reader, remote argv (`docs/38:...:329-331`).

### 6.3 The reach-path menu (Continuum UI)

Mirror t3's `getAdvertisedEndpoints` → default + `+N` (`DesktopServerExposure.ts:524-551`, `remote-access.md:25`). A `HostReachProvider` enumerates candidates:
- **core:** `localhost`.
- **ssh addon:** parse `~/.ssh/config` Host blocks (t3 discovers hosts from `ssh-config`/`known-hosts` — `DesktopSshEnvironment.discoverHosts`, `packages/ssh/src/config.ts`).
- **tailscale addon:** spawn `tailscale status --json`, filter `100.64/10` (steal `isTailscaleIpv4Address`), offer each Tailnet peer as an `sshForward`/`tailscale` target. Cache 60s; only spawn on demand.

Doctrine to keep (`remote.md:124`): a listed reach-path is a **hint** — only a successful ssh/attach marks it reachable. And per Dylan's TDD memory, every threshold (ConnectTimeout, keepalive interval, port-scan window, readiness timeout) should be a persisted, Settings-exposed config, not hardcoded.

---

## 7. What does NOT transfer

1. **t3 forwards a *WebSocket* to a *web server*; Continuum forwards a *tmux/pty attach*.** t3's `-N -L local:127.0.0.1:remote` (`tunnel.ts:969-972`) exists because the thing on the far end is an HTTP/WS listener a browser/renderer dials. Continuum's far end is a tmux server you *attach* to with an interactive ssh command — the attach **is** the remote command, so `sshForward` typically needs **no `-L` and no `-N`**. `-L` only returns if Continuum later adds tmux **control mode** (`tmux -CC`) over a forwarded unix socket, or an agent-daemon HTTP port (Decision D's "Continuum host daemon" fork, `docs/38:337`). Do not cargo-cult the `-L`/readiness-probe machinery for the basic attach.

2. **The client/server runtime split.** t3's entire premise — server owns all runtime, thin clients (`remote.md:24-59`) — is the *opposite* of Continuum (native ghostty + offline-first spatial canvas). We are not adopting an `ExecutionEnvironment = one server` model; our "environment" is *a host we run tmux on*, and the canvas/state stay local (Decision E keeps the spatial layer device-portable, `docs/38:340`). Steal the *reach-path abstraction*, not the architecture.

3. **HTTP readiness probing as the health signal.** t3 knows the tunnel is up by `GET 127.0.0.1:localPort/` returning 2xx (`tunnel.ts:1072`). Continuum's health signal is "did the ssh attach succeed / is the tmux session alive" (`tmux has-session -t …`) — a different probe. Their *race-readiness-against-process-exit* pattern (`tunnel.ts:1071`) is still worth stealing conceptually for detecting a dead ssh link fast.

4. **`cloudflared` binary-management weight.** The pinned-version + checksum + atomic-install + file-lock apparatus (`relayClient.ts:172-473`) is real engineering, but it only matters if Continuum ships a tunnel path. For a VPS-first product where the user already has ssh to the box, path 1 covers the case without any of it. Defer path 3 until there's a concrete NAT'd-host requirement.

5. **Hosted-web mixed-content constraints & Tailscale Serve HTTPS.** The whole `hostedHttpsCompatibility` axis (`remoteAccess.ts:21-28`) and `tailscale serve --https` (`tailscale.ts:296`) exist to satisfy *browser* rules for `app.t3.codes`. Continuum is a native app; ignore the HTTPS-termination path and keep only Tailscale *discovery*.

---

## 8. Open questions / forks (for the implementing agent)

1. **ssh-wrap vs. host daemon (Decision D's own open item, `docs/38:335-337`).** t3 validates the *ssh-wrap-and-bootstrap-a-script* approach heavily (`REMOTE_LAUNCH_SCRIPT`). For Continuum's observer (Decision C poll over ssh), per-poll ssh latency may hurt (`docs/38:336`) — t3 sidesteps this by keeping *one* long-lived connection (the WS through the forward) rather than polling. **Fork:** does Continuum keep one long-lived `tmux -CC` control connection (t3-like, low-latency, needs `-L`) or many short `ssh tmux display` polls (Decision D's faster-to-ship ssh-wrap)? t3 leans toward the persistent connection.

2. **Where does the remote tmux session's lifecycle state live?** t3 keeps `~/.t3/ssh-launch/<key>/{pid,port,managed}` on the remote for reuse/reconnect (`tunnel.ts:441-449`). Continuum's tmux already persists server-side (`tmux new-session -A` reattaches). **Question:** do we still need a remote state dir, or is `tmux has-session` + our tile UUID (`sessionName`, `TmuxSession.swift:8-9`) sufficient? Likely sufficient — tmux *is* the state store — but reconnect-after-app-update (t3's runner-diff, `tunnel.ts:458`) may want a marker.

3. **Reconnect/backoff on link drop (Decision D open, `docs/38:335`).** Steal t3's `ServerAliveInterval=15`/`ServerAliveCountMax=3` (`tunnel.ts:965-967`) to *detect* drops, and the reuse-probe-then-rebuild pattern (`tunnel.ts:1424-1452`) to recover. Backoff policy is unspecified in t3 (it rebuilds on demand) — Continuum must define one.

4. **Auth boundary handshake (→ #2).** Path 1 ends with "loopback URL up + optional pairing token" (`ensureEnvironment` returns `DesktopSshEnvironmentBootstrap`, `tunnel.ts:1543-1550`). For Continuum-over-ssh, ssh *is* the auth (keys/known-hosts) — so is there even a separate app-level pairing step, or does #2's token layer collapse into "you have ssh access"? **This is the seam to reconcile with agent #2.**

5. **Tailscale as a *reach* vs. a *discovery* input.** In t3 Tailscale only *discovers HTTP endpoints* (`remote.md:238`). For Continuum, a Tailnet peer is really just "an ssh host reachable by its `100.x`/MagicDNS name" — i.e. it collapses into `sshForward`. **Fork:** keep `tailscale` as a distinct `RemoteReach` case (nicer UI labeling, t3-style provider) or fold it into `sshForward` with a discovered target? Leaning fold-with-label.

---

### Appendix — file:line index (t3code)

- SSH forward launcher & orchestration: `packages/ssh/src/tunnel.ts` (`startSshTunnel` :959, `ensureEnvironment` :1489, `REMOTE_LAUNCH_SCRIPT` :438, `launchOrReuseRemoteServer` :690, mgr :1142).
- SSH command/argv/`-G` resolve: `packages/ssh/src/command.ts` (`baseSshArgs` :102, `resolveSshTarget` :328, keys :72-81).
- Desktop SSH env service (wires manager + password prompt): `apps/desktop/src/ssh/DesktopSshEnvironment.ts` (:127-171).
- Tailscale discovery/serve: `packages/tailscale/src/tailscale.ts` (`readTailscaleStatus` :183, `isTailscaleIpv4Address` :142, `ensureTailscaleServe` :296, `probe` :320).
- Tailscale endpoint provider: `apps/desktop/src/backend/tailscaleEndpointProvider.ts` (:19-146).
- Cloudflare binary mgmt: `packages/shared/src/relayClient.ts` (`makeCloudflaredRelayClient` :172, assets :71-99, install :355).
- Cloudflare connector spawn/supervise: `apps/server/src/cloud/ManagedEndpointRuntime.ts` (`reconcileConfig` :184, spawn :224-236, log-scrape :71).
- Direct `0.0.0.0` bind toggle: `apps/desktop/src/backend/DesktopServerExposure.ts` (`resolveDesktopServerExposure` :101, hosts :30-31).
- CLI serve flags/host default: `apps/server/src/cli/config.ts` (`--host` :30, default :326-333, tailscale :64-72).
- The unified saved record + endpoint types: `packages/contracts/src/ipc.ts` (`PersistedSavedEnvironmentRecord` :389, SSH target/bootstrap :292-331, exposure mode :405), `packages/contracts/src/remoteAccess.ts` (`AdvertisedEndpoint` :55, reachability :13).
- Governing architecture: `docs/architecture/remote.md` (access vs launch, provider model), `docs/user/remote-access.md` (the four user-facing options).

### Appendix — Continuum seams touched

- `Sources/ContinuumRevivedCore/TmuxSession.swift` — `wrap` :12, `killSessionCommand` :27, `sessionName` :8; `TmuxLocator` :36 (remote-tool-locate analog).
- `Sources/ContinuumRevivedCore/LaunchProfile.swift` — `LaunchProfile` :3 (what ghostty forks).
- `Sources/ContinuumRevived/App/TileSpawner.swift` — `tmuxWrappedProfileIfAvailable` :221 (the call site that gains a `reach` param).
- `docs/38-agent-orchestration-architecture.md` — Decision D :324-338; Decision C observer (same-reader claim); Decision E sync boundary :340.
