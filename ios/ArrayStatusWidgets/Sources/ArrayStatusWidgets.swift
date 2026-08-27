import ActivityKit
import ContinuumRevivedAgentUI
import SwiftUI
import WidgetKit

@main
struct ArrayStatusWidgets: WidgetBundle {
    var body: some Widget {
        ArrayAgentStatusWidget()
        ArrayAgentLiveActivity()
    }
}

private struct ArrayAgentStatusEntry: TimelineEntry {
    var date: Date
    var snapshot: ArrayWidgetSnapshot
}

private struct ArrayAgentStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ArrayAgentStatusEntry {
        ArrayAgentStatusEntry(date: .now, snapshot: .previewWorking)
    }

    func getSnapshot(in context: Context, completion: @escaping (ArrayAgentStatusEntry) -> Void) {
        completion(ArrayAgentStatusEntry(
            date: .now,
            snapshot: context.isPreview ? .previewWorking : ArrayWidgetSnapshotStore.read()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ArrayAgentStatusEntry>) -> Void) {
        let snapshot = ArrayWidgetSnapshotStore.read()
        let nextRefresh = Date().addingTimeInterval(snapshot.runningCount > 0 ? 60 : 15 * 60)
        completion(Timeline(
            entries: [ArrayAgentStatusEntry(date: .now, snapshot: snapshot)],
            policy: .after(nextRefresh)
        ))
    }
}

private struct ArrayAgentStatusWidget: Widget {
    let kind = "ArrayAgentStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArrayAgentStatusProvider()) { entry in
            ArrayAgentStatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { ArraySurfaceBackground() }
                .widgetURL(entry.snapshot.deepLink)
        }
        .configurationDisplayName("Array Agents")
        .description("See running agents and anything that needs your attention.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ArrayAgentStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ArrayAgentStatusEntry

    var body: some View {
        switch family {
        case .systemMedium:
            ArrayMediumStatusView(snapshot: entry.snapshot)
        default:
            ArraySmallStatusView(snapshot: entry.snapshot)
        }
    }
}

private struct ArraySmallStatusView: View {
    let snapshot: ArrayWidgetSnapshot

