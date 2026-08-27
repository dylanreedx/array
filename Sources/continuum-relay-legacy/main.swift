import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

var host = "127.0.0.1", port: UInt16 = 8787
var operatorToken = ProcessInfo.processInfo.environment["CONTINUUM_RELAY_OPERATOR_TOKEN"]
var observerTokens: [String] = []
var arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("continuum-relay-legacy: \(message)\n".utf8)); exit(2) }
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String { guard !arguments.isEmpty else { fail("\(flag) needs a value") }; return arguments.removeFirst() }
    switch flag {
    case "--host": host = value()
    case "--port": guard let parsed = UInt16(value()) else { fail("invalid port") }; port = parsed
    case "--operator-token": operatorToken = value()
    case "--observer-token": observerTokens.append(value())
    default: fail("unknown flag \(flag)")
    }
}
guard let operatorToken, !operatorToken.isEmpty else { fail("CONTINUUM_RELAY_OPERATOR_TOKEN is required") }
var seed = [operatorToken: RelayGrant(scopes: .operator)]
for token in observerTokens { seed[token] = RelayGrant(scopes: .observer) }
let registry = RelayTokenRegistry(seed: seed)
let hub = RelayHub { token in await registry.grant(for: token) }
let server = RelayHTTPServer(hub: hub, registry: registry, bindHost: host, port: port)
do { try server.start() } catch { fail("could not start: \(error)") }
FileHandle.standardOutput.write(Data("continuum-relay-legacy: ready url=http://\(host):\(server.port)\n".utf8))
dispatchMain()
