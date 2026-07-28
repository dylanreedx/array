import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/86-relay-sync-transport.md (slice 2, milestone A)
//
// The relay process. Dev loop today: run on the Mac (localhost for the sim,
// LAN address for the phone leg); slice 3 moves this same process to the VPS
// behind TLS. Tokens: the operator token authorizes the Mac's publish leg
// and lets it register phone pairing tokens at runtime via POST /v1/tokens.
//
//   CONTINUUM_RELAY_OPERATOR_TOKEN=<secret> continuum-relay --port 8787
//                   [--host 0.0.0.0] [--observer-token <secret>]…
// `--operator-token` remains accepted for compatibility, but the managed dev
// service uses the environment so credentials never appear in argv.

var host = "127.0.0.1"
var port: UInt16 = 8787
var operatorToken = ProcessInfo.processInfo.environment["CONTINUUM_RELAY_OPERATOR_TOKEN"]
var observerTokens: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
let logTimestamp: @Sendable () -> String = {
    ISO8601DateFormatter().string(from: Date())
}
func writeLine(_ message: String, to handle: FileHandle) {
    handle.write(Data("\(logTimestamp()) continuum-relay: \(message)\n".utf8))
}
func fail(_ message: String) -> Never {
    // FileHandle writes immediately even when launchd redirects the descriptor.
    writeLine(message, to: .standardError)
    exit(2)
}
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(flag) needs a value") }
        return arguments.removeFirst()
    }
    switch flag {
    case "--host": host = value()
    case "--port":
        guard let parsed = UInt16(value()) else { fail("--port must be 0-65535") }
        port = parsed
    case "--operator-token": operatorToken = value()
    case "--observer-token": observerTokens.append(value())
    case "--help", "-h":
        writeLine("usage: CONTINUUM_RELAY_OPERATOR_TOKEN=T continuum-relay [--host H] [--port P] [--observer-token T]…", to: .standardOutput)
        exit(0)
    default: fail("unknown flag \(flag)")
    }
}
guard let operatorToken, !operatorToken.isEmpty else {
    fail("an operator token is required (--operator-token or CONTINUUM_RELAY_OPERATOR_TOKEN)")
}

var seed: [String: RelayGrant] = [operatorToken: RelayGrant(scopes: .operator)]
for token in observerTokens {
    seed[token] = RelayGrant(scopes: .observer)
}

let registry = RelayTokenRegistry(seed: seed)
let hub = RelayHub { token in await registry.grant(for: token) }
let server = RelayHTTPServer(hub: hub, registry: registry, bindHost: host, port: port)
do {
    try server.start()
} catch {
    fail("could not start: \(error)")
}
// Never log even a token prefix: a readiness line is operational evidence and
// must be safe to retain or paste into a bug report.
writeLine("ready url=http://\(host):\(server.port) observerTokens=\(observerTokens.count)", to: .standardOutput)
dispatchMain()
