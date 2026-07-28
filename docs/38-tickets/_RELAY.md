# The relay — what it is, why it keeps dying, how to harden it

Written 2026-07-27 after the simulator sat on "Syncing… Waiting for your Mac" indefinitely.
Companion to `_PHONE_SYNC_HANDOFF.md` (which has the pairing/firewall lore) and ticket
`86-relay-sync-transport.md` (which specified it).

---

## 1 · What the relay is, and why it exists

`continuum-relay` is a small HTTP long-poll server. The Mac **publishes** sanitized activity into
it; the phone/simulator **long-polls** it. Neither side talks to the other directly.

It exists because of a locked product decision: **sync must be self-owned and fully remote.** No
iCloud, no CloudKit dependency, no Apple account in the path, and not LAN-only either — the phone
has to work from anywhere. A relay we run is the only shape that satisfies all three. Today it runs
on the Mac at `127.0.0.1:8787` for the dev loop; slice 3 of ticket 86 moves the same binary to a VPS
behind TLS.

**The I5 invariant still governs what crosses it**: only derived metadata — never paths, transcript
bodies, pids, or secrets. The relay is a dumb pipe and must stay one.

### Shape

- **Target**: `Sources/continuum-relay/main.swift` (63 lines — argument parsing and a `dispatchMain()`).
- **Guts**: `RelayHub` (sessions, sequence numbers, long-poll waiters), `RelayHTTPServer`,
  `RelayTokenRegistry`, `RelayWire`.
- **Endpoints**: `GET /v1/health`, `POST /v1/hello`, `GET /v1/poll`, `POST /v1/publish`,
  `POST /v1/tokens`.
- **Auth**: bearer tokens with scopes. The **operator** token authorizes the Mac's publish leg and
  lets it register phone pairing tokens at runtime via `POST /v1/tokens`. Observer tokens are a dev
  convenience.
- **State is entirely in memory.** `RelayTokenRegistry(seed:)` is seeded from the command line;
  everything else lives in the hub. There is no database and nothing on disk.

---

## 2 · What actually happened tonight

Evidence, in order:

```
2026-07-27T00:37:48Z reason=relay-token-sync registered=3/3     ← last healthy beat
2026-07-28T01:43:52Z manual publish FAILED: notConnected
2026-07-28T01:44:19Z manual publish FAILED: notConnected        ← 21:44 local, app launch
```

At 21:47 there was **no `continuum-relay` process and nothing listening on 8787**. The relay had
been started by hand at some earlier point and had since gone away. The Mac was trying to publish
and failing; the simulator was long-polling a hub that did not exist. Both sides waited forever,
which is exactly what "Waiting for your Mac" means — it is the phone's honest report that nobody is
publishing.

I restarted it. The Mac reconnected in under ten seconds and re-registered every token:

```
2026-07-28T01:48:41Z reason=relay-token-sync registered=3/3
```

Now healthy: PID 15804 holds the listener, `/v1/health` answers `{"latestSeq":30,"subscribers":0}`,
the Mac and the simulator are both connected, and the Mac publishes every few seconds with
`transport=relay paired=true pairedDevices=3 lastError=nil`.

### Two corrections to what I said in the moment

1. **`pairedDevices: []` in `registry.json` is not the pairing source of truth.** The live sync log
   reports `pairedDevices=3`. The registry field is empty while pairing is genuinely fine. Do not
   diagnose pairing from that field.
2. **The relay log lied to me**, and the way it lied is itself a bug — see §3.2.

---

## 3 · Why it broke — root causes, ranked

### 3.1 Nothing supervises it (the actual cause)

The relay is started by hand:

```bash
nohup .build/debug/continuum-relay --host 0.0.0.0 --port 8787 --operator-token "$(…)" \
  > ~/Library/Logs/continuum-relay.log 2>&1 & disown
```

`nohup … & disown` survives the terminal closing. It does **not** survive a reboot, a logout, a
crash, or an OOM kill, and nothing restarts it. There is no supervisor, no health check, and no
alert. The first thing that tells you it died is a phone stuck on "Waiting for your Mac" — a symptom
that appears far from the cause and looks like a sync bug rather than a dead process.

