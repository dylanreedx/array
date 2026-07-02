import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// D8's RemoteReach menu, first two arms only. Additive later: .tailscale, .tunnel.
public enum HostIdentity: Hashable, Sendable {
    case localhost
    case sshForward(host: String)   // an ssh-reachable box; `host` is the ssh target name
}

public enum HostError: Error, Equatable {
    case unknownHost(HostIdentity)   // no TmuxControl is registered/reachable for this identity
}

// Answers exactly one question: given a host identity, hand me the TmuxControl I
// reach it through. The real implementation (a follow-up ticket) returns a
// ProcessTmuxControl for .localhost and an ssh-wrapping TmuxControl for
// .sshForward per D9; this ticket ships only the protocol, the identity/error
// types, and the fake.
public protocol Host: Sendable {
    func control(for identity: HostIdentity) throws -> any TmuxControl
}

public final class FakeHost: Host, @unchecked Sendable {
    private var controls: [HostIdentity: any TmuxControl] = [:]

    public init() {}

    public func register(_ control: any TmuxControl, for identity: HostIdentity) {
        controls[identity] = control
    }

    public func control(for identity: HostIdentity) throws -> any TmuxControl {
        guard let control = controls[identity] else {
            throw HostError.unknownHost(identity)
        }
        return control
    }
}
