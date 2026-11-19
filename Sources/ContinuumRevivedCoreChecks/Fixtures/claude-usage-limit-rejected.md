# claude-usage-limit-rejected.jsonl — INFERRED, not a live capture

No account was at its limit while this was written (2026-11-18), so no real
`claude -p --output-format stream-json` run could be captured at the stop.

Every field is copied from what claude 2.1.321-2.1.326 really wrote at a
usage stop in Dylan's session logs (`~/.claude/projects/**/*.jsonl`, 591
entries): the synthetic assistant message (`model: "<synthetic>"`,
`error: "rate_limit"`, the one text block "You've hit your 5-hour limit ·
resets 6:20pm (America/Toronto)"), and `apiErrorParams.rate_limit_info`
(`status: "rejected"`, `resetsAt`, `rateLimitType`). The stream-json framing
(a `rate_limit_event` carrying that `rate_limit_info`, then an `is_error`
result) follows the CLI's documented stream shape and Array's committed
`rate_limit_event` fixtures. Replace it with a real capture the next time an
account runs out: the witness must stay GREEN on the real stream.
