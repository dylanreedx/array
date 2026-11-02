# 0.7.39 release (build 90): prep

2 November 2026. Bench `.worktrees/release-0739`, branch `array/release-0739`.
Prep only: nothing pushed, published, notarized or deployed. No appcast, no
production relay change, no full matrix yet.

## The merge

**The base is `origin/array/integration` (`b0689628`, 0.7.38, build 89), not
the local `array/integration`.**

The local `array/integration` in the main checkout is at `982d241e`. It is
stale. It forked at `61de0eb6`, before 0.7.32, and never received
0.7.32 to 0.7.38. Its 8 "newer" commits (iOS simulators on the canvas, tile
multiselect, group agent drag, CLI fixtures, palette test, ten app themes,
iOS preview agents, one phone alert per task) all shipped in **0.7.35**
(`0c28fc06`), cherry-picked under new hashes:

| Local integration | Shipped as | Patch |
|---|---|---|
| `efcce530` iOS simulators on the canvas | `221ab950` | same apart from run-matrix.sh context lines |
| `18b0f3da` multi-tile selection | `ff6acad9` | identical |
| `0e5e2ec9` group agent drag | `321a4ba3` | identical |
| `a7950c0d` CLI fixtures | `627fabe3` | identical |
| `55d88f95` palette test | `e95db500` | identical |
| `c4013d70` ten app themes | `02918b1a` | same apart from one inventory count line |
| `524e3104` iOS preview agents | `cbacd9c5` | identical |
| `982d241e` one phone alert per task | `413e56e0` | same; the one differing guard was already in the tree |

Merging `982d241e` would have replayed 8 shipped commits against 436 commits
of divergence, and gained nothing. So the bench was cut from
`origin/array/integration`. `array/preview-0739` is built on `b0689628`, so it
**fast-forwarded**: no merge commit and no conflicts. The run-matrix.sh,
inventory, ContinuumApp.swift, UIProbeAppearance.swift and sidebar/tile files
are exactly as the preview left them.

Tip: `adbeaa00`. That is 84 commits on top of 0.7.38, including the
preview's 15 merges (portal and every shared tile kind, live terminals and
terminal Stop, tmux stall fix, relay housekeeping, characters, sidebar sort
and filter, lead glyph and chip fix, the 0.7.38 live-tile refusal). There are
two more since the PREVIEW.md proof tip `92558673`:

- `98a1c3d7 feat(collaboration): let a multiplayer preview run the person's
  own CLIs` (MultiplayerPreview.swift, a ContinuumApp.swift arm,
  scripts/preview-0739.sh)
- `adbeaa00 docs(release): launch the preview on the real CLIs`

The local `array/integration` should be reset to the release tip once this
ships, or it will keep looking like it holds unreleased work.

## What built

| Build | Result |
|---|---|
| `scripts/prepare-ghosttykit.sh` | exit 0 |
| Debug, whole package (`swift build --disable-sandbox --skip-update`, under the lock) | exit 0, 181 s |
| Release configuration (`swift build -c release --product Array`, under the lock) | exit 0, no errors, 956 s |
| iOS (`xcodebuild … -sdk iphonesimulator`, as run-matrix.sh runs it) | BUILD SUCCEEDED |

The first debug and iOS attempts failed with "No space left on device": the
disk had 1.6 GB free. The `.build` caches of the shipped release benches
(release-0732, -0735, -0736, -0737) were removed: nothing had them open,
they are build caches only, and the benches and their commits are untouched.
That freed about 45 GB. At the end of prep there was 44 GB free. The full
matrix needs room too, so check `df -h` first.

## Legs on the merged tree

All on `adbeaa00`, run the way the matrix runs them: temp project and app
support, tmux off for app checks, `ARRAY_AGENT_ID` unset, `</dev/null`.

| Leg | Result |
|---|---|
| Journey `--relay local --mode b --name ReleasePortal` | 70 PASS, 0 FAIL; cleanup left nothing on the relay |
| Journey `--relay local --mode terminal --name ReleaseTerminal` | 32 PASS, 0 FAIL; cleanup left nothing on the relay |
| `--sidebar-sort-check` | pass |
| `--character-sprite-check` | pass (100 sprites x 10 s, 0 layouts, 0 draws) |
| `--tile-character-check` | pass |
| `--tile-multiselect-check` (multi-tile selection) | pass |
| `--agent-tile-reference-check` (group agent drag) | pass |
| `--companion-task-host-check` (one alert per task) | pass |
| `--ios-preview-tile-check` (iOS simulators) | pass |
| `ContinuumRevivedAgentUIChecks` (includes the ten app themes) | pass |