    var body: some View {
        VStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ArrayGyroGlyph(phase: effectivePhase, size: 64)
                if snapshot.attentionCount > 0 {
                    Text("\(snapshot.attentionCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.orange, in: Circle())
                        .accessibilityLabel("\(snapshot.attentionCount) need attention")
                }
            }
            Text(summary)
                .font(.headline)
                .lineLimit(1)
            Text(snapshot.isStale ? "Status may be out of date" : statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var effectivePhase: DualPlaneGyroPresentationPhase { snapshot.isStale ? .stale : snapshot.phase }
    private var summary: String { snapshot.runningCount == 1 ? "1 agent running" : "\(snapshot.runningCount) agents running" }
    private var statusLine: String { snapshot.attentionCount > 0 ? "Needs attention" : (snapshot.runningCount > 0 ? "Working" : "Array is ready") }
}

private struct ArrayMediumStatusView: View {
    let snapshot: ArrayWidgetSnapshot

    var body: some View {
        HStack(spacing: 18) {
            ArrayGyroGlyph(phase: snapshot.isStale ? .stale : snapshot.phase, size: 76)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Label("\(snapshot.runningCount)", systemImage: "bolt.fill")
                    if snapshot.attentionCount > 0 {
                        Label("\(snapshot.attentionCount)", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption.bold())
                if let agent = snapshot.highlightedAgent {
                    Text(agent.name).font(.headline).lineLimit(1)
                    if let workspace = agent.workspaceName {
                        Text(workspace).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(statusText(for: agent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Array is ready").font(.headline)
                    Text(snapshot.isStale ? "Last status is stale" : "No agents running")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(for agent: ArrayWidgetAgent) -> String {
        if snapshot.isStale { return "Status may be out of date" }
        switch agent.status {
        case .configuring: return "Starting"
        case .working: return "Working since \(agent.startedAt.formatted(date: .omitted, time: .shortened))"
        case .needsAttention: return "Needs attention"
        case .done: return "Completed"
        case .stale: return "Offline"
        case .idle: return "Idle"
        }
    }
}

private struct ArrayAgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ArrayAgentActivityAttributes.self) { context in
            ArrayLiveActivityLockScreen(state: context.state)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(deepLink(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArrayGyroGlyph(phase: context.state.phase, size: 38)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.agentName ?? "Array Agents").font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.runningCount)").font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.statusText)
                        Spacer()
                        if let startedAt = context.state.startedAt, context.state.runningCount > 0 {
                            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                ArrayGyroGlyph(phase: context.state.phase, size: 22)
            } compactTrailing: {
                Text(context.state.attentionCount > 0 ? "!\(context.state.attentionCount)" : "\(context.state.runningCount)")
                    .font(.caption.bold())
                    .foregroundStyle(context.state.attentionCount > 0 ? .orange : .primary)
            } minimal: {
                ArrayGyroGlyph(phase: context.state.phase, size: 22)
            }
            .widgetURL(deepLink(for: context.state))
            .keylineTint(ArrayGlyphPalette.accent(for: context.state.phase, colorScheme: .dark))
        }
    }

    private func deepLink(for state: ArrayAgentActivityAttributes.ContentState) -> URL {
        URL(string: state.agentID.map { "array://agent/\($0.uuidString)" } ?? "array://agents")!
    }
}

private struct ArrayLiveActivityLockScreen: View {
    let state: ArrayAgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ArrayGyroGlyph(phase: state.phase, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.agentName ?? "Array Agents").font(.headline).lineLimit(1)
                Text(state.workspaceName ?? state.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(state.statusText).font(.caption.bold())
                if let startedAt = state.startedAt, state.runningCount > 0 {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ArraySurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View { ArrayGlyphPalette.color(SurfaceToken.panel.color, colorScheme: colorScheme) }
}

private struct ArrayGyroGlyph: View {
    @Environment(\.colorScheme) private var colorScheme
    let phase: DualPlaneGyroPresentationPhase
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let modelBounds = CGRect(origin: .zero, size: CGSize(width: 18, height: 18))
            let scale = min(canvasSize.width, canvasSize.height) / 18
            context.scaleBy(x: scale, y: scale)
            for plane in [DualPlaneGyroNodeState.Plane.primary, .secondary] {
                var path = Path()
                for (index, point) in DualPlaneGyroIndicatorModel.guidePoints(in: modelBounds, plane: plane).enumerated() {
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(.secondary.opacity(plane == .primary ? 0.34 : 0.24)), lineWidth: 0.7)
            }
            let nodes = DualPlaneGyroIndicatorModel.nodeStates(in: modelBounds, phase: phase.modelPhase)
                .sorted { $0.zPosition < $1.zPosition }
            for node in nodes {
                let diameter = node.diameter * node.scale
                let emphasis: CGFloat = phase == .needsAttention && node.token == .accentApproval ? 1.32 : 1
                let renderedDiameter = diameter * emphasis
                let rect = CGRect(x: node.position.x - renderedDiameter / 2, y: node.position.y - renderedDiameter / 2, width: renderedDiameter, height: renderedDiameter)
                let token: AccentToken
                switch phase {
                case .failed: token = .accentFailed
                case .completed: token = .accentDone
                default: token = node.token
                }
                let color = ArrayGlyphPalette.color(token.color, colorScheme: colorScheme)
                let attentionOpacity = phase == .needsAttention && node.token != .accentApproval ? 0.48 : 1
                context.opacity = (phase == .stale ? node.opacity * 0.45 : node.opacity) * attentionOpacity
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(phase.accessibilityLabel)
    }
}

private enum ArrayGlyphPalette {
    static func color(_ token: TokenColor, colorScheme: ColorScheme) -> Color {
        let chip = token.resolved(for: colorScheme == .dark ? .dark : .light)
        return Color(.sRGB, red: chip.r, green: chip.g, blue: chip.b, opacity: 1)
    }

    static func accent(for phase: DualPlaneGyroPresentationPhase, colorScheme: ColorScheme) -> Color {
        let token: AccentToken
        switch phase {
        case .needsAttention: token = .accentApproval
        case .failed: token = .accentFailed
        case .completed: token = .accentDone
        case .idle, .working, .stale: token = .accentWorking
        }
        return color(token.color, colorScheme: colorScheme)
    }
}

private extension ArrayWidgetSnapshot {
    static let previewWorking = ArrayWidgetSnapshot(
        generatedAt: .now,
        instanceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        runningCount: 3,
        attentionCount: 1,
        phase: .needsAttention,
        highlightedAgent: ArrayWidgetAgent(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Release companion",
            workspaceName: "Array",
            status: .needsAttention,
            startedAt: Date(timeIntervalSinceNow: -12 * 60)
        )
    )
}

#Preview("Small", as: .systemSmall) {
    ArrayAgentStatusWidget()
} timeline: {
    ArrayAgentStatusEntry(date: .now, snapshot: .previewWorking)
}

#Preview("Medium", as: .systemMedium) {
    ArrayAgentStatusWidget()
} timeline: {
    ArrayAgentStatusEntry(date: .now, snapshot: .previewWorking)
}

#Preview("Live Activity", as: .content, using: ArrayAgentActivityAttributes(
    instanceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    macName: "Dylan’s Mac"
)) {
    ArrayAgentLiveActivity()
} contentStates: {
    ArrayAgentActivityAttributes.ContentState(
        runningCount: 3,
        attentionCount: 1,
        phase: .needsAttention,
        agentID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
        agentName: "Release companion",
        workspaceName: "Array",
        startedAt: Date(timeIntervalSinceNow: -12 * 60),
        statusText: "Needs attention"
    )
}
