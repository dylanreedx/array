# Array brand

Array is a native workspace for coding agents. Keep every agent in view. More work. Less hidden state.

## Mark and lockup

The mark repeats the A's left stroke as it recedes, then resolves into the full A. Use the SVG in a single solid color, on a quiet field, with clear space at least the width of the A's crossbar on every side. Keep the left-to-right trail intact. The wide lockup places the mark before the lowercase `array` wordmark. Use a simplified two-stroke silhouette below 24 px; preserve the existing favicon and app icon until a direction is selected.

Dark use: `#4CD6B4` or `#5FA8FF` on `#0B0D10`. Light use: `#1257C7` or `#096B57` on `#E9EBEF`. The three folders in `out/` are exploratory campaign directions. Their color pairings come from the app's Swift tokens; they are options, not an app-icon selection.

## Palette and type

The complete light/dark export is [tokens.json](tokens.json), copied from `DesignTokens.swift`. Core dark surfaces are canvas `#0B0D10`, panel `#101318`, tile `#14171C`, and chrome `#1C212A`. Core light surfaces are canvas `#E9EBEF`, panel `#F5F6F9`, tile `#FAFBFC`, and chrome `#F1F3F6`. Text is `#F2F4F8` / `#14171C` with secondary `#AFB6C2` / `#54585F`. Status colors: working `#5FA8FF`, approval `#FFB347`, input `#C08CFF`, failed `#FF8A85`, done `#4FD07A`, review `#4CD6B4` (dark values; use the light values in `tokens.json` on light surfaces).

Use the system font for prose and SF Mono for code and small technical labels. App type roles are title large 18 pt bold, title 15 pt semibold, body 13 pt, label 11 pt medium, and caption 9 pt. Social headline type may scale up while retaining that system voice.

## Voice and imagery

Approved lines: “Keep every agent in view.” “Launch agents and tools from anywhere. Array keeps everything they touch visible on one native workspace.” “More work. Less hidden state.” Use direct, calm language and show the real workspace. Workflow diagrams are explanatory illustrations, never UI screenshots.

Never show an activity dock, a dev-server tile kind, a canvas lineage overlay, or hardcoded model names as product claims. The companion is only a teaser: the invite flow is disabled, its canvas is read-only, and its rewrite is unmerged. These limits follow [.plans/68-launch-film/README.md](../.plans/68-launch-film/README.md#L189-L197).
