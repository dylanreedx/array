import Foundation
import ContinuumRevivedRelayProtocol

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let event = RelayEvent(sequence: 42, kind: "agent.status", payload: Data("working".utf8))
let frame = RelaySocketFrame.event(event)
guard case .event(let decoded) = try decoder.decode(RelaySocketFrame.self, from: encoder.encode(frame)), decoded.sequence == event.sequence, decoded.kind == event.kind, decoded.payload == event.payload else { fatalError("frame round trip") }
guard !RelayWire.companionCapabilities.contains(.publishState), RelayWire.companionCapabilities.contains(.stopAgents) else { fatalError("fixed capabilities") }
print("ContinuumRevivedRelayProtocolChecks passed")
