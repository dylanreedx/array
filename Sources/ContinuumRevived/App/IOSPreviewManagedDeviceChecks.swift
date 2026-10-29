import Foundation
import ContinuumRevivedCore

@MainActor
enum IOSPreviewManagedDeviceChecks {
    private struct Failure: Error { let message: String }
    private actor Commands {
        let borrowed = UUID().uuidString
        var devices: Set<String> = []
        var created = 0
        var deleted: [String] = []
        init() { devices.insert(borrowed) }
        func run(_ argv: [String]) throws -> Data {
            guard argv.prefix(2) == ["/usr/bin/xcrun", "simctl"], argv.count >= 3 else { throw Failure(message: "untyped simulator command") }
            switch argv[2] {
            case "list": return try JSONSerialization.data(withJSONObject: ["devices": ["iOS": devices.map { ["udid": $0] }]])
            case "create":
                let id = UUID().uuidString; devices.insert(id); created += 1; return Data((id + "\n").utf8)
            case "shutdown": return Data()
            case "delete":
                guard argv.count == 4, devices.contains(argv[3]), argv[3] != borrowed else { throw Failure(message: "attempt to delete unknown/borrowed simulator") }
                devices.remove(argv[3]); deleted.append(argv[3]); return Data()
            default: throw Failure(message: "unsupported simulator command")
            }
        }
        func count() -> Int { created }
        func deletedIDs() -> [String] { deleted }
        func removeExternally(_ id: String) { devices.remove(id) }
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-managed-device-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("managed.json"), commands = Commands()
        let pool = IOSPreviewManagedDevices(fileURL: file, command: { try await commands.run($0) })
        let scope = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: UUID(), checkout: CheckoutHandle.derive(canonicalRoot: root.path))
        let template = IOSPreviewDeviceTemplate(typeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        let first = try await pool.create(template: template, scope: scope)
        let second = try await pool.create(template: template, scope: scope)
        do { _ = try await pool.create(template: template, scope: scope); throw Failure(message: "per-agent inventory cap ignored") }
        catch let error as WorkspaceAPIError { try expect(error.code == .busy, "inventory limit has wrong error") }
        try expect(await commands.count() == 2, "rejected creation must perform zero simulator creates")
        let restored = IOSPreviewManagedDevices(fileURL: file, command: { try await commands.run($0) })
        try expect(try await restored.isOwned(deviceID: first, scope: scope), "ownership receipt must survive host restart")
        let foreign = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: scope.project, checkout: scope.checkout)
        try expect(try await !restored.isOwned(deviceID: first, scope: foreign), "foreign principal cannot adopt a receipt")
        let borrowed = await commands.borrowed
        do { try await restored.discard(deviceID: borrowed, scope: scope); throw Failure(message: "borrowed device deletion admitted") }
        catch is IOSPreviewAutomationSessions.Failure {}
        try expect(await commands.deletedIDs().isEmpty, "borrowed UUID must issue zero delete commands")
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                let other = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: scope.project, checkout: scope.checkout)
                group.addTask { try await pool.create(template: template, scope: other) }
            }
            for try await _ in group {}
        }
        let ninth = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: scope.project, checkout: scope.checkout)
        do { _ = try await pool.create(template: template, scope: ninth); throw Failure(message: "global inventory cap ignored") }
        catch let error as WorkspaceAPIError { try expect(error.code == .busy, "global limit has wrong error") }
        try expect(await commands.count() == 8, "concurrent creation must not oversubscribe global inventory")
        await commands.removeExternally(second)
        _ = try await pool.create(template: template, scope: scope)
        try expect(await commands.count() == 9, "Xcode-deleted device must release an inventory slot")
        try await pool.discard(deviceID: first, scope: scope)
        try expect(await commands.deletedIDs() == [first], "cleanup must target only the exact receipt-owned device")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        try expect(permissions.intValue == 0o600, "ownership receipts must stay private to the user")
        let corruptFile = root.appendingPathComponent("corrupt.json")
        let corrupt = Data("{not valid JSON".utf8)
        try corrupt.write(to: corruptFile)
        let invalid = IOSPreviewManagedDevices(fileURL: corruptFile, command: { try await commands.run($0) })
        do { _ = try await invalid.create(template: template, scope: scope); throw Failure(message: "corrupt ownership state was ignored") }
        catch let error as WorkspaceAPIError { try expect(error.code == .durabilityFailed, "corrupt ownership must fail closed") }
        let finalCount = await commands.count()
        try expect(try Data(contentsOf: corruptFile) == corrupt && finalCount == 9,
            "unreadable receipts must remain untouched and cause zero creates")
        print("IOSPreviewManagedDeviceChecks passed: fresh owned creation, durable scoped receipts, two/eight inventory bounds under concurrency, borrowed deletion denied, exact cleanup and external deletion recovery")
    }
}
