import Foundation
import CryptoKit
import ContinuumRevivedCore

struct IOSPreviewDeviceTemplate: Equatable, Sendable {
    let typeIdentifier: String
    let runtime: String
    var id: String {
        "sim_template_" + SHA256.hash(data: Data((runtime + "\n" + typeIdentifier).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    var name: String { (typeIdentifier.split(separator: ".").last.map(String.init) ?? "iOS").replacingOccurrences(of: "-", with: " ") }
}

/// Receipts prove which devices this host created. Never adopts, erases or
/// deletes a simulator on the strength of a model's UUID or a matching name.
actor IOSPreviewManagedDevices {
    static let shared = IOSPreviewManagedDevices()
    struct Receipt: Codable, Sendable {
        let deviceID: String
        let principal: UUID
        let project: UUID
        let checkout: CheckoutHandle
        let templateID: String
        let createdAt: Date
    }
    private let overrideFile: URL?
    private let command: @Sendable ([String]) async throws -> Data
    init(fileURL: URL? = nil, command: @escaping @Sendable ([String]) async throws -> Data = { try await IOSPreviewCommands.run($0) }) {
        overrideFile = fileURL; self.command = command
    }
    private var loaded = false
    private var receipts: [String: Receipt] = [:]
    private var pending: [UUID: Int] = [:]
    private var file: URL {
        if let overrideFile { return overrideFile }
        let base = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"].map { URL(fileURLWithPath: $0) }
            ?? RegistryStore.defaultApplicationSupportDirectory()
        return base.appendingPathComponent("DeveloperTools/iOSPreview/managed-devices.json")
    }
    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let decoded = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: file))
                guard decoded.allSatisfy({ key, receipt in key == receipt.deviceID && UUID(uuidString: key) != nil }) else {
                    throw IOSPreviewObservation.Failure.invalidFrame
                }
                receipts = decoded
            } catch {
                throw WorkspaceAPIError(code: .durabilityFailed, message: "Managed simulator ownership state is unreadable. No existing device was adopted or deleted.")
            }
        }
        loaded = true
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Prunes only receipts whose devices simctl proves are gone. A catalogue
    /// captured before another creation cannot remove that newer receipt.
    private func refresh() async throws {
        let candidates = Set(receipts.keys)
        let bytes = try await command(["/usr/bin/xcrun", "simctl", "list", "devices", "--json"])
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let groups = root["devices"] as? [String: [[String: Any]]] else { throw IOSPreviewObservation.Failure.unavailable }
        let existing = Set(groups.values.flatMap { $0 }.compactMap { $0["udid"] as? String })
        var changed = false
        for id in candidates where !existing.contains(id) { receipts[id] = nil; changed = true }
        if changed { try save() }
    }
    func create(template: IOSPreviewDeviceTemplate, scope: IOSPreviewAutomationSessions.Scope) async throws -> String {
        try load()
        guard template.typeIdentifier.hasPrefix("com.apple.CoreSimulator.SimDeviceType."),
              template.runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") else { throw IOSPreviewObservation.Failure.unavailable }
        guard pending[scope.principal, default: 0] == 0 else { throw IOSPreviewAutomationSessions.Failure.busy }
        pending[scope.principal, default: 0] += 1
        defer {
            let remaining = pending[scope.principal, default: 1] - 1
            if remaining == 0 { pending[scope.principal] = nil } else { pending[scope.principal] = remaining }
        }
        try await refresh()
        guard receipts.count + pending.values.reduce(0, +) <= 8,
              receipts.values.filter({ $0.principal == scope.principal }).count + pending[scope.principal, default: 0] <= 2 else {
            throw WorkspaceAPIError(code: .busy, message: "Managed simulator budget reached (2 per agent, 8 per app). Reopen an owned tile, or remove unused Array Agent devices in Xcode to free capacity.")
        }
        let bytes = try await command(["/usr/bin/xcrun", "simctl", "create", "Array Agent " + String(UUID().uuidString.prefix(8)), template.typeIdentifier, template.runtime])
        let id = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw IOSPreviewObservation.Failure.unavailable }
        receipts[id] = Receipt(deviceID: id, principal: scope.principal, project: scope.project,
            checkout: scope.checkout, templateID: template.id, createdAt: Date())
        do { try save() }
        catch {
            // Only the exact device just returned by our own successful create.
            _ = try? await command(["/usr/bin/xcrun", "simctl", "delete", id])
            receipts[id] = nil
            throw error
        }
        return id
    }
    func owned(scope: IOSPreviewAutomationSessions.Scope) throws -> [Receipt] {
        try load()
        return receipts.values.filter { $0.principal == scope.principal && $0.project == scope.project && $0.checkout == scope.checkout }
    }
    func isOwned(deviceID: String, scope: IOSPreviewAutomationSessions.Scope) throws -> Bool {
        try owned(scope: scope).contains { $0.deviceID == deviceID }
    }
    func discard(deviceID: String, scope: IOSPreviewAutomationSessions.Scope) async throws {
        try load()
        guard let receipt = receipts[deviceID], receipt.principal == scope.principal,
              receipt.project == scope.project, receipt.checkout == scope.checkout else { throw IOSPreviewAutomationSessions.Failure.notOwned }
        _ = try? await command(["/usr/bin/xcrun", "simctl", "shutdown", deviceID])
        _ = try await command(["/usr/bin/xcrun", "simctl", "delete", deviceID])
        receipts[deviceID] = nil; try save()
    }
}
