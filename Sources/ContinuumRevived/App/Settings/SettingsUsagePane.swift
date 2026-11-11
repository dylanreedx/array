import AppKit
import ContinuumRevivedCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Usage (`.plans/116` part 21, first slice). Counts only while the
/// pane is on screen, on a utility queue, from a snapshot of the run ledger; it
/// never writes the ledger and never takes its writer's queue.
@MainActor
@Observable
final class SettingsUsageModel {
    enum Phase: Equatable {
        case idle
        case counting
        /// `ledgerTasks` is how many tasks the whole ledger holds.
        case ready(UsageReport, ledgerTasks: Int)
    }

    @ObservationIgnored var ledgerURL: URL?
    var period: UsageReport.Period = .week
    private(set) var phase: Phase = .idle
    /// Rows shown in the task list; "Show more" adds a page.
    var limit = SettingsUsageModel.page
    static let page = 30

    /// Checks: every count that ran, and whether it ran on the main thread.
    @ObservationIgnored private(set) var qaRuns: [(onMain: Bool, readSeconds: Double, reportSeconds: Double)] = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var cancel: CancelToken?
    @ObservationIgnored private let worker = Worker()

    /// The pane appeared: count.
    func appear() {
        active = true
        refresh()
    }

    /// The pane left: stop any count in flight.
    func disappear() {
        active = false
        cancel?.cancel()
        cancel = nil
    }

    func select(_ period: UsageReport.Period) {
        guard period != self.period else { return }
        self.period = period
        limit = Self.page
        refresh()
    }

    func refresh() {
        guard active else { return }
        cancel?.cancel()
        let token = CancelToken()
        cancel = token
        if case .ready = phase {} else { phase = .counting }
        let (url, period, worker) = (ledgerURL, period, worker)
        worker.queue.async {
            let readStart = Date()
            let tasks = url.map { worker.tasks(at: $0, isCancelled: token.isCancelled) } ?? []
            let reportStart = Date()
            let report = UsageReport.make(tasks, period: period)
            let run = (onMain: Thread.isMainThread, readSeconds: reportStart.timeIntervalSince(readStart),
                       reportSeconds: Date().timeIntervalSince(reportStart))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !token.isCancelled() else { return }
                    self.qaRuns.append(run)
                    self.phase = .ready(report, ledgerTasks: tasks.count)
                }
            }
        }
    }

    /// The report on screen, as a file. Nothing else is written.
    func export(to url: URL) throws {
        guard case let .ready(report, _) = phase else { return }
        try report.exportJSON().write(to: url, options: .atomic)
    }

    func presentExport(in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "array-usage.json"
        panel.allowedContentTypes = [.json]
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            try? self?.export(to: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// Queue-confined: the last read, kept while the file is unchanged.
    final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.array.settings-usage", qos: .utility)
        private var cached: (url: URL, size: Int, modified: Date, tasks: [RunLedgerUsageReader.Task])?

        func tasks(at url: URL, isCancelled: () -> Bool) -> [RunLedgerUsageReader.Task] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if let cached, cached.url == url, cached.size == size, cached.modified == modified { return cached.tasks }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            let tasks = RunLedgerUsageReader.read(data, isCancelled: isCancelled)
            if !isCancelled() { cached = (url, size, modified, tasks) }
            return tasks
        }
    }
}

// MARK: - The pane

/// The Usage pane's sections, inside the pane's grouped Form.
struct SettingsUsageSections: View {
    let settings: SettingsModel
    let field: SettingsField
    private var usage: SettingsUsageModel { settings.usage }

