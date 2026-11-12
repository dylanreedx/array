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
        /// `ledgerTasks` is how many tasks (and untasked rows) the whole ledger holds.
        case ready(UsageReport, ledgerTasks: Int)
    }

    @ObservationIgnored var ledgerURL: URL?
    var period: UsageReport.Period = .week
    private(set) var phase: Phase = .idle
    /// Tasks whose breakdown is open.
    var openTasks: Set<UUID> = []
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

    func toggle(_ task: UUID) {
        if openTasks.remove(task) == nil { openTasks.insert(task) }
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
            let tasks = url.map { worker.tasks(at: $0, isCancelled: token.isCancelled) } ?? RunLedgerUsageReader.Ledger()
            let reportStart = Date()
            let report = UsageReport.make(tasks, period: period)
            let run = (onMain: Thread.isMainThread, readSeconds: reportStart.timeIntervalSince(readStart),
                       reportSeconds: Date().timeIntervalSince(reportStart))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !token.isCancelled() else { return }
                    self.qaRuns.append(run)
                    self.phase = .ready(report, ledgerTasks: tasks.tasks.count + tasks.untasked.count)
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
        private var cached: (url: URL, size: Int, modified: Date, tasks: RunLedgerUsageReader.Ledger)?

        func tasks(at url: URL, isCancelled: () -> Bool) -> RunLedgerUsageReader.Ledger {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if let cached, cached.url == url, cached.size == size, cached.modified == modified { return cached.tasks }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return RunLedgerUsageReader.Ledger() }
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
                    let text = "No tasks are recorded on this Mac yet. A task appears here once an agent you prompted finishes it."
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
                       help: "Every turn's tokens were recorded, in every kind its harness reports.")
                figure("usage.split", "How the work was split",
                       "\(UsageWords.count(report.solo)) solo · \(UsageWords.count(report.oneHelper)) with one helper · \(UsageWords.count(report.twoOrMoreHelpers)) with two or more",
                       help: "A helper is any agent working under the lead, at any depth.")
                figure("usage.mode", "Mode", UsageWords.modes(report),
                       help: "How the agent was set when the task began.")
            }
            if report.untaskedRows > 0 {
                let text = UsageWords.untasked(report)
                InfoRow(text: text).settingsRenderedText("usage.noTask", text, model: settings)
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
                UsageTokenGrid(table: report.tokens, exact: false, id: "usage.tokens", settings: settings)
            } header: {
                Text("Tokens")
            } footer: {
                let text = UsageWords.coverage(report)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .settingsRenderedText("usage.coverage", text, model: settings)
            }
        }
        Section {
            if report.tasks.isEmpty {
                let text = "No tasks in the \(period)."
                InfoRow(text: text).settingsRenderedText("usage.noTasks", text, model: settings)
            } else {
                UsageTaskColumns.header
            }
            ForEach(Array(report.tasks.prefix(usage.limit).enumerated()), id: \.element.task) { index, line in
                UsageTaskRow(line: line, index: index, usage: usage, settings: settings)
            }
            if report.tasks.count > usage.limit {
                HStack {
                    Text("Newest \(usage.limit) of \(UsageWords.count(report.tasks.count))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show more") { usage.limit += SettingsUsageModel.page }
                }
            }
        } header: {
            Text("Recent tasks")
        } footer: {
            if !report.tasks.isEmpty {
                Text("Click a task to see its tokens by kind, for the lead and the helpers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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

/// Lead / Helpers / All by kind, plus Total. Compact on the page, exact in an
/// opened task. A cell missing part of its count reads "at least"; the reason is
/// said once, under the table.
private struct UsageTokenGrid: View {
    let table: UsageReport.Table
    let exact: Bool
    let id: String
    let settings: SettingsModel

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: exact ? 4 : 8) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["Lead", "Helpers", "All"], id: \.self) { Text($0).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
            }
            ForEach(UsageReport.TokenType.allCases, id: \.self) { type in
                if type == .total { Divider().gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    Text(type.title)
                        .fontWeight(type == .total ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    ForEach(UsageReport.Column.allCases, id: \.self) { column in
                        let words = UsageWords.figure(table[column]?[type] ?? .init(), exact: exact)
                        Text(words)
                            .monospacedDigit()
                            .fontWeight(type == .total ? .semibold : .regular)
                            .frame(minWidth: 96, alignment: .trailing)
                            .settingsRenderedText("\(id).\(type.rawValue).\(column.rawValue)", words, model: settings)
                    }
                }
            }
        }
        .font(exact ? .callout : .body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fixed columns so a reader can scan down: when, time to answer, how, tokens, model.
private enum UsageTaskColumns {
    static let time: CGFloat = 100
    static let how: CGFloat = 76
    static let tokens: CGFloat = 96
    static let model: CGFloat = 112
    static let chevron: CGFloat = 14

    static func row<A: View, B: View, C: View, D: View, E: View>(_ when: A, _ time: B, _ how: C, _ tokens: D, _ model: E) -> some View {
        HStack(spacing: 10) {
            when.frame(maxWidth: .infinity, alignment: .leading)
            time.frame(width: Self.time, alignment: .trailing)
            how.frame(width: Self.how, alignment: .leading)
            tokens.frame(width: Self.tokens, alignment: .trailing)
            model.frame(width: Self.model, alignment: .leading)
        }
        .lineLimit(1)
    }

    static var header: some View {
        row(Text("Closed").padding(.leading, chevron + 6), Text("Time to answer"), Text("Done"), Text("Tokens"), Text("Model"))
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct UsageTaskRow: View {
    let line: UsageReport.TaskLine
    let index: Int
    let usage: SettingsUsageModel
    let settings: SettingsModel

    var body: some View {
        let cells = UsageWords.cells(line)
        let opened = usage.openTasks.contains(line.task)
        VStack(alignment: .leading, spacing: 8) {
            Button { usage.toggle(line.task) } label: {
                UsageTaskColumns.row(
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(opened ? 90 : 0))
                            .frame(width: UsageTaskColumns.chevron)
                        Text(cells.when).foregroundStyle(line.state == .closed ? .primary : .secondary)
                    },
                    Text(cells.time).monospacedDigit(),
                    Text(cells.how),
                    Text(cells.tokens).monospacedDigit(),
                    Text(cells.model).truncationMode(.middle).foregroundStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ArraySettingsUsageTask.\(index)")
            .accessibilityAddTraits(opened ? .isSelected : [])
            .settingsRenderedText("usage.task.\(index)", cells.joined, model: settings)
            if opened {
                VStack(alignment: .leading, spacing: 8) {
                    let detail = UsageWords.detail(line)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsRenderedText("usage.task.\(index).detail", detail, model: settings)
                    UsageTokenGrid(table: line.tokens, exact: true, id: "usage.task.\(index).tokens", settings: settings)
                }
                .padding(.leading, UsageTaskColumns.chevron + 6)
                .padding(.bottom, 4)
            }
        }
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

    /// 139, 5.1K, 320K, 5.4M: three figures at most, one decimal below 100.
    static func compact(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }
        var scaled = Double(value)
        var units = ["K", "M", "B"][...]
        var unit = ""
        while scaled >= 999.95, let next = units.popFirst() { scaled /= 1_000; unit = next }
        let text = scaled < 99.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
    }

    /// One cell: a number, "at least" a number, "unknown", a dash for a kind
    /// the harness never reports, or "included in parent" for a subagent whose
    /// tokens its parent's figure already holds.
    static func figure(_ figure: UsageReport.Figure, exact: Bool) -> String {
        if figure.isNotReported { return "—" }
        if figure.isInParent { return "included in parent" }
        let value = exact ? count(figure.known) : compact(figure.known)
        guard figure.isUnknown else { return value }
        return figure.known == 0 ? "unknown" : "at least \(value)"
    }

    /// The one line under the Tokens table.
    static func coverage(_ report: UsageReport) -> String {
        var lines: [String] = []
        if report.missing > 0 {
            lines.append("\(count(report.missing)) of \(count(report.closed)) tasks are missing part of their count, so totals marked “at least” are lower bounds.")
        } else {
            lines.append("Every task closed in this period is fully counted.")
        }
        for (harness, kinds) in report.notReportedKinds.sorted(by: { $0.key < $1.key }) where !kinds.isEmpty {
            let names = kinds.map { "tokens \($0.title.lowercased())" }.joined(separator: " or ")
            lines.append("— \(harness) does not report \(names); its tasks count fully without them.")
        }
        return lines.joined(separator: " ")
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "unknown" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// "Today 14:02", "Yesterday 09:10", "Nov 7, 05:14": short enough for its column.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : "\(Self.day.string(from: date)),"
        return "\(day) \(time.string(from: date))"
    }

    struct Cells {
        /// The close time, or "Still open" / "Interrupted": neither has one.
        var when: String
        var time: String
        var how: String
        var tokens: String
        var model: String
        var joined: String { [when, time, how, tokens, model].joined(separator: " | ") }
    }

    static func cells(_ line: UsageReport.TaskLine) -> Cells {
        let closed: String
        switch line.state {
        case .closed: closed = line.ended.map { when($0) } ?? "unknown"
        case .open: closed = "Still open"
        case .interrupted: closed = "Interrupted"
        }
        let models = line.models.compactMap(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // The lead's model; a blank one stays unknown rather than borrowing a helper's.
        let others = models.count - (line.models.first { $0.role == .lead }?.model == nil ? 0 : 1)
        let lead = line.models.first { $0.role == .lead }?.model ?? "unknown"
        let model = others > 0 ? "\(lead) +\(others)" : lead
        return Cells(when: closed,
                     time: duration(line.timeToAnswer),
                     how: line.helpers == 0 ? "solo" : line.helpers == 1 ? "1 helper" : "\(line.helpers) helpers",
                     tokens: figure(line.total, exact: false),
                     model: model)
    }

    /// The opened row's first line: active time and every harness and model.
    static func detail(_ line: UsageReport.TaskLine) -> String {
        let models = line.models.map { model -> String in
            let source = model.source == "record" ? ", from its settings" : ""
            return "\(model.role == .lead ? "Lead" : "Helper") \(model.harness ?? "unknown harness") (\(model.model ?? "model unknown")\(source))"
        }
        let mode = line.mode == "free" ? ["Free"] : line.mode == "managed" ? ["Managed"] : []
        let opened = line.state == .closed ? [] : ["Opened \(line.opened.map { when($0) } ?? "unknown")"]
        return (mode + opened + ["Active \(duration(line.activeTime))"] + (models.isEmpty ? ["harness and model unknown"] : models)).joined(separator: " · ")
    }

    static func modes(_ report: UsageReport) -> String {
        var parts = ["\(count(report.managed)) Managed", "\(count(report.free)) Free"]
        if report.modeUnknown > 0 { parts.append("\(count(report.modeUnknown)) not recorded") }
        return parts.joined(separator: " · ")
    }

    /// The one line for usage no human-prompted task owns.
    static func untasked(_ report: UsageReport) -> String {
        let turns = report.untaskedRows == 1 ? "1 record" : "\(count(report.untaskedRows)) records"
        return "Not in any task: \(figure(report.untasked, exact: false)) tokens in \(turns), from agents no one prompted here. Not counted above."
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
