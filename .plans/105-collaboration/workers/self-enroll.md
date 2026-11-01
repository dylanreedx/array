# Release blocker 0.7.37: sharing works out of the box

Bench `.worktrees/collab-self-enroll`, branch `array/collab-self-enroll`, base
`array/release-0737` c0511c3b. 31 October 2026.

## The problem

A fresh install could not share. The first Share needed a collaboration
service address plus a one-time enrollment code, and only a relay operator
could mint that code (`continuum-relay --collaboration-enroll`).

## What changed

**Default relay per channel.** `CollaborationServiceEndpoint.channelDefault` is
the one place that decides:
- A Prod build (`dev.arrayapp.macos`) uses `https://relay.arrayapp.dev`.
- Every other build (Dev, bare binaries, checks) uses
  `https://arrayapp-relay-staging.fly.dev`, the `arrayapp-relay-staging` Fly
  app. A dev build never signs anyone up on production.
- `CONTINUUM_COLLABORATION_ENDPOINT` overrides both, and may be plain http on
  loopback. This is the preview's and the checks' override. The preview also
  keeps working without it, because it pre-enrolls its accounts and a Mac with
  an account reuses it.

**Self-enrollment** (`POST /collaboration/v1/self-enroll`, unauthenticated):
- It takes a display name and a device label. It creates the caller's own
  person and first device and returns the device credential.
- It grants no area. Sharing, or a link, admits them to one afterwards.
- No operator code, no key.
- It allows 10 per client address per rolling hour. Over the limit it returns
  429 `rateLimited` and creates nothing, because the check runs in the same
  transaction, before any insert.
- Set the limit with `RELAY_COLLABORATION_SELF_ENROLLS_PER_ADDRESS`; 0 turns
  self-enrollment off.
- The address comes from the same source as `/links/join`: the socket peer, or
  `RELAY_CLIENT_ADDRESS_HEADER`. That is `fly-client-ip` in both fly configs.
- Only a hash of the address is kept, and only for the window, in the
  `self_enrollments` table (migration `collaboration-self-enroll-v1`).

**First use in the app:**
- `CollaborationAccountController.ensureAccount(defaultEndpoint:deviceLabel:askName:)`
  reuses a remembered account. On a Mac with none, it asks for a name and calls
  `selfEnroll`. `selfEnroll` and link joins share one credential-adoption path
  (`adoptNewCredential`): save, verify, remember, select.
- `ShareLinkCoordinator.signedInAccount()` goes through `ensureAccount`. That
  covers header Share, sidebar Share, the Share tool, the popover's New link,
  Revoke and Remove, and the shared zone's `readyAccount()`.
- The name prompt is one sheet on the canvas window: "Share from Array", a
  single "Your name" field prefilled with the macOS full name, and Continue /
  Cancel. It is the same sheet a link newcomer sees, with different words.
- File > Collaboration fills in the channel's relay. Connect with no
  enrollment code signs up there, using the macOS full name.
- The hub's error text covers 429.

## Witnesses

`ContinuumRevivedCollaborationChecks` (`runFirstUseShareChecks`), over real
HTTP against an in-process NIO relay: 6 checks.
1. The channel defaults and the override.
2. A Mac with no account signs up at the default relay with only a name. One
   more person exists afterwards, and no operator code is involved.
3. After a relaunch (a fresh controller on the same store) the account is
   reused, with no prompt.
4. That account shares an agent, mints a link, and a second fresh Mac joins
   through the link alone and sees the agent observation.
5. Past the per-address limit, self-enroll returns 429 and creates nothing,
   while another address still gets in.
6. A rate-limited first use saves no account.

`Array --collaboration-native-check`, stage "a real Share against a local
relay" (`ShareEntryRelayChecks`). It runs a real `continuum-relay` process on
loopback.
- The sender now starts with no account and no operator enrollment (the
  operator `enroll` helper is gone).
- The header Share and Copy, clicked through `NSApp.sendEvent`, raise the
  production name sheet. The check answers it, signs up, and gets the real
  zone and link.
- The second Share asks for no name.
- The existing later steps have a fresh newcomer join through the link.

Mutations, each applied, rebuilt and run, each RED:

| Mutation | Red check |
|---|---|
| No self-enroll limit | "self-enroll answers 429 past the per-address limit…" |
| `ensureAccount` ignores the remembered account | "a Mac with an account reuses it after a relaunch, asking nothing" |
| Prod defaults to staging | "Prod builds default to relay.arrayapp.dev…" |
| Coordinator skips first-use sign-up (old hub path) | "share entry (relay): timeout: the first share finishes" (the Share waits on a hub nobody fills in) |
| The name sheet is never shown | "the first Copy succeeds against the relay (Sign in to collaboration to share a link.)" |

The first run of the last mutation failed earlier, in the existing
live-view-delta budget stage ("[3, 1, 3] Array layout passes"), so it never
reached the share stage. That run does not count. It was rerun on its own under
`caffeinate -u` and went RED at the right check. The budget stage is not mine
and looks display-dependent; it is worth watching in the gate.

## Gate

- `scripts/run-matrix.sh --collaboration`, once, under
  `.worktrees/.locks/app-build.sh`, with an isolated `TMUX_TMPDIR` and
  `CONTINUUM_APP_SUPPORT`, `TMUX`/`TMUX_PANE` unset,
  `CONTINUUM_SKIP_UI_BASELINES=1`, and `caffeinate -u`. Result: "Collaboration
  matrix (targeted) passed", 13 legs. The log shows 36 `PASS share links:`
  lines, including the 4 first-use HTTP checks, and 27 `PASS share entry
  (relay)` lines.
- The Linux relay leg runs separately on this branch, outside the lock, as the
  matrix asks: `scripts/run-matrix.sh --notifications-linux`, which runs
  `check-relay-linux.sh` in Docker on Linux/amd64. Result: "Linux notifications
  matrix (targeted) passed", 2 legs. The new route and migration compile and
  pass the relay suites on Linux.

## Open

- **Staging relay host.** It is assumed to be `arrayapp-relay-staging.fly.dev`,
  Fly's default domain for the app in `deploy/fly.staging.toml`. If staging
  has a custom domain, change `CollaborationServiceEndpoint.stagingURL`.
- **Both relays must be redeployed with this route** before a 0.7.37 build can
  sign anyone up: production for Prod builds, staging for Dev. Until then the
  first Share fails on a 404 from `/self-enroll`. The popover's wording for that
  case was not checked.
- **No live run against the real relays.** Nothing here talked to Fly. Every
  witness used a loopback relay.
