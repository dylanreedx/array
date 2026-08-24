#!/usr/bin/env python3
"""`.plans/45` S7 — the transcript gallery builder.

Pairs two `--ui-tour-check` render directories (before / after) into one
self-contained HTML page for Dylan's review. Only the semantic-transcript
surface is included; images are embedded as data URIs so the page needs no
host. The page is published as a PRIVATE artifact and re-published to the SAME
URL each iteration; nothing merges to a release until the gallery is approved.

Usage:
  python3 scripts/transcript-gallery.py BEFORE_TOUR_DIR AFTER_TOUR_DIR OUT_HTML \
      --before-label "6926044b (rejected)" --after-label "58336c09"
"""
import argparse
import base64
import html
import re
import sys
from pathlib import Path

PATTERN = re.compile(
    r"^semantic-transcript-(?P<state>.+)-(?P<w>\d+)x(?P<h>\d+)-(?P<appearance>aqua|darkAqua)\.png$"
)

STATE_ORDER = [
    "real-claude-turn", "mixed", "long", "active-tool", "failed-tool", "approval",
    "heading-ladder", "lists", "table-and-breaks", "error-vs-notice",
    "turn-boundary", "receded-work",
]

STATE_NOTES = {
    "real-claude-turn": "The replayed REAL claude capture — the state the rejection proved the authored fixtures cannot stand in for. Judge the tool rows here first.",
    "turn-boundary": "Turn separation: 32pt + hairline, consecutive queued prompts split.",
    "receded-work": "Three settled tools fold to one summary line; the failure stays plain.",
}


def collect(directory: Path):
    renders = {}
    for path in sorted(directory.glob("semantic-transcript-*.png")):
        match = PATTERN.match(path.name)
        if not match:
            continue
        key = (match["state"], int(match["w"]), match["appearance"])
        renders[key] = path
    return renders


