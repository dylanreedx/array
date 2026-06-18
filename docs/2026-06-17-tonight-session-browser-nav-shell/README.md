# Tonight ticket bundle — Browser, navigation, shell, zones, backgrounds

Status: draft planning

## High priority implementation candidates
1. T13 shell scroll ergonomics — explicit wheel normalizer, remove hidden precise-delta 2x
2. T12 terminal zoom-pan stability — body-height alignment + idempotent Ghostty resize
3. T06 camera-aware jump indicators
4. T16 zone/readability policy + fit-zone framing
5. T07 jump focus zoom/framing/smoothing — animation only after T12 guardrail
6. T08 previous view/tile/zone navigation
7. T09 terminal title cwd + git branch
8. T10 rename terminal/note tiles
9. T17 native background customization

Before running overnight, read `02-nightly-run-readiness.md`.

## Browser track
Safe implementation order after audits/research and latest product preference:
1. T02 WKWebView Web Inspector developer enablement — honest public-API slice, default-off
2. T05 Chrome integration guardrails matrix — prevent unsafe profile/password/cookie work
3. T04 password/autofill security guardrails — policy/no-go tests only
4. T04b Keychain PasswordVaultService — isolated storage only, no WebKit JS
5. T01 browser tab model + schema migration — pure core/schema slice
6. T01b browser tab strip + single-live-WKWebView runtime slice — conditional on T01
7. T03 tab session restore — conditional on T01/T01b

Browser tickets intentionally **not** ready as broad all-in-one work:
- No Chromium/Electron DevTools; Continuum uses WKWebView.
- No password/autofill fill/save implementation until T04/T04b pass.
- No Chrome profile sync.
- No open-in-Chrome/default-browser handoff in this bundle; user explicitly removed it from scope.

## Navigation/zones track
- T06 camera-aware jump indicators
- T07 jump-to-tile focus zoom/framing
- T08 previous tile/zone navigation
- T15 zone tile bar customization
- T16 zone navigation and scale/readability metrics

## Terminal/tile identity track
- T09 terminal title defaults
- T10 rename terminal/note tiles
- T11 agent-running tile status experiment
- T12 terminal zoom-pan flicker investigation
- T13 shell scroll ergonomics
- T14 terminal theme fidelity

## Background/theming track
- T17 background customization: transparency, blur, images, native patterns
- T18 AI-generated background preset spike

## Security decisions already emerging
- Revoke/rotate the OpenAI API key pasted in chat; treat it as compromised.
- Do not directly reuse/mutate a user's live Chrome profile.
- Do not scrape/decrypt Chrome passwords.
- DevTools/embedded browser work must keep remote content sandboxed and IPC narrow.


## Workspace/session UX track
- T19 Cmd-K fundamentals overhaul
- T20 Top session bar
- T21 Sidebar workspace glimpse
- T22 Defer global overview / Mission Control

Priority for this track:
1. Make Cmd-K broadly clean and habit-forming: recents, switch, jump, create, command.
2. Add compact top session bar for cross-session awareness.
3. Add sidebar glimpse into current/other workspaces.
4. Hold global overview until dogfooding proves the need.
