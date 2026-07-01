# Cloud, DevOps & Hosting — the money-and-plumbing guide

Status: **research / decision-support — 2026-06-30.** Audience: the Continuum owner
(Dylan) + future implementing agents. This is the companion to
`docs/38-agent-orchestration-architecture.md`: that doc decides *what* the distributed
canvas is; **this** doc decides *what it costs, what you sign up for, and which vendor
box each piece runs in.* It resolves the parts of the design that are least about Swift
and most about "wait, how much is this and what do I actually provision."

**How to read the confidence tags.** Every price is tagged:
- **[verified]** — read off the vendor's own pricing page or a first-party doc, with a
  URL + access date (all accesses 2026-06-30 unless noted). These are real 2026 dollars.
- **[estimate]** — my arithmetic on top of verified inputs (e.g. "solo stack total"), or
  a figure from a reputable third-party aggregator when the vendor hides the number.
- **[judgment]** — reasoning about fit/tradeoffs, not a number.

Prices move. Currency: EUR-priced vendors (Hetzner, Scaleway) are shown in EUR with an
approximate USD at ~1.08 USD/EUR **[estimate]**; treat the EUR as authoritative.

**The scenario this must serve** (from the prompt + `docs/38`): Continuum is a **native
macOS/Swift** app (future iOS companion), an infinite-canvas terminal + agent
workspace. It wants to (a) run coding agents on a **remote VPS** and attach from the
Mac; (b) **sync** its spatial op-log and stream a one-way agent-activity projection to
iOS in ~realtime; (c) send iOS **push** ("your agent needs you"); (d) *maybe* run a
small **Node "sidecar"** to drive agent protocols (ACP / `codex app-server` / Claude
SDK are Node/TS). It is **offline-first and native, not a web app** — which changes
almost every recommendation below versus a typical SaaS.

---

## TL;DR — the two stacks and their monthly cost

If you read nothing else, read this. Full derivation in §8.

| Layer | **Solo / Personal (cheapest sane)** | **Small team (2–5 people)** |
|---|---|---|
| Remote agent host (VPS) | Hetzner CX32 (EU) — **€6.80/mo** (~$7.34) | Hetzner CPX41 or CCX-dedicated — **~€30–45/mo** |
| Reach the box | SSH (free) + Tailscale Personal (**free**) | Tailscale Standard **$8/user/mo** (or stay on SSH, free) |
| Sync transport | CloudKit private DB — **$0** (rides iCloud) | CloudKit — **$0**, or self-host relay on the same VPS — **$0 marginal** |
| iOS push (APNS) | Apple Developer Program — **$99/yr** (~$8.25/mo amortized) | same **$99/yr** (one org membership) |
| Node sidecar | bundled in the .app — **$0** marginal (no separate host) | same **$0** |
| CI/CD | GitHub Actions free tier + manual notarize — **$0** | GitHub Actions macOS overage — **~$5–20/mo** |
| Auto-update | Sparkle + static file host (or GitHub Releases) — **$0** | same **$0** |
| **Recurring cash /mo** | **≈ $15.6/mo** (VPS $7.3 + Apple $8.25; everything else free-tier) | **≈ $50–90/mo** depending on team size + VPS tier |
| **Required one-time** | Apple Developer Program is annual, not one-time; no other upfront | same |

The headline: **the whole solo stack is dominated by two line items — a small VPS and
the Apple Developer membership — and everything genuinely hard (sync, push transport,
auto-update) is free at your scale.** That is not an accident of this design; it is the
*point* of choosing CloudKit + APNS + Sparkle + a hand-rolled op-log over commercial
SaaS. **[judgment]**

---

## 1. Remote agent hosting — the VPS

**The job (narrow, and it matters).** You are not hosting a web app or a database
fleet. You need "a box I can SSH into that runs `tmux` + coding agents (Claude Code,
Codex, Pi) for hours, survives disconnects, and that my Mac attaches to." Per `docs/38`
Decision D and the t3code reach-path analysis (`01-remote-reach-paths.md`), Continuum
forwards a **tmux attach over an interactive SSH command** — *not* a forwarded web port.
So the box's requirements are humble:

- **RAM is the binding constraint, not CPU.** Coding agents are memory-hungry when they
  spawn language servers, run test suites, and hold large context; a Node sidecar + a
  couple of concurrent agents wants headroom. 4 GB is a workable floor, **8 GB is the
  comfortable solo target**, 16 GB if you run several agents at once. CPU is bursty —
  shared vCPU is fine. **[judgment]**
- **Persistent disk** for repos + agent state stores (`~/.claude`, `~/.codex`,
  `<projectRoot>/.pi`). 40–80 GB covers a lot of repos.
- **A stable place `tmux` lives.** Any always-on Linux box qualifies. tmux *is* the
  persistence layer (`docs/34`), so you do not need the host to do anything clever.

### Options + verified 2026 pricing

All specs are shared-vCPU Linux, the right class for this workload.

| Provider | Plan | vCPU / RAM / disk | Region | Monthly | Source |
|---|---|---|---|---|---|
| **Hetzner** | CX22 | 2 / 4 GB / 40 GB | EU (DE/FI) | **€3.79** (~$4.09) | [verified] hetzner.com/cloud |
| **Hetzner** | **CX32** | **4 / 8 GB / 80 GB** | EU | **€6.80** (~$7.34) | [verified] |
| **Hetzner** | CX42 | 8 / 16 GB / 160 GB | EU | **€16.40** (~$17.71) | [verified] |
| **Hetzner** | CPX21 | 3 / 4 GB / 80 GB | EU | ~**€7.99** (US higher) | [verified] press/price-adj |
| **DigitalOcean** | Basic 2 GB | 1 / 2 GB / 50 GB | global | **$12.00** | [verified] digitalocean.com/pricing/droplets |
| **DigitalOcean** | Basic 4 GB | 2 / 4 GB / 80 GB | global | **$24.00** | [verified] |
| **DigitalOcean** | Basic 8 GB | 4 / 8 GB / 160 GB | global | **$48.00** | [verified] |
| **Fly.io** | shared-cpu-2x @ 4 GB | 2 / 4 GB (+vol) | global | **~$22.22** + $0.15/GB vol | [verified] fly.io/docs/about/pricing |
| **Fly.io** | shared-cpu-4x @ 8 GB | 4 / 8 GB (+vol) | global | **~$44.44** + vol | [verified] |
| **AWS Lightsail** | 2 GB | 2 / 2 GB / 60 GB | global | **$30 (bundle "Small")** | [verified] aws.amazon.com/lightsail/pricing |
| **AWS Lightsail** | 4 GB | 2 / 4 GB / 80 GB | global | **$80 (bundle "Large")** | [verified] |
| **Scaleway** | DEV1-S | 2 / 2 GB | EU | **~€6.42** (~$6.93) | [estimate] vpsbenchmarks/pcr |
| **Scaleway** | DEV1-M | 3 / 4 GB | EU | **~€14.45** (~$15.61) | [estimate] |

