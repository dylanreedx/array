import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/10-session-topology-snapshot.md
// Logic (pure Core) checks for SessionTopologySnapshot and its parser. All in-process,
// no daemon, no filesystem, no wall clock.

func runSessionTopologySnapshotTests() {
    typealias Snapshot = SessionTopologySnapshot
    typealias WindowEntry = SessionTopologySnapshot.WindowEntry
    typealias SessionEntry = SessionTopologySnapshot.SessionEntry

    // MARK: - ParseError public surface: Codable + Sendable (+ Equatable)

    do {
        // Compile-time proof that ParseError is Sendable: a function requiring a Sendable
        // generic parameter accepts it directly (would fail to build otherwise).
        func requiresSendable<T: Sendable>(_ value: T) -> T { value }
        _ = requiresSendable(Snapshot.ParseError.malformedLine("x"))

        // Runtime proof that ParseError is Codable: round-trip both cases through JSON.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in [Snapshot.ParseError.malformedLine("bad\tline"), Snapshot.ParseError.invalidPid("nope")] {
            let data = try! encoder.encode(original)
            let decoded = try! decoder.decode(Snapshot.ParseError.self, from: data)
            expect(decoded == original, "ParseError must round-trip through JSON unchanged: \(original)")
        }
    }

    // MARK: - Format string self-check

    do {
        let format = Snapshot.tmuxFormatString
        let expectedOrder = [
            "#{session_name}", "#{window_id}", "#{pane_id}",
            "#{pane_current_path}", "#{pane_current_command}", "#{pane_pid}",
        ]
        let fields = format.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        expect(fields == expectedOrder, "tmuxFormatString must contain the six format variables tab-separated in the documented order, got \(fields)")
    }

    // MARK: - Parse fixture test: two sessions, three windows, one empty command field

    do {
        let fixture = [
            "continuum-proj-A\t@1\t%1\t/Users/dylan/proj-a\tzsh\t100",
            "continuum-proj-A\t@2\t%2\t/Users/dylan/proj-a/sub\t\t101",
            "continuum-ws-B\t@3\t%3\t/Users/dylan/ws-b\tvim\t202",
        ].joined(separator: "\n")

        let snapshot = try! Snapshot.parse(tmuxOutput: fixture)
        expect(snapshot.sessions.count == 2, "expected 2 sessions, got \(snapshot.sessions.count)")

        let sessionA = snapshot.session(named: "continuum-proj-A")
        expect(sessionA != nil, "expected session continuum-proj-A to be present")
        expect(sessionA?.windows.count == 2, "expected 2 windows in continuum-proj-A")

        let w1 = sessionA?.windows[0]
        expect(w1?.windowId == "@1", "w1 windowId")
        expect(w1?.paneId == "%1", "w1 paneId")
        expect(w1?.paneCurrentPath == "/Users/dylan/proj-a", "w1 path")
        expect(w1?.paneCurrentCommand == "zsh", "w1 command")
        expect(w1?.panePid == 100, "w1 pid as Int32")

        let w2 = sessionA?.windows[1]
        expect(w2?.windowId == "@2", "w2 windowId")
        expect(w2?.paneId == "%2", "w2 paneId")
        expect(w2?.paneCurrentPath == "/Users/dylan/proj-a/sub", "w2 path")
        expect(w2?.paneCurrentCommand == "", "w2 empty command must parse as empty string, not collapse fields")
        expect(w2?.panePid == 101, "w2 pid as Int32")

        let sessionB = snapshot.session(named: "continuum-ws-B")
        expect(sessionB?.windows.count == 1, "expected 1 window in continuum-ws-B")
        expect(sessionB?.windows.first?.paneId == "%3", "sessionB window paneId")
        expect(sessionB?.windows.first?.panePid == 202, "sessionB window pid")
    }

    // MARK: - JSON round-trip test (I7): empty, single-session, multi-session

    do {
        let empty = Snapshot(sessions: [])
        let single = Snapshot(sessions: [
            SessionEntry(sessionName: "s1", windows: [
                WindowEntry(windowId: "@1", paneId: "%1", paneCurrentPath: "/tmp", paneCurrentCommand: "zsh", panePid: 1),
            ]),
        ])
        let multi = Snapshot(sessions: [
            SessionEntry(sessionName: "s1", windows: [
                WindowEntry(windowId: "@1", paneId: "%1", paneCurrentPath: "/tmp", paneCurrentCommand: "zsh", panePid: 1),
            ]),
            SessionEntry(sessionName: "s2", windows: [
                WindowEntry(windowId: "@2", paneId: "%2", paneCurrentPath: "/var", paneCurrentCommand: "", panePid: 0),
            ]),
        ])

        for (label, original) in [("empty", empty), ("single", single), ("multi", multi)] {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try! encoder.encode(original)
            let decoded = try! decoder.decode(Snapshot.self, from: data)
            expect(decoded == original, "\(label) snapshot round-trips through JSON unchanged")
        }
    }

    // MARK: - Parse error tests

    do {
        // Empty string and whitespace-only input are NOT errors — they are a valid
        // zero-session snapshot (RULING 2026-07-01, supersedes the emptyInput case).
        let fromEmpty = try! Snapshot.parse(tmuxOutput: "")
        expect(fromEmpty.sessions.isEmpty, "parse(\"\") must return a zero-session snapshot, not throw")

        let fromBlank = try! Snapshot.parse(tmuxOutput: "\n\n")
        expect(fromBlank.sessions.isEmpty, "parse(\"\\n\\n\") must return a zero-session snapshot, not throw")

        let fromSpacesAndTabs = try! Snapshot.parse(tmuxOutput: "   \n\t\t\t\t\t\n  \t \n")
        expect(fromSpacesAndTabs.sessions.isEmpty, "whitespace/tab-only lines must also be treated as empty, not malformedLine")

        // Five-field line (missing pid) throws malformedLine.
        do {
            _ = try Snapshot.parse(tmuxOutput: "sess\t@1\t%1\t/tmp\tzsh")
            expect(false, "five-field line must throw malformedLine")
        } catch Snapshot.ParseError.malformedLine {
            // expected
        } catch {
            expect(false, "expected malformedLine, got \(error)")
        }

        // Non-numeric pid throws invalidPid.
        do {
            _ = try Snapshot.parse(tmuxOutput: "sess\t@1\t%1\t/tmp\tzsh\tnotapid")
            expect(false, "non-numeric pid must throw invalidPid")
        } catch Snapshot.ParseError.invalidPid {
            // expected
        } catch {
            expect(false, "expected invalidPid, got \(error)")
        }

        // Pid "0" is a valid pid and must parse successfully.
        let zeroPidSnapshot = try! Snapshot.parse(tmuxOutput: "sess\t@1\t%1\t/tmp\tzsh\t0")
        expect(zeroPidSnapshot.window(paneId: "%1")?.panePid == 0, "pid 0 must parse successfully, not be treated as invalid")
    }

    // MARK: - Window lookup test

    do {
        let fixture = [
            "s1\t@1\t%1\t/a\tzsh\t1",
            "s1\t@2\t%2\t/b\tvim\t2",
            "s2\t@3\t%3\t/c\tbash\t3",
        ].joined(separator: "\n")
        let snapshot = try! Snapshot.parse(tmuxOutput: fixture)
        expect(snapshot.window(paneId: "%3")?.windowId == "@3", "window lookup hit returns the correct entry")
        expect(snapshot.window(paneId: "%99") == nil, "window lookup miss returns nil")
    }

    // MARK: - Order stability test

    do {
        let fixture = [
            "sess-z\t@1\t%1\t/a\tzsh\t1",
            "sess-a\t@2\t%2\t/b\tvim\t2",
            "sess-m\t@3\t%3\t/c\tbash\t3",
        ].joined(separator: "\n")
        let snapshot = try! Snapshot.parse(tmuxOutput: fixture)
        expect(snapshot.sessions.map(\.sessionName) == ["sess-z", "sess-a", "sess-m"], "session order must match first-appearance order in the input, got \(snapshot.sessions.map(\.sessionName))")
    }

    print("SessionTopologySnapshotTests passed")
}
