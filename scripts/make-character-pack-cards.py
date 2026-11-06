#!/usr/bin/env python3
"""Write each built-in character pack's card.json, and the packs' manifest.json.

A pack's theme.json is megabytes of JSON, too much to parse for a picker. So each
pack carries card.json, a valid theme cut down to what a preview card draws: the
first helpers with the card's loop whole and one frame of everything else, and the
lead's first level. manifest.json holds each set's title and character count.

Run it after changing a pack. --agent-character-theme-check goes RED if a card or
the manifest no longer matches its pack.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKS = ROOT / "Sources/ContinuumRevivedCharacterPacks/Resources/packs"
DUCKS = ROOT / "Sources/ContinuumRevivedCore/Resources/AgentCharacters/ducks.theme.json"
PACK_IDS = ["street-sigils", "living-chords", "ascii-morph", "signal-ghosts"]
# What a card draws. AgentCharacterCardArt.loops names the same loops.
CARD_LOOPS = ["type", "read"]
SINGLE_CLIPS = ["cheer", "droop", "asleep", "idle", "flinch", "wave", "noticed"]


def card_helper(helper, loop_name):
    loops = {}
    for name, loop in helper["loops"].items():
        frames = loop["frames"] if name == loop_name else loop["frames"][:1]
        loops[name] = {"frameMs": loop["frameMs"], "frames": frames}
    ends = {name: helper["ends"][name] for name in ("done", "failed")}
    ends.update({name: helper["ends"][name][:1] for name in SINGLE_CLIPS})
    keep = {key: helper[key] for key in ("name", "names", "colors") if key in helper}
    return {**keep, "loops": loops, "ends": ends}


def card(theme):
    skip = {"helpers", "lead", "voices", "sounds"}
    out = {key: value for key, value in theme.items() if key not in skip}
    out["helpers"] = [card_helper(h, CARD_LOOPS[i]) for i, h in enumerate(theme["helpers"][: len(CARD_LOOPS)])]
    lead = theme["lead"]
    level = lead["levels"][0]
    out["lead"] = {"rest": lead["rest"][:1], "rising": lead["rising"][:1], "levels": [level]}
    return out


def main():
    ducks = json.loads(DUCKS.read_text())
    manifest = [{"id": ducks["id"], "title": ducks["title"], "characters": len(ducks["helpers"])}]
    for pack_id in PACK_IDS:
        theme = json.loads((PACKS / pack_id / "theme.json").read_text())
        (PACKS / pack_id / "card.json").write_text(json.dumps(card(theme), separators=(",", ":")))
        manifest.append({"id": theme["id"], "title": theme["title"], "characters": len(theme["helpers"])})
    (PACKS / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
