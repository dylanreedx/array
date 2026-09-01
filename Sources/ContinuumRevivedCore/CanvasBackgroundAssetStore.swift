import CryptoKit
import Foundation

/// WS7 — the managed store for background images.
///
/// The user picks a file once; Array copies its bytes into the CHANNEL's own
/// Application Support directory and from then on refers to it by a
/// content digest. Nothing outside this file ever sees a URL.
///
/// Why not just keep the picked URL: a path is not stable (moves, renames,
/// external volumes), it leaks the user's filesystem into a document that syncs,
/// and a security-scoped bookmark is a credential we would have to persist.
/// A digest is stable, deduplicating, and says nothing about where the file was.
public struct CanvasBackgroundAssetStore {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case unreadable
        case unsupportedExtension(String)
        case tooLarge(bytes: Int, limit: Int)
        case empty
        case notAFile

        public var description: String {
            switch self {
            case .unreadable: return "the file could not be read"
            case .unsupportedExtension(let ext): return "unsupported image type '\(ext)'"
            case .tooLarge(let bytes, let limit): return "image is \(bytes) bytes, limit is \(limit)"
            case .empty: return "the file is empty"
            case .notAFile: return "not a regular file"
            }
        }
    }

    /// 64 MB of encoded bytes. Generous for a wallpaper, small enough that a
    /// bounded read can hold it and an accidental pick of a video or a disk image
    /// is refused rather than copied.
    public static let maximumEncodedBytes = 64 * 1024 * 1024

    public let directory: URL

    public init(applicationSupportDirectory: URL? = nil) {
        let base = applicationSupportDirectory ?? WorkspaceStore.defaultApplicationSupportDirectory()
        self.directory = base.appendingPathComponent("canvas-background-assets", isDirectory: true)
    }

    /// Managed location of an asset. Derived, never stored.
    public func url(for id: CanvasBackgroundAssetID) -> URL {
        directory.appendingPathComponent(id.fileName, isDirectory: false)
    }

    public func exists(_ id: CanvasBackgroundAssetID) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url(for: id).path, isDirectory: &isDirectory)
        return found && !isDirectory.boolValue
    }

    // MARK: - Import

    /// Copy `source` into the managed directory and return its deterministic id.
    ///
    /// Atomic: the bytes are written to a temp file **in the same directory**
    /// (so the rename cannot cross a filesystem), fsynced, then renamed over the
    /// destination. A crash mid-import leaves either nothing or a complete file,
    /// never a truncated one that would later decode as "corrupt".
    ///
    /// Idempotent: the same bytes always produce the same id, so re-importing a
    /// file the user already picked costs one hash and no new storage.
    @discardableResult
    public func importImage(at source: URL) throws -> CanvasBackgroundAssetID {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImportError.notAFile
        }
        let ext = source.pathExtension.lowercased()
        guard CanvasBackgroundAssetID.allowedExtensions.contains(ext) else {
            throw ImportError.unsupportedExtension(ext.isEmpty ? "(none)" : ext)
        }
        let attributes = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumEncodedBytes {
            throw ImportError.tooLarge(bytes: size.intValue, limit: Self.maximumEncodedBytes)
        }
        guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]) else {
            throw ImportError.unreadable
        }
        return try importImage(data: data, fileExtension: ext)
    }

    @discardableResult
    public func importImage(data: Data, fileExtension: String) throws -> CanvasBackgroundAssetID {
        guard !data.isEmpty else { throw ImportError.empty }
        guard data.count <= Self.maximumEncodedBytes else {
            throw ImportError.tooLarge(bytes: data.count, limit: Self.maximumEncodedBytes)
        }
        let ext = fileExtension.lowercased()
        guard CanvasBackgroundAssetID.allowedExtensions.contains(ext) else {
            throw ImportError.unsupportedExtension(ext.isEmpty ? "(none)" : ext)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let id = CanvasBackgroundAssetID(digest: digest, fileExtension: ext) else {
            throw ImportError.unsupportedExtension(ext)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: id)
        if exists(id) { return id }

        let temp = directory.appendingPathComponent(".import-\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temp, options: [.atomic])
        // fsync the payload before the rename publishes it.
        if let handle = try? FileHandle(forWritingTo: temp) {
            try? handle.synchronize()
            try? handle.close()
        }
        do {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } catch {
            // `replaceItemAt` fails when the destination does not exist yet.
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temp, to: destination)
            } else if !fm.fileExists(atPath: destination.path) {
                throw error
            }
        }
        try? fm.removeItem(at: temp)
        return id
    }

    // MARK: - Reference-aware deferred cleanup

    /// 7 days. An asset removed from every document today may be wanted back
    /// tomorrow (an undo, a workspace restored from a backup, a document not yet
    /// migrated), so unreferenced files are aged out rather than deleted at the
    /// moment their last reference disappears.
    public static let cleanupGrace: TimeInterval = 7 * 24 * 60 * 60

    public struct CleanupResult: Equatable, Sendable {
        public var scanned = 0
        public var referenced = 0
        public var deleted: [String] = []
        public var withheldForGrace: [String] = []
        public var skippedNonRegular: [String] = []
    }

    /// Delete only managed regular files that no live configuration names and
    /// whose modification time is older than `grace`.
    ///
    /// `referencedIDs` must be the union across the global configuration AND
    /// every workspace document — a cleanup that saw only the active workspace
    /// would delete the image of every other one.
    @discardableResult
    public func cleanup(
        referencedIDs: Set<CanvasBackgroundAssetID>,
        now: Date = Date(),
        grace: TimeInterval = CanvasBackgroundAssetStore.cleanupGrace
    ) -> CleanupResult {
        var result = CleanupResult()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return result }
        let referencedNames = Set(referencedIDs.map(\.fileName))
        for entry in entries {
            result.scanned += 1
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            // Never follow a symlink and never recurse: this directory is ours,
            // and anything in it that is not a plain file is left strictly alone.
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                result.skippedNonRegular.append(entry.lastPathComponent)
                continue
            }
            if referencedNames.contains(entry.lastPathComponent) {
                result.referenced += 1
                continue
            }
            let modified = values?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) >= grace else {
                result.withheldForGrace.append(entry.lastPathComponent)
                continue
            }
            if (try? fm.removeItem(at: entry)) != nil {
                result.deleted.append(entry.lastPathComponent)
            }
        }
        return result
    }
}
