import ContinuumRevivedRelayProtocol
import XCTest
@testable import Continuum

final class HostedPairingPolicyTests: XCTestCase {
    func testProductionRelayIsPinnedAndPathsAreRemoved() {
        XCTAssertEqual(
            HostedPairingPolicy.relayHTTPOrigin(
                advertisedURL: URL(string: "wss://relay.arrayapp.dev/v2/socket?ignored=yes#secret"),
                allowLoopback: false
            ),
            URL(string: "https://relay.arrayapp.dev")
        )
        XCTAssertEqual(
            HostedPairingPolicy.relayHTTPOrigin(advertisedURL: nil, allowLoopback: false),
            URL(string: "https://relay.arrayapp.dev")
        )
    }

    func testUntrustedAndInsecureProductionOriginsAreRejected() {
        XCTAssertNil(HostedPairingPolicy.relayHTTPOrigin(
            advertisedURL: URL(string: "https://evil.example/v2/socket"), allowLoopback: false
        ))
        XCTAssertNil(HostedPairingPolicy.relayHTTPOrigin(
            advertisedURL: URL(string: "http://relay.arrayapp.dev/v2/socket"), allowLoopback: false
        ))
        XCTAssertNil(HostedPairingPolicy.relayHTTPOrigin(
            advertisedURL: URL(string: "https://relay.arrayapp.dev:444/v2/socket"), allowLoopback: false
        ))
    }

    func testLoopbackRequiresExplicitDevelopmentAllowance() {
        let loopback = URL(string: "http://127.0.0.1:8787/v2/socket")!
        XCTAssertNil(HostedPairingPolicy.relayHTTPOrigin(advertisedURL: loopback, allowLoopback: false))
        XCTAssertEqual(
            HostedPairingPolicy.relayHTTPOrigin(advertisedURL: loopback, allowLoopback: true),
            URL(string: "http://127.0.0.1:8787")
        )
    }

    func testCompanionCapabilitiesMustExactlyMatchServerProfile() {
        XCTAssertEqual(
            HostedPairingPolicy.companionScope(
                capabilities: RelayWire.companionCapabilities,
                credential: "phone_credential"
            ),
            .companionControl
        )
        XCTAssertNil(HostedPairingPolicy.companionScope(
            capabilities: RelayWire.companionCapabilities.union([.publishState]),
            credential: "phone_credential"
        ))
        XCTAssertNil(HostedPairingPolicy.companionScope(
            capabilities: RelayWire.companionCapabilities,
            credential: ""
        ))
    }
}
