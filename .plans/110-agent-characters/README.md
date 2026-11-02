# 110 — Agent characters (Duckherd-compatible sprites)

Researched and written 2026-11-01 on the `array/agent-characters` bench, from
`origin/array/integration` at `2af6fdd8` (0.7.37). **Built 2026-11-01**: see
"Built" at the end, which records what changed from this design and why.

Dylan's request: "add characters/sprites/animations which Duckherd has built into
claude mods… this can be appended to the provider logo i think… idk how they
exactly are assigned but we should be able to handle the same format and render it
in the sidebar and on agent tiles. Thoroughly research Duckherd and how to render
performantly, as well as import the configuration within our settings."

## The short version

- **Duckherd** is an MIT-licensed Claude Code plugin (a "mod") by Ali Alsalkhadi.
  Its main job is orchestration: a lead agent that plans, and helper agents that do
  the work. The characters are its UI. Each helper is drawn as an animated pixel duck
  in Duckherd's side panel inside the terminal, and the duck acts out what the
  helper is doing.
- **Its format is easy to support.** A character set is one JSON "theme" file.
  Every frame is a few rows of letters, each letter a palette colour, with `.` for
  clear. A helper has five work loops (`dabble`, `read`, `type`, `run`, `think`) and
  ten reaction sets (`done`, `failed`, `cheer`, `droop`, `asleep`, `idle`,
  `idleMove`, `flinch`, `wave`, `noticed`). Array can parse it, check it with the
  same rules Duckherd uses, and turn each character into one small texture.
- **Duckherd's own ducks are code, not files.** We exported them through Duckherd's
  own drawing code into a theme file, and Duckherd's own validator accepts it:
  8 characters, 105 frames each, plus the lead duck.
- **License: MIT.** Array may read the theme files users already have, and may
  bundle Duckherd's ducks if it ships the copyright and permission notice. The
  MIT license gives no right to the name, so we say "Duckherd-compatible", never
  "Duckherd". Themes written by other people carry their own licenses: Array may
  display them on the user's Mac, but may not bundle them.
- **Performance is a non-issue if it's done one way.** All the sprites share one
  decoded texture per character and are stepped by changing `contentsRect`. Driven
  by Core Animation keyframes, 100–500 sprites cost **0.01–0.3% CPU** and no
  main-thread work per frame. One shared timer costs **0.2–0.5%**. The naive versions
  cost far more: a timer per sprite is **2–11%**, swapping `NSImageView` images is
  **2.8–7.4%**, and redrawing in `draw(_:)` is **4–15%**. Numbers are below.
- **Placement:** Dylan's suggestion works. In the sidebar the character sits just
  left of the provider mark on line 2. In the tile header it goes between the
  provider mark and the title. Both are 20 × 12 pt, at 1 pt per art pixel.

## 1. What Duckherd is

Sources, all read on 2026-11-01:

- Repository: https://github.com/AliAlsalkhadi/duckherd at commit
  `ea44e834632e91c17fc410e3227e7ba060ce0674` (tag `v0.4.10`, 2026-10-27), MIT, 6 stars,
  0 forks. Cloned read-only into a scratch folder. Files read: `README.md`,
  `LICENSE`, `SECURITY.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`,
  `hooks/creatures.ts` (the ducks and the animation engine), `hooks/themes.ts` (the
  theme file format and validator), `hooks/critter.ts` (colours),
  `hooks/register.tsx` (assignment and theme discovery), `hooks/settings.ts`,
  `hooks/duck-view.tsx` (the terminal-side clock), `hooks/finer.ts` and `hooks/png.ts`
  (the picture renderer), `sounds/README.md`, and the theme cases in
  `hooks/duckherd.test.tsx`.
- Claude Code plugin manifest reference, for where plugin settings are stored:
  https://code.claude.com/docs/en/plugins-reference ("Where values are stored":
  non-sensitive `userConfig` values live under `pluginConfigs` in `settings.json`).
- Array's own earlier research: `.plans/97-trustworthy-professional-software/research/07-duckherd.md`
  (same commit), and the 2026-10-29 conversation where Dylan pointed at the repo
  ("my coworkers … they all have mods").

What it is:

- A Claude Code plugin that loads a "mod" module (`hooks/hooks.json` →
  `register.tsx`). The mod draws a side panel (`$.ui.open`, 88 columns) in a
  terminal Claude Code session. The README says: "A lead duck that plans and picks
  each helper's model. It can't edit files; helpers do the work."
- **The characters.** Every helper agent gets a duck in the panel. The duck acts
  out the helper's latest step: dabbling while it searches, reading a page, pecking
  at a laptop while it edits, running with a stopwatch while a command runs,
  thinking. It startles when a step fails and waves when it needs your OK. It slows
  down when the helper goes quiet and dozes when it seems stuck. It cheers when the
  helper finishes, or droops under a rain cloud when it fails. A Haiku helper is a
  duckling and an Opus helper is a crowned drake. The lead is a "super duck" that
  powers up while work runs.
- **How it's drawn.** Inside the terminal the ducks are either Unicode octant block
  characters (2 × 4 pixels per cell, at most two colours per cell) or real PNG
  pictures (kitty, WezTerm, cmux; not tmux), redrawn every 150 ms "beat", and only
  when the picture changes. While cmux is not the front app the panel paces itself
  to every 5 s.
- **Not on this Mac.** There is no `~/.claude/duckherd/`, no Duckherd entry in
  `~/.claude/plugins/installed_plugins.json`, and no theme file anywhere Spotlight
  can see. Dylan's coworkers run it. Every example below comes from the source.
- **No third-party themes exist yet.** A GitHub code search for `duckherdTheme`
  finds only Duckherd's own `themes.ts`, and a web search finds nothing. The format
  is real and documented, but today the only content in it is what we exported.

## 2. The format, precisely

### 2.1 Where a character set comes from

