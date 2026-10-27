import Foundation

public enum AgentContextWindowResolutionSource: String, Codable, Sendable {
    case provider, remembered, catalog, bundled, unknown
    /// Persisted readings from before every harness had the catalogue rung.
    case piStore
}

public struct AgentContextWindowResolution: Equatable, Sendable {
    public let tokens: Int?
    public let source: AgentContextWindowResolutionSource
    public let model: String
    public init(tokens: Int?, source: AgentContextWindowResolutionSource, model: String) {
        self.tokens = tokens; self.source = source; self.model = model
    }
}

/// One denominator ladder for every harness. Remembered provider answers are
/// app-scoped and keyed by harness and exact model, never a family guess.
/// `catalog` is the window the harness's OWN CLI publishes for the model
/// (Codex's models_cache.json, pi's models-store.json). It ranks above the
/// bundled table: that table is a dated copy of those same files, so a model
/// the CLI ships after the table was cut (gpt-6.1-terra) would otherwise read
/// as unknown, and a window the CLI raised (gpt-6.1-sol, 272K → 500K) would
/// read stale. Callers pass only the record's own harness's catalogue.
public final class AgentContextWindowResolver: @unchecked Sendable {
    private final class SharedMemory: @unchecked Sendable {
        let lock = NSLock()
        var stores: [String: [String: Int]] = [:]
        var unknownReports: [String: Set<String>] = [:]
    }
    private static let sharedMemory = SharedMemory()
    private let lock = NSLock()
    private let fileURL: URL?
    private let bundled: [String: Int]
    private var remembered: [String: Int]
    private var unknownReported: Set<String> = []

    public init(applicationSupportDirectory: URL? = nil, bundledWindows: [String: Int]? = nil) {
        fileURL = applicationSupportDirectory?.appendingPathComponent("context-windows.json")
        bundled = bundledWindows ?? Self.bundledWindows()
        if let fileURL {
            remembered = Self.sharedMemory.lock.withLock {
                if let loaded = Self.sharedMemory.stores[fileURL.path] { return loaded }
                let loaded = Self.load(fileURL)
                Self.sharedMemory.stores[fileURL.path] = loaded
                return loaded
            }
        } else { remembered = [:] }
    }

    public func resolve(harness: AgentHarness, model: String, stated: Int? = nil,
                        legacyRemembered: Int? = nil, catalog: Int? = nil) -> AgentContextWindowResolution {
        lock.withLock {
            let key = harness.rawValue + ":" + model
            func result(_ value: Int?, _ source: AgentContextWindowResolutionSource) -> AgentContextWindowResolution {
                AgentContextWindowResolution(tokens: value, source: source, model: model)
            }
            // Shared memory is refreshed by other resolver instances when they
            // observe a provider value. Streaming updates do not read disk.
            if let fileURL {
                remembered = Self.sharedMemory.lock.withLock { Self.sharedMemory.stores[fileURL.path] ?? remembered }
            }
            func remember(_ value: Int) {
                guard remembered[key] != value else { return }
                remembered[key] = value
                guard let fileURL else { return }
                Self.sharedMemory.lock.withLock {
                    var shared = Self.sharedMemory.stores[fileURL.path] ?? [:]
                    shared[key] = value
                    Self.sharedMemory.stores[fileURL.path] = shared
                    remembered = shared
                    if let data = try? JSONEncoder().encode(shared) {
                        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: fileURL, options: .atomic)
                    }
                }
            }
            if let stated, stated > 0 {
                remember(stated)
                return result(stated, .provider)
            }
            if let value = remembered[key], value > 0 { return result(value, .remembered) }
            if let value = legacyRemembered, value > 0 {
                remember(value)
                return result(value, .remembered)
            }
            if let value = catalog, value > 0 { return result(value, .catalog) }
            if let value = bundled[model], value > 0 { return result(value, .bundled) }
            return result(nil, .unknown)
        }
    }

    /// Startup and checks use exactly the same resolver as live telemetry.
    public func unresolvedModels(in catalogs: [AgentHarnessCatalogSnapshot]) -> [String] {
        catalogs.flatMap { catalog in
            catalog.models.compactMap { model in
                resolve(harness: catalog.harness, model: model,
                        catalog: catalog.contextWindows[model]).tokens == nil
                    ? "\(catalog.harness.rawValue):\(model)" : nil
            }
        }
    }

    /// True once for a model in this app lifetime, so repeated stream frames
    /// cannot flood the log or user notices.
    public func shouldReportUnknown(harness: AgentHarness, model: String) -> Bool {
        lock.withLock {
            let key = harness.rawValue + ":" + model
            if let fileURL {
                return Self.sharedMemory.lock.withLock {
                    Self.sharedMemory.unknownReports[fileURL.path, default: []].insert(key).inserted
                }
            }
            return unknownReported.insert(key).inserted
        }
    }

    private static func load(_ url: URL?) -> [String: Int] {
        guard let url, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return values.filter { $0.value > 0 }
    }

    public static func bundledWindows() -> [String: Int] {
        let name = "continuum-revived_ContinuumRevivedCore.bundle"
        let roots = [Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let values = load(root.appendingPathComponent(name).appendingPathComponent("ContextWindows.json"))
            if !values.isEmpty { return values }
        }
        return [:]
    }
}
