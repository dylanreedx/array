import AppKit
import ContinuumRevivedCore
import Foundation

/// Turns a local-file link an agent authored into a file tile beside that agent.
///
/// Split out of `AppDelegate` so the whole decision — resolve against the agent's
/// own checkout, refuse anything outside it, open anchored, reveal the coordinate —
/// is one testable unit that the witness drives through the real production route
/// rather than re-deriving. `AppDelegate` supplies only the responding agent's live
/// `cwd`; nothing here consults the process working directory or the active project.
@MainActor
struct AgentLocalFileOpener {
    let openFile: (String, WorkspaceRuntime.FileOpenPlacement) -> WorkspaceRuntime.FileOpenOutcome
    let fileTile: (UUID) -> FileTileNSView?

    enum Result: Equatable {
        case opened(tileId: UUID, revealedLine: Int?)
        case revealed(tileId: UUID, revealedLine: Int?)
        /// Nothing opened. The destination did not resolve to a regular file inside
        /// the checkout, or the open itself failed.
        case refused(String)
    }

    @discardableResult
    func open(destination: String, checkoutRoot: URL, sourceTileId: UUID) -> Result {
        switch AgentLocalFileLinkResolver.resolve(destination: destination, checkoutRoot: checkoutRoot) {
        case let .failure(reason):
            return .refused("\(destination): \(reason)")
        case let .success(link):
            let outcome = openFile(link.path, .beside(tileId: sourceTileId))
            switch outcome {
            case let .opened(tileId):
                revealIfNeeded(link, in: tileId)
                return .opened(tileId: tileId, revealedLine: link.line)
            case let .revealed(tileId):
                revealIfNeeded(link, in: tileId)
                return .revealed(tileId: tileId, revealedLine: link.line)
            case let .failure(message):
                return .refused(message)
            }
        }
    }

    private func revealIfNeeded(_ link: AgentLocalFileLink, in tileId: UUID) {
        guard let line = link.line, let view = fileTile(tileId) else { return }
        view.reveal(line: line, column: link.column)
    }
}
