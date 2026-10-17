import SwiftUI

struct StatusDot: View {
    let status: AgentStatus
    var body: some View { Circle().fill(status.color).frame(width: 8, height: 8) }
}
