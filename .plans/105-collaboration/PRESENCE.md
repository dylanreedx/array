# Presence and live token usage on hover

29 October 2026. **Dylan explicitly wants live teammate token usage when hovering a collaborator's cursor or a similar presence target, without a constant usage overlay.** This supersedes the initial assistant suggestion to confine tokens to a separate usage screen.

This is desired product behavior, not an implemented feature. Accounting choices and runner telemetry coverage remain open.

## Candidate hover interaction

Hover a teammate's cursor label to reveal a compact card. Offer the same card from an avatar or participant list when their cursor is offscreen or absent. A keyboard/focus action should reveal the equivalent information.

Illustrative content, with synthetic values:

> **Alex · Reviewing interface changes**
>
> 3 agents running · 1 awaiting input
>
> **Tokens today: 1.24M**
>
> Shared area · Updated 2s ago
>
> Input 980K · Output 60K · Cached input 200K

The illustrated total assumes those input/cache categories are normalized to be disjoint; real provider reports may use different definitions. The UI must name the actual categories and avoid double-counting.

No token counter or teammate-usage overlay stays visible after hover/focus ends. A moving cursor should not make the card impossible to inspect: compare a short intent delay, a stable card anchor, and a move-into-card interaction. These timing details are hypotheses, not selected constants. Hover should consume existing usage observations, not trigger a summary model call.

## Live means freshest available reported usage

Some providers may report usage during execution; others may update only when a turn or request completes. Do not fabricate streaming token counts. Show the freshest reported value, timestamp and coverage; distinguish live connection from fresh measurements. An explicit estimate, if later offered, must remain distinguishable from measured usage.

Open accounting questions:

- Default period: current run, today, shared-session lifetime or selectable period?
- Default scope: current shared area, all shared work, or a personal total the teammate deliberately makes visible?
- Does “today” use the viewer's timezone or a shared workspace timezone?
- How do cached input, fresh input, output and cache writes map across actual runner reports?
- How do cumulative counters, reconnect, retries, forks and duplicated views avoid counting the same work twice?
- Does attribution follow the executing owner, the prompt author, or both? Shared host usage should not be double-counted across every participant.
- What should appear when some runners have no usage telemetry: partial total with coverage, unavailable category, or separate provider totals?

These questions should refine the requested hover experience rather than remove it. Token volume is an instrument users can inspect. No productivity score or ranking is required by this proposal.

## Three signals, separately understandable

| Signal | Candidate information |
| --- | --- |
| Human availability | Available, focused, away; optional expiring status |
| Human attention | Viewing a shared tile, reviewing a diff, composing in shared discussion |
| Agent activity | Running, awaiting input, ready for review, host unavailable |

A person can be away while several agents continue. A shared host can be unavailable while its owner remains present elsewhere. Agent state should link to the relevant visible work where access permits.

Cursor/selection presence belongs inside a common shared coordinate space. Across independently arranged canvases, use object/content presence instead. Sharing one area should not expose unrelated private names or content; whether a teammate chooses to share a broader aggregate token count is a separate profile/scope decision.

## Reference patterns

- Amp shows owners, active/away participants and running-thread counts on shared runners: [Multiplayer](https://ampcode.com/docs/collaborate/multiplayer), [runners](https://ampcode.com/docs/cli/runners).
- Slack separates chosen status and availability: [official guide](https://slack.com/intl/en-gb/help/articles/201864558-Set-your-Slack-status-and-availability/).
- GitHub supports optional status with visibility and expiration: [profile guide](https://docs.github.com/en/account-and-profile/tutorials/personalize-your-profile).
- Zed distinguishes collaborator locations and offers pane-specific following: [channels](https://zed.dev/docs/collaboration/channels).
- Claude documents separate cache accounting: [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching). This motivates checking semantics per runner; it does not establish uniform cross-provider telemetry.

No cursor-hover prototype, native appearance preview, usage aggregation test or provider telemetry experiment was run.
