import ContinuumRevivedCore
import Darwin
import Foundation

/// Channel-local, private screenshots. Directory descriptors and O_NOFOLLOW
/// prevent a pre-existing symlink from redirecting an agent's output.
enum BrowserArtifactStore {
    static func save(root: URL, agentId: AgentID, png: Data) -> URL? {
        let parent = root.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parentFD >= 0 else { return nil }
        defer { Darwin.close(parentFD) }
        guard let rootFD = openDirectory(parent: parentFD, name: root.lastPathComponent, create: true) else { return nil }
        defer { Darwin.close(rootFD) }
        let agentName = agentId.rawValue.uuidString
        guard let agentFD = openDirectory(parent: rootFD, name: agentName, create: true) else { return nil }
        defer { Darwin.close(agentFD) }
        let name = UUID().uuidString + ".png"
        let fd = name.withCString { Darwin.openat(agentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        let written = png.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return Darwin.fsync(fd) == 0
        }
        guard written else { name.withCString { _ = Darwin.unlinkat(agentFD, $0, 0) }; return nil }
        return root.appendingPathComponent(agentName, isDirectory: true).appendingPathComponent(name)
    }

    /// WebKit requires a non-existing destination. Random names inside a
    /// private, no-follow tile directory avoid collisions and path traversal.
    @MainActor
    static func downloadDestination(root: URL, tileId: UUID, suggestedFilename: String) -> URL? {
        let parent = root.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parentFD >= 0 else { return nil }
        defer { Darwin.close(parentFD) }
        guard let rootFD = openDirectory(parent: parentFD, name: root.lastPathComponent, create: true) else { return nil }
        defer { Darwin.close(rootFD) }
        let name = tileId.uuidString
        guard let tileFD = openDirectory(parent: rootFD, name: name, create: true) else { return nil }
        defer { Darwin.close(tileFD) }
        let safe = WKWebViewBrowserRuntime.sanitizedDownloadFilename(suggestedFilename)
        let suffix = String(safe.prefix(40))
        let filename = UUID().uuidString + "-" + (suffix == "." || suffix == ".." ? "download" : suffix)
        return root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(filename)
    }

    static func remove(root: URL, agentId: AgentID, file: URL) {
        let parent = root.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parentFD >= 0 else { return }
        defer { Darwin.close(parentFD) }
        guard let rootFD = openDirectory(parent: parentFD, name: root.lastPathComponent, create: false) else { return }
        defer { Darwin.close(rootFD) }
        guard let agentFD = openDirectory(parent: rootFD, name: agentId.rawValue.uuidString, create: false) else { return }
        defer { Darwin.close(agentFD) }
        file.lastPathComponent.withCString { _ = Darwin.unlinkat(agentFD, $0, 0) }
    }

    private static func openDirectory(parent: Int32, name: String, create: Bool) -> Int32? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        if create {
            let result = name.withCString { Darwin.mkdirat(parent, $0, mode_t(0o700)) }
            guard result == 0 || errno == EEXIST else { return nil }
        }
        let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { return nil }
        var attributes = stat()
        guard Darwin.fstat(fd, &attributes) == 0, attributes.st_mode & mode_t(0o077) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