## Fixes folded in (2 November, second round)

Each was the newest tip of its branch, with its bench clean:

| Merge | Branch tip | What |
|---|---|---|
| `529ce623` | `array/sidebar-sort` `6e7cf64f` | the sort button sits in the search field's trailing slot, so search and scope keep their widths |
| `273ca13c` | `array/terminal-sharing` `1b80f909` | the shared terminal's palette is read through `GhosttyThemeSnapshot.color(hex:)` |
| `44bbb156` | `array/mp-share-kinds` `32368469` | the shared-tile check's stand-in page is drawn from tokens |

`array/preview-0739` was still at `adbeaa00`, already in the branch.

**One conflict**, in `SharedTileAppearance.swift`'s stand-in page. Both
colour fixes rewrote its header band: terminal-sharing used a system grey,
share-kinds drew the whole page from light-theme tokens. Kept share-kinds'
version: it covers the band and the rest of the page. `check-color-hygiene.sh`
passes with 0 new violations.

The "no agent responses" fix has not arrived; nothing for it is in the branch.

### After the fixes (tip `44bbb156`)

| Check | Result |
|---|---|
| `scripts/check-color-hygiene.sh` | passed: 27 allowlisted, 0 new |
| Debug, whole package | exit 0 |
| Release configuration, `Array` | exit 0, no errors, 878 s |
| iOS | BUILD SUCCEEDED |
| `--sidebar-screenshot-check` | passed, 48 images (4 widths x 2 appearances) |
| `--sidebar-sort-check` | passed |
| `--shared-tile-render-check` | passed |
| `--shared-terminal-render-check` | passed |

### Full matrix (`44bbb156`)

Run 09:47-10:37 from the agent shell: `ARRAY_AGENT_ID` unset, `</dev/null`,
`TERM=xterm-256color`, `caffeinate -u -i`, `CONTINUUM_SKIP_UI_BASELINES=1`
(Dylan was using the Mac, so no fixture window took the screen). 39 GB free
after.

**444 legs. 10 KNOWN-RED as expected, none unexpectedly passing. 3 failed,
none reproducible alone:**

- **`scripts/check-film-scenes.sh`**: 5 of 12 scenes. Four are the same as
  every release since 0.7.36 (`full-day`, `full-day-v2`, `v2-smoke`,
  `v2-smoke-day`). The fifth, `v2-day-check`, failed in the matrix: the
  scene's pointer found no bulk bar, so "bulk settle" never happened. Alone
  (`ARRAY_FILM_SCENE`, isolated like the script), it passed 2 of 2 on this
  build, and 2 of 2 on the preview's film binary. That reads as load in the
  matrix, not the sidebar change. Still worth a look: this scene also flaked
  during 0.7.37's A/B.