`_PHONE_SYNC_HANDOFF.md` records that a LaunchAgent was attempted and **failed oddly** — "process
runs under launchd but never listens on the port", left unresolved. So the one attempt at
supervision was abandoned and never revisited. See §5 for why that probably happened and how to
settle it in one run.

### 3.2 The log cannot distinguish a healthy relay from a dead one

This one wasted my time tonight and will waste yours.

`main.swift` announces success with `print(...)`. **`stdout` is block-buffered when it is not a
TTY**, so when you redirect to a file that line sits in a 4 KB buffer and never appears. Failure
goes through `FileHandle.standardError`, which is unbuffered and lands immediately.

The result is inverted from what you want: **a healthy relay writes an empty log; a failing one
writes a clear message.** Tonight the log contained exactly one line —
`continuum-relay: could not start: bindFailed(48)` — while a perfectly healthy relay was serving
traffic. I briefly believed the relay had failed when it had not.

### 3.3 A duplicate start destroys the evidence

Two things compound:

- The runbook uses `>` (truncate), not `>>` (append). Every start wipes the history.
- A second instance hits `bindFailed(48)` (`EADDRINUSE`), writes that to the same file, and exits 2 —
  **overwriting the log of the healthy instance that is still running**.

So "the log says bind failed" can mean "everything is fine and you started it twice". There is no
preflight check for an existing listener and no PID file.

### 3.4 The binary lives somewhere ephemeral

`.build/debug/continuum-relay` is a **debug** build inside a gitignored SPM build directory that the
ticket loop rebuilds constantly. Replacing the file under a running process is harmless on Unix (the
inode survives), but `swift package clean` deletes it outright — after which any supervisor would be
pointing at a path that no longer exists.

### 3.5 The operator token is exposed in the process table

```
$ ps -Ao command | grep continuum-relay
.build/debug/continuum-relay --host 0.0.0.0 --port 8787 --operator-token <redacted>
```

Passing the secret as `argv` makes it readable by **any local process**. `main.swift` already
accepts `CONTINUUM_RELAY_OPERATOR_TOKEN` from the environment; nothing uses it. The env route is
strictly better and is also what makes a LaunchAgent clean (§5).

### 3.6 `--host 0.0.0.0` is wider than the dev loop needs

Plain HTTP with a bearer token, bound to every interface. On loopback that is fine — the simulator
shares the Mac's loopback. On a café or hotel LAN it is an open door. The phone leg genuinely needs
a non-loopback bind, but the sim leg does not, and the default should not be the wide one.

---

## 4 · What is *not* broken (don't "fix" these)

- **Client resilience is already good.** `RelaySyncTransport` has an exponential backoff schedule —
  1s, 2s, 4s, 8s, 15s, last entry repeating — surfaces `.reconnecting` on `connectionState`, and
  keeps the underlying error for diagnostics. It reconnected on its own the moment the relay
  returned. The clients did not need changing tonight and do not now.
- **Restarts are safe.** Clients detect the hub reset and rejoin; the Mac re-registers all tokens on
  every connect (the `relay-token-sync registered=3/3` rows). Proven again tonight.
- **The hub core is covered by the matrix** — auth/scope, lossless catch-up, and the I5 gate all have
  checks (ticket 86 D4-R1). The gap is that nothing asserts the *process* starts and serves, only
  that the library behaves.

---

## 5 · The launchd mystery, and how to end it

The recorded symptom — "runs under launchd but never listens" — is worth re-testing, because
`main.swift` makes it nearly impossible as stated: if `server.start()` throws, the process calls
`fail()` and **exits 2**. It cannot run and not listen. So the observation was probably one of:

- **the process was exiting immediately and launchd was restarting it**, which from the outside
  looks like "running but not listening"; or
- **`$(defaults read …)` was placed in `ProgramArguments`**, which does **no shell expansion** — the
  relay would receive a literal `$(defaults …)` string as its token, start, listen, and then reject
  the Mac's auth; or
- **the whole command was passed as one `ProgramArguments` string**, so the relay hit
  `default: fail("unknown flag …")` and exited 2 on every launch.

