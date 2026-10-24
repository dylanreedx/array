import AppKit
import ContinuumRevivedCore

/// Behavioral checks drive the actual renderer, with a deterministic huge source
/// that records requested projections. No generated million-cell fixture or sleeps.
@MainActor
enum DelimitedGridChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    private final class Source: FileGridDataSource, @unchecked Sendable {
        let rowCount: Int
        let columnCount: Int
        let encodingName = "Exact text"
        private let lock = NSLock()
        private var requests: [(Range<Int>, Range<Int>)] = []
        init(rows: Int, columns: Int) { rowCount = rows; columnCount = columns }
        var readRequests: [(Range<Int>, Range<Int>)] { lock.lock(); defer { lock.unlock() }; return requests }
        func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]] {
            let columns = columns ?? 0..<columnCount
            lock.lock(); requests.append((range, columns)); lock.unlock()
            return range.map { row in columns.map { column in
                if row == 2, column == 1 { return "00123" }
                if row == 3, column == 1 { return "line\n\"quoted\"" }
                if row == 511, column == 40 { return "needle" }
                return "r\(row)c\(column)"
            } }
        }
    }

    private actor WorkGate {
        private var held: [CheckedContinuation<Void, Never>] = []
        var count: Int { held.count }
        func wait() async { await withCheckedContinuation { held.append($0) } }
        func releaseAll() { let pending = held; held.removeAll(); pending.forEach { $0.resume() } }
    }
    private static func eventually(_ predicate: () async -> Bool, _ message: String) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw Failure(description: message)
    }
    private static func schedulerChecks() async throws {
        let scheduler = FileGridWorkScheduler.shared, gate = WorkGate()
        let first = Task { try await scheduler.run { await gate.wait(); try Task.checkCancellation(); return 1 } }
        let second = Task { try await scheduler.run { await gate.wait(); return 2 } }
        // Always release blocked workers even if a check throws; a failure must
        // not leave the test process holding scheduler permits.
        defer { first.cancel(); second.cancel(); Task { await gate.releaseAll() } }
        try await eventually({ await gate.count == 2 }, "shared scheduler did not admit two workers")
        let cancelled = Task { try await scheduler.run { throw Failure(description: "cancelled queued work executed") } as Int }
        defer { cancelled.cancel() }
        try await eventually({ await scheduler.qaCounts.queued == 1 }, "third worker was not queued")
        cancelled.cancel()
        try await eventually({ await scheduler.qaCounts.queued == 0 }, "cancelled queued work kept its permit request")
        do { _ = try await cancelled.value; throw Failure(description: "queued cancellation succeeded") }
        catch is CancellationError { }
        let next = Task { try await scheduler.run { 4 } }
        defer { next.cancel() }
        try await eventually({ await scheduler.qaCounts.queued == 1 }, "replacement worker was not queued")
        first.cancel()
        let counts = await scheduler.qaCounts
        try expect(counts.active == 2 && counts.queued == 1 && counts.peak == 2,
                   "cancellation released resources before admitted work exited, or exceeded two workers")
        await gate.releaseAll()
        do { _ = try await first.value; throw Failure(description: "active cancellation was lost") }
        catch is CancellationError { }
        _ = try await second.value
        let final = try await next.value
        try expect(final == 4, "queued replacement did not execute after release")
        try await eventually({ await scheduler.qaCounts.active == 0 }, "scheduler leaked an active permit")
    }

    static func run() async throws {
        _ = NSApplication.shared
        try await schedulerChecks()
        // Sparse search visits three stored cells, never the 1,048,576 ×
        // 16,384 bounding rectangle. Exact row-major wrapping is deterministic.
        let sparse = [("XFD1048576", "needle end"), ("B1", "needle start"), ("C500000", "needle middle")]
        let far = try WorkbookGridSource.nextSparseMatch(query: "needle", afterRow: 499_999, column: 2, cells: sparse)
        try expect(far == FileGridMatch(row: 1_048_575, column: 16_383), "sparse workbook search did not select the next stored cell")
        let wrapped = try WorkbookGridSource.nextSparseMatch(query: "needle", afterRow: 1_048_575, column: 16_383, cells: sparse)
        try expect(wrapped == FileGridMatch(row: 0, column: 1), "sparse workbook search did not wrap in row-major order")
        let source = Source(rows: 100_000, columns: 100_000)
        let renderer = DelimitedGridRenderer(source: source, title: "Scaling", allowsHeaderChoice: true)
        defer { renderer.dispose() }
        renderer.qaLayout(size: NSSize(width: 640, height: 420))
        await renderer.qaWaitForIdle()
        try expect(renderer.qaCachedPageCount <= 8 && renderer.qaCachedBytes <= 4 * 1_024 * 1_024, "grid cache exceeds its count or payload cap")
        for style in [NSScroller.Style.legacy, .overlay] {
            renderer.qaSetScrollerStyle(style)
            renderer.qaLayout(size: NSSize(width: 640, height: 420))
            await renderer.qaWaitForIdle()
            let settledReads = renderer.qaPageReadCount
            for _ in 0..<20 { renderer.qaLayout(size: NSSize(width: 640, height: 420)) }
            await renderer.qaWaitForIdle()
            try expect(renderer.qaPageReadCount == settledReads, "unchanged layout scheduled new data reads")
            try expect(renderer.qaCachedPageCount <= 8, "scroller style exceeded the working-set cap")
        }
        try expect(source.readRequests.allSatisfy { $0.0.count <= 64 && $0.1.count <= 16 }, "viewport read did not project both axes")
        renderer.qaSelect(row: 2, column: 1)
        await renderer.qaWaitForIdle()
        try expect(renderer.qaSelectedValue == "00123", "selection inferred a numeric value")
        renderer.qaSelect(row: 3, column: 1, extending: true)
        renderer.qaCopySelection()
        await renderer.qaWaitForIdle()
        try expect(renderer.qaCopiedTSV == "00123\n\"line\n\"\"quoted\"\"\"", "rectangle copy lost exact text or TSV quoting")
        renderer.qaSelect(row: 90_000, column: 80_000)
        await renderer.qaWaitForIdle()
        try expect(renderer.qaSelectedValue == "r90000c80000", "horizontal or vertical page offset is incorrect")
        try expect(renderer.qaCachedPageCount <= 8 && renderer.qaCachedBytes <= 4 * 1_024 * 1_024, "far navigation exceeded cache caps")
        let before = renderer.qaPageReadCount
        renderer.setVisible(false)
        renderer.qaSelect(row: 99_999, column: 99_999)
        await renderer.qaWaitForIdle()
        try expect(renderer.qaPageReadCount == before, "suspended grid read another page")
        renderer.setVisible(true)
        await renderer.qaWaitForIdle()
        try expect(renderer.qaSelectedValue == "r99999c99999", "resume did not refresh selected cell")

        let searchable = Source(rows: 512, columns: 48)
        let finder = DelimitedGridRenderer(source: searchable, title: "Find")
        defer { finder.dispose() }
        finder.qaLayout(size: NSSize(width: 640, height: 420))
        finder.findNext(query: "needle")
        await finder.qaWaitForIdle()
        try expect(finder.qaSelectedValue == "needle" && finder.qaStatus.contains("Whole file"), "find did not reach a cell beyond the initial page")
        finder.findNext(query: "missing")
        finder.setVisible(false)
        await finder.qaWaitForIdle()
        try expect(!finder.qaIsFinding, "suspending did not cancel whole-file search")
        finder.dispose()
        try expect(finder.qaCachedPageCount == 0 && finder.qaCachedBytes == 0, "dispose retained projected pages")
        print("DelimitedGridChecks passed: exact selection/copy, two-axis projection, bounded cache, far navigation, suspension, whole-file find, sparse workbook search, shared two-worker admission/cancellation and disposal")
    }
}