**Naming caveat (Hetzner).** Hetzner has two overlapping generations in the wild in
2026: the older `CX22/CPX22` naming and a newer `CX23/CX33/CX43` line seen on some
calculators (CX23 ≈ €5.49, CX33 ≈ €8.49). The **CX-series (Intel/AMD shared, EU-only)**
is the price-leader; the **CPX-series (AMD EPYC shared)** is available in the US
(Ashburn VA, Hillsboro OR) and Singapore but at a **surcharge** — Hetzner states US/SG
operating costs are higher and prices those regions up with **reduced traffic
allowances** (US 1–8 TB vs EU 20 TB). A **CPX22 rose to €7.99/mo (from €5.99) on
2026-04-01.** [verified: hetzner.com/pressroom/new-cx-plans, docs.hetzner.com price-adjustment]

### Ergonomics for "run tmux + agents on a box" — the part that actually decides it

Raw price is only half the story. The lived experience of provisioning and running
long-lived agent sessions differs sharply. **[judgment throughout this subsection]**

- **Hetzner** — the pragmatic winner. Plain Ubuntu VM, full root, `apt install tmux`,
  SSH keys, done. 20 TB EU traffic is effectively unlimited for this use. The catch: the
  cheap CX tier is **EU-only**, so a US-based owner eats ~90–150 ms RTT on the SSH
  attach and observer polls. For Continuum that latency lands on *keystroke echo* in an
  attached pane and on the `ssh tmux display` observer poll (`docs/38` Decision C).
  Keystroke latency at 100 ms is noticeable but usable; the observer is occasional and
  fine. If you're in the US and latency bugs you, take a **CPX in Ashburn** (~$8–9) and
  pay the small surcharge for ~20–40 ms.
- **DigitalOcean** — the "it just works, and there's a US region near me" choice. More
  expensive per GB than Hetzner (2× at the 8 GB tier) but great docs, a clean console,
  global regions (so low-latency attach from anywhere), and per-second billing since
  2026-01-01. If ergonomics-per-dollar-of-your-time matters more than the raw bill, this
  is defensible.
- **Fly.io** — architecturally a poor fit here, and worth saying plainly. Fly is built
  to run *deployed app images* (Machines), not "a pet box you SSH into and leave tmux
  running for a week." You *can* run a persistent Machine with a volume, but you're
  fighting the grain: Machines are meant to be ephemeral/scale-to-zero, the **legacy
  free tier is gone for new customers**, and "long-lived interactive tmux host" is not
  the workflow Fly optimizes. Skip for the VPS role. (Fly could later host a *stateless
  relay*, §3 — different story.)
- **AWS Lightsail** — the most expensive for equivalent RAM ($80 for 4 GB vs Hetzner's
  €6.80 for 8 GB — roughly **10× at the comparable tier**) and you inherit AWS-console
  complexity for zero benefit at this scale. Its only real draw is if you're *already*
  deep in AWS. There is a **3-month free trial** on the $5/$7/$12 Linux bundles (accounts
  since 2021-07-08) — nice for a spike, not a basis for the standing recommendation. Skip.
- **Scaleway** — a credible EU budget alternative to Hetzner (DEV1-M ≈ €14.45 for 4 GB);
  fewer people run it, docs are thinner, and a **price increase took effect 2026-06-01**.
  Fine as a fallback, no reason to prefer it over Hetzner.

### RECOMMENDATION — VPS

> **Solo: Hetzner CX32 (4 vCPU / 8 GB / 80 GB, EU) at €6.80/mo (~$7.34).** [verified]
> It is the price-performance leader by a wide margin, gives you comfortable RAM for a
> Node sidecar + multiple agents, and tmux-on-Ubuntu is the exact ergonomic Continuum's
> reach layer assumes. **If you are US-based and the ~100 ms attach latency annoys you,
> switch to a Hetzner CPX in Ashburn (~$8–9) or a DigitalOcean 8 GB droplet ($48) for a
> US region** — the whole recommendation is "small shared-vCPU box near you with root +
> tmux," and any of these satisfy it.
>
> **Small team: Hetzner CPX41-class or a dedicated CCX (~€30–45/mo)** when several
> people run agents concurrently and you want more predictable CPU. The step up is about
> concurrency headroom, not a different architecture.

**Tradeoff being accepted:** Hetzner's cheap tier is EU-located, so a US user trades
~$40/mo (DO 8 GB) for lower attach latency, or accepts ~100 ms to save it. That is the
only real fork here, and it is a comfort call, not a correctness one. **[judgment]**

---

## 2. Reaching the box — SSH vs Tailscale vs Cloudflare Tunnel

**The Continuum-specific twist, stated up front.** Per `01-remote-reach-paths.md` §7,
Continuum forwards a **tmux attach**, which *is* an interactive SSH command — so unlike
t3code (which forwards a WebSocket and therefore needs `ssh -N -L …`), Continuum's basic
remote attach needs **no port-forward and no `-N`**. The wrap is essentially
`ssh -t <host> 'tmux new-session -A -s … '`. Port-forwarding only re-enters the picture
if you later add a **tmux control-mode socket** (`tmux -CC`) or a **Continuum host
daemon** with an HTTP port (the Decision D open fork). This makes the reach story much
simpler than a web-app's.

### The three options

