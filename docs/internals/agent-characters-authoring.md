# Making an agent character set

For an agent asked to "make a new character set" or "improve the ducks". Array draws
a small pixel character beside each agent's provider mark, in the sidebar and in the
tile header, and it acts out what the agent is doing. A set is one JSON file.

## Where it goes, and how you know it worked

1. Find the themes folder. Run the validator with no file and it prints the folder:

       /Applications/Array.app/Contents/MacOS/Array --validate-agent-character-theme

   It is `~/Library/Application Support/Array/characters/` for the released app and
   `.../Array Dev/characters/` for a dev build.
2. Write your set there as `<your-id>.theme.json`.
3. Validate it. The command prints JSON and exits 0 when the set is valid, 1 when not:

       /Applications/Array.app/Contents/MacOS/Array --validate-agent-character-theme <file>

   Each problem says where it is, for example
   `helpers[0].loops.type[3]: rows are 20 wide`. At most the first 8 are listed, so fix
   them and run it again.
4. Array watches the folder. A valid file shows on the canvas and in the sidebar as
   soon as it is saved, with no relaunch, once the person picks the set in
   Settings › Appearance › Agent characters (a set already selected updates by itself).
   While a file is broken, the last good version keeps showing and Settings lists the
   file's problems.

To improve the built-in ducks, copy them and give the copy its own `id` and `title`:

    cp "/Applications/Array.app/Contents/Resources/continuum-revived_ContinuumRevivedCore.bundle/AgentCharacters/ducks.theme.json" \
       "$HOME/Library/Application Support/Array/characters/my-ducks.theme.json"

The id `ducks` is reserved, and `ducks-classic` is the built-in set's.

## The file

    {
      "duckherdTheme": 1,
      "id": "pond-night",
      "title": "Pond at night",
      "palette": { "A": "#1b2a3a", "B": "#ffcc00", "e": "#ffffff" },
      "helpers": [ { "name": "Robin", "loops": { ... }, "ends": { ... } } ]
    }

- `duckherdTheme`: must be the number `1` (the format's version key).
- `id`: lowercase letters, digits and dashes, 1–31 characters, starting with a letter
  or digit.
- `title`: what Settings shows, up to 60 characters. Defaults to the id.
- `palette`: one-character keys, each a `#rrggbb` colour. `.` is reserved for clear.
- `helpers`: the characters, 1 to 12. Each agent gets one from a hash of its id, or
  the one the person (or an agent, through `agent.update` with `character`) picked by
  `name`.

### Frames

A frame is an array of rows, each row a string of palette letters, `.` for a clear
pixel. Every frame of a set has the same size:

- Default size 20 × 12 (width × height). Array draws it at 1 point per pixel: 20 × 12
  points beside the mark.
- `helperSize: [w, h]` changes it: `w` a multiple of 2 and at most 80, `h` a multiple
  of 4 and at most 32. Array still draws it 12 points tall in the sidebar, so keep the
  20 × 12 shape unless you need more.
- `scale: 4` means every frame is drawn at 4× the detail (80 × 48 by default) into the
  same space.

Design for a 12-point glyph: a clear silhouette and one prop per state read best. On a
light row Array adds a thin tonal outline around the figure, so pale characters stay
visible; you do not need to draw one.

### Each character

    {
      "name": "Robin",
      "colors": { "x": "#4fb6a8" },
      "loops": {
        "dabble": { "frameMs": 300, "frames": [ ...frames... ] },
        "read":   { "frameMs": 300, "frames": [ ... ] },
        "type":   { "frameMs": 150, "frames": [ ... ] },
        "run":    { "frameMs": 150, "frames": [ ... ] },
        "think":  { "frameMs": 300, "frames": [ ... ] }
      },
      "ends": {
        "done": frame, "failed": frame,
        "cheer": [ ... ], "droop": [ ... ], "asleep": [ ... ], "idle": [ ... ],
        "flinch": [ ... ], "wave": [ ... ], "noticed": [ ... ]
      }
    }

- `name`: up to 30 characters; the name an agent's pick uses.
- `colors`: optional letters for this character only; they override the palette.
- All five loops and all of `ends` except `idleMove` are required. Each list holds
  1 to 64 frames. `frameMs` is 50 to 5000; Array never steps faster than 12 frames a
  second (83 ms).

### What Array plays, and when

| Agent | Plays |
|---|---|
| working, latest step edits a file | `type` loop |
| working, searching (grep, glob, web search, ls, find) | `dabble` loop |
| working, reading a file | `read` loop |
| working, running a command | `run` loop |
| working, thinking or writing, or no step yet | `think` loop (or the loop the title's first verb suggests) |
| quiet 40 s while working | the same loop at half speed |
| quiet 180 s while working | `asleep`, 600 ms a frame, repeating |
| waiting for approval or an answer | `wave`, 300 ms a frame, repeating |
| a tool step just failed | `flinch` once over 0.75 s, then the loop |
| the person just sent a prompt | `noticed` once over 2.4 s, then the loop |
| finished well | `cheer` once over 2.4 s, then `done` held |
| failed | `droop` once over 2.4 s, then `failed` held |
| finished and read, or never started | `done`, `failed` or the first `idle` frame, held still |

Resting agents never move, and with Reduce Motion every state shows its first frame.
The first frame of each loop is its still pose, so make it a good one.

### Accepted but not drawn

`lead`, `sounds`, `blink`, `names`, `marks`, `stuck`, `opusMark` and `idleMove` are
validated (a bad value still fails the file) but Array does not use them yet. Sounds
are never played.

## Rules

- Only put art you made, or art whose license allows it, in a set. Array reads the
  files in this folder on this Mac and never redistributes them.
- The built-in ducks are Ali Alsalkhadi's pixel art under the MIT License; a set
  derived from them keeps that notice with it.
