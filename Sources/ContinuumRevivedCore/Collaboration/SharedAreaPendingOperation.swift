import Foundation
import ContinuumRevivedCollaborationProtocol

/// A private, exact document mutation retained before transport. This record is
/// not a capability and never represents a provider/executor command.
public struct SharedAreaPendingOperation: Codable, Equatable, Sendable {
    public enum Rejection: String, Codable, Sendable { case conflict, forbidden, invalidCommand }
    public enum State: Codable, Equatable, Sendable {
        case pending
        case accepted(UInt64)
        case rejected(Rejection)
    }
    public struct Publication: Codable, Equatable, Sendable {
        public let reviewDigest: String
        public let author: SharedArea.ID<SharedArea.Person>
        public let host: SharedArea.ID<SharedArea.Host>
        public init(reviewDigest: String, author: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Host>) {
            self.reviewDigest = reviewDigest; self.author = author; self.host = host
        }
    }
    public let command: SharedArea.Command
    public let actor: Collaboration.Identity
    public let publication: Publication?
    public let sourceBindings: [SharedAreaLocalSourceBinding]
    public let preservedDraft: SharedAreaLocalDraft?
    /// Incremented atomically before an attempt; a crash can never imply that an
    /// already-authorized request was not sent. Every retry retains the same ID.
    public var attempts: UInt64
    public var state: State
    public var isPending: Bool { if case .pending = state { return true }; return false }

    public init(command: SharedArea.Command, actor: Collaboration.Identity,
                publication: Publication? = nil, sourceBindings: [SharedAreaLocalSourceBinding] = [],
                preservedDraft: SharedAreaLocalDraft? = nil, attempts: UInt64 = 0, state: State = .pending) {
        self.command = command; self.actor = actor; self.publication = publication
        self.sourceBindings = sourceBindings; self.preservedDraft = preservedDraft
        self.attempts = attempts; self.state = state
    }

    func validate(scope: SharedAreaLocalScope) throws {
        guard command.schema == 1, command.expectedRevision < UInt64.max, command.area == scope.area, actor.person == scope.person,
              !command.edits.isEmpty, Set(sourceBindings.map(\.object)).count == sourceBindings.count else {
            throw SharedAreaLocalStoreError.invalidState
        }
        if let publication {
            guard publication.author == actor.person, publication.reviewDigest.count == 64,
                  publication.reviewDigest.allSatisfy({ $0.isHexDigit }) else { throw SharedAreaLocalStoreError.invalidState }
            for binding in sourceBindings {
                let admitted = command.edits.compactMap { edit -> SharedArea.Item? in
                    if case .admit(let item, _) = edit, item.id == binding.object { return item }
                    return nil
                }.first
                guard binding.agentID != nil, binding.tileID != nil, binding.host == publication.host,
                      admitted?.kind == .agentObservation,
                      admitted?.source == .init(owner: actor.person, host: publication.host, binding: binding.binding) else {
                    throw SharedAreaLocalStoreError.invalidState
                }
            }
        } else if !sourceBindings.isEmpty { throw SharedAreaLocalStoreError.invalidState }
        for edit in command.edits {
            switch edit {
            case .admit(_, let position), .place(let position):
                guard position.rect.valid else { throw SharedAreaLocalStoreError.invalidState }
            case .post(let post):
                guard post.author == actor.person else { throw SharedAreaLocalStoreError.invalidState }
            case .context(let context):
                guard context.author == actor.person else { throw SharedAreaLocalStoreError.invalidState }
            case .remove: break
            }
        }
        switch state {
        case .accepted(let revision):
            guard revision > 0, revision == command.expectedRevision + 1 else { throw SharedAreaLocalStoreError.invalidState }
        case .pending, .rejected: break
        }
    }

    /// Receipts are retained in authoritative document snapshots. Running the
    /// reducer on a private copy verifies its intent digest before recognizing a
    /// lost reply. An absent operation is definitively obsolete only once the
    /// server's revision has advanced beyond its original precondition.
    func reconciled(with document: SharedArea.Document) throws -> Self {
        guard isPending else { return self }
        var probe = document
        var next = self
        do {
            if case .duplicate(let revision) = try probe.apply(command) { next.state = .accepted(revision) }
        } catch SharedArea.Failure.conflict where document.revision > command.expectedRevision {
            next.state = .rejected(.conflict)
        } catch SharedArea.Failure.changedIntent {
            throw SharedAreaLocalStoreError.conflictingDocument
        } catch {
            // Do not turn a transient/current permission failure into a claim
            // about a request that may have committed before the disconnect.
        }
        return next
    }
}