| Option | What it is | Cost 2026 | Inbound port needed? | Source |
|---|---|---|---|---|
| **Plain SSH** | You already have it; `ssh user@host`, keys in `~/.ssh`, `ssh -G` expands `~/.ssh/config` | **$0** | Yes — port 22 open to the internet (or firewalled to your IP) | — |
| **Tailscale** | WireGuard mesh; the VPS + your Mac + iPhone all join a private *tailnet*; reach the box by its `100.x` / MagicDNS name | **Personal: free** (up to 6 users, unlimited devices); Standard **$8/user/mo**; Premium **$18/user/mo** | **No** — mesh, box binds to tailnet only | [verified] tailscale.com/pricing |
| **Cloudflare Tunnel** | `cloudflared` on the box dials *out* to Cloudflare's edge; clients reach a CF hostname routed back | **Core tunnel: free, no usage limits.** Zero Trust free up to 50 users | **No** — outbound-only (NAT-punch) | [verified] blog.cloudflare.com/tunnel-for-everyone, cloudflare.com/plans |

### How each maps onto a tmux attach

- **SSH** is the natural fit and the phase-1 answer. The attach *is* an SSH command;
  `ssh -G myvps` picks up your `~/.ssh/config` Host block for free (real hostname, key,
  jump host) — steal exactly this, never reimplement SSH config parsing
  (`01-remote-reach-paths.md` §2.4). Harden with `ServerAliveInterval=15` /
  `ServerAliveCountMax=3` to detect dropped links fast (`tunnel.ts` pattern). The only
  downside is you expose port 22 (mitigate: key-only auth, `fail2ban`, or firewall to
  your source IPs).
- **Tailscale** is the upgrade that makes **iOS-reaches-the-box** clean and removes the
  public SSH port entirely. Your iPhone, Mac, and VPS all sit on one private mesh; the
  Mac attaches to `100.x.y.z` or `myvps.tailnet.ts.net` with no inbound firewall rule
  anywhere. Crucially it collapses into the SSH path — a Tailnet peer is "just an SSH
  host reachable by its `100.x` name" (`01-remote-reach-paths.md` §8 fork 5), so
  Continuum can model it as a discovered `sshForward` target rather than a distinct
  transport. Discovery is `tailscale status --json` filtered to the `100.64.0.0/10`
  CGNAT range; **cache it 60 s and only spawn on demand** (Mac App Store Tailscale
  triggers a TCC prompt per spawn).
- **Cloudflare Tunnel** solves a problem Continuum mostly doesn't have. It's for
  reaching a box behind NAT with no inbound route and no mesh — but a **VPS already has a
  public IP**, so there's nothing to punch. It also shines for *HTTPS to a browser*,
  which is irrelevant to a native tmux attach. Its binary-management weight (pinned
  version, checksum, atomic install — `relayClient.ts`) is real engineering you'd only
  take on for a concrete NAT'd-host requirement. **Defer.**

### RECOMMENDATION — reach

> **Solo, phase 1: plain SSH** (free; hardened key-only, `ServerAlive*` keepalives),
> modeled as the `localhost | sshForward | tailscale | tunnel` reach-path *menu* from
> `01-remote-reach-paths.md` but only `localhost` + `sshForward` wired.
>
> **The moment iOS enters the picture (or you want to stop exposing port 22): add
> Tailscale Personal — free for your 6 users / unlimited devices.** It is the single
> highest-leverage free upgrade in this whole document: it makes Mac↔VPS↔iPhone one
> private network, kills the public SSH surface, and folds neatly into the existing
> `sshForward` code path. Only pay for Tailscale Standard ($8/user/mo) if a **team**
> needs shared ACLs / SSO.
>
> **Cloudflare Tunnel: not now.** Revisit only if you ever need to reach a box with no
> public IP (e.g. an agent host behind a home router).

**Tradeoff:** SSH exposes a port but needs zero new software; Tailscale adds a daemon on
every device but is strictly nicer once >1 device is involved — and it's free at your
scale, so the "cost" is purely the install. **[judgment]**

---

## 3. Sync transport — the spatial op-log + the activity projection

This is the layer the owner finds most confusing, and rightly: it's where "native
Apple app" collides with "realtime sync," and the vendor landscape is noisy. Anchor on
what `docs/38` and the spikes already decided, because it narrows the field hard:

- The **merge model is settled: a deterministic op-log** (`SYNC-MODEL.md`), *not* an
  off-the-shelf CRDT, contingent on low contention + the I4 fuzz going green. The op-log
  emits **self-contained `LoggedOp`s + occasional compacted snapshots, ordered by a
  logical (Lamport) clock**, and is **transport-agnostic by design**. So the transport's
  only job is: *move small opaque messages between a few of one person's Apple devices,
  reliably, eventually, ideally near-realtime, with an offline queue.*
- Two logical topics ride the transport (`04-orchestration-sessions-projections.md` S1,
  open-Q7): **(a) spatial ops** (bidirectional) and **(b) the activity-tree projection**
  (one-way host→observers, snapshot-then-tail). One channel, two topics.
- **I5 keeps runtime handles off the wire regardless of transport** — that's the op-log
  enum's job, not the transport's.

Given that, "realtime SaaS" is mostly the wrong category. Here are the three real
candidates.

### Option A — CloudKit (Swift-native, no server)

**What it is.** Apple's iCloud-backed sync + datastore. The user's **iCloud account is
the identity** — no signup, no password reset, no account recovery to build
(`medium.com/@chandra.welim CloudKit`, `developer.apple.com/icloud/cloudkit`). You get a
**private database** per user (their data, their iCloud), plus a shared/public DB. Push
delivery of changes is built in via `CKSubscription` (silent pushes on record change).

