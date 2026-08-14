# Brand mark provenance

§4.5 requires a provenance manifest for every vendor mark: source URL, brand-guideline
URL, retrieval date, SHA-256, appearance variants, transformations, and review status.
This is that manifest.

**Status: DESIGN-TIME MATERIAL, NOT SHIPPED.** These files are loaded by the S0 proposal
mock from this directory by repo-relative path so the density review can be judged with
the mark slot really filled. They are **not** bundled into the `.app`, and nothing in the
shipped sidebar reads them. Promoting them to real resources — a `BrandMarkCatalog`,
`Package.swift` resource declarations, `make-app-bundle.sh` handling, and the offline
bundle witness §5.5 demands — is P3.1's job.

Supplied by Dylan on 2026-08-14 (`~/Downloads`) — the first four with the batch, `gemini.svg` after seeing what its absence did to a row — sourced from svgl.app, which §4.5 permits
as a **design-time discovery** source. §10 forbids fetching provider logos at runtime, and
nothing here does.

| file | mark | variants | SHA-256 | transformations |
|---|---|---|---|---|
| `anthropic.svg` | Anthropic / Claude | single (carries `fill="#D97757"`) | `0df6dad2…46e5eea1` | none — renamed only |
| `openai-light.svg` | OpenAI | light | `a4b4dae5…c321718e` | none — renamed only |
| `openai-dark.svg` | OpenAI | dark | `db81a822…c59840c8` | none — renamed only |
| `xai-light.svg` | xAI / Grok | light | `46e9e816…107f3566` | none — renamed only |
| `xai-dark.svg` | xAI / Grok | dark | `a2d3a91c…132c4128` | none — renamed only |
| `gemini.svg` | Google / Gemini | single (masked, own gradient) | `9433d6ef…edc36760` | none — renamed only |

No file has been edited. Renaming to a semantic key is the only change.

## Tinting — the mock now DOES tint, and that is an open question, not a decision

§4.5 says: *"Do not tint vendor marks unless the brand rules explicitly permit template
treatment."* `anthropic.svg` carries Anthropic's own `#D97757`, and the OpenAI and xAI
files ship separate light/dark variants precisely because each vendor expects the correct
variant to be chosen rather than a single mark recoloured.

**On 2026-08-14 Dylan directed the mock to draw the marks flat, in the theme's own
colour** — the T3 Code reference he is working from renders all of its trailing icons as
one muted monochrome, and a row of full-colour vendor logos competes with the status
colour for attention. The mock therefore loads one canonical file per vendor for its
silhouette, discards the file's colours, and fills the alpha coverage with
`primary @ 72%`. The per-appearance *files* consequently carry no information in the mock;
they are retained because P3.1 may need them.

This is a **design-time mock choice**. It does not resolve §4.5, it sharpens it:

- Monochrome/template treatment must be confirmed **per vendor** against that vendor's own
  brand rules before anything ships. Some publish an explicit one-colour mark and permit
  it; some require the full-colour mark at all sizes; some specify a minimum size.
- If a vendor forbids it, the shipped catalogue needs a per-mark flag — *this one is a
  template, that one is not* — and the row must look acceptable with the two mixed.

Until that review happens, treat every image in `qa-runs/**/status/` and
`qa-runs/**/proposals/` as showing a treatment Array has **not** established it may use.

## Outstanding before P3.1 can ship these

1. **Trademark review per vendor** — each brand's usage terms read and recorded, with the
   brand-guideline URL captured here, **and now also whether monochrome/template
   treatment is permitted** (see Tinting above). **Not yet done; Dylan's call.** These
   marks are in a local review artifact today, which is a materially lower bar than
   shipping them in a distributed `.app`.
2. **Missing coverage** — Google/Gemini has landed. §4.5's initial set still names
   OpenRouter, Mistral, Groq, Cerebras, and the three harness marks (Codex, Claude Code,
   Pi). Pi matters most: today a Pi agent renders as its provider's glyph and is
   indistinguishable from Claude Code or Codex. The mock keeps one unbundled provider on
   screen (`Mistral Large 3`) so the name fallback stays visible in the artifact instead
   of quietly disappearing as marks arrive.
3. **The resource pipeline and its witness** — build the real `.app`, enumerate
   `Contents/Resources`, resolve every semantic key offline, render both appearance
   variants, prove the unknown-provider fallback (now the model NAME, not initials — see below),
   and prove a missing known asset fails visibly in QA rather than rendering blank.
4. **A licence/attribution decision** — whether Array must display attribution anywhere.

## The two-character fallback is being replaced by the model name (2026-08-14)

§4.5 specifies a two-character badge when a provider has no asset. The mock rendered one —
`GE`, for `Gemini 3 Pro` — and Dylan, looking at his own review artifact, asked what it was
supposed to be. A monogram only reads once you know the set it is drawn from.

It matters more than it looks, because the mark-only anatomy has already taken the model
name off that row: the badge is not a degraded identity, it is the only one. The mock now
prints the model's name instead. **This needs a §4.5 amendment**, and it makes bundling the
missing marks (item 2 above) the difference between a rare fallback and a routine one.

Also observed and not acted on: **the xAI mark does not survive at 14 pt** — Grok's logo
reduces to roughly a slashed circle. It needs either a larger slot or a vendor small-size
variant. P3.1.
