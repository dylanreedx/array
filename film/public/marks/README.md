# film/public/marks

Logos the Remotion edit draws, loaded as `marks/<file>`. Names follow one pattern:
`array-*.svg` for Array, and `provider-<name>.svg` for a model provider.

| File | What | Array runs it? | Where it may appear |
| --- | --- | --- | --- |
| array-mark.svg | Array mark (cropped to the ink, for lockups) | — | anywhere |
| array-logo-blue.svg | Array logo, blue | — | anywhere |
| provider-anthropic.svg | Anthropic (Claude Code) | yes | anywhere |
| provider-openai.svg | OpenAI (Codex) | yes | anywhere |
| provider-pi.svg | Pi | yes | anywhere |
| provider-gemini.svg | Google Gemini | **no** | the edit only |
| provider-meta.svg | Meta | **no** | the edit only |

Gemini and Meta were added on 2026-10-17 for the dictation film (`.plans/76-dictation-film`),
by Dylan's decision: "we're not going to add their CLI support just yet, but just for the video's
sake." Array has no Gemini or Meta runner, so these two marks never go into the app, a film scene
or `website/public`. Before a cut that shows them goes public, ask Dylan whether it needs a "coming
soon" label: Array's copy rule is to claim only what it does, and the marks belong to Google and
Meta.

Adding a mark: name it `provider-<name>.svg`, give it `xmlns` and a `viewBox`, keep the brand's own
colours, prefix its internal ids with the name (`gemini__a`) so two marks on one page don't
collide, and add a row here.
