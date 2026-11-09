"""Seed a messy mixed-kind zone into a project's canvas.json for the tidy film.
usage: python3 -I film_seed.py <project root> <zoneId> <zoneX> <zoneY>
Positions are offsets from the zone origin; frames written in WORLD space."""
import json, sys, uuid, os
root, zone, zx, zy = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
def page(colour, label):
    return ("data:text/html;charset=utf-8,<html><body style='margin:0;background:%s;font:600 42px -apple-system;"
            "color:white;display:flex;align-items:center;justify-content:center;height:100vh'>%s</body></html>" % (colour, label))
os.makedirs(os.path.join(root, "docs"), exist_ok=True)
for name in ("plan.md", "notes.md"):
    with open(os.path.join(root, "docs", name), "w") as f:
        f.write("# %s\n\n" % name + "\n".join("- item %d of the tidy film" % i for i in range(40)))
# (kind, title, x, y, w, h, extra metadata) -- deliberately messy: odd ratios, ragged gaps
spec = [
    ("browser", "Preview A", 40, 70, 900, 760, {"url": page("%23315a8c", "Browser A")}),
    ("note", "Scratch", 980, 90, 520, 300, {}),
    ("browser", "Docs B", 1530, 60, 700, 300, {"url": page("%23527a4a", "Browser B")}),
    ("file", "plan.md", 990, 430, 460, 640, {"filePath": os.path.join(root, "docs/plan.md")}),
    ("note", "Todo", 60, 880, 380, 420, {}),
    ("browser", "Dashboard C", 480, 900, 480, 520, {"url": page("%238c5a31", "Browser C")}),
    ("file", "notes.md", 1500, 420, 720, 380, {"filePath": os.path.join(root, "docs/notes.md")}),
    ("note", "Ideas", 1540, 860, 300, 560, {}),
]
tiles = []
for i, (kind, title, x, y, w, h, meta) in enumerate(spec):
    tiles.append({"id": str(uuid.uuid4()).upper(), "kind": kind, "title": title,
                  "frame": {"x": zx + x, "y": zy + y, "width": w, "height": h},
                  "zPosition": (i + 1) / (len(spec) + 1), "metadata": meta, "zoneId": zone})
path = os.path.join(root, ".array", "canvas.json")
d = json.load(open(path))
d["tiles"] = tiles
d["lastActiveTileId"] = None
json.dump(d, open(path, "w"), indent=1)
print("seeded %d tiles into %s" % (len(tiles), path))
