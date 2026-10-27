# Context window fallback provenance

`ContextWindows.json` is a denominator fallback, never a picker catalogue. Models
are offered exclusively by each installed CLI's live catalogue.

Initial source captured 2026-10-13: `~/.pi/agent/models-store.json` read-only on
Dylan's Mac. Each fully-qualified model key and positive `contextWindow` value
was copied verbatim; `maxTokens` (output allowance) was excluded. The originating
store is maintained by pi 0.85.0. The checked-in file includes both providers present in that source (anthropic
and openai-codex)
so a pi account enabling another provider can resolve its exact model too.

Additional exact provider observation:

| Model | Window | Source |
|---|---:|---|
| anthropic/claude-opus-5-5 | 1000000 | `ContinuumRevivedCoreChecks/Fixtures/claude-2.1.291-opus-turn.jsonl`, `result.modelUsage[claude-opus-5-5].contextWindow` |

Live stated windows always supersede this file, and are remembered by harness
and exact model. The window each harness's own CLI publishes (Codex's
`models_cache.json`, pi's `models-store.json`) also supersedes it: this file
is a dated copy of those, so a model the CLI ships later must not read as
unknown. No prefix, fuzzy match, inferred model-family value or guessed
capacity is used. Missing entries remain visibly unknown and fail the offered
model gate.

Current installed CLI captures (2026-10-13):

| Model | Window | Source |
|---|---:|---|
| anthropic/claude-sonnet-5-5 | 1000000 | `Fixtures/context-meter/claude-2.1.296.jsonl`, real result modelUsage.contextWindow |
| openai-codex/gpt-5.4 | 272000 | `Fixtures/context-meter/catalogs/pi-0.85.0.txt`, context column 272K |
| openai-codex/gpt-5.4-mini | 272000 | `Fixtures/context-meter/catalogs/pi-0.85.0.txt`, context column 272K |

All slugs in `Fixtures/context-meter/catalogs/codex-0.159.3.json` were copied
with exact `context_window` values and `openai-codex/` qualification.
`max_context_window` was excluded: it is a configurable upper limit.
Runtime app-server `modelContextWindow` (which can reflect the effective
percent and configuration) remains the first rung and supersedes this fallback.

`anthropic/claude-haiku-5-5` was added after the live offered-model sweep
failed on it. An actual `claude` 2.1.296 tiny turn (`--model claude-haiku-5-5`)
reported `modelUsage.claude-haiku-5-5.contextWindow = 1000000`; the scrubbed
turn is appended in `Fixtures/context-meter/claude-2.1.296.jsonl`.
