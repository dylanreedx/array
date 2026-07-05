# Night-3 iteration prompt — Tracks B + C (main worktree)

You are one iteration of the night-3 loop. Do ONE work item end-to-end (implement → verify → dual
review → commit or honest skip), then emit the LOOP token and exit. Same contract as
`overnight-orchestration-prompt.md` (Workflow `scripts/overnight-iteration-wf.js`, one item per
commit, no push, no AI footers, LOOP token as a raw line) — only the QUEUE and the mobile
verification rules differ.

## Load state (in order)
1. `docs/38-tickets/_NIGHT3_PLAN.md` — tonight's contract
2. `docs/38-tickets/_NIGHT3_FIX_TICKETS.md` — B0/B0b specs + audit rulings
3. `docs/38-tickets/_COMPANION_SPEC.md` — the mobile product spec (architecture, surfaces, N1–N8 taxonomy, test tiers)
4. `docs/38-tickets/_PROGRESS.md` (newest rows supersede older rows for the same item) + `git log --oneline`
5. The numbered ticket file for the item, if one exists (57/60/61/62/63/64/65 and Track C tickets), INCLUDING any ruling banners

## The night-3 queue (STRICT order; first not-done, not-skipped item)
B0 fix-66-supervisor (CRITICAL, per _NIGHT3_FIX_TICKETS.md — 4 defects, file:line given)
B0b fix-58-cursor-resume (snapshot-first serve + receiver seeds from cursor + fresh-receiver check)
B1 60-pairing-token-model
B2 57-cloudkit-transport-impl (conforms to the 55 SyncTransport seam; if real CKContainer access
    fails headless, implement fully + verify through the seam fakes and tag `device-gate-owed` for the
    real-CK leg — do NOT fake a green CK integration)
B3 61a agents board + agent detail (iOS app in `ios/`, per spec §2.3–2.4; ALWAYS cold-connect
    `cursor: nil` per the B0b ruling)
B4 61b canvas view + editor (spec §2.2; ops on gesture-end; editing behind operator scope)
B5 62-ios-approve-action (scope gate per C-20260702-012)
B6 63 push sender + N1–N8 payload builders (key config at `~/.continuum/apns.env`; the .p8 NEVER
    enters the repo; if key/env absent, land behind the flag)
B7 64-deep-link-validation
B8 65-notify-categories-setting
B9 T2 simulator push suite: `scripts/push-sim-test.sh` firing all 8 categories via `xcrun simctl push`
C1 40-session-observer   C2 41-fsevents-push-watch   C3 43→47 sidebar/dock (one item each)
C4 71, 72, 73 (one each)   C5 17, 18, 26, 29, 27 then 30, 28 (one each)
If ALL items are done/skipped → `LOOP: STOP queue-drained`.

## Verification rules
- Desktop items: unchanged — `swift build` + `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh`
  green; checks in `*Checks`/flag-wired self-checks; NO XCTest in SwiftPM targets; never weaken
  run-matrix.sh. Supervised-visual items are implemented code-complete with headless self-checks and
  the visual proof recorded as `visual-gate-owed` in the ledger row (morning checklist picks it up).
- iOS items (`ios/`): gate = `cd ios && xcodegen generate && xcodebuild -project Continuum.xcodeproj
  -scheme Continuum -destination 'generic/platform=iOS Simulator' build` clean, PLUS the item's logic
  proven either in shared SwiftPM code (preferred — put protocol/model logic in the SwiftPM packages
  where the existing `*Checks` gate it) or via a simulator-runnable check. Device/TestFlight/real-push
  legs are tagged `device-gate-owed`, never faked. Keep `ios/project.yml` the source of truth
  (regenerate the xcodeproj; don't hand-edit it).
- Code shared between desktop and phone (transport, ops, projection, scopes) lives in the SwiftPM
  packages, NOT duplicated into `ios/` — the app target consumes the packages (add the local package
  dependency to project.yml when first needed).
- Reviewers: same dual review as always (Claude review model + Codex GPT-5.5); they read the fix-ticket
  spec / companion spec as the contract for B-items.

## ComponentLab rule (Dylan's directive, 2026-07-04 — applies to EVERY item tonight)
Any item that ships a user-visible surface or a reusable component MUST land with its ComponentLab
entry in the same commit: a lab card demonstrating the component with realistic fixture data, plus a
`--component-lab-check` assertion where the ticket defines one (follow the existing card/self-check
patterns, e.g. ticket 14's "Session Naming" card and 67's adapter projection rows). This includes:
the C3 sidebar/dock items, C4's 71/72/73 cards, and the DESKTOP-side companions of Track B (pairing
QR panel, Devices/scope settings, push-test trigger). Reviewers REJECT a UI-bearing diff with no lab
entry. iOS-only SwiftUI views are exempt (no macOS lab host) — but any shared Core/Sync component
they consume that has a visual/desktop representation gets a card.

## Implementer routing (Dylan's directive, 2026-07-04)
Pass `implementer` in the Workflow args for every item:
- **`"codex"` (gpt-5.5 low) is the DEFAULT — use it for MOST items.** The specs/rulings are precise
  enough; repair rounds automatically escalate codex to high. Everything in B0/B0b/B1/B5–B9 and all
  of Track C's scoped items goes here.
- **`"sonnet"` ONLY for items you classify hard/creative** — expected: B2 (57 CloudKit transport),
  B4 (61b canvas editor), C1 (40 session observer), and any item codex already failed twice on.
- Review rigor is NOT reduced for codex-implemented items — the extensive Fable + Codex dual review
  runs identically on everything, and commit still requires both clear + green gates.

## Ledger
Append the row to `_PROGRESS.md` as usual (`night3` note prefix). Skips record precise findings.
Emit exactly one LOOP token: `LOOP: CONTINUE <item>` / `LOOP: CONTINUE skipped:<item>` / `LOOP: STOP <reason>`.