All three are invisible without captured stderr, which the original attempt presumably lacked. **The
diagnostic is one line in the plist**: set `StandardErrorPath`, load it, and read the file. That
settles it in a single run rather than another evening of guessing.

The plist should also avoid the shell entirely by putting the secret in `EnvironmentVariables`,
which `main.swift` already reads.

---

## 6 · Managed development service (implemented)

`scripts/relay-dev.sh` is the only supported local-development lifecycle surface. It builds a
release executable and installs it at:

```
~/Library/Application Support/Continuum/DevRelay/bin/continuum-relay
```

It generates `~/Library/LaunchAgents/com.continuum.revived.relay.dev.plist` with absolute paths,
`RunAtLoad`, `KeepAlive`, a restart throttle, separate captured stdout/stderr logs, and the operator
credential in `EnvironmentVariables`. The credential is never put in `ProgramArguments`, readiness
and failure lines are written immediately, and readiness logs contain no token or token prefix.
The script reuses the Mac's configured development operator token when present; on a first install
it generates one and configures the Mac defaults.

The default mode is **loopback** (`127.0.0.1`). `lan` is an explicit opt-in that binds plain HTTP to
`0.0.0.0` for supervised physical-phone work on a trusted network. The Mac and simulator still use
`http://127.0.0.1:8787`; the existing pairing path advertises the Mac's LAN address where needed.
Changing mode regenerates and reloads the owned LaunchAgent.

The in-memory token registry remains intentionally unchanged. After a process restart the running
Mac reconnects and registers active phone tokens again. VPS/Linux/TLS, relay persistence,
multi-tenancy, and product-visible relay UX remain outside this local-dev cut.

The relay matrix leg now crosses the executable boundary: it launches the real `continuum-relay`
on an ephemeral loopback port, probes `/v1/health`, and proves its token is absent from argv and
logs. A side-effect-free contract seam checks both generated plist modes without touching launchd,
defaults, or user files.

---

## 7 · Runbook

```bash
cd /Users/dylan/Documents/personal/continuum-overnight

# Install/update, configure Mac defaults, and start under launchd (loopback default)
./scripts/relay-dev.sh install

# Truthful layered diagnosis: launchd → expected PID/binary → listener → health
# → Mac config → latest redacted companion-sync line
./scripts/relay-dev.sh status

# Captured append-style history (separate immediate stdout/stderr)
./scripts/relay-dev.sh logs

# Lifecycle (all idempotent)
./scripts/relay-dev.sh start
./scripts/relay-dev.sh stop
./scripts/relay-dev.sh restart

# Explicitly expose on the LAN, or return to the safe default
./scripts/relay-dev.sh mode lan
./scripts/relay-dev.sh mode loopback

# Configure the booted simulator (an explicit UDID may be supplied)
./scripts/relay-dev.sh simulator

# Independent real-subprocess probe
./scripts/relay-dev.sh smoke

# Unload and remove only the managed service, its directory, plist, and relay defaults
./scripts/relay-dev.sh uninstall
```

Do **not** start a second copy with `nohup`, pass the token with `--operator-token`, redirect with
`>` into a shared log, `pkill -f` relay processes, or run a `.build` binary as the long-lived
service. Those are historical incident evidence above, not supported operations.

**Diagnostic order when the phone says "Waiting for your Mac":**

1. `./scripts/relay-dev.sh status` — any failed launchd/process/listener/health layer is a relay
   lifecycle failure; use `restart`, then inspect `logs`.
2. Read `mac-sync-latest` in status. `notConnected` confirms the Mac cannot reach the relay;
   `reason=relay-token-sync registered=N/N` proves active pairing tokens were re-registered.
3. Only if all layers are healthy, investigate pairing — and use `pairedDevices=N` from the sync
   log, **not** `pairedDevices` in `registry.json`, which can be empty while pairing works.

---

## 8 · Deferred questions

- What should the phone show when the relay is unreachable versus when the Mac is simply idle?
  Today both read "Waiting for your Mac". That is product UX and was deliberately not changed here.
- VPS hosting, TLS, relay persistence, and multi-tenancy remain future deployment work. The Mac app
  does not own or spawn the local service; launchd ownership is now the settled development path.
