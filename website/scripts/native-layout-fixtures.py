#!/usr/bin/env python3
"""Generate TS parity fixtures by compiling the exact native layout methods.

Only the Swift command-line harness is compiled. This does not build or launch
the Array app. The extracted methods are read directly from CanvasAutoLayoutEngine.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift"
OUTPUT = ROOT / "website/src/lib/native-layout.fixtures.json"


def extract(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 0
    in_string = False
    escaped = False
    for i in range(brace, len(source)):
        ch = source[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start : i + 1]
    raise ValueError(f"unterminated Swift declaration: {marker}")


def frame(x: float, y: float, width: float, height: float) -> dict[str, float]:
    return {"x": x, "y": y, "width": width, "height": height}


BASELINE = {
    "a-stabilize": frame(70, 90, 430, 550),
    "b-verify": frame(550, 90, 380, 470),
    "c-audit": frame(980, 90, 340, 450),
    "d-shell": frame(1370, 90, 300, 470),
    "e-note": frame(70, 680, 800, 430),
    "f-browser": frame(920, 680, 560, 430),
}
CONTENT = frame(66, 103, 1616, 999)

# Request frames model deterministic pointer positions, while native IDs are
# generated in label order so UUID ordering and TS string ordering agree.
SCENARIOS = [
    {
        "id": "guided-main-drag",
        "baseline": BASELINE,
        "active": "a-stabilize",
        "moves": [
            {"id": "pre-push", "requested": frame(300, 90, 430, 550)},
            {"id": "slot-enter", "requested": frame(430, 90, 430, 550)},
            {"id": "latched-follow-through", "requested": frame(650, 95, 430, 550), "latched": "b-verify"},
            {"id": "backtrack-outside-band", "requested": frame(200, 90, 430, 550), "latched": "b-verify"},
            {"id": "return-home", "requested": frame(70, 90, 430, 550), "latched": "b-verify"},
        ],
        "resizes": [],
    },
    {
        "id": "guided-editor-drag",
        "baseline": BASELINE,
        "active": "f-browser",
        "moves": [
            {"id": "browser-drag", "requested": frame(970, 690, 560, 430)},
        ],
        "resizes": [],
    },
    {
        "id": "unequal-width-row",
        "baseline": {
            "a-stabilize": frame(80, 110, 430, 550),
            "b-verify": frame(540, 110, 380, 470),
            "c-audit": frame(950, 110, 340, 450),
            "d-shell": frame(1320, 110, 300, 470),
        },
        "active": "a-stabilize",
        "moves": [
            {"id": "unequal-cascade", "requested": frame(385, 110, 430, 550)},
            {"id": "unequal-slot-swap", "requested": frame(490, 110, 430, 550)},
        ],
        "resizes": [],
    },
    {
        "id": "native-resize-members",
        "baseline": {
            "a-main": frame(80, 120, 430, 550),
            "b-verify": frame(518, 120, 380, 470),
            "c-audit": frame(906, 120, 340, 450),
            "d-shell": frame(1254, 120, 300, 470),
            "e-board": frame(80, 678, 800, 430),
            "f-editor": frame(888, 678, 560, 430),
        },
        "active": "a-main",
        "moves": [],
        "resizes": [
            {"id": "main-width-and-height", "active": "a-main", "requested": frame(80, 120, 550, 420)},
            {"id": "shell-width-and-height", "active": "d-shell", "requested": frame(1254, 120, 480, 560)},
            {"id": "editor-width-and-height", "active": "f-editor", "requested": frame(888, 678, 800, 560)},
        ],
    },
    {
        "id": "native-honor-snap-reflow",
        "content": frame(66, 79, 1970, 1230),
        "baseline": BASELINE,
        "settleBaseline": {"mover": "a-stabilize", "pin": True},
        "active": "a-stabilize",
        "moves": [
            {"id": "raw-main-snaps-home", "requested": frame(260, 90, 430, 550), "snapped": frame(70, 90, 430, 550)},
        ],
        "resizes": [],
    },
]

SWIFT_PREFIX = r'''import CoreGraphics
import Foundation

struct TileFrame: Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
}
struct ZonePlacement {
    var origin: CGPoint; var size: CGSize
    init(x: Double, y: Double, width: Double, height: Double) { origin=CGPoint(x:x,y:y); size=CGSize(width:width,height:height) }
}
enum CanvasAutoLayoutEngine {
    struct LayoutTile { var id: UUID; var frame: TileFrame; var zoneId: UUID?; var minimumSize: CGSize }
    static func autoLayoutFirstWinsDictionary<Key: Hashable, Value>(_ pairs: some Sequence<(Key, Value)>) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for (key, value) in pairs where result[key] == nil { result[key] = value }
        return result
    }
'''
SWIFT_SUFFIX = r'''
}

func idMap(_ labels: [String]) -> [String: UUID] {
    let ordered = Array(Set(labels)).sorted()
    return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, label in
        (label, UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d", index + 1))!)
    })
}
func frame(_ d: [String: Any]) -> TileFrame {
    TileFrame(x:(d["x"] as! NSNumber).doubleValue, y:(d["y"] as! NSNumber).doubleValue, width:(d["width"] as! NSNumber).doubleValue, height:(d["height"] as! NSNumber).doubleValue)
}
func json(_ f: TileFrame) -> [String: Double] { ["x":f.x,"y":f.y,"width":f.width,"height":f.height] }
func mapped(_ frames: [UUID: TileFrame], ids: [String: UUID]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: frames.compactMap { key, value in ids.first(where: {$0.value == key}).map { ($0.key, json(value)) } })
}
func run(_ input: [String: Any]) -> [String: Any] {
    let defaultContent = frame(input["content"] as! [String: Any])
    let gap = (input["gap"] as! NSNumber).doubleValue
    let scenarios = input["scenarios"] as! [[String: Any]]
    return ["scenarios": scenarios.map { scenario in
        let content = (scenario["content"] as? [String: Any]).map(frame) ?? defaultContent
        let zone = ZonePlacement(x:content.x,y:content.y,width:content.width,height:content.height)
        let baselineJSON = scenario["baseline"] as! [String: [String: Any]]
        var labels = Array(baselineJSON.keys)
        for move in scenario["moves"] as? [[String: Any]] ?? [] {
            if let latch = move["latched"] as? String { labels.append(latch) }
        }
        let ids = idMap(labels)
        var baseline = Dictionary(uniqueKeysWithValues: baselineJSON.map { (ids[$0.key]!, frame($0.value)) })
        if let setup = scenario["settleBaseline"] as? [String: Any], let moverLabel = setup["mover"] as? String {
            let mover = ids[moverLabel]!
            let tiles = Dictionary(uniqueKeysWithValues:baseline.map { key, value in
                (key, CanvasAutoLayoutEngine.LayoutTile(id:key, frame:value, zoneId:nil, minimumSize:CGSize(width:value.width,height:value.height)))
            })
            baseline = CanvasAutoLayoutEngine.settleMembers(memberIds:baseline.keys.sorted(by:CanvasAutoLayoutEngine.uuidLess), tiles:tiles, zone:zone, gap:gap, padding:0, header:0, mover:mover, pinMover:(setup["pin"] as? Bool) ?? false)
        }
        var outputs: [String: Any] = [:]
        let moves = scenario["moves"] as? [[String: Any]] ?? []
        for move in moves {
            let activeLabel = scenario["active"] as! String
            let active = ids[activeLabel]!
            let nativeBaseline = Dictionary(uniqueKeysWithValues: baseline.map { key, value in
                (key, CanvasAutoLayoutEngine.LayoutTile(id:key, frame:value, zoneId:nil, minimumSize:CGSize(width:value.width,height:value.height)))
            })
            let requested = frame(move["requested"] as! [String: Any])
            let latchLabel = move["latched"] as? String
            var solvingTiles = nativeBaseline
            solvingTiles[active] = CanvasAutoLayoutEngine.LayoutTile(id:active, frame:requested, zoneId:nil, minimumSize:CGSize(width:requested.width,height:requested.height))
            let result = CanvasAutoLayoutEngine.solveMemberMove(activeTile:active, originalFrame:baseline[active]!, memberIds:baseline.keys.sorted(by:CanvasAutoLayoutEngine.uuidLess), tiles:solvingTiles, zone:zone, gap:gap, padding:0, header:0, latched:latchLabel.flatMap { ids[$0] })
            let snapped = (move["snapped"] as? [String: Any]).map(frame)
            var committed = result
            if let snapped {
                var snappedTiles = nativeBaseline
                snappedTiles[active] = CanvasAutoLayoutEngine.LayoutTile(id:active, frame:snapped, zoneId:nil, minimumSize:CGSize(width:snapped.width,height:snapped.height))
                committed = CanvasAutoLayoutEngine.solveMemberMove(activeTile:active, originalFrame:baseline[active]!, memberIds:baseline.keys.sorted(by:CanvasAutoLayoutEngine.uuidLess), tiles:snappedTiles, zone:zone, gap:gap, padding:0, header:0, latched:result.latch)
            }
            var releaseSource = committed.frames
            let isLatched = snapped != nil || result.latch != nil
            if let snapped {
                releaseSource[active] = snapped
            } else if let latch = result.latch, let slot = baseline[latch], var activeFrame = releaseSource[active] {
                activeFrame.x = slot.x; activeFrame.y = slot.y; releaseSource[active] = activeFrame
            }
            let releaseTiles = Dictionary(uniqueKeysWithValues:releaseSource.map { key, value in
                (key, CanvasAutoLayoutEngine.LayoutTile(id:key, frame:value, zoneId:nil, minimumSize:CGSize(width:value.width,height:value.height)))
            })
            let settled = CanvasAutoLayoutEngine.settleMembers(memberIds:baseline.keys.sorted(by:CanvasAutoLayoutEngine.uuidLess), tiles:releaseTiles, zone:zone, gap:gap, padding:0, header:0, mover:active, pinMover:isLatched)
            let name = move["id"] as! String
            let passive = settled.filter{$0.key != active}
            let isValid = settled[active].map { candidate in CanvasAutoLayoutEngine.valid(candidate, in: CGRect(x:content.x,y:content.y,width:content.width,height:content.height), against:Array(passive.values), gap:gap - 0.26) } ?? false
            outputs[name] = ["requested":json(requested), "snapped":snapped.map(json) as Any? ?? NSNull(), "latchedInput":latchLabel as Any? ?? NSNull(), "liveFrames":mapped(result.frames, ids:ids), "committedFrames":snapped == nil ? NSNull() : mapped(committed.frames, ids:ids), "latch":result.latch.flatMap { id in ids.first(where:{$0.value == id})?.key } as Any? ?? NSNull(), "releaseSource":mapped(releaseSource,ids:ids), "releaseFrames":mapped(settled,ids:ids), "destination":settled[active].map(json) as Any? ?? NSNull(), "passiveFrames":mapped(passive,ids:ids), "valid":isValid]
        }
        var resizeOutputs: [String: Any] = [:]
        for resize in scenario["resizes"] as? [[String: Any]] ?? [] {
            let activeLabel = resize["active"] as! String
            let active = ids[activeLabel]!
            let requested = frame(resize["requested"] as! [String: Any])
            let members = baseline.map { key, value in CanvasAutoLayoutEngine.LayoutTile(id:key, frame:value, zoneId:nil, minimumSize:CGSize(width:value.width,height:value.height)) }
            let resized = CanvasAutoLayoutEngine.resizeMembers(members, active:active, original:baseline[active]!, requested:requested, gap:gap)
            resizeOutputs[resize["id"] as! String] = ["active":activeLabel, "requested":json(requested), "frames":mapped(resized,ids:ids)]
        }
        return ["id":scenario["id"] as! String, "content":json(content), "baseline":mapped(baseline,ids:ids), "active":scenario["active"] as! String, "moves":outputs, "resizes":resizeOutputs]
    }]
}
let data = FileHandle.standardInput.readDataToEndOfFile()
let input = try JSONSerialization.jsonObject(with:data) as! [String: Any]
let output = run(input)
let encoded = try JSONSerialization.data(withJSONObject:output, options:[.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(encoded)
'''


def main() -> None:
    source = SOURCE.read_text()
    declarations = [
        extract(source, "    private static func resizeMembers("),
        extract(source, "    public static func isGapAdjacent("),
        extract(source, "    private static func contentRect("),
        extract(source, "    private static func clampIntoContent("),
        extract(source, "    private enum PushAxis"),
        extract(source, "    private static func pushAxis("),
        extract(source, "    private static func propagatePushes("),
        extract(source, "    private static func solveMemberMove("),
        extract(source, "    private static func settleMembers("),
        extract(source, "    private static func absorb("),
        extract(source, "    private static func contactPlacement("),
        extract(source, "    private static func valid("),
        extract(source, "    private static func overlapsOrUnderGap("),
        extract(source, "    private static func squaredDistance("),
        extract(source, "    private static func uuidLess("),
    ]
    # The extracted source declares most helpers private. The standalone driver
    # calls those helpers from outside the enum, so relax visibility only (all
    # function bodies and their signatures remain source-derived).
    declarations = [d.replace("private static func", "static func").replace("private enum PushAxis", "enum PushAxis") for d in declarations]
    harness = SWIFT_PREFIX + "\n".join(declarations) + SWIFT_SUFFIX
    payload = {"gap": 8.0, "content": CONTENT, "scenarios": SCENARIOS}
    with tempfile.TemporaryDirectory(prefix="array-native-layout-") as temp:
        swift = pathlib.Path(temp) / "NativeLayoutFixtures.swift"
        binary = pathlib.Path(temp) / "native-layout-fixtures"
        swift.write_text(harness)
        subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
        completed = subprocess.run([str(binary)], input=json.dumps(payload), text=True, capture_output=True, check=True)
    generated = json.loads(completed.stdout)
    document = {
        "provenance": {
            "source": "Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift",
            "generator": "website/scripts/native-layout-fixtures.py",
            "method": "The script extracts the named Swift declarations, relaxes only access modifiers so the standalone CLI driver can call them, compiles a temporary harness, and serializes its outputs. Function bodies are unchanged; no expected frame values are hand-authored.",
            "nativeFunctions": ["resizeMembers", "solveMemberMove", "settleMembers", "pushAxis", "propagatePushes", "absorb", "contactPlacement", "valid", "isGapAdjacent", "clampIntoContent", "overlapsOrUnderGap", "squaredDistance", "uuidLess"],
            "idOrdering": "Fixture labels are sorted and assigned UUIDs in the same order so native UUID-string ordering matches TypeScript string ordering.",
        },
        "gap": payload["gap"],
        "content": payload["content"],
        "scenarios": generated["scenarios"],
    }
    OUTPUT.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
