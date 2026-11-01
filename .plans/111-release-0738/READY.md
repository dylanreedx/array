# 0.7.38 release candidate: ready for Dylan's go

1 November 2026. Bench `.worktrees/release-0738`, branch `array/release-0738`,
cut from `origin/array/integration` at `2af6fdd8` (0.7.37, build 88).
Nothing in this file has been pushed, released or deployed to production.

## What it means

The candidate holds the multiplayer polish, "share one agent" (mode A) with the
fast cursor lane, the account rename and organisation labels, and two sidebar
click fixes. It compiles in release configuration. The Linux relay gate, the
matrix, the 12-step two-app journey on staging and a real-internet cursor
measurement all ran on it (results below). What is left is public: the
production relay deploy, then the signed release build, DMGs, appcast and the
push.

## Merged

| Branch | How | Commits |
|---|---|---|
| `array/mp-polish` | fast-forward | `dd5b74be` `243cfa42` `93fff4a3` `03fa6406` `46c28240` `f2a2c458` `fcde2183` `8b39d10b` |
| `array/mp-share-agent` (holds `array/mp-cursor-stream`) | fast-forward | `c34c96f9` `e842987d` `078da75b` `811903f1` `ea89b7db` `d5e774a0` `75770a3b` `06858aad` `862e5ab5` `847d94a0` `987ea471` `251f0480` `c9109e3e` `59683617` `b3595d23` (lane merge) `5581e43d` |
| `array/account-manage` | merge `4996cc49` | `82631d97` |
| `array/sidebar-expand-helpers` | merge `1fab626f` | `495e5b69` `567c5713` `0a9cc35c` |

No textual conflicts. Three commits added on the bench; the third,
`fa154424`, is described under Gates:

- `cd46f77f test(collaboration): run the three mode A share checks in the matrix`.
  `--shared-agent-migration-check`, `--share-agent-relay-check` and
  `--shared-agent-render-check` were never run by any matrix. They are now added
  as new lines to the full matrix and to `--collaboration`; no pinned line was
  edited. Six inventory records were added (a `check` and a `leg` for each).
  All three passed on their own first.
- `177c8e5d test(collaboration): measure the cursor lane against a remote relay`.
  Mode A shares no zone, so the journey has no cursor leg, and nothing measured
  the lane over the real internet. With `CONTINUUM_CURSOR_MOTION_RELAY` set,
  `--collaboration-cursor-motion-check` signs up on that relay instead of a local
  one behind the 50 ms delay proxy, and measures the lane both ways. Unset, it
  is the same offline witness as before (re-run green after the change).

Found, not fixed: the matrix inventory has never recorded the older
collaboration legs (`--collaboration-native-check`, `-full-access-`,
`-cursor-motion-`, `--shared-area-zone-check`, the pair scripts, the
Collaboration checks executables, about 18 records). They run, but the
inventory guard would not notice one being deleted. Regenerating the inventory
would fix it; it is out of scope for a release candidate.

`--shared-agent-render-check` writes the light and dark PNGs and fails only if
rendering fails. It does not compare pixels.

## Gates

| Gate | Result |
|---|---|
| Release compile (`swift build -c release --product Array`) | `177c8e5d` and again on the final tip `fa154424`: exit 0, no errors |
| Linux relay (`scripts/check-relay-linux.sh`) | exit 0, 493 PASS, 0 FAIL |
| Full matrix (`177c8e5d`, `CONTINUUM_SKIP_UI_BASELINES=1`) | 422 legs; 10 KNOWN-RED as expected, none unexpectedly passing; 2 failed, both explained below |

The matrix ran from the agent shell as the notes require: `ARRAY_AGENT_ID`
unset, `</dev/null`, `TERM=xterm-256color`, under `caffeinate -u`. The two
display baseline legs were skipped so no fixture window took the screen.

The two failures:

- **`scripts/check-film-scenes.sh`: not new.** 4 of 12 scenes failed:
  `full-day`, `full-day-v2`, `v2-smoke` and `v2-smoke-day`. These are the same 4
  as 0.7.36 and 0.7.37 (VERSIONING.md). `v2-day-check`, the scene that caught a
  real regression last release, passed.
- **`--browser-automation-engine-check`: a flake under load.** One assertion
  failed: "an agent download must reach a private tile directory without a
  Save panel". Re-run alone twice on the same binary, it passed both times.
  None of the merged branches touch the browser.

The three newly registered legs ran in this matrix and passed, along with
`--collaboration-cursor-motion-check`, `--collaboration-native-check`,
`--sidebar-fold-expand-check` and `--agent-account-manage-check`. The
inventory leg passed (870 records).

**One bug found by the matrix, and fixed after it:** `fa154424 fix(collaboration):
keep the shared agent render check out of the tree`. The render check took
whatever followed its flag as the output folder, and the matrix puts
`-continuum.terminal.tmux.enabled` there, so each matrix run wrote two PNGs
into a folder of that name inside the checkout. That folder from this run was
the RED witness. After the fix, the leg run exactly as the matrix runs it, from
an empty folder, writes nothing to that folder (GREEN), and an explicit folder
argument still works. The change only touches that check's argument parsing.
The matrix was not re-run for it. Staging was not redeployed either: the
change is app-only.

## Staging relay

Deployed `177c8e5d` to `arrayapp-relay-staging` only, from the bench's clean
tree: `fly deploy . --config deploy/fly.staging.toml --dockerfile Dockerfile`.

- Release **v9**, image `registry.fly.io/arrayapp-relay-staging:deployment-01M6CE52KWWN6MM7RF9E9M5WST`.
  Previous: v8, `deployment-01M6AF292R7HHFMDV829M67HSH`.