def data_uri(path: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("out")
    parser.add_argument("--before-label", default="before")
    parser.add_argument("--after-label", default="after")
    parser.add_argument("--changelog", default="")
    args = parser.parse_args()

    before = collect(Path(args.before))
    after = collect(Path(args.after))
    if not after:
        print("no semantic-transcript renders in the after directory", file=sys.stderr)
        return 1

    states = []
    seen = set()
    for key in after:
        state = key[0]
        if state not in seen:
            seen.add(state)
            states.append(state)
    states.sort(key=lambda s: (STATE_ORDER.index(s) if s in STATE_ORDER else 99, s))

    sections = []
    for state in states:
        blocks = []
        for appearance in ("darkAqua", "aqua"):
            widths = sorted({k[1] for k in after if k[0] == state and k[2] == appearance})
            for width in widths:
                after_path = after.get((state, width, appearance))
                if after_path is None:
                    continue
                before_path = before.get((state, width, appearance))
                before_cell = (
                    f'<figure><figcaption>{html.escape(args.before_label)}</figcaption>'
                    f'<img src="{data_uri(before_path)}" alt="{html.escape(state)} before"></figure>'
                    if before_path
                    else '<figure class="absent"><figcaption>'
                    + html.escape(args.before_label)
                    + "</figcaption><div class=\"missing\">state did not exist</div></figure>"
                )
                blocks.append(
                    f'<div class="pair" data-appearance="{appearance}">'
                    f'<div class="pair-label">{appearance} · {width}px</div>'
                    f'<div class="pair-grid">{before_cell}'
                    f'<figure><figcaption>{html.escape(args.after_label)}</figcaption>'
                    f'<img src="{data_uri(after_path)}" alt="{html.escape(state)} after"></figure>'
                    f"</div></div>"
                )
        note = STATE_NOTES.get(state, "")
        note_html = f'<p class="note">{html.escape(note)}</p>' if note else ""
        sections.append(
            f'<section id="{html.escape(state)}"><h2>{html.escape(state)}</h2>'
            f"{note_html}{''.join(blocks)}</section>"
        )

    nav = "".join(
        f'<a href="#{html.escape(s)}">{html.escape(s)}</a>' for s in states
    )
    changelog = (
        f'<div class="changelog"><h2>What moved</h2>{args.changelog}</div>'
        if args.changelog
        else ""
    )

    page = f"""<title>Transcript Gallery</title>
<style>
:root {{
  --ink: #d6d9e0; --ink-dim: #8a8fa3; --ground: #16181f; --panel: #1d2029;
  --edge: #2a2e3b; --accent: #7aa2f7; --good: #9ece6a;
}}
* {{ box-sizing: border-box; }}
body {{ background: var(--ground); color: var(--ink); margin: 0;
  font: 15px/1.6 "SF Pro Text", -apple-system, "Segoe UI", sans-serif; }}
header {{ padding: 40px 32px 24px; border-bottom: 1px solid var(--edge); }}
h1 {{ font-size: 22px; margin: 0 0 6px; letter-spacing: -0.01em; }}
h2 {{ font-size: 16px; margin: 0 0 8px; color: var(--accent);
  font-family: "SF Mono", ui-monospace, monospace; }}
.meta {{ color: var(--ink-dim); font-size: 13px; }}
nav {{ display: flex; flex-wrap: wrap; gap: 8px 14px; padding: 14px 32px;
  border-bottom: 1px solid var(--edge); position: sticky; top: 0;
  background: var(--ground); z-index: 2; }}
nav a {{ color: var(--ink-dim); text-decoration: none; font-size: 12px;
  font-family: "SF Mono", ui-monospace, monospace; }}
nav a:hover, nav a:focus {{ color: var(--accent); }}
section {{ padding: 28px 32px; border-bottom: 1px solid var(--edge); }}
.note {{ color: var(--ink-dim); font-size: 13px; max-width: 68ch; margin: 0 0 16px; }}
.pair {{ margin: 0 0 22px; }}
.pair-label {{ font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase;
  color: var(--ink-dim); margin-bottom: 8px;
  font-family: "SF Mono", ui-monospace, monospace; }}
.pair-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }}
figure {{ margin: 0; background: var(--panel); border: 1px solid var(--edge);
  border-radius: 8px; padding: 10px; }}
figcaption {{ font-size: 12px; color: var(--ink-dim); margin-bottom: 8px;
  font-family: "SF Mono", ui-monospace, monospace; }}
figure img {{ max-width: 100%; height: auto; display: block; border-radius: 4px; }}
.missing {{ color: var(--ink-dim); font-size: 13px; padding: 40px 0; text-align: center; }}
.changelog {{ padding: 24px 32px; border-bottom: 1px solid var(--edge); }}
.changelog ul {{ margin: 0; padding-left: 20px; color: var(--ink); max-width: 76ch; }}
.changelog li {{ margin-bottom: 6px; }}
.verdict {{ padding: 24px 32px 48px; color: var(--ink-dim); font-size: 13px; max-width: 70ch; }}
.verdict strong {{ color: var(--good); }}
@media (max-width: 760px) {{ .pair-grid {{ grid-template-columns: 1fr; }} }}
</style>
<header>
  <h1>Transcript Gallery</h1>
  <div class="meta">before: {html.escape(args.before_label)} &nbsp;·&nbsp; after: {html.escape(args.after_label)} — semantic-transcript renders from <code>--ui-tour-check</code>, both appearances</div>
</header>
<nav>{nav}</nav>
{changelog}
{''.join(sections)}
<div class="verdict"><strong>The gate:</strong> nothing merges to a release until this gallery is approved. The ledger records this iteration; reply with a verdict or the specific states that still fail.</div>
"""
    Path(args.out).write_text(page)
    print(f"wrote {args.out} ({Path(args.out).stat().st_size / 1024 / 1024:.1f} MB, {len(states)} states)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
