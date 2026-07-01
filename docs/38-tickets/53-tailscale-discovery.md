# Tailscale peer discovery, caching, and folding into the SSH forward path

## What this delivers

When the user opens the reach-path menu to connect a workspace to a remote host,
Continuum automatically enumerates every machine on their Tailnet — VPSes, other Macs,
any Linux box — and presents them as ready-to-connect SSH targets without the user
having to type a hostname or IP address. Discovery runs by spawning `tailscale status
--json`, parsing the CGNAT-range addresses (`100.64.0.0/10`) and MagicDNS names from the
JSON output, and caching the result for 60 seconds so repeated opens of the menu don't
hammer the Tailscale daemon. Each discovered peer materialises as an `sshForward` reach
target on the `RemoteEnvironment`, so the rest of the attach path — the `TmuxSession.wrap`
SSH command construction, keepalive flags, `ssh -G` config resolution — is completely
unchanged. The `.tailscale` case in `wrap` is already built and shipped by the `Host` /
`RemoteReach` model ticket (which folds `.tailscale` into the same switch branch as
`.sshForward`), so this ticket touches no attach code at all; the discovery layer is just a
provider of `SSHTarget` values, nothing more.

The system outcome is that adding a Tailscale VPS to the user's workflow costs zero
configuration in Continuum: enroll the box in the tailnet, open the reach-path menu, and
it appears. No public SSH port needs to be exposed; the Tailnet mesh is the network.

## How it fits

This ticket sits at the end of the Phase 5 remote-execution sprint. The `Host` /
`RemoteReach` model (the settled Swift enum that holds `localhost | sshForward | tailscale
| tunnel` and the `SSHTarget` struct) must already exist before this ticket starts — that
model is what this ticket produces values *for*. The `sshForward` attach wrap (which
produces the `ssh -t <host> 'tmux new-session -A -s …'` command from an `SSHTarget`) must
also be in place, because Tailscale peers fold directly into that path and are exercised on
a real host by the remote attach real path ticket. Together those two tickets give this
ticket a known-good code path to deliver into.

Concretely: once this ticket ships, the reach-path menu has all three non-tunnel cases
populated — localhost is always present, manually-entered SSH aliases are resolved via `ssh
-G`, and tailnet peers are discovered automatically. The Tailscale case does not add a new
code path through `TmuxSession.wrap`; it adds a new *source* of `SSHTarget` values that
feed into the existing `sshForward` branch. That clean composition is the whole point.

This ticket does not unblock any subsequent ticket directly — the remote execution phase
is otherwise complete — but it is the quality-of-life capstone that makes the remote story
usable without manual hostname entry, and it is the prerequisite for a future iOS reach
(an iPhone on the same tailnet can observe the VPS via the same discovered target).

## The approach

