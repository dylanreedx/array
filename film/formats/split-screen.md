# Format: 1 of 5, split screen (UNBUILT)

Status: an idea, never built. Source: research/20 idea 5 (2026-10-15).

Two panes, the same five agents and the same clock. Left, "tabs": you see one
agent at a time, a counter reads `VISIBLE 1/5`, and a finished agent goes
unnoticed. Right, "Array": `VISIBLE 5/5`, and every change is seen. A counter
of missed moments ticks up on the left. It claims visibility, not speed.

## Beats (about 15 s loop, vertical first)

| Beat | What happens |
| --- | --- |
| Set | Both panes and both counters |
| Miss | A change happens; the left misses it, the right shows it |
| Again | Twice more, faster; the missed counter climbs |
| Seam | Back to the start; it loops |

## Open questions before building

- Both halves must be the same real run: the left is the same take re-cut to
  one tile full-frame at a time.
- 9:16 stacks the panes top and bottom; 16:9 puts them side by side.
