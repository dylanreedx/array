# 101 — Subscription accounts and usage limits

Parked 2026-10-29 at Dylan's request. **Not started: brainstorm first, then
design.** Nothing below is decided except what Dylan said.

## What Dylan asked for (his words, lightly trimmed)

> I need a way to manage my subscription accounts within Array. I now have a
> personal Claude Code Max account as well as a team plan. I want to be aware of
> which I'm using as well as switch within Array while using Array. We need to
> think about switching mid agent execution, the usage limits between accounts.
>
> For the most part I'm not going to be thinking about my account, but the usage
> limit remaining, 5h AND weekly, is super important. Maybe we think about the
> UI/UX above the composer — we have a native hover UI effect handling for the
> usage details.

## Why it came up

On the night of 2026-10-28, the overnight agents ran on Codex and used up
Dylan's ChatGPT credits by 08:09 the next morning. He should have been signed
into his new personal Max account. The morning was spent moving agents from
Codex to Claude by hand.

## What exists today (observed 2026-10-29, 0.7.34 + the 0.7.35 candidate)

- The pill row above the composer shows context %, `5h 84%`, `7d 5%` and an
  estimated session cost. Hovering it opens a plain text panel (see
  `usage-meter-today.png`) with each figure's source, observed time, reset
  time and scope ("this whole provider account, shared by every agent signed
  into it"). It names no account.
- The 5h/7d figures come from the Claude CLI's own account rate limits.
- The Claude CLI on this Mac was signed into personal@example.com, the
  personal Max 5x plan (`claude auth status` → orgType `claude_max`). The team
  plan is a separate login.
- Every managed Claude agent shares the one keychain login
  (`Claude Code-credentials`). There is no per-agent account.
- Codex and pi have their own logins and limits. Pi's default provider is
  `openai-codex`, so pi spends Codex credits.
- Switching a tile from Codex to Claude starts Claude with an empty memory: it
  tries `--resume`, finds nothing, and starts fresh. The tile only keeps the old
  transcript on screen.

## Constraints that already bind any design

- **CLIs own their auth** (CLAUDE.md non-negotiable #3). Array may observe which
  account a CLI is using and drive the CLI's own login flow. It must never
  store credentials or ask for API keys.
- Usage limits are per account, not per agent. Any per-agent view has to say so.
- Notification paths (non-negotiable #6): any limit alert added here goes into
  `docs/internals/notification-paths.md`.

## Open questions for the brainstorm

1. How does Array see which account each CLI is signed into, and keep up when
   it changes outside Array?
2. Can two Claude accounts coexist on one Mac (separate config directories,
   separate keychain items), so agents can be pinned to one or the other?
3. What happens to a running agent when the account changes: finish the turn
   on the old account, or stop at a turn boundary and resume on the new one?
4. What should Array do near a limit: warn, suggest switching, or switch
   automatically to the account with the most headroom?
5. Codex and pi: the same model for their accounts and credits?
6. UI: the 5h and weekly remaining figures above the composer are the primary
   surface. The hover panel is a wall of text today, so it needs a real design
   that names the account and both limits, using Array's styled components,
   checked in light and dark.