Spawn `tailscale status --json` as a one-shot subprocess with a 1.5-second timeout (the
same ceiling t3code uses, from `tailscaleEndpointProvider.ts:101`). Parse the JSON output
using `JSONSerialization` — no Codable schema needed, the structure is stable and the
fields we need are shallow. Extract `Self.TailscaleIPs` (an array of IP strings on the
local node) and `Peer` (a dictionary keyed by public key, each entry carrying
`TailscaleIPs`, `DNSName`, `HostName`, and `Online`). Filter peers to those with at least
one address in the `100.64.0.0/10` CGNAT range (first octet is 100, second octet is in
[64, 127] — the exact predicate from t3's `isTailscaleIpv4Address`, `tailscale.ts:142-158`).
Discard offline peers (`Online == false`). For each surviving peer, prefer the MagicDNS
name (`DNSName` with its trailing `.` stripped) as the hostname, falling back to the raw
`100.x.y.z` IP address if the DNS name is empty.

Wrap this logic in a `TailscaleDiscovery` actor (an actor, not a class, so cache access
is safe across the async call sites that the reach-path menu will use). The actor holds a
cached result and a timestamp; on each call it checks whether the cache is older than 60
seconds, and only spawns `tailscale` if the cache has expired or was never populated. This
60-second TTL is not configurable in Settings (the menu is opened infrequently and the
cost of a stale 60-second window is zero — the user just reopens) but the constant is
defined as a named `let` at the top of the actor so it can be changed without hunting.

Crucially, the spawn must be guarded: if `tailscale` is not on `$PATH` and is not at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale` (the Mac App Store install
location), the actor returns an empty array silently and logs at debug level. It never
surfaces an error to the UI — Tailscale is an optional enhancement, not a requirement.
Avoid spawning at all until the user opens the reach-path menu for the first time; do not
prefetch on app launch, because the Mac App Store Tailscale daemon triggers a macOS TCC
"Other Apps" access-confirmation prompt on every spawn and prefetching would cause that
prompt to fire unexpectedly at startup.

Each discovered peer is returned as an `SSHTarget` with `alias` set to the MagicDNS name
(or the `100.x` IP if no DNS name), `hostname` set to the same value (since `ssh -G`
resolution adds no value for a raw IP or a MagicDNS name that is directly routable),
`username` nil (the user's system username is the ssh default), and `port` nil (22). The
calling site wraps each in a `RemoteEnvironment` with `reach: .tailscale(target)` so the
UI can badge the entry with the Tailscale label. The `RemoteReach.tailscale` case is
*already handled* in `TmuxSession.wrap` — the model ticket wired it into the same switch
branch as `.sshForward` (`case .sshForward(let target), .tailscale(let target):`), so a
`.tailscale` `RemoteEnvironment` flows through the identical, existing SSH argv path with no
new wrap code needed here. This ticket only produces the values; it does not touch `wrap`.

## Where it lives

The entire discovery implementation is new Core code. No existing file needs structural
changes. In particular, `TmuxSession.swift` is **not** touched by this ticket: its `wrap`
switch already handles `.tailscale` in the same branch as `.sshForward`, wired by the `Host`
/ `RemoteReach` model ticket (dependency). This ticket relies on that existing handling — it
adds no case, no argv, no line to `wrap`.

**New files:**

- `Sources/ContinuumRevivedCore/TailscaleDiscovery.swift` — the `TailscaleDiscovery`
  actor: `discover() async -> [SSHTarget]`, internal cache (`cachedResult: [SSHTarget]?`,
  `cacheTimestamp: Date?`), `spawnTailscaleStatus() async throws -> Data`,
  `parsePeers(json: Any) -> [SSHTarget]`, `isTailscaleIPv4(_ address: String) -> Bool`.

- `Sources/ContinuumRevivedCore/TailscaleDiscoveryTests.swift` (or in the test target) —
  pure unit tests against `parsePeers` and `isTailscaleIPv4` with fixture JSON.

**Existing files touched:**

- The reach-path menu UI call site (wherever in the app layer the `HostReachProvider`
  enumerates candidates for the connection sheet) gains a call to
  `TailscaleDiscovery.shared.discover()` and merges the resulting `SSHTarget` array into
  the menu items as `.tailscale`-reach `RemoteEnvironment` values.

**Not touched (already done by the dependency):**

- `Sources/ContinuumRevivedCore/TmuxSession.swift` — no edit. The `Host` / `RemoteReach`
  model ticket already ships the combined `case .sshForward(let target), .tailscale(let
  target):` branch in `wrap` (they produce identical argv). There is nothing for this ticket
  to add there. If you open `wrap` and find `.tailscale` *not* already in that branch, the
  model ticket did not land as specified — stop and reconcile with it rather than adding the
  case here, so the case is never defined in two places.

## Implementation breadcrumbs

```swift
// TailscaleDiscovery.swift
public actor TailscaleDiscovery {
    public static let shared = TailscaleDiscovery()
    private let cacheTTL: TimeInterval = 60
    private var cachedPeers: [SSHTarget] = []
    private var cacheTimestamp: Date = .distantPast

    public func discover() async -> [SSHTarget] {
        if Date().timeIntervalSince(cacheTimestamp) < cacheTTL {
            return cachedPeers
        }
        guard let executableURL = resolveTailscaleBinary() else {
            // tailscale not installed; silently return empty — not an error
            return []
        }
        do {
            let data = try await spawnTailscaleStatus(at: executableURL)
            let parsed = try parsePeers(from: data)
            cachedPeers = parsed
            cacheTimestamp = Date()
            return parsed
        } catch {
            // log at debug, never surface to UI
            return cachedPeers // stale is better than empty on transient error
        }
    }

    // Internal: spawn "tailscale status --json" with 1.5s timeout
    private func spawnTailscaleStatus(at url: URL) async throws -> Data {
        // Use Foundation Process; set qualityOfService = .userInitiated
        // Enforce 1.5-second wall-clock timeout; throw if exceeded or nonzero exit
    }

    // Internal: walk json["Peer"] dict, filter to CGNAT, return SSHTargets
    func parsePeers(from data: Data) throws -> [SSHTarget] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: Any] else { return [] }
        return peers.values.compactMap { entry -> SSHTarget? in
            guard let dict = entry as? [String: Any],
                  let online = dict["Online"] as? Bool, online,
                  let ips = dict["TailscaleIPs"] as? [String],
                  let tailnetIP = ips.first(where: isTailscaleIPv4) else { return nil }
            let dnsName = (dict["DNSName"] as? String ?? "")
                .trimmingCharacters(in: .init(charactersIn: "."))
            let hostname = dnsName.isEmpty ? tailnetIP : dnsName
            return SSHTarget(alias: hostname, hostname: hostname, username: nil, port: nil)
        }
    }

    // Internal: 100.64.0.0/10 test — first octet 100, second octet in [64, 127]
    func isTailscaleIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    // Internal: check /Applications/Tailscale.app/Contents/MacOS/Tailscale, then PATH
    private func resolveTailscaleBinary() -> URL? { ... }
}

