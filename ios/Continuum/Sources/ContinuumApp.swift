import SwiftUI

// Continuum for iPhone — v1 scaffold (night-3). The real surfaces (agents board,
// canvas replica, approvals inbox) land per docs/38-tickets/_COMPANION_SPEC.md.
@main
struct ContinuumApp: App {
    var body: some Scene {
        WindowGroup {
            AgentsBoardPlaceholder()
        }
    }
}

struct AgentsBoardPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Continuum")
                .font(.system(.title2, design: .monospaced)).bold()
            Text("companion scaffold — agents board lands tonight")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.09, blue: 0.11))
        .foregroundStyle(.white)
    }
}