- Health 200, schema 5, about 0.13 s.
- The cursor lane upgrades through Fly's proxy: every measurement run below
  requires both peers' lanes to report `live` before it measures, and all
  passed. Without a token, the upgrade gets `401` and no frame.

## Two-app journey on staging

`scripts/check-multiplayer-journey.py --name ReleaseJourney` (its own bundles
and state, so it does not clobber another bench's): exit 0, **40 PASS, 0 FAIL,
all 12 mode A steps**. Prompts carry names both ways: step 5 (the host shows P1
tagged "Blake", the guest shows "You") and step 6 (the guest shows P2 tagged
"Avery"), each followed by the reply. The cursor leg prints its note, as it
should: mode A has no zone and no cursors.

## Cursor lane over the real internet

`CONTINUUM_CURSOR_MOTION_RELAY=https://arrayapp-relay-staging.fly.dev
.build/debug/Array --collaboration-cursor-motion-check`, 3 runs, all passing.
Both peers run on this Mac, so each position goes Mac → Fly yyz → Mac: one
real internet round trip, the same path two people in the same city would use.
Production controllers, publisher and overlay; the mouse is posted at 60 Hz.

| Lane, real internet, 3 runs | A → B 60 Hz | A → B 120 Hz | B → A 60 Hz | B → A 120 Hz |
|---|---|---|---|---|
| positions received per second | 54.1-56.2 | 55.4-56.7 | 55.4-56.6 | 55.8 |
| display frames on which the cursor moved | 98.6-100% | 98.6-100% | 100% | 99.7-100% |
| final position painted after the mouse stopped | 98-159 ms | 80-112 ms | 89-99 ms | 89-106 ms |
| cursor behind the mouse, median | 117-171 ms | 96-173 ms | 96-172 ms | 105-147 ms |

For comparison, without the lane (update pages only, A → B): 16.7-19.6
positions/s, cursor moved on 93.7-100% of frames, final position 143-213 ms.
The offline witness (local relay, 100 ms simulated round trip) gets about
56 positions/s and 136-160 ms on the lane.

## Production steps still needing Dylan's go

Run in this order. Relay first: the 0.7.37 app degrades gracefully against
the new relay (the Linux gate's `a 0.7.37 reader gets the prompt as "who and
when"` check; a relay without the lane is answered by falling back to pages,
which is how the app treats production today).

1. **Production relay.**
   - Snapshot `relay_data` (`vol_vgnxq0m5d1nmy514`) first:
     `fly volumes snapshots create vol_vgnxq0m5d1nmy514 -a arrayapp-relay`.
   - Rollback target: current **v20**, image
     `registry.fly.io/arrayapp-relay:deployment-01M6AFJC1M68F0ZG7JAFRNXC7W`.
     No relay schema change since 0.7.37 (still 5), so rolling back is code only:
     `fly deploy --app arrayapp-relay --config fly.toml --image registry.fly.io/arrayapp-relay:deployment-01M6AFJC1M68F0ZG7JAFRNXC7W`.
   - Deploy from the bench at the release tip (the relay code is identical at
     `177c8e5d`, which staging runs, and `fa154424`):
     `fly deploy . --app arrayapp-relay --config fly.toml --dockerfile Dockerfile`.
   - After: health 200 and schema 5; the companion route baseline from
     RELAY-DEPLOY.md unchanged; `/collaboration/v1/self` 401; a 10-minute
     health watch with zero timeouts; live Mac event sequence still advancing.
2. **App release, build 89.** Check `xcrun notarytool history --keychain-profile array-notary`
   works first (the profile went missing during 0.7.37).
   `scripts/release-app.sh --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" --notary-profile array-notary --set-version 0.7.38 --set-build 89`,
   then `scripts/check-app-bundle.sh --configuration release --channel prod`.
3. **DMGs.** `Array-0.7.38.dmg` into `releases/`, and both `Array.dmg` and
   `Array-0.7.38.dmg` on a `v0.7.38` GitHub release in
   `dylanreedx/array-releases`, with the notes below.
4. **Appcast.** `scripts/generate-appcast.sh`; check that it adds exactly one
   build-89 item and keeps every older one. It has dropped pre-archive 0.2.0
   on every recent release; re-insert it verbatim if so.
5. **Ledger and push.** Append the 0.7.38 / 89 row to `docs/VERSIONING.md`,
   commit it with `website/public/appcast.xml`, merge `array/release-0738` into
   `array/integration` and push it, then bring `main` up (merge in anything
   pushed to `main` directly; never force). Vercel deploys the feed from `main`.
6. **Spot-check.** The appcast shows 0.7.38; the latest `Array.dmg` is 0.7.38;
   an installed 0.7.37 sees the update.

## Release notes

Array 0.7.38

- Share one agent. Share on an agent now shares just that agent, with no zone.
  Your teammate gets one tile in their canvas, live, named for you. They can
  prompt it; it runs on your Mac.
- Prompts show who sent them, on both sides, including a prompt you type while
  the agent is still working.
- Teammates' cursors move smoothly, at your display's refresh rate, instead of
  jumping a few times a second.
- If you shared a zone holding a single agent in 0.7.37, it becomes a shared
  agent tile when you open it.
- Accounts in Settings show each login's organisation as well as its plan. You
  can rename an account and sign in to it again.
- Sidebar: clicking the words of a lead's "N more" line now opens its folded
  subagents, and clicking the words "Show 25 more" under History shows more
  closed agents. Before, a click on the words did nothing.
