import ContinuumRevivedAgentContent
import Foundation

/// A local-file destination authored in agent content, resolved against one
/// agent checkout. `path` is canonical (standardized, symlinks resolved) and the
/// navigation metadata an agent likes to append (`:42:8`, `#L42C8`) has already
/// been separated from it.
public struct AgentLocalFileLink: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Resolves an authored local-file link destination into a real file inside one
/// agent's checkout.
///
/// Authored content can only ever *request* resolution. Every destination is
/// re-parsed here, resolved against the caller-supplied checkout root — never the
/// process working directory and never "the active project" — canonicalized, and
/// then required to be a regular file whose canonical path lies strictly inside
/// the canonical checkout. A link is not authorization.
public enum AgentLocalFileLinkResolver {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a local-file candidate at all (https, mailto, javascript:, an
        /// unknown scheme, a remote `file://host/` authority).
        case notALocalFile
        /// A local-file candidate that could not be parsed into a path.
        case malformed
        /// Resolved outside the checkout: `../` traversal, an absolute path
        /// elsewhere, or a symlink pointing out.
        case outsideCheckout
        /// Nothing there, or there but not a regular file (a directory, a socket).
        case notARegularFile
    }

    /// Resolves `destination` against `checkoutRoot`, the responding agent's live
    /// working directory — the only base a relative path may resolve against.
    public static func resolve(
        destination: String,
        checkoutRoot: URL,
        fileManager: FileManager = .default
    ) -> Result<AgentLocalFileLink, Failure> {
        guard AgentLocalFileDestination.isCandidate(destination) else { return .failure(.notALocalFile) }

        let (rawPath, line, column) = AgentLocalFileDestination.splitNavigation(destination)
        let pathText: String
        if AgentLocalFileDestination.hasFileScheme(rawPath) {
            guard let url = URL(string: rawPath),
                  let scheme = url.scheme?.lowercased(), scheme == "file",
                  url.user == nil, url.password == nil, url.query == nil,
                  AgentLocalFileDestination.isLocalFileHost(url.host),
                  !url.path.isEmpty
            else { return .failure(.malformed) }
            // URL already percent-decodes `path`.
            pathText = url.path
        } else {
            pathText = rawPath
        }

        guard !pathText.isEmpty, !pathText.hasPrefix("~") else { return .failure(.malformed) }

        // Re-flavour the root as a directory. A URL built without `isDirectory: true`
        // has no trailing slash, and relative resolution against it drops its last
        // component — so `Sources/App.swift` would resolve as the checkout's SIBLING
        // and then be refused for being outside it.
        let rootDirectory = URL(fileURLWithPath: checkoutRoot.path, isDirectory: true)
        let candidate = pathText.hasPrefix("/")
            ? URL(fileURLWithPath: pathText)
            : URL(fileURLWithPath: pathText, relativeTo: rootDirectory)

        // Canonicalize BOTH sides: /var is a symlink to /private/var on macOS, so
        // containment between a raw and a resolved path is meaningless.
        let resolvedRoot = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()

        guard isContained(resolved, in: resolvedRoot) else { return .failure(.outsideCheckout) }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.notARegularFile)
        }
        if let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == false {
            return .failure(.notARegularFile)
        }

        return .success(AgentLocalFileLink(path: resolved.path, line: line, column: column))
    }

    /// Path-COMPONENT containment. A string-prefix test would accept
    /// `/tmp/checkout-evil` for the root `/tmp/checkout`.
    public static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let urlComponents = url.pathComponents
        guard urlComponents.count > rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}
