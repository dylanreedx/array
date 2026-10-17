import SwiftUI

struct AgentListView: View {
    let agents: [AgentSummary]

    var body: some View {
        List(agents) { agent in
            HStack {
                StatusDot(status: agent.status)
                Text(agent.name)
                Spacer()
                Text(agent.zone).foregroundStyle(.secondary)
            }
        }
    }
}
