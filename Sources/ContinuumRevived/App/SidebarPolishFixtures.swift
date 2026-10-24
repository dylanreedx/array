import ContinuumRevivedAgentUI
import Foundation

/// Rows for judging the sidebar polish pass in the Component Lab's Live Sidebar:
/// folded stacks of 1, 3 and 8 subagents, working and idle children, identity
/// colours, and three projects whose icons come from the fixture roots
/// `scripts/sidebar-preview.sh` lays down beside the preview's project.
///
/// Ids are canned (InboxSort breaks ties on them); the clock is the caller's.
enum SidebarPolishFixtures {
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000005%02X", n))!
    }

    static let arrayProject = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    static let harmonyProject = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    static let selectusProject = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!

    /// Project roots for the icon resolver, under the preview's pinned project.
    /// Empty outside the preview, so a check run draws the folder fallback.
    static func iconRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UUID: URL] {
        guard let root = environment["CONTINUUM_PROJECT_ROOT"], !root.isEmpty else { return [:] }
        let base = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("fixture-projects", isDirectory: true)
        return [
            arrayProject: base.appendingPathComponent("array", isDirectory: true),
            harmonyProject: base.appendingPathComponent("harmony", isDirectory: true),
            selectusProject: base.appendingPathComponent("selectus", isDirectory: true),
        ]
    }

    static func rows(now: Date) -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var rows: [AgentInboxRow] = []

        // A wide swarm: eight children, all working.
        let swarm = id(1)
        rows.append(AgentInboxRow(
            id: swarm, title: "Plan richer file tile previews", projectName: "Array", projectId: arrayProject,
            state: .working, model: "gpt-6.1-sol", branch: "array/integration", elapsed: 840,
            createdAt: ago(60), harness: "Codex"))
        for n in 0..<8 {
            rows.append(AgentInboxRow(
                id: id(10 + n), title: ["Image decode budget", "CSV grid layout", "XLSX sheet tabs", "Thumbnail cache",
                                        "Large file guard", "Preview a11y labels", "Quick Look fallback", "Scroll perf probe"][n],
                projectName: "Array", projectId: arrayProject, state: .working, model: "gpt-6.1-sol",
                branch: "array/integration", elapsed: Double(120 + n * 45), depth: 1,
                createdAt: ago(55 - Double(n)), parentId: swarm, harness: "Codex"))
        }

        // A small team with an identity colour: three children, one finished.
        let team = id(2)
        rows.append(AgentInboxRow(
            id: team, title: "Polish sidebar card hover interactions", projectName: "Array", projectId: arrayProject,
            state: .working, model: "claude-opus-5-5", branch: "array/sidebar-preview", elapsed: 3_900,
            createdAt: ago(50), harness: "Claude Code", identityColor: "teal"))
        for (n, title) in ["Sidebar: hover, inset, fold speed", "Sidebar: fold button, constellations",
                           "Sidebar: project icons"].enumerated() {
            rows.append(AgentInboxRow(
                id: id(20 + n), title: title, projectName: "Array", projectId: arrayProject,
                state: n == 2 ? .ready : .working, model: "claude-opus-5-5", branch: "array/sidebar-preview",
                elapsed: n == 2 ? nil : Double(2_400 + n * 300), depth: 1, createdAt: ago(45 - Double(n)),
                parentId: team, harness: "Claude Code"))
        }

        // One child, in another project.
        let pair = id(3)
        rows.append(AgentInboxRow(
            id: pair, title: "Audit the intake form validation", projectName: "harmony", projectId: harmonyProject,
            state: .ready, model: "claude-opus-5-5", branch: "main", createdAt: ago(40), harness: "Claude Code"))
        rows.append(AgentInboxRow(
            id: id(30), title: "Trace the date-of-birth parser", projectName: "harmony", projectId: harmonyProject,
            state: .working, model: "claude-opus-5-5", branch: "main", elapsed: 600, depth: 1,
            createdAt: ago(38), parentId: pair, harness: "Claude Code"))

        // Singles around them, so a stack's hover can be judged against its neighbours.
        rows.append(AgentInboxRow(
            id: id(4), title: "Draft LinkedIn and X posts for video", projectName: "Array", projectId: arrayProject,
            state: .approval, attention: .unread, model: "claude-opus-5-5", branch: "array/integration",
            createdAt: ago(35), harness: "Claude Code"))
        rows.append(AgentInboxRow(
            id: id(5), title: "Fix the pricing rounding on renewals", projectName: "selectus", projectId: selectusProject,
            state: .working, model: "gpt-6.1-sol", branch: "fix/renewal-rounding", elapsed: 1_260,
            createdAt: ago(30), harness: "Codex", identityColor: "purple"))
        rows.append(AgentInboxRow(
            id: id(6), title: "Resume performance optimization work", projectName: "Array", projectId: arrayProject,
            state: .ready, model: "claude-opus-5-5", branch: "array/integration", createdAt: ago(25),
            harness: "Claude Code"))
        return rows
    }
}
