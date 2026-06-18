# Nightly run readiness — navigation/terminal push

Status: preflight required before Ralph loop

## Decision
Do not run the overnight implementation loop directly from the current dirty/ahead `main` checkout.

Before a real automated run:
1. create/switch to the intended branch;
2. make the working tree clean or intentionally commit/stash planning docs;
3. archive/clear any active `.pi` watches intentionally;
4. choose either Linear queue mode or a custom prompt mode;
5. ensure the runner writes enough morning observability.

## Current runner state
- Checkout is now on an intentional branch: `nightly/browser-nav-shell-loop-2026-06-18`.
- Working tree is still dirty/untracked with planning docs and `.pi/tmux...` artifacts; commit or stash setup before running with default preflight.
- `scripts/overnight-loop.sh` now defaults to local-doc mode, not Linear:
  - `PROMPT_FILE=${PROMPT_FILE:-scripts/overnight-local-docs-prompt.md}`
  - `QUEUE_FILE=${QUEUE_FILE:-docs/2026-06-17-tonight-session-browser-nav-shell/04-local-implementation-queue.md}`
  - `PUSH_MODE=${PUSH_MODE:-local-only}`
  - loads `OPENAI_API_KEY` from `.env` by default without printing the value (`ENV_FILE` / `LOAD_DOTENV` override)
