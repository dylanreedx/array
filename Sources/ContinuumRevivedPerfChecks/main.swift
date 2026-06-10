import Foundation

struct Baseline: Decodable {
    struct Metric: Decodable {
        var limit: Double
        var unit: String
        var comparison: String
    }

    var metrics: [String: Metric]
}

struct Finding {
    var title: String
    var metric: String
    var value: Double
    var limit: Double
    var unit: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func percentile(_ samples: [Double], _ percentile: Double) -> Double? {
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

func finding(metric: String, value: Double, baseline: Baseline) -> Finding? {
    guard let expected = baseline.metrics[metric] else { return nil }
    guard expected.comparison == "lessThanOrEqual" else {
        fputs("FAIL: unsupported comparison \(expected.comparison)\n", stderr)
        Foundation.exit(1)
    }
    guard value > expected.limit else { return nil }
    return Finding(
        title: "\(metric) exceeded perf baseline",
        metric: metric,
        value: value,
        limit: expected.limit,
        unit: expected.unit
    )
}

let baselineURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("qa/perf-baseline.json", isDirectory: false)
let data = try Data(contentsOf: baselineURL)
let baseline = try JSONDecoder().decode(Baseline.self, from: data)
let requiredKeys = Set(["launch-time", "drag-latency-p95", "memory-at-10-tiles", "palette-leak-delta"])

expect(Set(baseline.metrics.keys) == requiredKeys, "perf baseline should contain exactly the required metric keys")
expect(baseline.metrics.values.allSatisfy { $0.comparison == "lessThanOrEqual" }, "all baseline metrics use lessThanOrEqual comparison")
expect(percentile([1, 2, 3, 4, 5], 95) == 4.8, "p95 percentile should interpolate samples")

let forced = finding(metric: "drag-latency-p95", value: 999, baseline: baseline)
expect(forced?.title.contains("[qa-finding]") == false, "finding title should not duplicate task prefix")
expect(forced?.metric == "drag-latency-p95", "forced regression should produce a drag finding")
expect(finding(metric: "drag-latency-p95", value: 1, baseline: baseline) == nil, "passing metric should not produce a finding")

print("ContinuumRevivedPerfChecks passed")