// TmuxSession.swift — NOT edited here. The dependency (Host / RemoteReach model ticket)
// already ships this combined branch; a .tailscale RemoteEnvironment flows straight through
// it. Confirm it is present; do not re-add it:
//     case .sshForward(let target), .tailscale(let target):
//         // identical argv — tailscale IS sshForward over the Tailnet mesh (already built)
```

The reach-path menu call site:

```swift
// In the connection sheet / HostReachProvider:
let tailscalePeers = await TailscaleDiscovery.shared.discover()
let tailscaleItems = tailscalePeers.map { target in
    RemoteEnvironment(id: UUID(), label: target.alias, reach: .tailscale(target), lastConnectedAt: nil)
}
// Merge with manually-entered ssh hosts; present tailscale items with a "Tailscale" badge
```

## How we test it

### Logic (pure Core checks)

`parsePeers` and `isTailscaleIPv4` are pure functions on the actor and are tested without
any process spawn. Write XCTest cases covering:

- A JSON fixture with two online peers in the CGNAT range (one with a MagicDNS name, one
  with only an IP), one online peer with a non-CGNAT IP (should be filtered out), and one
  offline peer with a CGNAT IP (should be filtered out). Assert exactly two `SSHTarget`
  values are returned; assert the MagicDNS name is used for the first; assert the raw IP
  is used for the second; assert the trailing `.` is stripped from `DNSName`.

- `isTailscaleIPv4` boundary cases: `100.64.0.1` → true, `100.127.255.255` → true,
  `100.63.255.255` → false (second octet 63 is outside the range), `100.128.0.0` → false,
  `101.64.0.1` → false, `100.64` (short) → false, `not-an-ip` → false.

- A JSON fixture with a `DNSName` of `"myvps.tailnet.ts.net."` (trailing dot); assert the
  returned `hostname` is `"myvps.tailnet.ts.net"` with no trailing dot.

- An empty `Peer` dictionary → zero results, no crash.

- Malformed JSON → `parsePeers` throws; the actor catches and returns the stale cache
  (which is empty on first call), no error propagated to callers.

### Backend (real-path / integration)

This test requires a machine with Tailscale installed and enrolled in a tailnet — it cannot
be faked or mocked. On a real Mac with at least one other active tailnet peer (the VPS used
for the remote attach real path ticket is the natural counterpart):

1. Call `TailscaleDiscovery.shared.discover()` and assert the result is non-empty.
2. Assert that at least one returned `SSHTarget.hostname` matches what `tailscale status
   --json` reports directly for that peer's `DNSName` or first `TailscaleIPs` entry.
3. Assert that calling `discover()` a second time within 60 seconds returns the same
   result without re-spawning `tailscale` (instrument with a counter on the spawn path or
   verify via elapsed time — a second call should complete in under 5 ms because it is
   served from cache).
4. Take one of the returned `SSHTarget` values, pass it through `TmuxSession.wrap` with
   reach `.tailscale(target)`, and assert the resulting `LaunchProfile.command` is the ssh
   executable and the `arguments` array contains `-t` and the expected hostname string.

This test is gated behind an availability check: if `resolveTailscaleBinary()` returns nil
the test skips with `XCTSkip`, so CI without Tailscale installed does not fail.

### UX (visual gate + dogfood snippet)

The dogfood path: open Continuum on a Mac that is enrolled in a Tailscale tailnet alongside
at least one other device (the remote VPS is ideal). Open the workspace connection sheet or
the reach-path menu via Settings > Remote > "Add host…". Before any input, the "Tailscale"
section of the menu should populate automatically within 1.5 seconds and list the tailnet
peer by its MagicDNS name (e.g. `myvps.tailnet.ts.net`). The item should be visually
badged with the Tailscale label (not a plain SSH entry). Select it and initiate the
connection. The attach should succeed identically to a manually-entered `sshForward` host —
a ghostty surface appears, attached to the remote tmux session, with the title showing the
remote hostname. Dismiss and reopen the menu within 60 seconds: the list should reappear
instantly with no visible delay (cache hit). Wait 61 seconds and reopen: a brief spinner
(under 1.5 seconds) should precede the list reappearing (cache miss, re-spawn).

If Tailscale is not installed, the "Tailscale" section of the menu must be absent entirely —
no error message, no empty section header, nothing that implies a broken feature.

## Execution mode

**Needs-substrate.** The logic tests (pure Core) are autonomous and deterministic, but
the integration test requires a real Tailscale installation with a real tailnet and at
least one enrolled peer, and the UX gate requires a real attach to a remote host. The TCC
prompt behavior (Mac App Store Tailscale triggering an OS confirmation dialog on first
spawn) can only be verified on a real Mac, not in CI. No part of this ticket can be fully
verified by core/matrix checks alone — real network substrate is required for the
integration and UX gates.

## Done when

- [ ] `TailscaleDiscovery` actor exists in `Sources/ContinuumRevivedCore/` with
  `discover() async -> [SSHTarget]`, the 60-second cache, and `resolveTailscaleBinary()`
  checking both the App Store install path and `$PATH`.
- [ ] `isTailscaleIPv4(_:)` passes all boundary-case unit tests including the `100.63`
  and `100.128` edge values.
- [ ] `parsePeers(from:)` correctly strips the trailing `.` from `DNSName` and falls back
  to the raw IP when `DNSName` is empty, verified by the fixture tests.
- [ ] Offline peers (`Online == false`) are absent from the returned array, verified by
  the fixture test.
- [ ] `TmuxSession.wrap` handles `.tailscale(let t)` in the same branch as `.sshForward(let
  t)` with no duplicate logic.
- [ ] Calling `discover()` when `tailscale` is not installed returns an empty array and
  does not throw or log at any level above debug.
- [ ] The integration test passes on a real tailnet: non-empty result, correct hostname,
  second call within TTL is cache-served in under 5 ms.
- [ ] The reach-path menu in the real app shows a Tailscale section populated with tailnet
  peers by MagicDNS name, with no section visible when Tailscale is not installed.
- [ ] An end-to-end attach through a discovered Tailscale peer succeeds: ghostty surface
  opens, remote tmux session attached, session survives a disconnect and reattach (`-A`
  flag is present in the spawned argv).
- [ ] No spawn occurs on app launch; the first spawn is deferred until the reach-path menu
  is opened.

## Depends on / unblocks

This ticket depends on the `Host` / `RemoteReach` model (the `RemoteReach` enum,
`SSHTarget` struct, and `RemoteEnvironment` record that the discovery layer produces values
into) and the `sshForward` attach wrap (which is the code path that Tailscale peers fold
into and which the integration test exercises end-to-end). It also depends on the remote
attach real path ticket, because the "does a Tailscale-discovered host actually attach
correctly" integration test uses the same real VPS that the remote attach work proves out.

This ticket does not gate any subsequent ticket in the planned build order. It is the final
Phase 5 remote-execution ticket and completes the reach-path menu's three wired cases
(`localhost`, manual `sshForward`, auto-discovered `tailscale`). The `tunnel` case remains
a stub in the enum; it is not wired here and fires `fatalError` or returns nil in
`wrap` until a future ticket implements it.

## Watch out for

**The TCC prompt is the most dangerous UX regression.** On the Mac App Store version of
Tailscale, each call to `tailscale status --json` (spawning the CLI) can trigger a macOS
"Other Apps" access dialog if the app hasn't been granted permission yet. Do not spawn on
app launch, do not spawn in the background on a timer, and do not spawn more than once per
60-second window. The guard that checks `cacheTimestamp` before spawning is not optional
— it is the protection against repeated TCC prompts annoying the user.

**The `tailscale` binary location is not stable.** The Homebrew install puts it at
`/opt/homebrew/bin/tailscale` (arm64 Macs) or `/usr/local/bin/tailscale` (Intel). The Mac
App Store install's CLI is at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`. A user who installed via a third
path (e.g. direct download) may have it somewhere else entirely. The resolver should check
the App Store path first, then walk `$PATH`, and return nil — not crash — if neither finds
it. Do not hardcode a single path.

