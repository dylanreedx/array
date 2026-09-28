import Foundation

/// The one door every durable mutation `WorkspaceStore` and `ProjectStore` make
/// goes through.
///
/// Production installs nothing, and `perform` is a direct call. A QA leg installs
/// a `Plan` scoped to its own temp directory and can then make the Nth write
/// fail, make every write from the Nth fail, or abort after the Nth: writes
/// 1...N land and every later mutation is dropped, which is exactly what a
/// process killed after its Nth write leaves on disk. The leg then remounts a
/// fresh runtime on the same directories and reads what survived.
///
/// Process-global on purpose. Production constructs a `ProjectStore` at ~90
/// call sites; a writer threaded through initializers would miss precisely the
/// ones a leg most needs to see.
public enum StoreFileWriter {
    public enum Mutation: String, Sendable, Equatable {
        case write
        case remove
    }

    public enum Outcome: String, Sendable, Equatable {
        /// The mutation reached disk.
        case landed
        /// The caller was handed an `InjectedFailure`; disk is untouched.
        case failed
        /// The caller was told it succeeded; disk is untouched (post-abort).
        case dropped
    }

    public struct Entry: Sendable, Equatable, CustomStringConvertible {
        public let index: Int
        public let mutation: Mutation
        public let path: String
        public let outcome: Outcome

        public var description: String { "#\(index) \(mutation.rawValue) \(outcome.rawValue) \(path)" }
    }

    public enum Fault: Sendable, Equatable {
        /// Record only.
        case none
        /// Only the Nth counted mutation (1-based) throws.
        case failWrite(Int)
        /// The Nth and every later counted mutation throws.
        case failFrom(Int)
        /// Mutations 1...N land; every later one is silently dropped.
        case abortAfter(Int)
        /// The Nth counted mutation waits `seconds` on its caller's thread, then
        /// lands: a blocked I/O queue. The gate's lock is not held while it waits.
        case delayWrite(Int, seconds: Double)
    }

    public struct Plan: Sendable {
        public let fault: Fault
        /// Only mutations under this directory are counted, traced or faulted.
        public let scope: URL
        /// Narrows the counted mutations further (e.g. one store's canvas file).
        public let matching: @Sendable (URL) -> Bool

        public init(fault: Fault, scope: URL, matching: @escaping @Sendable (URL) -> Bool = { _ in true }) {
            self.fault = fault
            self.scope = scope
            self.matching = matching
        }
    }

    public struct InjectedFailure: Error, Equatable, CustomStringConvertible {
        public let index: Int
        public let path: String
        public var description: String { "StoreFileWriter: injected failure of mutation #\(index) at \(path)" }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var plan: Plan?
        var scopePath = ""
        var count = 0
        var trace: [Entry] = []
    }

    private static let state = State()

    /// Install `plan`, resetting the count and the trace.
    public static func install(_ plan: Plan) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.plan = plan
        state.scopePath = canonicalPath(plan.scope)
        state.count = 0
        state.trace = []
    }

    /// Remove the plan and return the trace it recorded.
    @discardableResult
    public static func uninstall() -> [Entry] {
        state.lock.lock()
        defer { state.lock.unlock() }
        let trace = state.trace
        state.plan = nil
        state.scopePath = ""
        state.count = 0
        state.trace = []
        return trace
    }

    public static var trace: [Entry] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.trace
    }

    static func perform(_ mutation: Mutation, at url: URL, _ body: () throws -> Void) throws {
        state.lock.lock()
        guard let plan = state.plan else {
            state.lock.unlock()
            try body()
            return
        }
        let path = canonicalPath(url)
        guard path.hasPrefix(state.scopePath + "/"), plan.matching(url) else {
            state.lock.unlock()
            try body()
            return
        }
        state.count += 1
        let index = state.count
        let verdict: Outcome
        var delay: Double = 0
        switch plan.fault {
        case .none: verdict = .landed
        case let .failWrite(n): verdict = index == n ? .failed : .landed
        case let .failFrom(n): verdict = index >= n ? .failed : .landed
        case let .abortAfter(n): verdict = index > n ? .dropped : .landed
        case let .delayWrite(n, seconds):
            verdict = .landed
            if index == n { delay = seconds }
        }
        if delay > 0 {
            state.lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            state.lock.lock()
        }
        // Held across the mutation so the trace order is the disk order.
        defer { state.lock.unlock() }
        switch verdict {
        case .landed:
            try body()
            state.trace.append(Entry(index: index, mutation: mutation, path: path, outcome: .landed))
        case .failed:
            state.trace.append(Entry(index: index, mutation: mutation, path: path, outcome: .failed))
            throw InjectedFailure(index: index, path: path)
        case .dropped:
            state.trace.append(Entry(index: index, mutation: mutation, path: path, outcome: .dropped))
        }
    }

    /// Temp directories come back as `/var/...` from one API and
    /// `/private/var/...` from another. Symlink resolution cannot be used: a
    /// write's parent directory may not exist yet.
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
