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

Supplied by Dylan on 2026-08-14 (`~/Downloads`), sourced from svgl.app, which §4.5 permits
as a **design-time discovery** source. §10 forbids fetching provider logos at runtime, and
nothing here does.

| file | mark | variants | SHA-256 | transformations |
|---|---|---|---|---|
| `anthropic.svg` | Anthropic / Claude | single (carries `fill="#D97757"`) | `0df6dad2…46e5eea1` | none — renamed only |
| `openai-light.svg` | OpenAI | light | `a4b4dae5…c321718e` | none — renamed only |
| `openai-dark.svg` | OpenAI | dark | `db81a822…c59840c8` | none — renamed only |
| `xai-light.svg` | xAI / Grok | light | `46e9e816…107f3566` | none — renamed only |
| `xai-dark.svg` | xAI / Grok | dark | `a2d3a91c…132c4128` | none — renamed only |

No file has been edited. Renaming to a semantic key is the only change.

## Tinting

**Do not tint these.** §4.5: *"Do not tint vendor marks unless the brand rules explicitly
permit template treatment."* `anthropic.svg` carries Anthropic's own `#D97757`, and the
OpenAI and xAI files ship separate light/dark variants precisely because the vendor
expects the correct variant to be chosen rather than a single mark recoloured. The mock
selects by appearance and draws each mark unmodified.

## Outstanding before P3.1 can ship these

1. **Trademark review per vendor** — each brand's usage terms read and recorded, with the
   brand-guideline URL captured here. **Not yet done; Dylan's call.** These marks are in a
   local review artifact today, which is a materially lower bar than shipping them in a
   distributed `.app`.
2. **Missing coverage** — §4.5's initial set also names Google/Gemini, OpenRouter,
   Mistral, Groq, Cerebras, and the three harness marks (Codex, Claude Code, Pi). Pi
   matters most: today a Pi agent renders as its provider's glyph and is indistinguishable
   from Claude Code or Codex.
3. **The resource pipeline and its witness** — build the real `.app`, enumerate
   `Contents/Resources`, resolve every semantic key offline, render both appearance
   variants, prove the unknown-provider initials fallback, and prove a missing known asset
   fails visibly in QA rather than rendering blank.
4. **A licence/attribution decision** — whether Array must display attribution anywhere.