1. **Built in: the ducks.** These are drawn by code (`creatures.ts`), not stored as a
   file. They are 20 × 12 pixel frames built from parts (head, body, feet, wing,
   props), in six breeds (Classic, Mallard, Mallard hen, Pekin, Khaki, Black), with
   hats (bow, beanie, beret, cap, crown) on every other helper. Haiku helpers are
   ducklings and Opus helpers are a drake. The lead's frames are 28 × 16.
2. **Theme files ("themes from outside", `themes.ts`).** A theme is found in three
   places:
   - `<themesDir>/*.theme.json`;
   - `<themesDir>/<folder>/duckherd-theme.json`;
   - `duckherd-theme.json` at the root of **any other installed Claude Code plugin**,
     found through `installed_plugins.json`. A plugin can ship a theme just by
     including that file.

   Duckherd reads at most 40 candidate files. Each file must be under the runtime's
   4 MiB read cap and the parser's 3 MB text cap. Theme ids must be unique, and
   `ducks` is reserved.

### 2.2 The theme file (v1)

This is Duckherd's own description, from the header of `themes.ts`, restated:

| key | required | meaning |
|---|---|---|
| `duckherdTheme` | yes | must be `1` |
| `id` | yes | `^[a-z0-9][a-z0-9-]{0,30}$`, not `ducks` |
| `title` | no | display name, ≤ 60 chars (defaults to `id`) |
| `scale` | no | `1` or `4`. At 4 every frame is 4× as wide and tall and fills the same space |
| `helperSize` / `leadSize` | no | `[width, height]` in art pixels. Whole cells: width a multiple of 2·scale, height of 4·scale, at most 40 cells × 8 rows. Defaults are 20 × 12 (helper) and 28 × 16 (lead), times the scale |
| `palette` | yes | `{ "A": "#rrggbb", … }`, one-character keys, not `.` |
| `helpers` | yes | 1 to 12 characters. Each new helper takes the next one |
| `helpers[].name` | yes | ≤ 30 chars |
| `helpers[].names` | no | ≤ 10 agent-type names (letters and digits, ≤ 20, unique across the theme) |
| `helpers[].colors` | no | extra palette letters for this character only (overrides) |
| `helpers[].blink` | no | `[eye, lid]`: every 3.3 s, `eye eye` → `lid lid` in the head's rows for one beat |
| `helpers[].loops.{dabble,read,type,run,think}` | **all five** | `{ "frameMs": 50…5000, "frames": [1…64 frames] }` |
| `helpers[].ends.done`, `.failed` | yes | one frame each (the pose held after finishing) |
| `helpers[].ends.{cheer,droop,asleep,idle,flinch,wave,noticed}` | **all seven** | 1…64 frames each |
| `helpers[].ends.idleMove` | no | a second idle moment, alternating with `idle` |
| `lead` | no | `{ rest, rising, levels: [1…4 sets], flare? }`: the lead's frames at `leadSize` |
| `lead.flare` | no | `{ small, big }`: per-step lists of `[row, col, letter]` cells painted over the lead while helpers run |
| `marks` | no | palette letters for `star`, `starLit`, `drop`, `dropLit`, `asked`, `told` (the Opus star, the stuck sweat drop, and `?` / `!`) |
| `opusMark` | no | `false` hides the star on Opus helpers |
| `stuck` | no | `{ "drop": [row, col], "mark": col }`, positions in the 1× grid |
| `sounds` | no | `{ quack, honk, chirp, snore }`: `.wav` / `.mp3` file names beside the theme file |

A **frame** is an array of `height` strings, each `width` characters long. Each
character is a palette letter or `.` (clear). Any problem rejects the whole file.
The parser reports up to 8 problems, each saying where it is, for example
`helpers[0].loops.type[3]: rows are 20 wide`. A helper that is missing any loop or
ending is invalid.

A real frame: the Classic duck typing, frame 2 of 8, exported from Duckherd's code.
`S`/`s` is the laptop, `m`/`c` are code scrolling on its screen, `H`/`i` are the
head, `k`/`e` the eye, `O`/`o` the bill, `Y`/`L`/`y` the body, `W`/`v` the wing and
`f` the feet:

```
....................
...............SmcSS
.........HHHH..ScmcS
........HiiHHH.Sc..S
.......HiiHHkeHSmm.S
YY.....HHHHwkkOSSSSS
YYLY.YLHHHHHHoo.s...
.YYYYWWWWWWYYKKKKKKK
.YYvWWvWWvWWYYY.....
.yYYvWWvWWvYYYy.....
..yyyyyyyyyyyyy.....
....ff.....ff.......
```

