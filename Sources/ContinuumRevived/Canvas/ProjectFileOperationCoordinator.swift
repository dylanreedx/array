import Foundation

/// The only filesystem mutation surface exposed by editor file browsers.
/// Every operation is rooted before it reaches FileManager; web content never
/// receives paths or filesystem authority.
final class ProjectFileOperationCoordinator {
    enum OperationError: LocalizedError, Equatable {
        case invalidName
        case outsideRoot
        case rootMutation
        case collision(String)
        case missing(String)
        case filesystem(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Use a single file or folder name."
            case .outsideRoot: return "That item is outside this project."
            case .rootMutation: return "The project root cannot be renamed or moved to Trash."
            case let .collision(name): return "An item named \(name) already exists."
            case let .missing(path): return "The item no longer exists: \(path)"
            case let .filesystem(message): return message
            }
        }
    }

    struct RenameResult: Equatable {
        var source: URL
        var destination: URL
        var isDirectory: Bool
    }

    struct TrashResult: Equatable {
        var original: URL
        var trashed: URL?
        var isDirectory: Bool
    }

    private let root: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.root = Self.canonical(rootURL, directory: true)
        self.fileManager = fileManager
    }

    func createFile(parent: URL, name: String) throws -> URL {
        let parent = try validatedDirectory(parent)
        let destination = try destination(parent: parent, name: name)
        guard fileManager.createFile(atPath: destination.path, contents: Data(), attributes: nil) else {
            throw OperationError.filesystem("Could not create \(destination.lastPathComponent).")
        }
        return destination
    }

    func createDirectory(parent: URL, name: String) throws -> URL {
        let parent = try validatedDirectory(parent)
        let destination = try destination(parent: parent, name: name)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            return destination
        } catch {
            throw OperationError.filesystem(error.localizedDescription)
        }
    }

    func rename(entry: URL, newName: String) throws -> RenameResult {
        let source = try validatedEntry(entry, allowRoot: false)
        let destination = try destination(parent: source.deletingLastPathComponent(), name: newName, source: source)
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &directory) else {
            throw OperationError.missing(source.path)
        }
        do {
            // A temporary sibling makes case-only renames reliable on the
            // default case-insensitive macOS volume without permitting replace.
            if source.path.caseInsensitiveCompare(destination.path) == .orderedSame,
               source.path != destination.path {
                let temporary = source.deletingLastPathComponent()
                    .appendingPathComponent(".array-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: source, to: temporary)
                do { try fileManager.moveItem(at: temporary, to: destination) }
                catch {
                    try? fileManager.moveItem(at: temporary, to: source)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
            return RenameResult(source: source, destination: destination, isDirectory: directory.boolValue)
        } catch let error as OperationError {
            throw error
        } catch {
            throw OperationError.filesystem(error.localizedDescription)
        }
    }

    func moveToTrash(entry: URL) throws -> TrashResult {
        let source = try validatedEntry(entry, allowRoot: false)
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &directory) else {
            throw OperationError.missing(source.path)
        }
        var resulting: NSURL?
        do {
            try fileManager.trashItem(at: source, resultingItemURL: &resulting)
            return TrashResult(original: source, trashed: resulting as URL?, isDirectory: directory.boolValue)
        } catch {
            throw OperationError.filesystem(error.localizedDescription)
        }
    }

    private func validatedDirectory(_ url: URL) throws -> URL {
        let value = try validatedEntry(url, allowRoot: true)
        let resolved = Self.canonical(value, directory: true)
        guard contains(resolved) else { throw OperationError.outsideRoot }
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue else {
            throw OperationError.missing(resolved.path)
        }
        return resolved
    }

    private func validatedEntry(_ url: URL, allowRoot: Bool) throws -> URL {
        if allowRoot, Self.canonical(url, directory: true).path == root.path { return root }
        // Canonicalize the parent and retain the selected final directory entry,
        // so a symlink may itself be renamed/trashed without following its target.
        let standardized = url.standardizedFileURL
        let parent = Self.canonical(standardized.deletingLastPathComponent(), directory: true)
        guard contains(parent) else { throw OperationError.outsideRoot }
        let value = parent.appendingPathComponent(standardized.lastPathComponent)
        if value.path == root.path, !allowRoot { throw OperationError.rootMutation }
        return value
    }

    private func destination(parent: URL, name: String, source: URL? = nil) throws -> URL {
        guard Self.validName(name) else { throw OperationError.invalidName }
        let destination = parent.appendingPathComponent(name)
        guard contains(parent) else { throw OperationError.outsideRoot }
        if fileManager.fileExists(atPath: destination.path), destination.path != source?.path {
            // The exact same directory entry is allowed only for a no-op rename.
            if source == nil || destination.path.caseInsensitiveCompare(source!.path) != .orderedSame {
                throw OperationError.collision(name)
            }
        }
        return destination
    }

    private func contains(_ url: URL) -> Bool {
        let rootParts = root.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
    }

    private static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == name && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/") && !trimmed.contains(":") && !trimmed.contains("\0")
    }

    private static func canonical(_ url: URL, directory: Bool) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: directory)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
}