**Pricing / limits (2026).** The **private database costs against the *user's* iCloud
quota, not yours** — effectively free to you at any single-user scale. The developer-side
**free tier** (which governs the *public* DB and shared containers) is roughly **10 GB
asset storage, 100 MB DB storage, 2 GB/day transfer**, and public storage scales with
active users (+250 MB per user). [verified-ish: developer articles dated 2026-01;
**Apple has removed the detailed quota table from public docs**, so treat the exact
numbers as [estimate] and the shape — "private DB is on the user's dime, generous free
public tier" — as [verified]].

**Fit.** Excellent for this exact shape. Single user, ≤ few Apple-only devices, small
documents (tens of tiles), offline-tolerant. CloudKit gives you **offline queue +
change push + zero servers to run + zero auth to build**. The op-log maps cleanly: one
`CKRecord` per `LoggedOp` (idempotent upsert keyed by `OpId`) or per compacted snapshot;
`CKSubscription` pushes deliver the live tail; the activity projection is a second record
type. `SYNC-MODEL.md` explicitly names CloudKit as the lowest-ops first transport.

**The catches (be honest):**
- **Latency is "near-realtime," measured in seconds, not milliseconds.** CloudKit push
  is not a low-latency game channel. For a *canvas that also renders on a phone*, seconds
  is fine (`SYNC-MODEL.md` transport table). For the **activity projection** — "your
  agent needs you" — seconds is also fine because the *urgent* signal is APNS (§4), not
  the sync channel. So CloudKit's latency profile is acceptable precisely because
  Continuum's realtime-urgent path is push, not sync.
- **Apple-only.** That's a feature here (iOS is the only other client), not a bug.
- **CKShare has known 2026 rough edges** (open bugs; iOS 26 beta changed share-URL app
  launching; `CKShareRequestAccessOperation` reportedly nonfunctional in beta). This only
  matters if you use CloudKit *sharing* across **different** iCloud accounts (i.e. a team
  of different people). For **one person's own devices** you use the **private DB with
  no CKShare** — you never touch the buggy surface. [verified: forums 2026]

### Option B — Self-hosted WebSocket relay on the VPS

**What it is.** A dumb, stateless op-log broker: a small process on the *same VPS from §1*
that fans `LoggedOp`s out over WebSockets and can replay the log. `SYNC-MODEL.md` names
this the **best real-time-latency** option.

**Pricing.** **$0 marginal** — it runs on the box you're already paying for. (If you
wanted it separate: a Fly.io shared-cpu-1x @ 256 MB is ~$2/mo [verified], but there's no
reason to.)

**Fit / cost.** Lowest latency (real WebSocket, sub-second). But **you own auth,
identity, reconnect, and uptime** — which is exactly the machinery `02-transport-auth-pairing.md`
specs (pairing token → scoped session → per-message authorize, `wsTicket` for the
upgrade). That doc is a gift: if you go relay, you have a battle-tested blueprint. But
it's real code, and the relay is now a **thing that can be down** while your Mac and
phone want to sync. For a solo user that's a step backwards from CloudKit's "Apple keeps
it up." **[judgment]**

### Option C — Commercial realtime (Ably / Pusher / Liveblocks)

| Vendor | Free tier (2026) | First paid | Swift/iOS fit | Source |
|---|---|---|---|---|
| **Ably** | 6M msgs/mo, 200 concurrent connections, 500 msg/s | scales by usage | Has Swift SDK; generic pub/sub, maps to op stream | [verified] ably.com/pricing |
| **Pusher Channels** | Sandbox: 100 concurrent conns, 200k msgs/day | Startup **$49/mo** | Swift SDK; simple channels | [verified] pusher.com/channels/pricing |
| **Liveblocks** | Free: up to ~50–200 MAU (varies by source), unlimited rooms | Pro **$25/mo** | **Presence/collab-doc shaped, JS/web-first**; weak native-Swift story | [verified] liveblocks.io/pricing |

**Fit.** All three are built for **web apps with many end-users**, billed by
messages/connections/MAU. Continuum is **one user, a few devices, offline-first, native
Swift**. You would be paying (eventually) for a realtime backbone you don't need, adding
a third-party dependency + your own auth glue, and — critically — **giving up CloudKit's
free offline queue + free identity.** Liveblocks in particular is presence/collab-doc
shaped and JS-first; it fights a native op-log. Ably is the most generic and its free
tier is genuinely generous, so it's the least-bad of the three if you ever needed a
cross-platform (non-Apple) client. But for the stated scenario, **none of them beats "$0
CloudKit" or "$0 relay on the box you already have."** **[judgment]**

### RECOMMENDATION — sync transport

> **Solo: CloudKit private database — $0.** It is Swift-native, needs **no server and
> no auth code**, gives you an **offline queue + change-push for free**, rides the
> **user's own iCloud quota**, and its seconds-latency is fine because the *urgent*
> signal is APNS, not sync. Map one `CKRecord` per `LoggedOp` (idempotent upsert by
> `OpId`) + a second record type for the activity projection. Use the **private DB, no
> CKShare**, so you never touch CloudKit's 2026 sharing bugs.
>
> **Keep the model behind the Decision-E `SyncTransport` seam** so the backend is
> swappable. The op-log is deliberately transport-indifferent — that indifference is
> the whole hedge.
>
> **Switch to the self-hosted WebSocket relay (on the §1 VPS, $0 marginal) when:** you
> need genuine sub-second sync (real concurrent multi-device editing), OR you add a
> **non-Apple client**, OR you want the op-log to be authoritative+replayable on a server
> you control. At that point implement the `02-transport-auth-pairing.md` pairing/scope
> model verbatim.
>
> **Commercial realtime (Ably/Pusher/Liveblocks): not for this scenario.** Only revisit
> if Continuum grows a web client with many users — a different product.

**Tradeoff:** CloudKit trades latency (seconds) and Apple-lock-in for zero ops and zero
auth; the relay trades those back for sub-second latency at the price of you running and
securing a service. For a solo Apple-only tool, CloudKit's trade is the right one, and
the seam keeps the relay one refactor away. **[judgment]**

---

## 4. iOS push — APNS ("your agent needs you")

This is the **urgent, realtime-feeling** signal (approvals, `needsAttention`), and it's
the reason CloudKit's seconds-latency sync is acceptable — the important event arrives as
a push, not as a synced record.

### What you need

- **Apple Developer Program membership — $99/year.** [verified:
  developer.apple.com/programs] This is the gate for *everything* Apple-distribution:
  APNS, code-signing certificates, TestFlight, App Store. It is **required and
  unavoidable** for a shipping macOS/iOS app; it is annual, not one-time.
- **A token-based APNS auth key (`.p8`).** [verified:
  developer.apple.com/.../establishing-a-token-based-connection-to-apns] You generate one
  `.p8` signing key in the developer portal; it yields a **Key ID + Team ID**. Your
  *sender* (whatever process decides "agent needs you") signs a short JWT with the `.p8`
  and POSTs a ≤4 KB JSON payload to APNS over **HTTP/2**, addressed to the device token.
  The key **never expires**, works for **all apps under your account**, and replaces the
  old per-app `.p12` certificate dance. Token-based is the 2026-recommended method.

