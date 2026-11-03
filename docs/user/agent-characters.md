---
title: "Agent characters"
description: "Show a character for each agent and make your own set."
section: "Agents"
order: 21
---

Agent characters show an agent’s activity in sidebar rows and the tile header. They are off by default. To turn them on, open **Settings › Appearance › Agent characters** and enable **Show agent characters**. Choose a **Character set** there. To choose a character for one agent, use its tile’s **⋯ › Character** menu. Turn off **Show agent characters** to hide them.

Choose **Character size** in the same settings group: **Small** is the default, with **Medium** and **Large** available. The tile header and sidebar row grow with the character and provider logo; the tile header title grows too. On a Retina display, Large draws the pixel art at 2.5 times Small’s scale to keep it crisp. Zoomed far out, every size draws like Small. Transcript chips stay at text size.

Motion can be limited to working agents or set to **Never (still poses)**. macOS Reduce Motion also shows still poses.

In the default drawn transcript, characters also appear on delegated agent chips, agent message cards, and provider subagent rows. Turning characters off restores their icons.

## Characters in a pack

The top agent in a pack shows the set’s lead art while it has helpers. Only the top agent becomes the lead; a helper that delegates stays a helper. The lead’s direct helpers get different characters in the order they started and keep them across restarts. Characters repeat when the set runs out.

A choice made with **⋯ › Character** always wins, including for the lead. If the set has no lead art, the lead keeps its own character.

## What the poses mean

- **Search**, **Read**, **Edit**, and **Run** represent the current kind of work. **Think** is the fallback while working.
- **Noticed** appears briefly after you send a prompt. **Flinch** briefly follows a failed step.
- **Wave** means the agent needs approval or input.
- **Cheer**, then **Done**, follows a successful turn. **Droop**, then **Failed**, follows a failed turn.
- **Asleep** means a working agent has been quiet for three minutes; it may be stuck. **Idle** is a ready agent without a completed outcome.

## Make your own set

A set is a Duckherd v1 JSON theme. Save a file ending in `.theme.json` in `~/Library/Application Support/Array/characters/`. Array watches the folder and reloads changes. You can also import a set from the character settings.

This tiny set uses the same two-by-four pixel frame for every pose. Change the frames to draw your own character:

```json
{
  "duckherdTheme": 1,
  "id": "my-set",
  "title": "My set",
  "helperSize": [
    2,
    4
  ],
  "palette": {
    "A": "#FFCC00"
  },
  "helpers": [
    {
      "name": "Dot",
      "loops": {
        "dabble": {
          "frameMs": 200,
          "frames": [
            [
              "AA",
              "AA",
              "AA",
              "AA"
            ]
          ]
        },
        "read": {
          "frameMs": 200,
          "frames": [
            [
              "AA",
              "AA",
              "AA",
              "AA"
            ]
          ]
        },
        "type": {
          "frameMs": 200,
          "frames": [
            [
              "AA",
              "AA",
              "AA",
              "AA"
            ]
          ]
        },
        "run": {
          "frameMs": 200,
          "frames": [
            [
              "AA",
              "AA",
              "AA",
              "AA"
            ]
          ]
        },
        "think": {
          "frameMs": 200,
          "frames": [
            [
              "AA",
              "AA",
              "AA",
              "AA"
            ]
          ]
        }
      },
      "ends": {
        "cheer": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "droop": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "asleep": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "idle": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "flinch": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "wave": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "noticed": [
          [
            "AA",
            "AA",
            "AA",
            "AA"
          ]
        ],
        "done": [
          "AA",
          "AA",
          "AA",
          "AA"
        ],
        "failed": [
          "AA",
          "AA",
          "AA",
          "AA"
        ]
      }
    }
  ]
}
```

A frame is an array of rows. Each character is a palette key or `.` for transparent. Rows must match `helperSize`. The five loops (`dabble`, `read`, `type`, `run`, `think`) each need `frameMs` and a list of frames. `done` and `failed` are single frames; the other endings are lists of frames. The ID uses lowercase letters, digits, and hyphens, and `ducks` is reserved. A set can contain 1–12 helpers.

Check a file or folder with the Array executable before importing it:

```sh
Array --validate-agent-character-theme path/to/my-set.theme.json
```

The validator prints a JSON report and exits with 0 for a valid theme or 1 for an invalid one.

## Add lead art

A custom set can include lead art. Add `leadSize` at the top level and a `lead` object with `rest`, `rising`, and one to four `levels`. Each is a list of frames, except `levels`, which is a list of frame lists. For example, these fields add one two-by-four frame for each state to the set above:

```json
"leadSize": [2, 4],
"lead": {
  "rest": [["AA", "AA", "AA", "AA"]],
  "rising": [["AA", "AA", "AA", "AA"]],
  "levels": [[["AA", "AA", "AA", "AA"]]]
}
```

Lead frames use the top-level palette. If `leadSize` is omitted, it defaults to 28 by 16 pixels at scale 1.
