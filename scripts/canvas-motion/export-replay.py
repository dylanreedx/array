"""Export a READ-ONLY replay spec of a real Array workspace for --canvas-motion-probe.

  python3 -I export-replay.py <out-dir> [--support DIR] [--workspace ID] [--window WxH]

Reads the registry, the workspace document and each project's .array/canvas.json,
and copies the files its file tiles show into <out-dir>/files. Nothing is written
outside <out-dir>. The probe rebuilds every agent's history from the CLI's own
session log, the way the app does at boot, so transcripts are the real ones.
"""
import json, os, shutil, sys, datetime

args = sys.argv[1:]
def option(name, default=None):
    if name in args:
        i = args.index(name); value = args[i + 1]; del args[i:i + 2]; return value
    return default
support = option("--support", os.path.expanduser("~/Library/Application Support/Array"))
workspace_id = option("--workspace")
window = option("--window")
out = os.path.abspath(args[0])
os.makedirs(os.path.join(out, "files"), exist_ok=True)

registry = json.load(open(os.path.join(support, "registry.json")))
workspace_id = workspace_id or registry["lastActiveWorkspaceId"]
workspace = next(w for w in registry["workspaces"] if w["id"] == workspace_id)
document = json.load(open(os.path.join(support, "workspaces", workspace_id, "canvas.json")))
projects = {p["id"]: p for p in registry["projects"]}
zone_ids = {z["zoneId"] for z in document["zones"]}

records = {}
for name in os.listdir(os.path.join(support, "agents")):
    try:
        record = json.load(open(os.path.join(support, "agents", name)))
    except Exception:
        continue
    if record.get("tileId") and not record.get("archivedAtReferenceInterval"):
        records[record["tileId"]] = record

tiles, agents, files, omitted = [], {}, {}, []
for project_id in workspace["projectIds"]:
    root = projects[project_id]["rootPath"]
    canvas = json.load(open(os.path.join(root, ".array", "canvas.json")))
    for tile in canvas["tiles"]:
        if tile.get("zoneId") not in zone_ids:
            continue  # lives in another workspace's zone
        kind = tile["kind"]
        if kind == "managedAgent":
            record = records.get(tile["id"])
            if not record:
                omitted.append({"tile": tile["id"], "kind": kind, "reason": "no agent record"}); continue
            agents[tile["id"]] = {k: record.get(k) for k in
                ("id", "harness", "model", "cwd", "providerSessionId", "codexThreadId", "displayName")}
        elif kind == "file":
            source = (tile.get("metadata") or {}).get("filePath")
            if not source or not os.path.isfile(source):
                omitted.append({"tile": tile["id"], "kind": kind, "reason": "file missing"}); continue
            name = "%s-%s" % (tile["id"][:8], os.path.basename(source))
            shutil.copyfile(source, os.path.join(out, "files", name))
            files[tile["id"]] = "files/" + name
        else:
            omitted.append({"tile": tile["id"], "kind": kind, "reason": "not replayed"}); continue
        tiles.append(tile)

# Keep only what the canvas draws; links and ambient tiles point at real paths.
document = {k: v for k, v in document.items() if k in ("schemaVersion", "viewport", "zones", "canvasBackground")}
document["lastActiveZoneId"] = document["zones"][0]["zoneId"] if document["zones"] else None
spec = {"source": {"workspace": workspace["name"], "exportedAt": datetime.datetime.now().isoformat(timespec="seconds")},
        "document": document, "tiles": tiles, "agents": agents, "files": files, "omitted": omitted}
if window:
    w, h = window.lower().split("x"); spec["window"] = {"width": float(w), "height": float(h)}
json.dump(spec, open(os.path.join(out, "spec.json"), "w"), indent=1)
print("workspace %s: %d zones, %d tiles (%d agents, %d files), %d omitted %s" % (
    workspace["name"], len(document["zones"]), len(tiles), len(agents), len(files), len(omitted),
    sorted({o["kind"] + ": " + o["reason"] for o in omitted})))
