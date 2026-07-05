import CloudKit
import ContinuumRevivedCore
import ContinuumRevivedSync
import SwiftUI

private let continuumCloudKitContainerIdentifier = "iCloud.dev.dylanreed.continuum"

@main
struct ContinuumApp: App {
    @StateObject private var model = AgentsBoardModel()

    var body: some Scene {
        WindowGroup {
            ContinuumRootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}

private enum ContinuumTab: Hashable {
    case agents
    case canvas
    case approvals
    case settings
}

private struct ContinuumRootView: View {
    @State private var selectedTab: ContinuumTab = .agents

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentsBoardView(selectedTab: $selectedTab)
                .tabItem { Label("Agents", systemImage: "person.2.fill") }
                .tag(ContinuumTab.agents)

            PlaceholderScreen(title: "Canvas", subtitle: "Canvas lands with ticket B4.")
                .tabItem { Label("Canvas", systemImage: "square.grid.2x2") }
                .tag(ContinuumTab.canvas)

            PlaceholderScreen(title: "Approvals", subtitle: "Approvals land with ticket 62.")
                .tabItem { Label("Approvals", systemImage: "checkmark.seal") }
                .tag(ContinuumTab.approvals)

            PlaceholderScreen(title: "Settings", subtitle: "Settings land with ticket B8.")
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(ContinuumTab.settings)
        }
        .tint(.orange)
    }
}

@MainActor
private final class AgentsBoardModel: ObservableObject {
    enum State: Equatable {
        case loading
        case unavailable(String)
        case live
    }

    @Published var state: State = .loading
    @Published var snapshot: ActivityLogSnapshot = .empty
    @Published var rows: [AgentsBoardRow] = []

    private var task: Task<Void, Never>?
    private var receiver: ActivityProjectionReceiver?

    func start() async {
        guard task == nil else { return }
        state = .loading

        let container = CKContainer(identifier: continuumCloudKitContainerIdentifier)
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                state = .unavailable("Sign in to iCloud in Settings to observe your agents")
                return
            }
        } catch {
            state = .unavailable("Sign in to iCloud in Settings to observe your agents")
            return
        }

        let transport = CloudKitSyncTransport(containerIdentifier: continuumCloudKitContainerIdentifier)
        let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: transport), scope: .observer)
        self.receiver = receiver

        task = Task { [weak self] in
            await receiver.connect(cursor: nil)
            let stream = await receiver.subscribe()
            for await item in stream {
                await self?.consume(item)
            }
        }
    }

    func activity(for tileId: UUID) -> TileActivity? {
        snapshot.byTile[tileId]
    }

    private func consume(_ item: ActivityStreamItem) {
        switch item {
        case .snapshot(let incoming):
            snapshot = incoming
        case .event(let event):
            snapshot = AgentsBoardProjection.applyEvent(event, to: snapshot)
        }
        rows = AgentsBoardProjection.rows(from: snapshot)
        state = .live
    }
}

private struct AgentsBoardView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    @Binding var selectedTab: ContinuumTab

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    LoadingBoardView()
                case .unavailable(let message):
                    ActionableErrorView(message: message)
                case .live:
                    if model.rows.isEmpty {
                        EmptyBoardView()
                    } else {
                        List(model.rows) { row in
                            NavigationLink(value: row.tileId) {
                                AgentRowView(row: row)
                            }
                            .listRowBackground(row.status == .needsAttention ? Color.orange.opacity(0.12) : Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle("Agents")
            .navigationDestination(for: UUID.self) { tileId in
                AgentDetailView(tileId: tileId, selectedTab: $selectedTab)
            }
        }
    }
}

private struct AgentRowView: View {
    let row: AgentsBoardRow

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyphView(status: row.status, presentation: row.presentation)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusPill(status: row.status, presentation: row.presentation)
                    Spacer(minLength: 8)
                    Text(row.updatedAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(row.lastSummary.isEmpty ? "No activity yet" : row.lastSummary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct AgentDetailView: View {
    @EnvironmentObject private var model: AgentsBoardModel
    let tileId: UUID
    @Binding var selectedTab: ContinuumTab

    private var row: AgentsBoardRow? {
        model.rows.first { $0.tileId == tileId }
    }

    private var activity: TileActivity? {
        model.activity(for: tileId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let row, let activity {
                    DetailHeader(row: row)
                    if row.status == .needsAttention {
                        PendingAttentionCard(activity: activity)
                    }
                    Button {
                        selectedTab = .canvas
                    } label: {
                        Label("Show on canvas", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    TimelineView(events: AgentsBoardProjection.timelineEvents(for: activity))
                } else {
                    Text("Agent activity is no longer available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                }
            }
            .padding()
        }
        .background(AppColors.background.ignoresSafeArea())
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailHeader: View {
    let row: AgentsBoardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusPill(status: row.status, presentation: row.presentation)
                Spacer()
                Text(row.updatedAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(row.lastSummary.isEmpty ? "No activity yet" : row.lastSummary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(row.tileId.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
        .background(AppColors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PendingAttentionCard: View {
    let activity: TileActivity

    private var latest: AgentActivityEvent? {
        AgentsBoardProjection.latestPendingAttentionEvent(in: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pending attention")
                    .font(.headline)
                Spacer()
                if let latest {
                    Text(latest.occurredAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(latest?.summary ?? activity.lastSummary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                Button("Approve") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                Button("Deny") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            Text("Actions land with ticket 62.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TimelineView: View {
    let events: [AgentActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timeline")
                .font(.headline)
            if events.isEmpty {
                Text("No transcript available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(AppColors.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(events, id: \.compositeId) { event in
                    TimelineEventRow(event: event)
                }
            }
        }
    }
}

private extension AgentActivityEvent {
    var compositeId: String {
        "\(replicaId.uuidString)-\(sequence)"
    }
}

private struct TimelineEventRow: View {
    let event: AgentActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text(event.occurredAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding()
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        switch event.tone {
        case .info: .blue
        case .tool: .teal
        case .approval: .orange
        case .error: .red
        }
    }
}

private struct StatusGlyphView: View {
    let status: AgentStatus
    let presentation: AgentStatusPresentation

    var body: some View {
        Text(presentation.glyph)
            .font(.title3.weight(.bold))
            .foregroundStyle(AppColors.color(for: presentation.colorToken))
            .accessibilityLabel(status.rawValue)
    }
}

private struct StatusPill: View {
    let status: AgentStatus
    let presentation: AgentStatusPresentation

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.glyph)
            Text(status.rawValue)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(AppColors.color(for: presentation.colorToken))
        .background(AppColors.color(for: presentation.colorToken).opacity(0.16))
        .clipShape(Capsule())
    }
}

private struct LoadingBoardView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to iCloud")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActionableErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyBoardView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("No agents observed")
                .font(.headline)
            Text("Spawn agents on the desktop to populate this board.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlaceholderScreen: View {
    let title: String
    let subtitle: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(title)
        }
    }
}

private enum AppColors {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.14)

    static func color(for token: String) -> Color {
        switch token {
        case "blue": .blue
        case "orange": .orange
        case "green": .green
        case "gray": .gray
        case "teal": .teal
        case "tertiaryLabel": Color(.tertiaryLabel)
        default: .secondary
        }
    }
}
