import Foundation
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-relay-integration-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let store = try RelayStore(path: directory.appendingPathComponent("db.sqlite").path, masterKey: Data(repeating: 9, count: 32))
let server = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0))
try await server.start()
try await server.stop()
print("ContinuumRevivedRelayIntegrationChecks passed: public/admin NIO listeners bind and shut down")
