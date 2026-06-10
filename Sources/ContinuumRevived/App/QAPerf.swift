import AppKit
import ContinuumRevivedCore
import Foundation
import QuartzCore

@MainActor
final class QAPerf {
    struct Baseline: Codable {
        var metrics: [String: MetricBaseline]
    }

    struct MetricBaseline: Codable {
        var limit: Double
        var unit: String
        var comparison: Comparison
    }

    enum Comparison: String, Codable {
        case lessThanOrEqual
    }

    struct Report: Codable {
        var flow: String
        var generatedAt: Date
        var metrics: [Metric]
        var findings: [Finding]
    }

    struct Metric: Codable {
        var key: String
        var value: Double
        var unit: String
        var samples: [Double]?
        var p50: Double?
        var p95: Double?
        var p99: Double?
    }

    struct Finding: Codable {
        var title: String
        var metric: String
        var value: Double
        var limit: Double
        var unit: String
    }

    private let outputDirectory: URL
    private let flowName: String
    private let baseline: Baseline
    private let fileManager: FileManager
    private var metrics: [Metric] = []
    private var findings: [Finding] = []

    init?(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        guard let rawOutput = environment["CONTINUUM_QA_PERF"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOutput.isEmpty
        else {
            return nil
        }

        self.outputDirectory = URL(fileURLWithPath: rawOutput, isDirectory: true)
        let rawFlow = environment["CONTINUUM_QA_FLOW"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.flowName = rawFlow.flatMap { $0.isEmpty ? nil : $0 } ?? "default-smoke"
        self.fileManager = fileManager

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let baselineURL = Self.baselineURL(environment: environment)
            self.baseline = try Self.loadBaseline(from: baselineURL)
        } catch {
            fputs("QA perf setup failed: \(error)\n", stderr)
            return nil
        }
    }

    static func timestamp() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), integerPointer, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info MACH_TASK_BASIC_INFO failed")
        return UInt64(info.resident_size)
    }

    static func percentile(_ samples: [Double], _ percentile: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = min(max(percentile, 0), 100)
        let rank = (clamped / 100) * Double(sorted.count - 1)
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        if lower == upper {
            return sorted[lower]
        }
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    func recordValue(key: String, value: Double, unit: String) {
        record(Metric(key: key, value: value, unit: unit, samples: nil, p50: nil, p95: nil, p99: nil))
    }

    func recordSamples(key: String, samples: [Double], unit: String) {
        guard let value = Self.percentile(samples, 95) else { return }
        record(Metric(
            key: key,
            value: value,
            unit: unit,
            samples: samples,
            p50: Self.percentile(samples, 50),
            p95: value,
            p99: Self.percentile(samples, 99)
        ))
    }

    func writeReport() {
        let report = Report(flow: flowName, generatedAt: Date(), metrics: metrics, findings: findings)
        let encoder = JSONCodec.makeEncoder(prettyPrinted: true)
        encoder.dateEncodingStrategy = .iso8601
        let reportURL = outputDirectory.appendingPathComponent("perf-report.json", isDirectory: false)
        do {
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            try writeFindings()
        } catch {
            fputs("QA perf report write failed: \(error)\n", stderr)
        }
    }

    private func record(_ metric: Metric) {
        metrics.removeAll { $0.key == metric.key }
        metrics.append(metric)
        if let finding = Self.finding(for: metric, baseline: baseline) {
            findings.removeAll { $0.metric == metric.key }
            findings.append(finding)
        }
    }

    private func writeFindings() throws {
        guard !findings.isEmpty else { return }
        let findingsDirectory = outputDirectory.appendingPathComponent("findings", isDirectory: true)
        try fileManager.createDirectory(at: findingsDirectory, withIntermediateDirectories: true)
        for finding in findings {
            let body = """
            [qa-finding][major] \(finding.title)

            metric: \(finding.metric)
            value: \(finding.value) \(finding.unit)
            limit: \(finding.limit) \(finding.unit)
            flow: \(flowName)
            """
            let url = findingsDirectory.appendingPathComponent("\(Self.slug(finding.metric)).md", isDirectory: false)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func finding(for metric: Metric, baseline: Baseline) -> Finding? {
        guard let expected = baseline.metrics[metric.key] else { return nil }
        switch expected.comparison {
        case .lessThanOrEqual:
            guard metric.value > expected.limit else { return nil }
        }
        return Finding(
            title: "\(metric.key) exceeded perf baseline",
            metric: metric.key,
            value: metric.value,
            limit: expected.limit,
            unit: expected.unit
        )
    }

    static func loadBaseline(from url: URL) throws -> Baseline {
        let data = try Data(contentsOf: url)
        return try JSONCodec.makeDecoder().decode(Baseline.self, from: data)
    }

    private static func baselineURL(environment: [String: String]) -> URL {
        if let override = environment["CONTINUUM_QA_PERF_BASELINE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("qa/perf-baseline.json", isDirectory: false)
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "metric" : collapsed
    }
}
