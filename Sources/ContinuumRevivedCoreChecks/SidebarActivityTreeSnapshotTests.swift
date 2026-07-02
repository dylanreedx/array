import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/11-activity-tree-snapshot.md
// Logic (pure Core) checks for ActivityTreeSnapshot. Everything below is
// constructed in-memory: no real files, no tmux, no wall clock.
//
// A note on the evidence-source fixture strings used throughout this file: the
// ticket's own illustrative example (lines 149, 176-190) uses the literal source
// "claude:sessions/pid.json" for both the evidence-threading test AND the dogfood
// snippet, and separately claims (line 190) that searching the printed JSON for
// the substring "pid" "returns nothing". Those two claims are mutually
// inconsistent: "claude:sessions/pid.json" itself contains the literal substring
// "pid" ("pid.json" begins with it), so any snapshot carrying that exact evidence
// value necessarily fails the I5 taint scan's substring search for "pid" as
// specified at line 151. Rather than silently using two different fixtures — a
// "real" one only for evidence-threading and a separately-sanitized one only for
// the taint scan (which would prove the scan passes on data the scan was never
// actually asked to examine) — every evidence-source fixture in this file uses an
// I5-safe equivalent that preserves the ticket's intent (a reader-tagged path to
// a per-session evidence file) without spelling out "pid". The SAME populated,
// evidence-threaded tree (built via the real `SidebarTreeBuilder.build(agentSnapshots:)`
// path, not a hand-rolled one) is then run through both the evidence-threading
// assertions and the I5 taint scan below, so the scan genuinely proves the
// ticket's populated/dogfood-shaped snapshot is I5-clean.

