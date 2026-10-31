import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// The receiving half of a share link: parse it, sign in to the relay if this
/// Mac is not signed in yet, admit through the token, then open the area.
/// Sign-in goes through the account's own enrollment path; no provider CLI
/// login or API key is ever read or asked for.
@MainActor
public final class ShareLinkOpener {
    public enum Outcome: Equatable, Sendable {
        case opened(area: UUID)
        /// A user-facing sentence. The caller shows it; a refusal is never silent.
        case refused(String)
        /// The person dismissed sign-in.
        case cancelled
    }
    /// Returns true once `account` is ready, false if the person dismissed it.
    public typealias SignIn = @MainActor (CollaborationAccountController) async throws -> Bool
    public typealias Open = @MainActor (Collaboration.State, CollaborationAccountController) async throws -> Void

    public let account: CollaborationAccountController
    private let signIn: SignIn
    private let openArea: Open
    public private(set) var lastOutcome: Outcome?

    public init(account: CollaborationAccountController, signIn: @escaping SignIn, open: @escaping Open) {
        self.account = account; self.signIn = signIn; openArea = open
    }

    public static let incompleteMessage = "This share link is incomplete. Ask for a new link."
    public static let refusedMessage = "This share link was refused. It was already used, revoked or is not valid. Ask for a new link."

    @discardableResult
    public func open(_ url: URL) async -> Outcome {
        let outcome = await resolve(url)
        lastOutcome = outcome
        return outcome
    }

    private func resolve(_ url: URL) async -> Outcome {
        guard let link = ShareLinkURL.parse(url) else { return .refused(Self.incompleteMessage) }
        do {
            if account.status != .ready, let remembered = account.selectedAccountID ?? (account.accounts.count == 1 ? account.accounts.first?.id : nil) {
                _ = try? await account.select(accountID: remembered)
            }
            if account.status != .ready {
                guard try await signIn(account), account.status == .ready else { return .cancelled }
            }
            let state = try await account.acceptShareLink(slug: link.slug, token: link.token)
            try await openArea(state, account)
            return .opened(area: state.document.id.rawValue)
        } catch {
            return .refused(Self.message(for: error))
        }
    }

    public static func message(for error: any Error) -> String {
        if let client = error as? CollaborationClientError, case let .server(status, _) = client {
            switch status {
            case 410: return refusedMessage
            case 401: return "This Mac is no longer signed in to collaboration. Sign in again, then open the link."
            default: return "Array could not reach the shared workspace. Try the link again."
            }
        }
        if let failure = error as? CollaborationAccountFailure {
            switch failure {
            case .invalidInput: return incompleteMessage
            case .invitationAcceptedStateUnavailable:
                return "You were admitted, but the shared workspace could not load. Open the link again to reconnect."
            default: return failure.errorDescription ?? refusedMessage
            }
        }
        return "Array could not open this share link. Try it again."
    }
}