**MagicDNS names in the JSON carry a trailing `.`** (they are fully-qualified DNS names
in the wire format). The strip must happen unconditionally; an `SSHTarget` with
`hostname: "myvps.tailnet.ts.net."` (trailing dot) will fail `ssh` host resolution with a
confusing error. The unit test for this is mandatory, not optional.

**Do not re-implement the `ssh -G` resolution step for Tailscale peers.** A Tailnet IP
or MagicDNS hostname is already directly routable on the tailnet; there is no `~/.ssh/config`
Host block to expand for it. Pass the discovered hostname directly as `SSHTarget.hostname`
and `SSHTarget.alias`. The `ssh -G` expansion happens inside the `sshForward` attach wrap
when it resolves the alias — for a raw IP or MagicDNS name, `ssh -G` will echo the input
back unchanged, which is correct behaviour.

**Stale cache on tailnet membership change** — if the user adds a new VPS to the tailnet
and opens the menu within 60 seconds of a prior spawn, they will not see it. This is
acceptable: the 60-second TTL is a deliberate tradeoff against TCC prompt frequency, and
the user can force a refresh by closing and reopening the menu after 60 seconds. Do not
add a manual refresh button in this ticket; that is scope creep.

**Offline peers in the JSON are not the same as unreachable peers.** `Online: false` means
Tailscale knows the peer is not currently connected to the tailnet. It does not cover the
case where `Online: true` but the peer is behind a firewall that blocks the tailnet route.
Filter on `Online` only; reachability is proven (or not) by the actual SSH connect attempt,
following the doctrine that a listed reach-path is a hint, not a guarantee.
