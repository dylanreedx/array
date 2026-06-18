# Local implementation queue — no Linear

Status: active queue for `scripts/overnight-loop.sh` when using `scripts/overnight-local-docs-prompt.md`.

Linear is unavailable. This file is the queue/state source for overnight local-doc runs.

Legend:
- `[ ]` ready / not started
- `[x]` done
- `[!]` blocked
- `[-]` deferred / do not implement

Rules:
- Work top to bottom.
- One ticket per loop iteration.
- One organized git commit per completed ticket.
- Do not implement blocked/deferred tickets.
- Required checks/manifests are in each ticket file.

## Browser queue

- [ ] T02 — WKWebView Web Inspector developer enablement  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T02-browser-inspect-element-devtools.md`

- [ ] T05 — Chrome integration guardrails matrix  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T05-chrome-profile-sync-feasibility.md`

- [ ] T04 — Password/autofill security guardrails and policy tests  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T04-password-autofill-safe-plan.md`

- [ ] T04b — Keychain PasswordVaultService  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T04b-keychain-password-vault-service.md`  
  Prerequisite: T04 done.

- [ ] T01 — Browser tab model + schema migration  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T01-browser-tab-model.md`

- [ ] T01b — Browser tab strip + single-live-WKWebView runtime slice  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T01b-browser-tab-ui-runtime-single-live-webview.md`  
  Prerequisite: T01 done.

- [ ] T03 — Browser tab session restore for single-live-webview tabs  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T03-browser-tab-session-restore.md`  
  Prerequisites: T01 and T01b done.

- [-] T05b — External browser handoff  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T05b-open-current-browser-url-externally.md`  
  Status: blocked/user-deferred. Do not implement.

## Navigation/terminal queue — optional after browser queue

- [ ] T13 — Shell scroll ergonomics  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T13-shell-scroll-ergonomics.md`

- [ ] T12 — Terminal zoom-pan stability  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T12-terminal-zoom-pan-flicker.md`

- [ ] T06 — Camera-aware jump indicators  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T06-camera-aware-jump-indicators.md`

- [ ] T16 — Zone navigation scale/readability  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T16-zone-navigation-scale-readability.md`

- [ ] T07 — Jump focus zoom/framing  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T07-jump-focus-zoom-framing.md`  
  Prerequisite: T12 done for animation; otherwise keep animation default-off.

- [ ] T08 — Previous tile/zone navigation  
  Ticket: `docs/2026-06-17-tonight-session-browser-nav-shell/T08-previous-tile-zone-navigation.md`  
  Prerequisite: T07 done.