- The loop writes durable run observability under root pi:
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/status.json`
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/events.jsonl`
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/report.md`
  - iteration logs under `logs/`
  - local pointer `.pi/overnight-logs/latest-run.txt`
- Branch/dirty preflight is now built in.
- Stop file is checked between iterations and during quota sleep.
- Iterations have a timeout (`ITER_TIMEOUT_SECONDS`, default 7200s).
- Stray project/root agent watches are archived before deletion.

## Recommended branch/run setup
Current branch created:

```bash
git switch nightly/browser-nav-shell-loop-2026-06-18
```

Linear is unavailable / out of free usage, so use the local queue:

```bash
docs/2026-06-17-tonight-session-browser-nav-shell/04-local-implementation-queue.md
```

Before sleeping:
1. commit or stash the setup docs/script changes;
2. run one preflight/dry short invocation if desired;
3. start with:

```bash
EXPECTED_BRANCH=nightly/browser-nav-shell-loop-2026-06-18 \
PUSH_MODE=local-only \
caffeinate -is ./scripts/overnight-loop.sh
```

## Recommended implementation order
Safe order based on audits:

1. **T13** — shell scroll normalizer, remove hidden precise-delta 2x.
2. **T12** — terminal body-height alignment + idempotent Ghostty resize.
3. **T06** — camera-aware visible jump indicators.
4. **T16** — readability policy + zone fit framing constants.
5. **T07** — tile framing; animation only if T12 guardrail passes.
6. **T08** — previous view/tile/zone history once framing is stable.

Reasoning:
- T13 is the most concrete low-risk UX fix.
- T12 must protect terminals before T07 animation multiplies viewport layouts.
- T06 is pure geometry plus overlay path, relatively bounded.
- T16 provides constants needed by T07/T08 zone behavior.
- T07 animation is powerful but can destabilize live terminal/browser tiles.
- T08 history should record completed transitions, so it benefits from T07 semantics.

## Per-ticket readiness

| Ticket | Status for overnight | Notes |
|---|---|---|
| T13 | Ready | Concrete normalizer/config/check. Manual matrix can be PENDING. |
| T12 | Ready | Concrete body-height + idempotent resize/check. Visual flicker can be PENDING. |
| T06 | Ready | Concrete intersection/edge-pill policy/check. |
| T16 | Ready as bounded slice | Policy + zone fit only; minimap/semantic zoom deferred. |
| T07 | Conditional | Framing ready; animation requires T12 guardrail or default-off flag. |
| T08 | Ready after T07 | A↔B semantics decided; depends on completed transition semantics. |

## Runner improvements completed
`scripts/overnight-loop.sh` now includes:

- env overrides:
  - `PROMPT_FILE`
  - `QUEUE_FILE`
  - `EXPECTED_BRANCH`
  - `ALLOW_DIRTY`
  - `ALLOW_MAIN`
  - `PUSH_MODE`
  - `ITER_TIMEOUT_SECONDS`
  - `RUN_ROOT`
- root run dir:
  - `~/.pi/overnight-runs/continuum-revived/run-$STAMP/`
  - `~/.pi/overnight-runs/continuum-revived/latest`
  - `.pi/overnight-logs/latest-run.txt`
- durable files:
  - `status.json`
  - `events.jsonl`
  - `report.md`
- watch archival before deletion for both:
  - `.pi/agent-runs/.scheduler/watches.json`
  - `~/.pi/agent-runs/.scheduler/watches.json`
- no-token classification:
  - quota/provider signatures → sleep/retry;
  - no-token without quota signature → stop `harness-malformed-output`.
- iteration timeout around `pi -p`.
- interruptible quota sleep that checks `STOP` every `SLEEP_CHECK_SECONDS`.

## Morning report must answer
- When did the run start and stop?
- Why did it stop?
- How many iterations ran?
- Which ticket was last active?
- Which commits were created?
- Which checks/artifacts exist?
- Which manual/PENDING items remain?
- Which reviewer blocked or requested rework?

## Stop conditions for this specific push
Stop the automated run if:
- working tree is dirty in an unrecognized way;
- T12 terminal stability check fails and T07 animation is next;
- any implementation claims visual flicker/native scroll feel without artifact or PENDING note;
- reviewer marks REWORK twice on the same issue;
- a UI ticket lacks a real-path app check;
- matrix fails for unrelated reasons;
- prompt/harness output lacks a `LOOP:` token without a quota signature.

## Browser-track readiness addendum

This file was originally written for the navigation/terminal push. It is **not sufficient by itself** for a browser-track nightly unless this addendum and the browser tickets are included in the run prompt.

Current browser implementation candidates after audits/research/user preference:

| Ticket | Status for overnight | Notes |
|---|---|---|
| T02 | Ready | WKWebView Web Inspector policy only; default-off; must also cover `target=_blank` child webviews. |
| T05 | Ready | Chrome no-go/guardrail matrix only. No Chrome sync/profile access. |
| T04 | Ready | Password/autofill guardrails only. No fill/save/vault code. |
| T04b | Ready after T04 | Keychain vault service only; must namespace Continuum-owned items and reject public HTTP saves. |
| T01 | Ready | Core tab model + BrowserState schema migration only. |
| T01b | Conditional | Visible tab UI/runtime single-live-WKWebView slice after T01. |
| T03 | Conditional | Tab restore only after T01/T01b. |
| T05b | Blocked | User removed open-in-Chrome/external-browser handoff from scope. Do not implement. |

Safe browser order:
1. T02 — Web Inspector default-off policy.
2. T05 — Chrome integration no-go matrix.
3. T04 — credential guardrails/no-go tests.
4. T04b — isolated Keychain vault storage service.
5. T01 — tab model/schema migration.
6. T01b — tab UI with one live WKWebView per tile.
7. T03 — tab restore with bounded hydration.

Browser stop conditions:
- Any agent selects T05b/open-in-Chrome/external-browser handoff.
- Any implementation reads Chrome `Login Data`, `Cookies`, `Local State`, or live profile directories.
- `webView.isInspectable` remains default-on or target-blank child webviews bypass the inspection policy.
- Password/autofill work injects JS, stores credentials, or prompts fill/save before T04/T04b land.
- Keychain vault queries can read/update/delete non-Continuum-owned Keychain items.
- Browser tab work creates one live WKWebView per tab in T01b.
- A browser ticket lacks its required app flag and manifest.