    var body: some View {
        let _ = settings.revision
        Section {
            HStack {
                SettingsRowLabel(title: "Period", help: "Tasks are counted on the day they closed.")
                Spacer()
                UsagePeriodChoice(usage: usage).frame(width: 160, height: 28)
            }
            .settingsAnchor(SettingsRegistry.anchor(for: field) ?? field.label, model: settings)
            .onAppear { usage.appear() }
            .onDisappear { usage.disappear() }
            InfoRow(text: "\(AppChannel.liveApplicationSupportDirectoryName) on this Mac only, read from its own run ledger. Nothing here is uploaded.")
            if !AgentTokenTelemetryConfig.enabled(defaults: settings.defaults) {
                let text = "Token recording is off. Tasks closed while it is off show tokens as unknown. What is already on this Mac is still shown."
                Label(text, systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .settingsRenderedText("usage.recordingOff", text, model: settings)
            }
        }
        switch usage.phase {
        case .idle, .counting:
            Section { InfoRow(text: "Counting…").settingsRenderedText("usage.counting", "Counting…", model: settings) }
        case let .ready(report, ledgerTasks):
            if ledgerTasks == 0 {
                Section {
                    let text = "No Managed tasks are recorded on this Mac yet. A task appears here once a Managed lead finishes it."
                    InfoRow(text: text).settingsRenderedText("usage.empty", text, model: settings)
                }
            } else {
                UsageReportSections(report: report, usage: usage, settings: settings)
            }
        }
        if let group = settings.sections.flatMap(\.groups).first(where: { $0.id == "agents.tokenTelemetry" }) {
            Section {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in ToggleRow(row: row, model: settings) }
                if case .ready(_, let tasks) = usage.phase, tasks > 0 {
                    ButtonRow(title: "Export these figures", buttonTitle: "Export…",
                              help: "Saves the period's figures as a file, with ids only: no names, prompts or paths.",
                              enabled: true) { usage.presentExport(in: settings.hostWindow) }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text([group.footer, "Account limits (5-hour and weekly) stay in each agent tile's status row."]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageReportSections: View {
    let report: UsageReport
    let usage: SettingsUsageModel
    let settings: SettingsModel

    var body: some View {
        let period = report.period.title.lowercased()
        Section {
            figure("usage.closed", "Tasks closed", UsageWords.count(report.closed))
            if report.closed > 0 {
                figure("usage.fullyCounted", "Fully counted", "\(UsageWords.count(report.fullyCounted)) of \(UsageWords.count(report.closed))",
                       help: "Every turn's tokens were recorded, all four kinds known.")
                figure("usage.split", "How the work was split",
                       "\(UsageWords.count(report.solo)) solo · \(UsageWords.count(report.oneHelper)) with one helper · \(UsageWords.count(report.twoOrMoreHelpers)) with two or more")
            }
            if report.open + report.interrupted > 0 {
                let text = "Listed below but not counted: \(report.open) still open, \(report.interrupted) interrupted."
                InfoRow(text: text).settingsRenderedText("usage.notCounted", text, model: settings)
            }
        } header: {
            Text("Tasks")
        } footer: {
            if report.closed > 0 {
                Text("Solo and fanned-out tasks are different tasks. These counts do not show which way works better.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        if report.closed > 0 {
            Section {
                UsageTokenGrid(report: report, settings: settings)
            } header: {
                Text("Tokens")
            } footer: {
                Text("Totals over the \(report.closed) \(report.closed == 1 ? "task" : "tasks") closed in the \(period == "all time" ? "ledger" : period). A task whose count is missing or partial is marked unknown, never counted as zero.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            if report.tasks.isEmpty {
                let text = "No tasks in the \(period)."
                InfoRow(text: text).settingsRenderedText("usage.noTasks", text, model: settings)
            }
            ForEach(Array(report.tasks.prefix(usage.limit).enumerated()), id: \.element.task) { index, line in
                UsageTaskRow(line: line, index: index, settings: settings)
            }
            if report.tasks.count > usage.limit {
                HStack {
                    Text("Newest \(usage.limit) of \(report.tasks.count)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show more") { usage.limit += SettingsUsageModel.page }
                }
            }
        } header: {
            Text("Recent tasks")
        }
    }

    private func figure(_ id: String, _ title: String, _ value: String, help: String? = nil) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            SettingsRowLabel(title: title, help: help)
        }
        .settingsRenderedText(id, value, model: settings)
    }
}

private struct UsageTokenGrid: View {
    let report: UsageReport
    let settings: SettingsModel

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["Lead", "Helpers", "All"], id: \.self) { Text($0).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
            }
            ForEach(UsageReport.TokenType.allCases, id: \.self) { type in
                GridRow {
                    Text(type.title).frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
                    cell("usage.tokens.\(type.rawValue).lead", report.tokens[.lead]?[type] ?? .init())
                    cell("usage.tokens.\(type.rawValue).helpers", report.tokens[.helpers]?[type] ?? .init())
                    cell("usage.tokens.\(type.rawValue).all", report.all[type] ?? .init())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ id: String, _ figure: UsageReport.Figure) -> some View {
        let words = UsageWords.figure(figure, of: report.closed)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(words.value).monospacedDigit()
            if let note = words.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsRenderedText(id, [words.value, words.note].compactMap { $0 }.joined(separator: " · "), model: settings)
    }
}

private struct UsageTaskRow: View {
    let line: UsageReport.TaskLine
    let index: Int
    let settings: SettingsModel

    var body: some View {
        let lines = UsageWords.task(line)
        VStack(alignment: .leading, spacing: 3) {
            Text(lines[0])
            ForEach(lines.dropFirst(), id: \.self) { text in
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRenderedText("usage.task.\(index)", lines.joined(separator: "\n"), model: settings)
    }
}

/// The page's words, one place, so the checks read what the rows draw.
enum UsageWords {
    static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func count(_ value: Int) -> String { number.string(from: NSNumber(value: value)) ?? "\(value)" }

    /// A total and, when part of it is missing, how many tasks are unknown.
    static func figure(_ figure: UsageReport.Figure, of tasks: Int) -> (value: String, note: String?) {
        guard figure.isUnknown else { return (count(figure.known), nil) }
        if figure.known == 0, figure.unknown >= tasks { return ("unknown", nil) }
        return (count(figure.known), "+ unknown in \(figure.unknown) of \(tasks)")
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "unknown" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func task(_ line: UsageReport.TaskLine) -> [String] {
        let state: String
        switch line.state {
        case .closed: state = "Closed"
        case .open: state = "Still open, not counted"
        case .interrupted: state = "Interrupted, not counted"
        }
        let date = (line.ended ?? line.opened).map { when.string(from: $0) } ?? "unknown time"
        let helpers = line.helpers == 0 ? "solo" : line.helpers == 1 ? "1 helper" : "\(line.helpers) helpers"
        var lines = ["\(date) · \(state)",
                     "Time to answer \(duration(line.timeToAnswer)) · active \(duration(line.activeTime)) · \(helpers)"]
        for role in UsageReport.Role.allCases where role == .lead || line.helpers > 0 {
            let figures = UsageReport.TokenType.allCases.map { ($0, line.tokens[role]?[$0] ?? .init()) }
            let label = role == .lead ? "Lead" : "Helpers"
            if figures.allSatisfy({ $0.1.isUnknown && $0.1.known == 0 }) {
                lines.append("\(label): unknown")
                continue
            }
            // Partial in every kind: say it once, after the known part.
            let everyPartial = figures.allSatisfy { $0.1.isUnknown }
            let parts = figures.map { type, figure -> String in
                let value = figure.isUnknown && !everyPartial
                    ? (figure.known == 0 ? "unknown" : "\(count(figure.known)) + unknown") : count(figure.known)
                return "\(type.title.lowercased()) \(value)"
            }
            lines.append("\(label): " + parts.joined(separator: " · ") + (everyPartial ? ", each plus an unknown part" : ""))
        }
        let models = line.models.map { "\($0.role == .lead ? "Lead" : "Helper") \($0.harness ?? "unknown harness") (\($0.model ?? "unknown model"))" }
        lines.append(models.isEmpty ? "Harness and model unknown" : models.joined(separator: " · "))
        return lines
    }
}

/// The period chooser: Array's choice button, as the update channel row uses.
private struct UsagePeriodChoice: NSViewRepresentable {
    let usage: SettingsUsageModel

    func makeNSView(context: Context) -> ChoiceButton {
        let button = ChoiceButton(title: usage.period.title)
        button.setAccessibilityLabel("Period")
        button.setAccessibilityIdentifier("ArraySettingsUsagePeriod")
        return button
    }

    func updateNSView(_ button: ChoiceButton, context: Context) {
        button.items = UsageReport.Period.allCases.map { ChoiceItem(id: $0.rawValue, title: $0.title) }
        button.selectedID = usage.period.rawValue
        button.onSelection = { item in
            guard let period = UsageReport.Period(rawValue: item.id) else { return }
            MainActor.assumeIsolated { usage.select(period) }
        }
    }
}