func runSidebarActivityTreeSnapshotTests() {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func evidence(_ source: String, _ lastEventType: String?, _ age: Double) -> AgentSnapshot.Evidence {
        AgentSnapshot.Evidence(source: source, lastEventType: lastEventType, mtimeAgeSeconds: age)
    }

    // Two workspaces, three zones, five tiles, three carrying evidence.
    func makeTree() -> SidebarTree {
        let t1 = SidebarTileRow(tileId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "t1", kind: .terminal, agentStatus: .working, evidence: evidence("claude:sessions/reader-a.json", "assistant", 12.4))
        let t2 = SidebarTileRow(tileId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "t2", kind: .terminal, agentStatus: .needsAttention, evidence: evidence("codex:sessions/reader-b.json", "tool", 3.1))
        let t3 = SidebarTileRow(tileId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "t3", kind: .terminal, agentStatus: .needsAttention, evidence: evidence("pi:sessions/reader-c.json", nil, 0.5))
        let t4 = SidebarTileRow(tileId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, title: "t4", kind: .browser, agentStatus: nil, evidence: nil)
        let t5 = SidebarTileRow(tileId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, title: "t5", kind: .note, agentStatus: nil, evidence: nil)

        let z1 = SidebarZoneRow(zoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "z1", color: "blue", navKey: "a", collapsed: false, projectId: nil, tiles: [t1, t2])
        let z2 = SidebarZoneRow(zoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "z2", color: "mint", navKey: "b", collapsed: false, projectId: nil, tiles: [t3])
        let z3 = SidebarZoneRow(zoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!, name: "z3", color: "gray", navKey: nil, collapsed: false, projectId: nil, tiles: [t4, t5])

        let ws1 = SidebarWorkspaceRow(workspaceId: UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!, name: "ws1", zones: [z1, z2])
        let ws2 = SidebarWorkspaceRow(workspaceId: UUID(uuidString: "0000000B-0000-0000-0000-000000000001")!, name: "ws2", zones: [z3])

        return SidebarTree(workspaces: [ws1, ws2])
    }

    // MARK: - I7 round-trip, mixed / all-present / all-absent evidence

    do {
        let mixedTree = makeTree()
        let allEvidenceTree = SidebarTree(workspaces: mixedTree.workspaces.map { ws in
            var ws = ws
            ws.zones = ws.zones.map { zone in
                var zone = zone
                zone.tiles = zone.tiles.map { tile in
                    var tile = tile
                    if tile.evidence == nil {
                        tile.evidence = evidence("terminal:no-reader", nil, 99.0)
                    }
                    return tile
                }
                return zone
            }
            return ws
        })
        let noEvidenceTree = SidebarTree(workspaces: mixedTree.workspaces.map { ws in
            var ws = ws
            ws.zones = ws.zones.map { zone in
                var zone = zone
                zone.tiles = zone.tiles.map { tile in
                    var tile = tile
                    tile.evidence = nil
                    return tile
                }
                return zone
            }
            return ws
        })

        for (label, tree) in [("mixed", mixedTree), ("all-evidence", allEvidenceTree), ("no-evidence", noEvidenceTree)] {
            let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "replica-1")
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try! encoder.encode(snapshot)
            let decoded = try! decoder.decode(ActivityTreeSnapshot.self, from: data)
            expect(decoded == snapshot, "ActivityTreeSnapshot must round-trip through JSON unchanged (\(label))")
        }
    }

    // MARK: - Decode-time rollup invariant (fix-round-3, concern 1)
    //
    // `make(...)` derives `rollup` from the tree, but the original synthesized
    // `Codable` gave `init(from:)` a second, unchecked construction path: it decoded
    // whatever `rollup` bytes were present in the JSON verbatim, so a hand-edited or
    // foreign document could decode into an `ActivityTreeSnapshot` whose `rollup`
    // disagrees with its own `tree`. The round-trip checks above are self-consistent
    // (they only ever decode JSON this same process just encoded) and so never
    // exercise that path. This test tampers with the `rollup` object in already-encoded
    // JSON before decoding it, and asserts the decoded value is the value correctly
    // re-derived from `tree` -- not the tampered bytes -- proving `init(from:)`
    // recomputes rather than trusts.
    do {
        let tree = makeTree()
        let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "replica-1")
        let correctRollup = snapshot.rollup

        let encoded = try! JSONEncoder().encode(snapshot)
        var jsonObject = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var tamperedRollup = jsonObject["rollup"] as! [String: Any]
        tamperedRollup["working"] = 9999
        tamperedRollup["needsAttention"] = 9999
        jsonObject["rollup"] = tamperedRollup
        let tamperedData = try! JSONSerialization.data(withJSONObject: jsonObject)

        let decoded = try! JSONDecoder().decode(ActivityTreeSnapshot.self, from: tamperedData)
        expect(decoded.rollup == correctRollup, "decoding must recompute rollup from the decoded tree, got \(decoded.rollup) expected \(correctRollup)")
        expect(decoded.rollup.working != 9999, "decoding must not trust an arbitrary rollup.working value carried in the JSON")
        expect(decoded.rollup.needsAttention != 9999, "decoding must not trust an arbitrary rollup.needsAttention value carried in the JSON")
    }

    // MARK: - Rollup derivation

    do {
        let tree = makeTree()
        let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "")
        expect(snapshot.rollup.needsAttention == 2, "rollup: expected 2 needsAttention, got \(snapshot.rollup.needsAttention)")
        expect(snapshot.rollup.working == 1, "rollup: expected 1 working, got \(snapshot.rollup.working)")
        expect(snapshot.rollup.unknown == 0, "rollup: nil agentStatus tiles must not contribute, got unknown=\(snapshot.rollup.unknown)")
        expect(snapshot.rollup.dominantKind == .needsAttention, "rollup: dominant kind must be needsAttention when any are present")
    }

    // Builds the "populated" tree the ticket's evidence-threading test and dogfood
    // snippet describe: a real registry + document run through
    // SidebarTreeBuilder.build(agentSnapshots:), one tile carrying a full
    // AgentSnapshot with evidence, one tile with no snapshot at all. The evidence
    // source below is the I5-safe equivalent of the ticket's literal
    // "claude:sessions/pid.json" example (see the file-header note on why).
    let claudeEvidenceSource = "claude:sessions/session-log.json"
    func buildPopulatedTree() -> (tree: SidebarTree, claudeTileId: UUID, terminalTileId: UUID) {
        let settings = RegistrySettings(preferredEditor: .auto, zoomModifier: .command, openLastProjectOnLaunch: true)
        let wsId = UUID(uuidString: "0000000A-0000-0000-0000-000000000010")!
        let ws = WorkspaceEntry(id: wsId, name: "WS", projectIds: [], createdAt: fixedDate, updatedAt: fixedDate)
        let registry = Registry(lastActiveWorkspaceId: nil, lastActiveProjectId: nil, workspaces: [ws], projects: [], settings: settings)

        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-000000000B01")!
        let zonePlacement = ZonePlacement(
            zoneId: zoneId, projectId: nil,
            origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 100, height: 100),
            color: "blue", collapsed: false, hydrationPolicy: .automatic, name: "Zone", navKey: "a"
        )
        let claudeTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000B02")!
        let terminalTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000B03")!
        func tile(_ id: UUID, _ title: String, _ zIndex: Int) -> Tile {
            Tile(id: id, kind: .terminal, title: title, frame: TileFrame(x: Double(zIndex) * 10, y: 0, width: 120, height: 80), zIndex: zIndex, runtimeRef: nil, metadata: TileMetadata())
        }
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [zonePlacement],
            zoneZOrder: [zoneId],
            lastActiveZoneId: nil,
            groupZoneTiles: [
                GroupZoneTiles(zoneId: zoneId, tiles: [
                    tile(claudeTileId, "Claude", 1),
                    tile(terminalTileId, "Terminal", 2),
                ]),
            ]
        )

        let snapshot = AgentSnapshot(
            kind: .claude,
            status: .working,
            title: "Claude",
            mode: "normal",
            asOf: fixedDate,
            detail: nil,
            evidence: evidence(claudeEvidenceSource, "assistant", 12.4)
        )
        let tree = SidebarTreeBuilder.build(
            registry: registry,
            documents: [wsId: document],
            agentSnapshots: [claudeTileId: snapshot]
            // terminalTileId intentionally omitted -- no reader -> nil evidence
        )
        return (tree, claudeTileId, terminalTileId)
    }

    // MARK: - Evidence threading via SidebarTreeBuilder.build(agentSnapshots:)

    do {
        let (tree, claudeTileId, terminalTileId) = buildPopulatedTree()
        let zoneRow = tree.workspaces[0].zones[0]
        let claudeRow = zoneRow.tiles.first { $0.tileId == claudeTileId }!
        let terminalRow = zoneRow.tiles.first { $0.tileId == terminalTileId }!

        expect(claudeRow.evidence != nil, "evidence-threading: claude tile must carry non-nil evidence")
        expect(claudeRow.evidence?.source == claudeEvidenceSource, "evidence-threading: claude tile evidence source mismatch, got \(String(describing: claudeRow.evidence?.source))")
        expect(claudeRow.agentStatus == .working, "evidence-threading: claude tile must carry agentStatus derived from snapshot.status")
        expect(terminalRow.evidence == nil, "evidence-threading: tile with no snapshot must have nil evidence")
        expect(terminalRow.agentStatus == nil, "evidence-threading: tile with no snapshot must have nil agentStatus")
    }

    // MARK: - I5 taint scan (snapshot shape)

    do {
        let tree = makeTree()
        let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "replica-1")
        let json = String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!
        let forbidden = ["pid", "paneId", "windowTarget", "content", "body", "prompt"]
        for token in forbidden {
            expect(!json.contains(token), "I5 taint scan: encoded ActivityTreeSnapshot JSON must not contain forbidden token '\(token)'")
        }
    }

    // MARK: - I5 taint scan on the real evidence-threaded (populated) snapshot
    //
    // The scan above uses the hand-built makeTree() fixture. This one runs the
    // identical scan against the snapshot produced by the real
    // SidebarTreeBuilder.build(agentSnapshots:) path with a genuine AgentSnapshot
    // threaded through -- the exact "populated" shape the ticket's dogfood snippet
    // exercises -- so the I5 guarantee is proven on the ticket's real construction
    // path, not only on a fixture assembled solely for this check. This closes the
    // gap flagged in fix-round-2 review: the taint scan now runs on the same
    // populated snapshot the evidence-threading test and dogfood section use.
    do {
        let (tree, _, _) = buildPopulatedTree()
        let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "replica-1")
        let json = String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!
        let forbidden = ["pid", "paneId", "windowTarget", "content", "body", "prompt"]
        for token in forbidden {
            expect(!json.contains(token), "I5 taint scan (populated/dogfood-shaped snapshot): encoded ActivityTreeSnapshot JSON must not contain forbidden token '\(token)'")
        }
    }

    // MARK: - I5 taint scan proves it can actually catch a violation (fix-round-3, concern 2)
    //
    // The two scans above only prove that the CURRENT populated/fixture snapshots stay
    // clean -- they say nothing about whether the substring scan itself would flag a
    // real leak, because every fixture in this file was hand-picked to be I5-safe. This
    // test deliberately taints one tile's `evidence.source` the way a misbehaving caller
    // or an unsanitized reader might (a literal "pid" substring, and separately a
    // "content" substring), runs the identical scan, and asserts it DOES flag the
    // tainted JSON. This proves the taint-scan assertions elsewhere in this file are a
    // genuine detector, not a check that only ever sees pre-sanitized input.
    do {
        var taintedTree = makeTree()
        taintedTree.workspaces[0].zones[0].tiles[0].evidence =
            evidence("claude:sessions/leaked-pid-value.json", "assistant", 1.0)
        let taintedSnapshot = ActivityTreeSnapshot.make(tree: taintedTree, capturedAt: fixedDate, replicaId: "replica-1")
        let taintedJson = String(data: try! JSONEncoder().encode(taintedSnapshot), encoding: .utf8)!
        expect(taintedJson.contains("pid"), "I5 taint scan sanity check: a deliberately tainted evidence.source containing 'pid' must be detectable by the same substring scan used above -- proves the scan is not vacuous")

        var taintedTree2 = makeTree()
        taintedTree2.workspaces[0].zones[0].tiles[0].evidence =
            evidence("claude:sessions/leaked-content-value.json", "assistant", 1.0)
        let taintedSnapshot2 = ActivityTreeSnapshot.make(tree: taintedTree2, capturedAt: fixedDate, replicaId: "replica-1")
        let taintedJson2 = String(data: try! JSONEncoder().encode(taintedSnapshot2), encoding: .utf8)!
        expect(taintedJson2.contains("content"), "I5 taint scan sanity check: a deliberately tainted evidence.source containing 'content' must be detectable by the same substring scan used above -- proves the scan is not vacuous")
    }

    // MARK: - Codable conformance of each struct independently

    do {
        let rollup = SidebarAgentStatusRollup(working: 1, needsAttention: 2, done: 3, stale: 4, unknown: 5)
        let rollupData = try! JSONEncoder().encode(rollup)
        expect(try! JSONDecoder().decode(SidebarAgentStatusRollup.self, from: rollupData) == rollup, "SidebarAgentStatusRollup must round-trip through JSON")

        let zone = makeTree().workspaces[0].zones[0]
        let zoneData = try! JSONEncoder().encode(zone)
        expect(try! JSONDecoder().decode(SidebarZoneRow.self, from: zoneData) == zone, "SidebarZoneRow must round-trip through JSON")

        let workspace = makeTree().workspaces[0]
        let workspaceData = try! JSONEncoder().encode(workspace)
        expect(try! JSONDecoder().decode(SidebarWorkspaceRow.self, from: workspaceData) == workspace, "SidebarWorkspaceRow must round-trip through JSON")

        let tree = makeTree()
        let treeData = try! JSONEncoder().encode(tree)
        expect(try! JSONDecoder().decode(SidebarTree.self, from: treeData) == tree, "SidebarTree must round-trip through JSON")
    }

    // MARK: - Dogfood: print the evidence-bearing snapshot for eyeball verification
    //
    // Uses the same real SidebarTreeBuilder.build(agentSnapshots:) path as the
    // evidence-threading and populated-I5-scan checks above (not the hand-rolled
    // makeTree() fixture), so what a human reads here is exactly the shape those
    // automated checks already proved is I5-clean.

    do {
        let (tree, _, _) = buildPopulatedTree()
        let snapshot = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedDate, replicaId: "")
        let json = String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!
        print("ActivityTreeSnapshot dogfood JSON (evidence attached, I5-clean):")
        print(json)
    }
}