- **`--share-agent-relay-check`**: one step timed out ("the open popover
  sees Sam join"). Alone it passed 2 of 2 (34 steps). It passed in 0.7.38's
  and the preview's matrices.
- **`--character-perf-check`**: with characters on, panning showed 80 bar
  layouts and draws, against 0 with them off. Alone: release build 5 of 6
  (the one failure had a different signature: 77 card layouts on, 55 off);
  preview build 4 of 4. The only `TileNSView` change since the preview is a
  hit-test, which cannot lay anything out. The check allows zero stray
  layouts, so one unrelated event in an arm fails it. **To its owner: flaky,
  maybe not a regression, but it failed twice in 8 tries on this build.**

Found in passing, not new: CoreChecks' **dependencies guard fails** ("Core
target must include exactly AgentContent, AgentUI, GRDB…"). Core has also
depended on `ContinuumRevivedCollaborationProtocol` and
`…CollaborationClient` since at least 0.7.38 (`b0689628` has the same target).
The whole CoreChecks leg is KNOWN-RED for its seed-byte baseline, so this
second failure inside it is invisible to the matrix. Either the guard's
expected declaration needs the two collaboration targets, or Core shouldn't
depend on them.

### Journeys

The relay code is identical to what staging v12 runs (`07122561`): no line
differs in any relay target, `RelayPackage.swift`, the Dockerfile or the deploy
config. So staging was **not redeployed**, and needed no snapshot. Staging
health was 200 with schema 5, still v12.

| Journey | Local relay | Staging v12 |
|---|---|---|
| Portal, `--mode b` | 70 / 70 | 70 / 70 |
| Live terminal, `--mode terminal` | 32 / 32 | 31 / 32 once, then 32 / 32 four times |
| One agent + every kind, `--mode a` | 94 / 94 | 98 / 98 (with `--old-guest ReleaseJourney`, the real 0.7.38 guest) |


**The staging terminal miss is a known flake, not a guest glitch.** One run
in five failed "screen: the guest's screen is the host's pane, line for line".
That step compares the two screens once, 0.4 s after the coloured line first
reaches the guest; it does not wait for them to agree. The guest held the
host's lines, with six blank rows where the top lines should be and the long
command wrapped at another place: a scroll still on its way over the
internet. Nothing stayed wrong. Later in the same run, both other
line-for-line checks passed: after the 100,000-line flood, and after the
full-screen program exited. Every other step passed too (echo median 62 ms,
400 of 400 lines in order, the flood's end within 1 s). The four reruns
passed 32 / 32. Every run's cleanup left nothing on the relay. The fix for
the flake belongs in the journey: poll that comparison for a second, as the
other screen steps do, rather than reading once.

## Third round (2 November afternoon)

- The "no agent responses" report was the preview's fake claude sending a
  whole message, which the app only draws as a stream. Not a product bug;
  nothing to fold in. The preview's `--real` commits `98a1c3d7` and
  `adbeaa00` are in the branch.
- **Folded in** `d50fffc7`: `array/sidebar-sort` `1b945bea`, "fix(sidebar): keep the
  selection when a re-sort moves rows". It merged with no conflict. It is the
  likely cause of the matrix's `v2-day-check` miss: a re-sort that dropped
  the selection leaves the bulk bar nothing to act on.
  - Debug and film builds: exit 0.
  - `--sidebar-sort-check`: passed, with the new step "a re-sort keeps two
    selected rows and the bulk bar".
  - `--sidebar-screenshot-check`: passed, 48 images.
  - `ARRAY_FILM_SCENE=…/v2-day-check.json --film-scene-check`: 3 of 3 passed.
  - Release configuration (`swift build -c release --product Array`): exit 0, no errors, 759 s.
- **Linux relay gate** (`bash scripts/check-relay-linux.sh`): exit 0, 533 PASS,
  0 FAIL, deletion checks included. The script is committed as mode 644, so
  `scripts/check-relay-linux.sh` on its own answers "permission denied"; run it
  through `bash`.
- **Notary profile**: `xcrun notarytool history --keychain-profile array-notary`
  answers; its newest entry is `Array-0.7.38.dmg`.

## Release notes draft

The text to paste starts on the line after this one.

Array 0.7.39

- Share part of your canvas. Press S, or pick Share in the toolbar, and drag over some tiles. Your teammate gets one window onto that part of your canvas, live. Nothing on your canvas moves. Drag another tile into the shared region and an "Add to share" button appears on it; nothing is shared until you press it.
- Share notes, files, diffs, browsers and terminals, not just agents. A note shared on its own can be edited by both of you at once. Files and diffs update when you save, and your teammate can Approve or Request changes on a diff. A browser on a public page follows your navigation; on a localhost page your teammate sees pictures of it, and their clicks and scrolls land on your page.
- Shared terminals are live and read-only. Your teammate sees your terminal as you do: your colours, cursor and grid, live as you type. They can never type into it. Array warns before sharing a terminal, because its output may contain secrets. A shared terminal shows a Live badge with a Stop sharing button.
- Stop sharing at any time from the Share popover: remove one person or revoke everyone. If your Mac goes offline, your teammate's view dims and their prompts wait until you are back.
- In a shared region, each of you sees the other's pointer over the shared tiles.
- Agent characters. Each agent can have a small animated duck in its sidebar row and tile header, acting out what it is doing. Turn them on in Settings › Appearance › Agent characters; pick another duck for one agent from its tile's ⋯ menu.
- Sidebar sort. The sort button in the search field orders agents by Most active, By project or Newest first. Rows wait while the pointer is over the sidebar, and a selection survives a re-sort. Filter by project from the scope list.
- A lead agent shows it is working while any of its helpers works.
- Teammates on 0.7.38 need to update to open a shared note, file, diff, browser or terminal. Shared agents still open for them.

## Prepared commands (nothing below has been run)

Run from the bench, `.worktrees/release-0739`, at the final tip, on Dylan's
"ship it". In zsh, keep the `${T}` braces in refspecs.

### 1. Production relay, first

The production relay is v21 today, image
`registry.fly.io/arrayapp-relay:deployment-01M6CJTY26P3GTSX2AFHX31WM5`,
volume `relay_data` `vol_vgnxq0m5d1nmy514`. It has no `RELAY_ADMIN_TOKEN`
secret, so the deletion routes refuse until this deploy sets one. The relay
code is what staging v12 has run since this morning. A 0.7.38 app degrades
against it: its live tiles get a 426 "update" instead of a broken tile. The
Linux gate and the old-guest journey cover that.

Snapshot first, and note the snapshot id:

fly volumes snapshots create vol_vgnxq0m5d1nmy514 -a arrayapp-relay
fly volumes snapshots list vol_vgnxq0m5d1nmy514 -a arrayapp-relay

A production admin token, kept beside the staging one (0600), staged as a
secret so the deploy applies it:

umask 077; openssl rand -hex 32 > ~/.config/array/relay-production-admin-token
fly secrets set RELAY_ADMIN_TOKEN="$(cat ~/.config/array/relay-production-admin-token)" --stage -a arrayapp-relay

Deploy:

git status --short
fly deploy . --app arrayapp-relay --config fly.toml --dockerfile Dockerfile

Roll back if needed:

fly deploy --app arrayapp-relay --config fly.toml --image registry.fly.io/arrayapp-relay:deployment-01M6CJTY26P3GTSX2AFHX31WM5

After the deploy, check:
- health is 200 with schema 5;
- the companion route baseline in RELAY-DEPLOY.md is unchanged;
- `/collaboration/v1/self` answers 401;
- the admin paths on the public port answer 401;
- a 10-minute health watch has zero timeouts;
- the live Mac event sequence is still advancing.

The checks as commands:

curl -s -m 10 -w ' %{http_code} %{time_total}\n' https://relay.arrayapp.dev/health
curl -s -o /dev/null -w '%{http_code}\n' https://relay.arrayapp.dev/collaboration/v1/self
curl -s -o /dev/null -w '%{http_code}\n' https://relay.arrayapp.dev/collaboration/people
for i in $(seq 120); do curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}\n' https://relay.arrayapp.dev/health; sleep 5; done | sort | uniq -c | sort -rn | head

### 2. Delete the Peer A/B and deploy-probe leftovers on production

The admin port is reached through `fly proxy`, never the public port. List
first, and delete only throwaway labels: "Peer A", "Peer B", "Deploy probe
(throwaway)", "Deploy probe joiner". Also delete the inert probe area
`A0924B21-6E6C-4E6E-B454-80C02E4EE9B8`. Delete areas before people: a person
with an area that stays answers 409 `personHasAreas` and lists those areas.
Delete such an area only if every member in it is a throwaway.

fly proxy 19090:9090 -a arrayapp-relay

In a second shell:

T=$(cat ~/.config/array/relay-production-admin-token)
curl -s -H "Authorization: Bearer ${T}" http://127.0.0.1:19090/collaboration/people | python3 -c 'import json,sys; [print(p["id"], p["devices"], p["areas"], p["label"]) for p in json.load(sys.stdin) if p["label"] in ("Peer A","Peer B","Deploy probe (throwaway)","Deploy probe joiner")]'
curl -s -X DELETE -H "Authorization: Bearer ${T}" http://127.0.0.1:19090/collaboration/areas/A0924B21-6E6C-4E6E-B454-80C02E4EE9B8
curl -s -H "Authorization: Bearer ${T}" http://127.0.0.1:19090/collaboration/people/<id>
curl -s -X DELETE -H "Authorization: Bearer ${T}" http://127.0.0.1:19090/collaboration/people/<id>

Repeat the last two for each id the list printed, then list again; none of
those labels should remain.

### 3. App, build 90

The version is set in the build, never committed to Packaging:

scripts/release-app.sh --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" --notary-profile array-notary --set-version 0.7.39 --set-build 90
scripts/check-app-bundle.sh --configuration release --channel prod

The artifacts land in `qa-runs/<stamp>/release/`.

### 4. DMGs and the GitHub release

D=$(ls -td qa-runs/*/release | head -1)
cp "${D}/Array-0.7.39.dmg" /Users/dylan/Documents/personal/Array/releases/
cp "${D}/Array-0.7.39.dmg" /tmp/Array.dmg
shasum -a 256 /tmp/Array.dmg /Users/dylan/Documents/personal/Array/releases/Array-0.7.39.dmg
gh release create v0.7.39 --repo dylanreedx/array-releases --title "Array 0.7.39" --notes-file .plans/115-release-0739/notes.txt /tmp/Array.dmg /Users/dylan/Documents/personal/Array/releases/Array-0.7.39.dmg

`notes.txt` is the release notes draft above, saved as plain text.

### 5. Appcast

Use the main checkout's `releases/`, not the bench's. Then put 0.2.0 back
with the saved item; `reinsert-0.2.0.py` round-trips the current feed
exactly. Then confirm the feed:

scripts/generate-appcast.sh /Users/dylan/Documents/personal/Array/releases
python3 -I .plans/115-release-0739/reinsert-0.2.0.py
grep -c '<item>' website/public/appcast.xml
git diff --stat website/public/appcast.xml

What to see: 89 items (88 today plus build 90), and the diff adds exactly
one build-90 item.

### 6. Ledger, merge and pushes

Append the `| 0.7.39  | 90    | <date> | \`v0.7.39\` | … |` row to
`docs/VERSIONING.md`, with what shipped, the source tip, the gate results
above and the relay record. Commit it with the appcast:

git add docs/VERSIONING.md website/public/appcast.xml
git commit -m "chore(release): ship 0.7.39 (build 90)"

`origin/array/integration` is `b0689628`, an ancestor of this branch, so
the push is a fast-forward:

T=$(git rev-parse HEAD)
git merge-base --is-ancestor origin/array/integration ${T} && echo fast-forward
git push origin ${T}:refs/heads/array/integration
git fetch origin main
git merge-base --is-ancestor origin/main ${T} && git push origin ${T}:refs/heads/main

If `main` received a direct push since 0.7.38, merge it into the release
branch first, then push both. Never force. Vercel deploys the feed from
`main`.

The main checkout's local `array/integration` (`982d241e`) is stale. Reset it
to the release tip once that checkout is clean, or leave it alone. Don't
merge it: its 8 commits shipped in 0.7.35.

### 7. Spot-check

curl -s https://arrayapp.dev/appcast.xml | grep -c '<sparkle:version>90<'
curl -sL -o /tmp/Array-latest.dmg https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg && shasum -a 256 /tmp/Array-latest.dmg

An installed 0.7.38 should see the update (Check for Updates…).

## Still before "ship it"

1. **Characters motion harness**, `scripts/canvas-motion/character-arms.sh`,
   in a quiet window. It takes the screen for a few minutes; on and off should
   match.
2. Dylan's go for the production relay, then steps 1-7 above.

## Shipped (2 November 2026)

Dylan's go, in the orchestrator's transcript at 16:40 UTC: "yep run it and
SHIP IT", answering a plan that listed the relay update, the deletions,
notarization, publishing and the push.

### Characters motion harness

`scripts/canvas-motion/character-arms.sh`, 11:41-11:44 EST, Mac idle. The
Release "Array Motion" bundle was the preview's, built at 04:34 from
`5ca9f761`. No characters source changed between that and the release tip;
only the sidebar header, sort-selection, terminal palette and share-page files
did. The summaries are in `motion/`. The probe scene has 14 tiles, 8 visible.

| Arm | main-thread CPU per camera commit | instructions | camera states/s | gaps >33 ms |
|---|---|---|---|---|
| zoom off 1 / 2 | 8.03 / 8.19 ms | 127.2 / 128.7 M | 84 / 82 | 0 / 0 |
| zoom on 1 / 2 | 8.33 / 8.38 ms | 129.5 / 133.3 M | 83 / 83 | 0 / 1 |
| pan off 1 / 2 | 4.20 / 4.25 ms | 53.0 / 46.7 M | 88 / 90 | 0 / 0 |
| pan on 1 / 2 | 4.10 / 3.86 ms | 51.4 / 46.7 M | 94 / 94 | 0 / 0 |

Characters cost nothing measurable.
- Zoom costs about 0.25 ms (3%) more with them on; the two off runs differ
  from each other by 0.16 ms. The picture rate is the same.
- Pan is no costlier with characters on.

### Production relay: v22

- Snapshot of `relay_data`: `vs_0RZjMjgoqNQAhwgV4XGDKmY` (306 MiB).
- `RELAY_ADMIN_TOKEN` staged as a secret. Its only copy is
  `~/.config/array/relay-production-admin-token` (0600); it was never printed.
- `fly deploy . --app arrayapp-relay --config fly.toml --dockerfile Dockerfile`
  from `22687213` gave **v22**, image
  `registry.fly.io/arrayapp-relay:deployment-01M6EJECB0Y4MYYJ40SJVFEE05`. The
  relay code is the same as staging v12.
- Rollback target: v21,
  `registry.fly.io/arrayapp-relay:deployment-01M6CJTY26P3GTSX2AFHX31WM5`.
- After the deploy:
  - Health 200, schema 5.
  - 48 route probes (24 public paths, GET and an empty POST) are identical to
    the pre-deploy baseline. That includes `/collaboration/v1/self` 401 and
    the admin paths on the public port 401.
  - 120 of 120 health calls in 10 minutes returned 200, with no timeouts,
    median 0.13 s and max 0.28 s.
  - The Mac's event sequence kept advancing (122840 to 122850 at 16:49 UTC).

### Deleted on production (admin port, through `fly proxy`)

First, a check that no real person's area was touched. Dylan and Adrianna
Boese share only their own two areas, `68EE1462…` and `B639116E…`.

- Areas, all 200:
  - `A0924B21-6E6C-4E6E-B454-80C02E4EE9B8`, the deploy probe's;
  - `531291E6-CE15-4FB5-931A-C1383F11A0D5`, `FBC4E464-B311-4685-880B-FC0CC0063770`
    and `88C9009B-230C-41F8-87FD-D19464844697`, one per Peer A/B pair.
- People, all 200:
  - Deploy probe (throwaway) `A1FE6237…`;
  - Deploy probe joiner `AC39D4BA…`;
  - Peer A `0A3CA3D6…`, `F53368A9…` and `F8CDC31D…`;
  - Peer B `16B2057F…`, `90407949…` and `CB0DD50F…`.
- Left: Dylan, Adrianna Boese, and a second probe pair, "Deploy probe v20
  (throwaway)" and its joiner, in area `E0F8869B…`. The second pair was not in
  the asked list, so it is still there.

### App, GitHub release and feed

- `scripts/release-app.sh --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" --notary-profile array-notary --set-version 0.7.39 --set-build 90`
  at `22687213`: the app and DMG were notarized and stapled, and Gatekeeper
  accepts both.
  - The app is 0.7.39, build 90, `dev.arrayapp.macos`.
  - Artifacts: `qa-runs/20261102T170011Z/release/`.
- `scripts/check-app-bundle.sh --configuration release --channel prod`:
  every self-check, codesign sign and codesign verify passed. Then it exited 1
  on its last guard, "real Array/Continuum defaults plists changed", twice.
  - The cause: Dylan's /Applications Array (pid 28153, running since
    1 November) rewrites `continuum.sidebar.hiddenExternalSessions` in
    `dev.arrayapp.macos.plist` every 5-10 s, with nothing else running.
  - A key-level diff of all four watched domains around the second run found
    only that one key changed. The bundle under test changed nothing.
  - The guard compares whole files, so it cannot pass while his app runs, and
    quitting his app is not allowed. Shipped on that evidence.
  - Worth fixing in the guard: compare keys, or ignore the keys a running prod
    app owns.
- Both DMG names have SHA-256
  `efb67fb15faaf011b734e4e73eb2e2867b3cfb1549e810fee4b4d656698ebe46`. They are in
  the main checkout's `releases/`, and on
  https://github.com/dylanreedx/array-releases/releases/tag/v0.7.39 (not a draft,
  not a prerelease) as `Array.dmg` and `Array-0.7.39.dmg`, 65,445,386 bytes each.
- `scripts/generate-appcast.sh /Users/dylan/Documents/personal/Array/releases`
  dropped 0.2.0 again, leaving 88 items. `reinsert-0.2.0.py` put it back.
  - The feed now has 89 items: exactly one new (build 90, 0.7.39, EdDSA-signed,
    the v0.7.39 asset URL) and none removed.
  - `git diff`: 10 added lines.
- The ledger row is appended to `docs/VERSIONING.md`.
