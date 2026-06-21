# Overnight audit/reimplementation master — one slice, then exit

You are auditing work already produced on branch `nightly/browser-nav-shell-loop-2026-06-18`.
Run NON-INTERACTIVELY (`pi -p`). Handle EXACTLY ONE audit queue item, then exit.

No Linear. Do not call Linear tools.

This is not a speed run. Bias toward product quality and ruthless honesty. A passing self-check is not enough.

## Harness header

Read the harness header above this prompt for:
- `QUEUE_FILE`
- `RUN_DIR`
- `PUSH_MODE`
- model/thinking settings if present

## Global context

User is disappointed with the overnight output. Initial observed problems:
- performance when zooming/panning around shell tiles is still not great;
- default Ghostty/tmux font/zoom in shell tiles is too small by default;
- browser work appears not actually product-visible; inspect element/devtools not available;
- tmux shell tile persistence still needs scrutiny;
- shell tiles still do not match Dylan's Ghostty/tmux theme.

Use those as a filter, but still perform a full audit of the selected slice.

## Pick exactly one queue item

1. Read `QUEUE_FILE`.
2. Pick the first `[ ]` item.
3. If no `[ ]` items remain, print `LOOP: STOP queue-empty` and exit.
4. Never work on more than one queue item.

## Required method

For the selected item:

1. Identify the relevant commits with `git log --oneline --reverse 735aa1a..HEAD` and/or queue metadata.
2. Read the original ticket(s), the implementation diff, and relevant production code.
3. Audit for:
   - product-visible behavior actually implemented;
   - fake/shallow/self-fulfilling checks;
   - app checks that bypass real user paths;
   - performance regressions or avoidable heavy work in input/layout/render loops;
   - over-broad access changes such as `fileprivate` just for checks;
   - architecture drift, hidden globals, hardcoded constants, persistence/schema risks;
   - mismatch with user's stated UX expectations.
4. If implementation is acceptable, improve only evidence/docs if needed and mark queue item `[x]` with an audit note.
5. If implementation is bad but locally fixable in this slice, reimplement/fix it, add real verification, and commit.
6. If implementation is bad and not safely fixable, mark queue item `[!]` and write a handoff under `RUN_DIR/audits/<item-id>-handoff.md`; do not paper over it.

## Quality bar

Do not mark an item done unless the answer is yes to all applicable questions:
- Would Dylan notice the improvement in the real app?
- Does the check exercise the same code path a user uses?
- Is the behavior robust after app restart / workspace reload where relevant?
- Is performance acceptable for zoom/pan/scroll or at least measured with an artifact?
- Is the implementation smaller/cleaner than the problem warrants?

## Verification

Run targeted checks for the slice. Run `./scripts/run-matrix.sh --fast` only when code changed materially or the slice touches shared systems.

For shell/browser UX slices, include at least one real app flag/artifact or a manual-check handoff explaining exactly what remains unverified.

## Commit policy

If you change code/docs:
- one audit queue item per commit;
- stage only relevant files;
- commit format:
  - `fix(audit): <item-id> <summary>` for fixes/reimplementation;
  - `docs(audit): <item-id> <summary>` for audit-only notes.

Default `PUSH_MODE=local-only`; do not push unless explicitly configured.

## Local audit artifact

Always write `RUN_DIR/audits/<item-id>.md` with:
- verdict: keep / fixed / needs-human / revert-candidate;
- commits inspected;
- files inspected;
- issues found;
- changes made, if any;
- verification commands and real output summary;
- artifact paths;
- remaining risks.

## Queue update

Update `QUEUE_FILE`:
- `[x]` for audited/fixed and acceptable;
- `[!]` for needs-human/revert-candidate;
- leave future items untouched.

## Exit contract

Final line must be exactly one of:
- `LOOP: CONTINUE <item-id> audited`
- `LOOP: CONTINUE <item-id> fixed`
- `LOOP: STOP queue-empty`
- `LOOP: STOP needs-human <item-id>`
- `LOOP: STOP provider-failure`
- `LOOP: STOP matrix-failure-needs-human`
- `LOOP: STOP ambiguous-scope`