Its palette starts `"H": "#FFD43B", "i": "#FFF6C4", "k": "#2B1A10", "e": "#FFFFFF",
"O": "#FF7B39", …`. The helper's own colour is `x` / `X`: `{"x": "#4FB6A8", "X":
"#377f76"}` for helper 1, teal. Duckherd's own test theme (abridged from
`duckherd.test.tsx`) shows the minimum shape:

```json
{
  "duckherdTheme": 1, "id": "pond", "title": "Theme pond",
  "palette": { "A": "#112233", "B": "#ffcc00", "S": "#99ccff" },
  "marks": { "star": "B", "starLit": "B", "drop": "S", "dropLit": "S", "asked": "B", "told": "A" },
  "stuck": { "drop": [2, 5], "mark": 16 },
  "helpers": [{
    "name": "First", "names": ["pondOne"], "blink": ["B", "A"],
    "loops": { "dabble": {"frameMs": 200, "frames": [F_A, F_B]}, "read": …, "type": …, "run": …, "think": … },
    "ends": { "done": F_A, "failed": F_B, "cheer": [F_A], "droop": [F_B], "asleep": [F_A],
              "idle": [F_A, F_B], "idleMove": [F_B], "flinch": [F_A], "wave": [F_B], "noticed": [F_A] }
  }],
  "lead": { "rest": [L_A], "rising": [L_B], "levels": [[L_A, L_B]],
            "flare": { "small": [[[1, 1, "B"]]], "big": [[[2, 2, "B"]]] } },
  "sounds": { "quack": "done.wav" }
}
```

Here `F_A` is twelve 20-character rows of `A`, and `L_A` is sixteen 28-character
rows.

**Our export.** `ducks-classic.theme.json` (281 KB) holds Duckherd's 6 breeds, the
duckling and the drake as 8 helpers, 105 frames each (dabble 12, read 12, type 8,
run 8, think 16, plus endings), and the super duck as the lead (rest 64, rising 6,
4 levels × 4). Duckherd's own `parseTheme` accepts it. It was generated by a
throwaway script that calls Duckherd's exported `duckDrawing` / `superDrawing` and
samples every loop at its frame rate. The script and the file are on the bench, not
committed (see open question 8).

### 2.3 How the animation is driven (Duckherd's engine)

Everything moves on a 150 ms **beat**, and every frame lasts a whole number of
beats ("uneven frames read as lag"). For one helper, in priority order:

| situation | what plays | timing |
|---|---|---|
| helper finished | `cheer` (ok) or `droop` (failed), then hold `done` / `failed` | spread over 2.4 s, then held |
| not moving (person away) | first frame of the current loop | still |
| waiting for the person's OK | `wave` | 300 ms per frame |
| quiet ≥ 180 s (maybe stuck) | `asleep` | 600 ms per frame |
| the person just sent it a message | an envelope flies in over the loop (3 × 300 ms), then `noticed` | 2.4 s total |
| a step just failed | `flinch` | 750 ms total |
| "calm" setting | the loop at half speed, no idle moments | — |
| otherwise | the loop for its current action, with an `idle`/`idleMove` clip every 9 s, at each helper's own phase | the loop's `frameMs`; ×2 slower once quiet ≥ 40 s |

**Action from the latest tool step** (`actionOfStep`):

| tool | action |
|---|---|
| `Edit`, `MultiEdit`, `Write`, `NotebookEdit` | `type` |
| `Grep`, `Glob`, `WebSearch`, `WebFetch`, or step text starting "Searching" / "Looking" / "Listing" | `dabble` |
| `Read`, or text "Reading…" | `read` |
| `Bash` | `run` |
| anything else | `think` |

Before a helper's first step, its action comes from the first job word in its
title: "fix / write / add…" → `type`, "find / search / read…" → `dabble`,
"review / verify / check…" → `read`, "test / run / lint…" → `run`.

Each helper's phase is offset by a hash of its id (`n·31 + char mod 100003`), so two
helpers doing the same job don't move in step.

### 2.4 How characters are assigned

Assignment is **not** stable per agent. It is per session, by order:

- The nth helper of the session gets colour `HELPER_COLORS[n mod 14]` (teal, pink,
  lime, blue, apricot, …). The lead's gold is never used for a helper.
- It takes a **name** from a pool of 8 registered names, choosing the one that has
  been free longest (Pip, Eider, Hazel, Fluff, Pebble, Inky, Sunny, Reed, …). The
  name sets the **breed**: each breed owns seven names. Even-numbered helpers wear
  nothing. Odd ones wear a bow, beanie, beret, cap or crown, except a Mallard,
  which only ever wears a bow.
- With a theme active, the character is the theme helper whose `names` contains the
  agent's name. Otherwise it is helper `n mod helpers.length`.
- The model decides the body (built-in ducks only): Haiku → duckling, Opus → drake.
  A theme has no model variants, only the optional Opus star mark.

So the same agent can get a different duck in a different session. Array should not
copy this (see §4.3).

### 2.5 Where Duckherd's configuration lives

- Plugin settings (`plugin.json` `userConfig`): `theme` (the id drawn at start,
  default `ducks`), `themesDir` (an extra folder), `sounds`, and others unrelated to
  characters. Claude Code stores these under `pluginConfigs` in the user's
  `settings.json`.
- `/crew theme <name>` changes the theme for later sessions. The choice is kept in
  the mod's private store (`$.store`), which Array cannot see.
- Status export (off by default, `statusFiles`): `~/.claude/duckherd/dashboard/`.
  It is orchestration data, not characters.

## 3. License: what Array may and may not do

Duckherd is **MIT** (`LICENSE`: "Copyright (c) 2026 Ali Alsalkhadi"). The duck art is
part of the source code (`creatures.ts`), so the MIT license covers it.
`sounds/README.md` says the sounds are "Original duck sounds, synthesised for
Duckherd and released under the MIT license."

| question | answer |
|---|---|
| Read a user's existing Duckherd theme files and settings? | **Yes.** They're the user's files. Read them only, never write them, and only after the user picks the file or turns on auto-detect. This needs no permission from Duckherd. |
| Implement a compatible parser? | **Yes.** A file format isn't copyrightable, and the parser is MIT anyway. We'd write our own Swift; porting the TypeScript rules is allowed under MIT. |
| Bundle Duckherd's ducks as Array's default characters? | **Yes, with attribution.** Ship the MIT copyright and permission notice with the bundled theme (in the file's folder and in Array's acknowledgements). Recommended courtesy: tell Ali before shipping (open question 9). |
| Call the feature "Duckherd"? | **No.** MIT grants no trademark rights. Say "Duckherd-compatible themes" and "Duckherd's ducks (MIT, © Ali Alsalkhadi)". Don't use the Duckherd logo (`docs/media/logo*`). |
| Bundle themes made by other people or shipped in other plugins? | **No**, unless their own license allows it. Array may display them locally on the user's Mac, the same way it reads any of the user's files. |
| Play the theme's sounds? | Allowed by the license, but **out of scope**: a sound on agent completion is a notification path (non-negotiable #6). It needs its own entry in `docs/internals/notification-paths.md` and its own witnesses. The proposal ignores `sounds`. |

## 4. Mapping onto Array

### 4.1 Array's status model → animation

Array has two status vocabularies: `InboxState` (`working`, `approval`, `input`,
`failed`, `ready`, plus `InboxAttention` `unread` / `woke`) for the sidebar, and
`AgentStatus` (`configuring`, `working`, `idle`, `needsAttention`, `done`,
`stale`) with `AgentTerminalOutcome` for the tile. The tool step comes from the
transcript item (`ItemKind`: `commandExecution`, `fileChange`, `mcpToolCall`,
`webSearch`, `reasoning`, `plan`, `subagent`, …).

| Array state | animation | notes |
|---|---|---|
| starting / `configuring` | `think` loop | the turn hasn't reported yet |
| `working`, latest item `fileChange` | `type` loop | |
| `working`, latest item `webSearch`, or a search/list tool (`Grep`, `Glob`, `rg`, `find`) | `dabble` loop | Claude's built-in tools reach Array as `mcpToolCall` / `commandExecution` with a title, so match by title as Duckherd does |
| `working`, latest item a file read (`Read`, `cat`, `sed -n`) | `read` loop | |
| `working`, latest item `commandExecution` (anything else) | `run` loop | |
| `working`, `reasoning`, `plan`, `assistantMessage`, `subagent` | `think` loop | |
| `working`, a tool item completed `failed` | `flinch` once (750 ms), then back to the loop | |
| `working`, silent ≥ 40 s | the loop at half speed | Duckherd's "slows down" |
| `working`, silent ≥ 180 s | `asleep` | "maybe stuck": the same idea as Array's liveness |
| `approval` (permission request) | `wave` | Duckherd's "waves when it needs your OK" |
| `input` (the agent asked you something) | `wave` | the same meaning: act now |
| the user just sent it a prompt | `noticed` (2.4 s) | |
| `failed`, unread | `droop` (2.4 s), then hold `failed` | |
| `ready` + `unread` after success | `cheer` (2.4 s), then hold `done` | |
| `ready`, read / settled (`idle`) | **still**: the `done` or `failed` pose | Recommendation: resting agents don't move. Duckherd's idle stretches are for helpers mid-task. |
| `stale` / background / closed | still, dimmed with the row | |
| managed-mode **lead** | the theme's `lead` set (`rest` → `rising` → `levels[min(helpers running, 4) − 1]`) | only if the theme has one; otherwise the lead is an ordinary character |

The rule that keeps this cheap and calm: **only agents in motion animate.**
`approval` and `input` wave because they're act-now states (and Array already
pulses the escalated row). Everything at rest holds one frame.

### 4.2 Where it renders

The design is Dylan's: the character is attached to the provider mark.

- **Sidebar row** (`AgentInbox96CellView`). The provider mark is 12 pt at the right
  end of line 2 (11 pt on the compact row). The character sits 4 pt to its left,
  20 × 12 pt, centred on line 2, and line 2's text gives up 24 pt. It's drawn as one
  more layer in the row's `Decorations` view, next to the existing `markLayer`. It
  fades with the mark under the hover actions (`setMarkVisible`) and is cleared on
  cell reuse.
- **Tile header** (`TitleBarView`). The provider mark is 14 pt at `Space.m`. The
  character sits `4·chromeScale` to its right, scaled with `chromeScale`, and the
  title starts after it (`titleLeadingX`). It's a sublayer of the bar, **not**
  drawn in `draw(_:)`. That keeps it alive while the bar's controls are drawn inline
  (`drawsControlsInline`), and it means a sprite frame never invalidates the chrome.
- **Size and crispness.** The art is 20 × 12 px. At 1 pt per art pixel it's exactly
  12 pt tall, the height of the sidebar mark, and 2 device pixels per art pixel on
  Retina. The layer uses `magnificationFilter = .nearest`, so it stays crisp at any
  canvas zoom from a 1× atlas. A `scale: 4` theme is drawn into the same 20 × 12 pt.

### 4.3 Assignment: the same agent always gets the same character

Recommendation: `index = FNV-1a(agent record id bytes) mod characters.count`,
computed (not stored), so it's stable across launches, sessions, devices and the
phone. It changes only if the user switches character set. That's acceptable: a new
set is a new cast. Two more points:

- **Colour.** For the built-in ducks, the helper colour `x`/`X` (the hat or the
  duckling's tuft) is the agent's **identity colour**, so the character matches the
  row's dot and the tile's tint. Theme characters keep their own colours.
- **Choosing a character** per agent would be a new user-editable property. It would
  need a `WorkspaceAPIExposure` classification (hazard 11) and an `agent.update`
  field. That's out of the first slices (open question 4).

### 4.4 Settings: import, validation, preview, toggle

A **Characters** section in Settings › Appearance, built from Array's existing
controls (`ChoiceButton` / `ChoicePopoverController` for the pickers, the standard
Settings rows and switch):

1. **Show characters** (switch). Off removes every sprite layer; nothing stays
   resident.
2. **Characters** (`ChoiceButton`): *Ducks (built in)* · each imported set by title ·
   *Import…*.
3. **Import…** opens an `NSOpenPanel` for a file (`*.theme.json`,
   `duckherd-theme.json`) or a folder (scanned the way Duckherd scans `themesDir`).
   Below it, **Found on this Mac**: theme files found through Claude Code's
   `settings.json` (`pluginConfigs` → Duckherd's `themesDir`) and the
   `duckherd-theme.json` of installed plugins. Each one is listed with an *Import*
   button and nothing is read until the user asks. Importing **copies** the file
   (and nothing else) into `~/Library/Application Support/Array/characters/<id>/`.
   A later edit or deletion of the original then can't break the app, and Array
   never writes to `~/.claude`.
4. **Validation.** The same rules and the same messages as Duckherd (the first 8
   problems, each saying where). A file with problems isn't imported. The panel shows
   the list in the standard warning style, plus a *Reveal in Finder* link.
5. **Preview grid.** Every character (rows) in every state (columns), at 3 pt per art
   pixel, animating while the Settings window is open and still under Reduce
   Motion. This is the still `stills/agent-characters-preview-grid.png`.
6. **Motion** (`ChoiceButton`): *Working agents only* (default) · *Never (still
   poses)*. **Reduce Motion** in System Settings forces *Never*: each state shows its
   representative still frame, and cheer and droop jump straight to their end pose.

### 4.5 Licensing in the UI

The built-in set's row says "Ducks · from Duckherd (MIT)" and links to
Acknowledgements. Imported sets show their own title and nothing else.

## 5. Performance plan

Read first: `docs/internals/performance.md` ("work proportional to content × work
repeated per display cycle = a frozen app") and
`.plans/83-performance-history/README.md` (Dylan's rules: no UX regressions, full
detail when zooming, no tile-count limit, no lag spikes). The sidebar can show 50+
rows and the canvas 80+ tiles.

### 5.1 The benchmark

`SpriteBench.swift` is a throwaway Swift program compiled with `swiftc -O`, kept on
the bench and not committed. It draws N sprites from our exported Classic duck
(16-frame `think` loop, 320 × 12 px atlas, 15 KB decoded) in a borderless window at
(−30000, −30000). It never activates the app, holds a `latencyCritical` activity so
App Nap can't coalesce its timers, steps at 10 fps, and measures 6–10 s per variant
after a 1.5 s warm-up. Process and main-thread CPU come from
`getrusage` / `thread_info`. "Handler" is the time spent inside the tick closure;
the per-tick figure is main-thread CPU divided by ticks, which includes the Core
Animation commit. Each run checked that the sprites really moved: sprite 0 showed
16 distinct frames in its presentation layer, and `draw(_:)` ran 1,050 times a
second for 100 sprites.

**100 sprites** (first run, 10 s per variant):

| variant | process CPU % | main-thread CPU % | main-thread ms per tick | handler mean / p95 ms |
|---|---|---|---|---|
| static layers (baseline) | 0.03 | 0.02 | — | — |
| **one shared clock, `contentsRect` on a shared atlas** | **0.19** | **0.18** | **0.19** | 0.14 / 0.18 |
| a `Timer` per sprite, same `contentsRect` work | 2.62 | 1.96 | 2.00 | 0.016 / 0.044 (×100 calls) |
| `NSImageView.image` swap per frame (images cached) | 2.81 | 2.80 | 2.81 | 0.42 / 0.48 |
| custom view redraw in `draw(_:)` | 4.06 | 4.05 | 4.05 | 0.06 / 0.08 (+ the draws) |
| **`CAKeyframeAnimation` on `contentsRect` (render server)** | **0.01** | **0.01** | **none per frame** | — |

**500 sprites** (6 s per variant; the baseline includes a small presentation probe
timer, about 0.2%):

| variant | process CPU % | main-thread CPU % | main-thread ms per tick |
|---|---|---|---|
| static layers (baseline) | 0.22 | 0.20 | — |
| one shared clock, `contentsRect` | 0.48 | 0.46 | 0.48 |
| a `Timer` per sprite | 10.93 | 8.93 | 8.96 |
| `NSImageView` swap | 7.43 | 7.42 | 7.43 |
| `draw(_:)` redraw | 14.66 | 14.66 | 14.66 |
| `CAKeyframeAnimation` | 0.32 | 0.30 | none per frame |

What the numbers mean:

- **The approach matters 10–30×.** Stepping `contentsRect` from one clock costs
  about 2 µs of main thread per sprite per frame (it grew from 0.19 to 0.48 ms per
  tick going from 100 to 500 sprites). A timer per sprite costs roughly 10× that in
  run-loop overhead. Swapping images or redrawing pays for AppKit's display pass on
  every view, which is the same "work per item per display cycle" trap
  `performance.md` warns about.
- **Keyframe animations cost the app nothing per frame.** Core Animation plays them
  in the render server. The main thread only works when a state changes and an
  animation is swapped.
- **What this can't see: WindowServer.** WindowServer sat at 43–48% CPU in every
  variant, including the static baseline, because the Mac was in use and driving its
  displays. Its noise (±2–3 points) is bigger than any difference between variants.
  The window was also off screen (`occlusionState` not visible), so compositing was
  probably skipped. The cost of compositing 100 small changing rects on a real
  screen is **unmeasured**. It has to be measured on the motion harness with the
  sprites on screen (slice 8), not on Dylan.

### 5.2 The rules the implementation must keep

1. **One texture per character, decoded once.** Build a `CGImage` atlas per character
   from its frames at **1 px per art pixel**. Lay it out as a grid, because a
   `scale: 4` character can exceed the 16,384 px texture width as a single row. Every
   layer showing that character sets `contents` to the *same* `CGImage`, so the
   render server uploads it once. Memory: 105 frames × 20 × 12 × 4 B ≈ **100 KB per
   character**, about 0.8 MB for all 8 ducks plus 160 KB for the lead. A `scale: 4`
   set is 16× that: about 1.6 MB a character, at most 19 MB for 12 characters. That
   is bounded by the format's limits (12 characters, 64 frames per set).
2. **Animate with `CAKeyframeAnimation` on `contentsRect`** (`calculationMode =
   .discrete`, `repeatCount = .infinity`, `beginTime` offset by the agent's hash so
   sprites don't move in step). The main thread only touches a sprite when its
   **state changes**. One-shot clips (`cheer`, `droop`, `flinch`, `noticed`) are a
   non-repeating animation whose completion holds the end pose. The fallback is the
   measured one-shared-clock design (0.2–0.5%), never a timer per sprite.
3. **The model value is always the state's still frame.** Residency pictures,
   far-parked tiles, Reduce Motion and the UIProbe all read the model layer and get
   the right pose with no animation.
4. **No layout per frame, ever.** The sprite's frame is set in the owner's `layout()`
   only when it changes (`if layer.frame != rect`, performance trap 3). A state
   change sets `contentsRect` and the animation, and never calls `needsLayout` or
   `needsDisplay`. Never re-add animations inside `layout()`: the gyro's
   "rebuilds 12 keyframe animations every layout" is still open in `.plans/83`.
5. **Pause what can't be seen.** Remove the animation (keeping the still frame) when
   a tile is parked, far-parked or pictured by residency, when a sidebar cell is
   reused or scrolled off (`NSTableView` already recycles cells), when the window is
   occluded or the app hidden, and while Settings has characters off. A focused or
   visible tile is never paused. The pause is a property of the tile's existing
   visibility seams, not a new timer.
6. **Frame-rate cap.** Clamp a theme's `frameMs` to at least 83 ms (12 fps).
   Duckherd's own ducks run at 150–300 ms (3–7 fps), and the rest beats are kept.
7. **During a zoom or pan gesture**, keep the animations. They're render-server work
   on layers that are already moving, with no main thread involved. This must be
   confirmed on the motion harness (slice 8) before shipping. If it shows a cost,
   freeze the sprites on their model frame during the gesture.
8. **Witness counts, not time** (performance.md): 0 layout passes and 0 `display`
   calls caused by sprite ticks; exactly 1 animation add per state change; 0
   animations on parked, pictured or reused sprites; 0 sprite layers with the feature
   off.

## 6. Stills

In `stills/`, all drawn by a throwaway `--agent-characters-sheet-check` on the bench.
It uses a real `AgentInboxView` with seven rows, and real `ManagedAgentTileNSView`
title bars with the real provider mark, tint, status and title. A bench-only 24 pt
reserve next to the mark shows the layout change. The character pixels are our
exported Duckherd frames, drawn nearest-neighbour at 1 pt per art pixel. Captured
offscreen at 2×, light and dark.

- `stills/agent-characters-sidebar.png`: the sidebar, light | dark. Seven rows:
  working while editing (Claude), working while searching (Codex), working on a
  command (Pi), needs approval, failed, done and unread, and resting a long time.
  `sidebar-light.png` and `sidebar-dark.png` are the same at full size.
- `stills/agent-characters-tile-header.png`: the tile header in six states,
  light | dark. It shows the provider mark, then the character, then the title,
  with the real status pill and controls.
- `stills/agent-characters-preview-grid.png`: what Settings' preview grid would
  show. All 8 exported characters × 7 states, at 3 pt per art pixel.

What reading them showed:

- **The pose reads at 12 pt; the fine detail doesn't.** The props carry the meaning:
  a laptop for editing, water for searching, speed lines for a command, a green tick
  for done, a rain cloud for failed, "z" for asleep. The breed colour reads; the
  hats and the code on the laptop screen don't. That's fine for a glance surface.
  The preview grid shows the detail.
- **The white Pekin nearly disappears on light rows** (the approval and done rows in
  the light column). Duckherd drew its ducks for a near-black terminal
  (`BACKGROUND = '#0D0F12'` in `creatures.ts`). Fix in slice 1: when the atlas is
  built for the light appearance, add a 1 px tonal outline. It goes only around
  clear pixels touching the figure, so no art pixel moves.
- **The words stay.** "Failed" and "Needs you: approve…" are still the status. The
  character adds to them and never replaces them. For accessibility the sprite is
  decorative (`setAccessibilityElement(false)`), and VoiceOver keeps reading the
  row's existing label.
- **Space.** On line 2 the 24 pt reserve did not truncate "Array · agent/sign-in"
  at 280 pt. A longer folder or branch would truncate 24 pt sooner (open
  question 2). In the header, the 12 pt character sits comfortably beside the 14 pt
  mark in the 24 pt bar, and the title moves 24 pt right.
- **The bench-only parts.** The sprites in the stills are views drawn into the
  capture, not the proposed `CALayer`, because the capture (`UIProbe.bitmap`)
  renders views. The pixels are identical either way. The 24 pt reserve is a
  bench-only hook in `AgentInbox96CellView` and `TitleBarView.titleLeadingX`.
  Nothing in production changed.

## 7. Build plan

Each slice lands on its own with its witnesses. Slices 1–3 are invisible; 4–6 are
the feature; 7–8 are the gate.

### Slice 1 — The format (Core, shared with iOS)

`AgentCharacterTheme` in `ContinuumRevivedAgentUI` (platform-neutral; the iOS
companion can draw the same characters later). A Duckherd v1 parser with
Duckherd's rules, limits and messages. An atlas builder (frames → grid image + frame
rects). The built-in ducks as a bundled `ducks-classic.theme.json` with the MIT
notice beside it.

Acceptance (CoreChecks `--agent-character-theme-check`):
- the exported `ducks-classic` file parses: 8 characters, 105 frames each, a lead;
- Duckherd's own valid test theme parses, and each of its invalid cases (wrong
  `duckherdTheme`, a reserved or bad `id`, `scale` 2, a bad size, a non-hex colour, a
  short row, an unknown letter, 0 or 65 frames, `frameMs` 49, 13 helpers, a
  duplicate name, a sound with a folder) is rejected with the same "where" message;
- **parity:** a committed corpus of good and bad files, each recorded as accepted or
  rejected by Duckherd's `parseTheme` when the fixture was made, gets the same
  verdict from the Swift parser;
- atlas: a frame's pixels read back from the atlas equal the palette colours of its
  letters (sampled), and `.` is transparent.
- the light-appearance atlas adds a 1 px outline only on clear pixels next to the
  figure; every art pixel is unchanged (the Pekin fix from §6).

### Slice 2 — The state machine (pure)

`AgentCharacterPose.resolve(snapshot, latestItem, now) → (set, loop | clip, still)`,
following the §4.1 table, plus the action-from-step rules.

Acceptance (CoreChecks): a table-driven check over every `InboxState` ×
`InboxAttention` × `ItemKind`/title combination; the clip expiries at 750 ms and
2.4 s; slow at 40 s and asleep at 180 s; Reduce Motion always returns a still.

### Slice 3 — The sprite layer (app)

`CharacterSpriteLayer` (a `CALayer`), with a per-character atlas cache keyed by theme
id and character index, the keyframe animations, and pause and resume.

Acceptance (`--character-sprite-check`, offscreen):
- 100 sprites, 10 s: 0 `layout`/`display` calls caused by sprites, exactly one
  animation add per state change, and two layers of the same character share one
  `contents` object;
- pausing keeps the still frame and removes the animation, and resuming restores it;
- a pixel check: the model frame drawn by `UIProbe.bitmap` equals the parser's frame.

### Slice 4 — Sidebar

The character slot in `AgentInbox96CellView`, on both the two-line and compact
rows.

Acceptance (`--sidebar-character-check`, real `AgentInboxView`, light and dark):
- the sprite rect sits 4 pt left of the provider mark, centred on its line, and
  never intersects text, the model label, the settle nudge or the hover actions;
- it fades with the mark under hover;
- reuse across 60 rows leaves no stale sprite (each cell's character matches its
  agent's hash);
- off in Settings → no sprite layers;
- scrolling 60 rows causes 0 sprite-caused layouts.

### Slice 5 — Tile header

The slot in `TitleBarView`, the `titleLeadingX` shift, `chromeScale` sizing, and the
pause hooks on parking, far parking, residency pictures and inline-drawn controls.

Acceptance (`--tile-character-check`):
- sprite geometry at every `chromeScaleBucket`;
- the title starts after it and never overlaps the status pill;
- driving the real park, far-park and residency seams removes the animation and
  bringing the tile back restores it;
- the zoom gesture path with sprites on asserts 0 sprite-caused layout (through
  `NSApp.sendEvent`, per `gesture-witness-real-event-path`).

### Slice 6 — Settings

The Characters section (§4.4), using `ChoiceButton`, `NSOpenPanel`, auto-detect,
the validation list and the preview grid.

Acceptance (`--character-settings-check`):
- importing the fixture folder copies one file into app support and lists its
  characters;
- importing a bad file shows its problems and imports nothing;
- auto-detect finds a theme through a fixture `settings.json` `pluginConfigs` and a
  fixture `installed_plugins.json`, in a temp `HOME`-like root passed explicitly,
  never the real `~/.claude`;
- Reduce Motion → preview still;
- both appearances render (ui-probe census: the new section's owner goes in
  `tokenAdoptedOwners`, hazard 8).

### Slice 7 — Lead art (optional)

In Managed mode a lead uses the theme's `lead` set, powering up while its helpers
run.

Acceptance: the `levels` index follows the running-helper count (1, 2, 3, ≥ 4), and
`rising` plays once over 900 ms.

### Slice 8 — The real-screen gate

Measure on the motion harness, on screen and unlocked, not on Dylan: 80 tiles and 50
sidebar rows with characters on versus off, during idle, pan and zoom, reading
WindowServer and app frame times. The ship bar is no measurable regression on
presented frames. If there is one, rule 7 freezes sprites during gestures. Register
the counts check in `run-matrix.sh` and confirm a real run prints it.

## 8. Open questions for Dylan

1. **Default on or off, and with which characters?** The recommendation is off by
   default, with Duckherd's ducks bundled (MIT, credited) as the built-in set, so
   turning it on needs no import.
2. **Placement cost in the sidebar.** The character takes 24 pt of line 2's text
   (folder, project, branch). Is that worth it at the 280 pt default width? The other
   option is the character in place of the identity dot before the title.
3. **Resting agents:** still (recommended), or let them idle and stretch like
   Duckherd's ducks do?
4. **Assignment:** a hash of the agent id (recommended), or let people pick a
   character per agent (a new `agent.update` property)?
5. **Model variants:** should Array copy Duckherd's Haiku-duckling / Opus-drake bodies
   for the built-in ducks, or keep one body per character?
6. **Sounds:** the proposal ignores theme sounds, because they'd be a new
   notification path. Agree?
7. **Lead art** for Managed-mode leads (slice 7): wanted, or later?
8. **Commit the benchmark and the export script?** They're throwaway files on the
   bench now (`SpriteBench.swift`, `export.ts`), and the instructions said docs and
   stills only.
9. **Courtesy:** shall we tell Ali Alsalkhadi before shipping his ducks? MIT doesn't
   require it.

## Built (2026-11-01)

Slices 1–6 and 8 are built, one commit each, on
`agent/agent-characters-build-ducks-679c0f0c` (local, unpushed). Slice 7 is not:
Dylan decided "no lead duck yet". Dylan's other decisions: off by default; the
built-in set is the eight exported ducks with the MIT notice beside them and in
`LICENSES/`; the UI never names the source plugin; import with validation and a
preview; placement as in the stills; character by a hash of the agent id; resting,
idle, offscreen, parked and occluded agents hold still; Reduce Motion is a still;
no model variants, no sounds.

| slice | what | witness |
|---|---|---|
| 1 | v1 parser (ordered JSON, the reference's rules and messages), atlas with the light outline, bundled `ducks.theme.json` | CoreChecks `--agent-character-theme-check`: 52-file corpus recorded against the reference `parseTheme` (7 accepted, 45 rejected, messages identical), 8 × 105 frames, atlas pixels |
| 2 | pose resolver, step → action through `AgentToolKind`, `lastStepFailedAt` in `AgentTurnPresence`, `characterActivity` on the row | CoreChecks `--agent-character-pose-check`: 409 table rows, clip expiries, 40 s / 180 s, Reduce Motion, the real reducer |
| 3 | `CharacterSpriteLayer`, `AgentCharacterController` (settings, hash, atlas cache, shared deadline timer) | `--character-sprite-check`: 100 sprites × 10 s, 0 layouts, 0 draws, 100 installs and none while animating, 8 shared atlases, parser pixels in an unflipped render and in a flipped real window |
| 4 | sidebar card slot | `--sidebar-character-check`: placement in Aqua + Dark Aqua, hover fade, 60 recycled rows, scroll layouts on = off, occlusion pause, off leaves none |
| 5 | tile header slot, fed by `ManagedAgentTileNSView` | `--tile-character-check`: supervisor `deliver` events, 6 chrome-scale buckets, title clear of the pill, far park / out of window hold still, ⌘-scroll zoom through window dispatch costs the bar nothing |
| 6 | Settings › Appearance › Agent characters | `--character-settings-check`: folder import, bad file, discovery in a fixture home, preview in both appearances, still under Reduce Motion |
| 8 | the on/off measurement | `--character-perf-check` (counts gated, times printed) |

### Round 2 (Dylan's newer decisions, same day)

Rebased onto 0.7.38 (`b0689628`). 0.7.38 draws sidebar rows as two-line lead cards
and one-line helper rows; the character sits left of the mark in both.

| what | witness |
|---|---|
| Per-agent pick: `AgentRecord.characterName` (a character's name in the selected set; unknown names fall back to the hash), the tile's ⋯ › Character menu, and `agent.update` `character` for agents. Classified `exposed(agent.update)` | `--workspace-api-agent-character-check`: production dispatch, header and row, fresh store, replay, refusal listing the allowed names, null clears, the tile menu via `performActionForItem` |
| The themes folder (`<app support>/characters`) takes files agents write (`*.theme.json`) as well as imports; one FSEvents stream reloads it; a broken edit keeps the last good set and Settings lists the file's problems | `--character-themes-live-check`: real file writes, new / edited / half-written / removed, no rescans while quiet, the validator binary's verdicts |
| `Array --validate-agent-character-theme <file or folder>`: JSON report, exit 0 / 1, handled before boot | the same check runs the real binary |
| `docs/internals/agent-characters-authoring.md` | — |
| The row and the tile show one pose for one agent | `--tile-character-check` builds the row with the production builder from the supervisor's snapshot and compares |
| The preview (`PREVIEW.md`) and its recording | `--agent-characters-recording-check` (not a matrix leg) |
| Motion harness arms, characters on vs off | `scripts/canvas-motion/character-arms.sh` (needs an unlocked, idle display; not run, see below) |

The per-agent pick is offered from the tile's menu, not a list in Settings: per-agent
identity (name, colour) already lives there, and Settings points to it.

### Departures from the design, and why

- **No identity-colour tint** (§4.3). Tinting the hat per agent needs an atlas per
  character × colour; Dylan's rule is one shared atlas per character.
- **Compact rows.** The sidebar's slim (History / Background) row draws no provider
  mark, so it has no "left of the mark" slot; characters are on the card row only.
- **Residency pictures do not pause.** Residency pictures the body; the header stays
  live and on screen, and rule 7 keeps sprites moving through gestures. Far parking,
  a parked workspace, occlusion and app hide do pause.
- **Offscreen-but-not-far-parked tiles keep their animation** (render-server work on a
  layer nobody composites). Residency is off by default, so far parking is too.
- **Orientation from the host view.** A view told it entered a window has not yet
  had its layer flip settled, so `contentsAreFlipped()` read then drew the character
  upside down until its next state change. Sprites take the host view's `isFlipped`.
- **"Noticed" needs the record's prompt stamp.** The presence's `submittedAt` is also
  the provider's own start for a turn it began itself.
- **The plugin theme file's fixed name is never shown** in "Found on this Mac".
- **Blink** (`helpers[].blink`) is validated but not drawn.
- **Motion choice** uses the existing Settings picker row (as every Settings choice
  does); the set picker uses `ChoiceButton`.

### The measurement (slice 8) and its blind spot

`--character-perf-check`, offscreen, A/B/A/B in one process: 80 agent tiles
attached to a real supervisor (60 working, fed through `deliver`, 60 characters
moving), 60 sidebar rows. Each arm: idle 4 s, pan 240 events, zoom 24 events (out and
back), all dispatched through the window. Bar layouts and draws, card layouts and
installs are equal on and off (card layouts within one tick of the list's own
one-second elapsed clock); gestures install nothing. Main-thread CPU and step times
are equal within noise. The numbers are in the slice 8 commit message.

**Motion harness (round 2):** `character-arms.sh` is ready but was not run: at the
end of the round the screen was locked (idle 1 h 44 min), and a locked session makes
ScreenCaptureKit capture blank or fail. Run it with the display unlocked and idle.

**Full matrix (round 2, locked display, from an agent shell):** 431 legs, the 10
documented KNOWN-RED, 20 failed. One was this branch's (`--agent-supervisor-check`: the
preview spelled the default agent name a second time), fixed in `63114a93`. The film
scenes failed in 0.7.38's own release matrix too. The other 18 (every Ghostty terminal
surface leg, the face and onboarding legs, session resume, the app-bundle launch smoke,
tile-project-scope, tile-chrome-canvas, composer-outline, throbber-timeline and
cli-update-settings) fail with identical messages on an unmodified 0.7.38 build in the
same session, so the cause is the locked display and agent shell, not this branch. The
Core dependency guard inside the KNOWN-RED bare CoreChecks run was already red on 0.7.38
(Collaboration dependencies); it now also pins `Resources/AgentCharacters`. Run the
matrix again with the display unlocked before landing.

**Motion harness, measured (round 3, unlocked display, release "Array Motion" bundle).**
Off and on interleaved, three rounds each, under the same background load (load
average 4.4-6.0 from other benches compiling):

| | off | on |
|---|---|---|
| zoom, camera states/s | 28, 28, 28 | 28, 28, 26 |
| zoom, main thread per commit (median) | 26.38 ms | 26.19 ms |
| zoom, instructions per commit (median) | 362 M | 357 M |
| pan, camera states/s | 57, 55, 54 | 56, 56, 57 |
| pan, main thread per commit (median) | 8.33 ms | 8.23 ms |

No measurable cost. An earlier, non-interleaved pair of zoom arms had shown 3-5 extra
full prose re-measures with characters on; the report now counts re-measures by cause
(`77faf747`), and the interleaved arms showed none in any arm, on or off, and a frozen
arm (`CANVAS_MOTION_CHARACTER_MOTION=never`) showed none either: characters never
change a transcript's width.

**Not measured: WindowServer and presented frames.** The motion harness
(`scripts/canvas-motion/`, on `array/0732-canvas-parity`, not on integration)
launches its own bundle with `open -n` and screen-captures an uncovered window, so
it needs Dylan's display idle and unlocked. It was not run, because it would take
his screen and focus. Run it before shipping, characters on versus off.