### Where the push is *sent from*

Two shapes, and the choice is easy given §1:

1. **From your own host (the §1 VPS or the Mac) using the `.p8` directly.** The sender
   is a tiny bit of code: sign a JWT, `POST https://api.push.apple.com/3/device/<token>`.
   Cost: **$0 beyond the box you already run.** This is the natural home — the thing that
   knows an agent needs attention is the SessionObserver / managed-agent adapter
   (`docs/38` Decision C / #10), which already lives on the host. It should just fire the
   APNS request itself. **[judgment]**
2. **Via a push service** (OneSignal, AWS SNS, Firebase, etc.). These wrap APNS, add a
   dashboard, and handle token bookkeeping — useful at scale with many device tokens and
   segmentation. For a **single user's two devices**, this is pure overhead + a new
   dependency + (often) a new bill. **Skip.**

### RECOMMENDATION — push

> **Apple Developer Program ($99/yr) + a token-based `.p8` APNS key, sent directly over
> HTTP/2 from the host that already detects "needs attention" (the VPS or the Mac).
> Zero marginal cost.** No push service. The `.p8` is generated once, never expires, and
> the sender is a few dozen lines. This is the authoritative-`needsAttention` →
> APNS pipeline that `docs/38` #10 (managed-agent tier) and the t3code approvals model
> feed into.

**Setup checklist (so an implementing agent isn't guessing):**
1. Enroll in Apple Developer Program ($99). 2. Enable **Push Notifications** capability
on the App ID. 3. Create a **Key** with APNS enabled → download the **`.p8`** (once!),
record **Key ID** + **Team ID**. 4. In the iOS app, register for remote notifications →
get the **device token** → sync it to the host (over the same authed channel as sync).
5. On the host, sign a JWT (`ES256`, header `kid`=Key ID, claim `iss`=Team ID, `iat`),
POST the payload to `api.push.apple.com` (prod) / `api.sandbox.push.apple.com` (dev).

**Tradeoff:** rolling your own sender means you own token storage + the JWT signing, but
both are trivial and keep you off a recurring push-service bill for a two-device app.
**[judgment]**

---

## 5. Node sidecar vs pure-Swift for agent drivers

This is the **central architectural fork** `docs/38` flags (Decision #10; the
DRIVE-vs-OBSERVE and Node-vs-Swift sub-fork) reframed as a **deployment/DevOps** cost —
which is where it actually bites. The agent protocols Continuum might *drive* — **ACP**
(Agent Client Protocol, used by Cursor/Grok/Gemini/Zed), **`codex app-server`** JSON-RPC,
and the **Claude Agent SDK** — are all **Node/TypeScript**. So "drive agents headlessly"
implies *running Node somewhere.*

### Option A — bundle a Node runtime inside the macOS .app

**What it costs you, concretely:**
- **App size.** A Node binary is **~46 MB on macOS arm64** [verified:
  hirenodejs.com/blog Node SEA 2026 + nodejs.org SEA docs]. Universal 2 (arm64 + x86_64,
  stitched with `lipo`) roughly doubles the Node portion to **~90 MB**, on top of your
  existing app + the `GhosttyKit.xcframework` you already ship. So order **+50–90 MB** to
  the download. **[estimate]**
- **Notarization + signing.** Every embedded executable/dylib must be **signed with your
  Developer ID and covered by the Hardened Runtime**, then the whole app notarized.
  Node's **SEA (Single Executable Applications)** flow — stable since Node 22, improved in
  24 — is now the clean way: build the blob, `postject` it into a copy of Node, **strip
  the old signature, re-sign with Developer ID, notarize** [verified: nodejs.org SEA
  docs; hirenodejs 2026]. This is a **known, documented pipeline**, not research — but it
  is *extra pipeline*: one more thing to sign, one more thing that can wedge
  notarization (and notarization had multi-hour stalls in early 2026 [verified: Apple
  forums Feb 2026]).
- **Security surface.** Hardened Runtime **disables JIT and dynamic-code features by
  default**; Node's V8 wants a JIT, so you may need the
  `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` entitlements,
  which slightly widen the app's trust profile. Manageable, but a real review item.
  **[judgment]**
- **Maintenance.** You now track Node security releases and re-bundle. Ongoing, small,
  forever.

**What you gain:** the Node drivers run **on the same machine as the agent** with **no
extra host** and **no network hop** to the driver. On a *remote* agent, the sidecar runs
on the **VPS** (where the agent + tmux already are, `docs/38` Decision D), so "bundle in
the .app" really means "ship it with the Mac app *and/or* install it on the VPS" — either
way it's **$0 extra hosting** because both machines already exist.

### Option B — reimplement ACP / JSON-RPC in pure Swift

**What it costs you:** ACP and `codex app-server` are **JSON-RPC over stdio** —
mechanically very reimplementable in Swift (it's framed JSON messages, not exotic). The
`02-transport-auth-pairing.md` doc even sketches the Swift shapes. **But**: you would be
**reimplementing and then chasing** three independently-evolving protocols
(ACP spec changes, Codex's app-server surface, Claude SDK semantics), forever, to reach
parity with drivers **t3code already wrote in TS** (`docs/38` #10 notes you could "reuse
t3's TS drivers verbatim"). That is a large, permanent maintenance tax for the privilege
of not shipping ~50 MB of Node. **[judgment]**

**What you gain:** no Node in the bundle (smaller app, simpler notarization, no JIT
entitlement), a fully-native stack, and no second-language toolchain. Real benefits — but
paid for with protocol-parity maintenance that never ends.

### The deciding lens: this fork is gated on DRIVE-vs-OBSERVE

Per `docs/38`, the **OBSERVE** path (readers over agent dotfiles, `docs/38` Decision C)
needs **no Node at all** — you read `~/.claude/**`, `~/.codex/**`, `<proj>/.pi/**` in
pure Swift. Node only enters if you choose the **DRIVE / managed-agent tier** (`docs/38`
#10) for authoritative status + approvals + push. So:

- If Continuum stays **observe-first** (which `docs/38` phasing does — readers are
  phases 3–5, managed-agent is a later fork): **no Node, no bundle question, $0, ship
  the readers in Swift.** This is the near-term answer.
- If/when Continuum adopts the **managed-agent tier**: **bundle Node (SEA), reuse
  t3code's TS drivers.** Do **not** reimplement ACP/Codex/Claude in Swift — the
  maintenance cost dwarfs the ~50 MB app-size cost, and ACP is the single highest-ROI
  integration (one client → Cursor/Grok/Gemini/Zed).

### RECOMMENDATION — Node vs Swift

> **Phase-1 / observe: pure Swift, no Node.** The reader path (`docs/38` Decision C)
> needs zero Node; ship it native. This is $0 and sidesteps the whole bundling question
> for now.
>
> **When you commit to driving agents (the managed-agent tier, `docs/38` #10): bundle a
> Node runtime via SEA and reuse t3code's TypeScript ACP / codex-app-server / Claude-SDK
> drivers — do not reimplement them in Swift.** Accept **+~50–90 MB** app size and one
> extra sign/notarize step (a documented pipeline) in exchange for not maintaining
> three moving protocol clients yourself. On a **remote** agent the sidecar runs on the
> VPS you already pay for — **$0 extra hosting** either way. Start ACP-first (best ROI).

**Tradeoff being accepted:** bundling Node grows the download and adds a JIT entitlement
+ a notarization step; the payoff is you inherit working drivers instead of an endless
protocol-parity project. The break-even is clearly on the *bundle* side once you're
driving agents at all. **[judgment]**

---

## 6. macOS/iOS CI/CD + release

The goal is a **minimal, boring, reproducible** pipeline: build → sign → notarize →
distribute → auto-update. None of it is exotic; the only cost line is the macOS CI
runner.

### The pieces + costs

- **Signing + notarization.** Requires the **Developer ID Application** certificate
  (from the $99 membership) + **Hardened Runtime** (`codesign --options runtime`) +
  `notarytool` submission + staple. [verified: developer.apple.com notarizing docs] **No
  incremental cost** beyond the membership. Budget for occasional **notarization
  latency** — early-2026 saw multi-hour "In Progress" stalls [verified: Apple forums];
  don't put a hard human deadline immediately after a notarize step.
- **TestFlight** (for the **iOS companion**; TestFlight is iOS/iPadOS/tvOS/watchOS — the
  **Mac app** distributes via Developer ID + Sparkle **or** the Mac App Store, not
  TestFlight-for-Mac in the same way). [judgment] Included in the membership; up to
  10,000 external testers. **$0** beyond membership.
- **GitHub Actions macOS runner.** The one real variable cost.
  - **Free tier:** Free plan **2,000 min/mo**, Pro **3,000**, Team **50,000** — for
    **private** repos; **public repos are free**. [verified: docs.github.com Actions
    billing]
  - **macOS multiplier is 10×** — a 10-min macOS job burns **100 min** of quota.
    [verified]
  - **Overage: ~$0.048/min for macOS** as of 2026-01-01 (down from $0.080; GitHub cut
    hosted-runner prices up to 39%). [verified: github.blog changelog 2025-12-16;
    docs.github.com]
  - **Practical math:** a full sign+notarize macOS build is ~10–20 min = **100–200
    quota-min**. On the **free 2,000 min**, that's ~**10–20 builds/mo before you pay a
    cent**; beyond that, ~**$0.48–$0.96 per build** in overage. [estimate] For a solo dev
    that's often **$0/mo**; a busy team lands around **$5–20/mo**.
  - **If macOS CI minutes ever hurt:** notarize **locally** on your Mac (free), or use a
    cheaper 3rd-party macOS runner — but at ~$0.048/min the incentive is low.
- **Sparkle** (macOS auto-update) — **free, open-source**. [verified:
  sparkle-project.org] Static files on any web server + an **RSS "appcast"** + **EdDSA**
  signatures; supports **delta updates** and silent background install. No server code.
  Host the appcast + zips on **GitHub Releases (free)** or any static host. The iOS
  companion auto-updates via the **App Store**, so Sparkle is Mac-only.

### A minimal pipeline (what to actually build)

```
on: push tag v*                      # GitHub Actions, macos-latest runner
  1. build         → xcodebuild / swift build (Universal 2: arm64 + x86_64 via lipo)
  2. sign          → codesign --options runtime --sign "Developer ID Application: …"
                      (every embedded binary incl. the Node SEA sidecar, if bundled)
  3. notarize      → xcrun notarytool submit --wait  (Key ID + Issuer + .p8 in secrets)
  4. staple        → xcrun stapler staple MyApp.app
  5. package       → create .dmg or .zip
  6. sign appcast  → Sparkle generate_appcast (EdDSA) over the release folder
  7. publish       → gh release upload (the .zip/.dmg + appcast.xml)   ← free static host
  8. iOS (separate)→ xcodebuild archive → xcrun altool/notarytool → upload to TestFlight
```

Secrets in GitHub: the Developer ID cert (base64 in a secret, imported to a temp
keychain — the standard federicoterzi.com pattern [verified]), the APNS/notary `.p8`,
Key ID, Issuer ID, and the **Sparkle EdDSA private key**.

### RECOMMENDATION — CI/CD

> **GitHub Actions `macos-latest` (free tier first; ~$0.048/min overage at 10× only if
> you exceed ~10–20 builds/mo) + `notarytool` + Sparkle (free) with the appcast on
> GitHub Releases (free); TestFlight for the iOS companion.** Total incremental cost:
> **$0 for a solo dev in most months; ~$5–20/mo for a busy team.** Keep a **local
> notarize path** as the fallback for the days Apple's notary service is slow or your CI
> minutes run out. Everything except the macOS runner overage is covered by the $99
> membership + free open-source tooling.

**Tradeoff:** GitHub-hosted macOS CI is the convenient default but the 10× multiplier
makes heavy build volumes add up; the escape hatch (notarize locally) is free and
always available, so you're never locked into the bill. **[judgment]**

---

## 7. Identity / account model

The question: how do a person's devices (and, later, teammates) prove who they are so
sync + control are authorized? Two philosophies, and `docs/38` + the t3code docs already
lean one way for control and the other way is available for sync.

### Option A — account-less device pairing (the t3code model)

`02-transport-auth-pairing.md` is a complete blueprint: a **one-time pairing token**
(12 chars, 5-min TTL, single-use) exchanged for a **scoped bearer session**; every
message authorized against a **capability scope set** carried in the token; the
**read/operate scope split** makes "observer-only" a *type-level* guarantee (an
`.observer` iPhone token literally cannot carry `orchestrationOperate`/`terminalOperate`,
so a compromised phone still can't move a tile or type into a pane). Crucially, t3code's
**`subject` is an opaque label** — *there is no user-account notion in the auth core*.

**Cost: $0.** It's code you write (pairing store, session store, scope table), reusing
the `02-transport-auth-pairing.md` design. **Fit:** this is the right model for the
**control channel** (typing into a remote pane, spawning remote sessions) and for a
**self-hosted relay** (§3 Option B), where you own auth anyway. It also serves the
"pair my iPhone as a read-only observer" flow perfectly (QR / 12-char code → observer
scope).

### Option B — Sign in with Apple + CloudKit

If sync is **CloudKit** (§3 recommendation), then **device identity is Apple's**: the
iCloud account on the device *is* the identity, with **no signup, no password reset, no
recovery to build** [verified]. Record-level access on a shared container is governed by
CloudKit / `CKShare` permissions. **Sign in with Apple** is only needed if you want an
explicit app-level account (e.g. to tie non-CloudKit state to a person, or to identify a
user on a **non-Apple** client) — for "observe your own machine from your own iPhone,"
**you don't need accounts at all.**

**Cost: $0** (both included with the membership). **Fit:** for **one person's own Apple
devices syncing via CloudKit**, this is the least code — Apple *is* your identity
provider and you build nothing.

### The clean synthesis (what to actually do)

These aren't competitors; they cover **different channels** (this is exactly
`02-transport-auth-pairing.md` §4's "applies partially" nuance):

- **Sync leg over CloudKit → lean on Apple's identity.** The iCloud account authorizes
  the private DB. Build **no** `SessionStore`/`wsTicket` for the sync path.
- **Control leg (type into a remote pane, spawn on the VPS, iOS→Mac commands) →
  account-less device pairing + scopes.** CloudKit can't carry these; the t3code pairing
  model does, and its **scope table survives even if the token machinery doesn't** (build
  the `Scope` OptionSet now, grant iOS `.observer` only, wire only read/subscribe).
- **No user accounts until multi-user sharing is real.** Device-scoped `subject`s (opaque
  labels) are enough. Introduce Sign in with Apple / accounts only when *different people*
  share a workspace.

### RECOMMENDATION — identity

> **Solo: CloudKit's built-in iCloud identity for the sync leg (zero code, zero
> accounts) + the account-less device-pairing + scope model (`02-transport-auth-pairing.md`)
> for any control leg.** Build the **`Scope` OptionSet in full now**, grant the iPhone
> **`.observer` only** (a type-level guarantee it can't control anything), and defer the
> full pairing-token/`wsTicket` machinery until you actually ship a control channel or a
> self-hosted relay.
>
> **Small team (different people): add Sign in with Apple + CloudKit sharing** when a
> workspace is genuinely shared across iCloud accounts — and budget time for the **2026
> `CKShare` rough edges** [verified]. Until then, do not build accounts to observe your
> own machine.

**Tradeoff:** leaning on Apple identity is near-zero-code but Apple-only and inherits
CloudKit's sharing bugs for multi-account; the pairing model is more code but
transport-agnostic and gives you type-level capability control. Using **each for the
channel it fits** gets both benefits and is what the design already points at.
**[judgment]**

---

## 8. The recommended tiered stack — with monthly cost

Everything above, assembled. Two tiers. Prices are 2026, USD; EUR-priced items converted
at ~1.08 [estimate]; recurring vs one-time called out.

### Solo / Personal (cheapest sane)

| Layer | Choice | Monthly | One-time / annual | Confidence |
|---|---|---|---|---|
| Remote agent host | **Hetzner CX32** (4 vCPU / 8 GB / 80 GB, EU) | **$7.34** (€6.80) | — | [verified] |
| Reach the box | **SSH (free)**, add **Tailscale Personal (free)** for iOS | **$0** | — | [verified] |
| Sync transport | **CloudKit private DB** (rides user's iCloud) | **$0** | — | [verified shape] |
| iOS push | **APNS** via `.p8` from the host | **$0** marginal | **Apple Dev Program $99/yr** (~$8.25/mo amortized) | [verified] |
| Node sidecar | **None (observe-first, pure Swift)** — or bundled later at $0 host | **$0** | — | [judgment] |
| CI/CD | **GitHub Actions free tier** + local notarize fallback | **$0** (most months) | — | [verified] |
| Auto-update | **Sparkle** + **GitHub Releases** appcast | **$0** | — | [verified] |
| Identity | **iCloud identity** (sync) + **scope enum** (control) | **$0** | — | [judgment] |
| **Total** | | **≈ $7.34/mo recurring cash** + **$99/yr Apple** = **≈ $15.6/mo all-in** | | [estimate] |

**Read that total carefully:** the *only* two things you pay for are a small VPS
(~$7/mo) and the Apple membership ($99/yr ≈ $8.25/mo). **Every genuinely hard piece —
realtime-ish sync, push transport, auto-update, identity — is $0** because the design
deliberately picks Apple-native + self-hosted-on-the-box + open-source over SaaS.

**Even cheaper variants** if you want to shave: Hetzner **CX22** (4 GB) at **€3.79
(~$4.09)** if 4 GB is enough for your agent load → all-in **≈ $12.3/mo**. You cannot
drop the $99 Apple membership — it's the gate for push + distribution.

### Small team (2–5 people)

| Layer | Choice | Monthly | Confidence |
|---|---|---|---|
| Remote agent host | **Hetzner CPX41 / CCX dedicated** (more concurrency headroom) | **~$32–49** (€30–45) | [estimate] |
| Reach the box | **Tailscale Standard** ($8/user/mo) for shared ACLs/SSO — *or* stay on SSH (free) | **$16–40** (2–5 users) *or $0* | [verified] |
| Sync transport | **CloudKit** ($0) — or **self-hosted relay on the VPS** ($0 marginal) if you need sub-second / a non-Apple client | **$0** | [verified] |
| iOS push | **APNS** via `.p8` (one org membership) | **$0** marginal | [verified] |
| Node sidecar | **Bundled (SEA)** if driving agents; runs on the VPS/Mac you already have | **$0** host | [judgment] |
| CI/CD | **GitHub Actions macOS overage** at team build volume | **~$5–20** | [estimate] |
| Auto-update | **Sparkle** + static host | **$0** | [verified] |
| Identity | **CloudKit sharing + Sign in with Apple** (multi-account) + pairing/scopes for control | **$0** | [judgment] |
| Shared org line | **Apple Developer Program** (one membership) | **$99/yr** (~$8.25/mo) | [verified] |
| **Total** | | **≈ $50–90/mo** depending on team size, VPS tier, Tailscale plan, CI volume | [estimate] |

**The team tier's cost is dominated by choices, not necessities:** Tailscale
per-user (skippable if you stay on SSH) and VPS concurrency headroom. Sync, push, and
auto-update stay $0 even for a team. The relay only becomes worth its (near-zero) cost
when you genuinely need sub-second sync or a non-Apple client.

---

## Consolidated recommendations (the short version)

| Topic | Choice | Why (one line) |
|---|---|---|
| **remoteHosting** | Hetzner CX32 (8 GB, EU) €6.80/mo; DO 8 GB ($48) if US-latency matters | Best €/GB for a tmux-on-Ubuntu box; RAM is the constraint; skip Fly/Lightsail as wrong-fit/overpriced |
| **reach** | SSH (free) now; Tailscale Personal (free) once iOS joins | The tmux attach *is* an SSH command (no `-N/-L`); Tailscale is a free upgrade that kills the public port + serves iOS |
| **syncTransport** | CloudKit private DB ($0); relay-on-VPS ($0) later if sub-second needed | Swift-native, no server, no auth, free offline queue + push; seconds-latency OK because urgency rides APNS |
| **push** | APNS via a `.p8` key sent from the host ($0 + $99/yr membership) | Token key never expires, one key for all apps; no push service needed for 2 devices |
| **nodeVsSwift** | Pure Swift while observe-first ($0); bundle Node via SEA + reuse t3's TS drivers when you DRIVE agents | Observe needs no Node; driving 3 evolving protocols in Swift is a forever-tax vs +~50 MB app |
| **cicd** | GitHub Actions free tier + `notarytool` + Sparkle (free) + GitHub Releases; TestFlight for iOS | Only cost is macOS 10× runner overage (~$0.048/min) beyond ~10–20 builds/mo; local notarize as fallback |
| **identity** | iCloud identity for sync + account-less pairing/scope model for control; no accounts until multi-person | Apple *is* the identity for CloudKit; scopes make iOS observer-only a type-level guarantee; both $0 |
| **monthlyCostSolo** | **≈ $15.6/mo all-in** (VPS ~$7.3 + Apple ~$8.25 amortized; everything else free-tier) | The design deliberately makes every hard layer free; you pay only for a box + Apple membership |

---

## Sources (accessed 2026-06-30)

**VPS / hosting**
- Hetzner Cloud pricing + CX plans — https://www.hetzner.com/cloud/ ,
  https://www.hetzner.com/pressroom/new-cx-plans/ , price adjustment
  https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ ,
  locations https://docs.hetzner.com/cloud/general/locations/ , calculator
  https://costgoat.com/pricing/hetzner
- DigitalOcean Droplet pricing — https://www.digitalocean.com/pricing/droplets ,
  https://docs.digitalocean.com/products/droplets/details/pricing/
- Fly.io pricing — https://fly.io/docs/about/pricing/
- AWS Lightsail pricing — https://aws.amazon.com/lightsail/pricing/
- Scaleway pricing — https://www.scaleway.com/en/pricing/virtual-instances/ ,
  STARDUST1-S https://pcr.cloud-mercato.com/providers/scaleway/flavors/stardust1-s/pricing ,
  DEV1-S https://www.vpsbenchmarks.com/hosters/scaleway/plans/dev1-s

**Reach**
- Tailscale pricing — https://tailscale.com/pricing , plans
  https://tailscale.com/blog/pricing-v4 , free plans
  https://tailscale.com/docs/account/manage-plans/free-plans-discounts
- Cloudflare Tunnel (free) — https://blog.cloudflare.com/tunnel-for-everyone/ ,
  https://www.cloudflare.com/plans/ , Zero Trust
  https://www.cloudflare.com/plans/zero-trust-services/

**Sync transport**
- CloudKit — https://developer.apple.com/icloud/cloudkit/ , limits/pricing discussion
  https://developer.apple.com/forums/thread/715649 , "sync without a backend"
  https://medium.com/@chandra.welim/cloudkit-sync-user-data-across-devices-without-a-backend-2a58aaf88cbc
  , CKShare https://developer.apple.com/documentation/cloudkit/ckshare
- Ably pricing — https://ably.com/pricing
- Pusher Channels pricing — https://pusher.com/channels/pricing/
- Liveblocks pricing — https://liveblocks.io/pricing

**Push**
- Apple Developer Program — https://developer.apple.com/programs/whats-included/ ,
  https://developer.apple.com/programs/enroll/
- APNS token-based (`.p8`, HTTP/2, JWT) —
  https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns

**Node bundling**
- Node SEA 2026 — https://www.hirenodejs.com/blog/nodejs-single-executable-applications-2026 ,
  https://nodejs.org/api/single-executable-applications.html ,
  https://joyeecheung.github.io/blog/2026/01/26/improving-single-executable-application-building-for-node-js/

**CI/CD + release**
- GitHub Actions runner pricing — https://docs.github.com/en/billing/reference/actions-runner-pricing ,
  price cut https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/
- macOS notarization — https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution ,
  CI signing pattern https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/
- Sparkle — https://sparkle-project.org/documentation/ ,
  https://github.com/sparkle-project/Sparkle

**Identity**
- CloudKit identity / Sign in with Apple — https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app ,
  https://developer.apple.com/documentation/CloudKit/sharing-cloudkit-data-with-other-icloud-users

**Continuum design docs (this repo)**
- `docs/38-agent-orchestration-architecture.md` (Decisions D/E, #10)
- `docs/2026-06-30-t3code-steal/01-remote-reach-paths.md`, `02-transport-auth-pairing.md`,
  `04-orchestration-sessions-projections.md`
- `docs/2026-06-30-orchestration-spikes/SYNC-MODEL.md`
