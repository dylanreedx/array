import Foundation

public enum WorkspaceProfileCaptureMode: String, Codable, Equatable, Sendable, CaseIterable {
    case snapshot   // layout + resumable session-state (T13 fields kept)
    case template   // layout only (T13 session fields stripped)
}

public enum WorkspaceProfileApplyMode: String, Codable, Equatable, Sendable, CaseIterable {
    case restoreOver       // overwrite THIS workspace's canvas.json with the profile
    case instantiateAsNew  // create a new workspace from the profile as a template
}

public enum WorkspaceProfileApplicationError: Error, Equatable {
    case unknownFutureSchema(path: String, version: Int, supported: Int)
}

public struct WorkspaceProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var captureMode: WorkspaceProfileCaptureMode
    public var document: WorkspaceDocument

    public init(
        schemaVersion: Int = WorkspaceProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        captureMode: WorkspaceProfileCaptureMode,
        document: WorkspaceDocument
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.captureMode = captureMode
        self.document = document
    }

    public func validateSchema(at url: URL) throws {
        if schemaVersion > WorkspaceProfile.currentSchemaVersion {
            throw WorkspaceProfileApplicationError.unknownFutureSchema(
                path: url.path,
                version: schemaVersion,
                supported: WorkspaceProfile.currentSchemaVersion
            )
        }
    }
}

public struct WorkspaceProfileStoreLayout: Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var profilesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    public var backupsDirectory: URL {
        profilesDirectory.appendingPathComponent("backups", isDirectory: true)
    }
}

public struct WorkspaceProfileStore: Sendable {
    public let layout: WorkspaceProfileStoreLayout
    private let writer: AtomicWriter

    public init(
        applicationSupportDirectory: URL? = nil,
        retainedBackups: Int = 3
    ) {
        let baseDir = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
        let layout = WorkspaceProfileStoreLayout(applicationSupportDirectory: baseDir)
        self.layout = layout
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups
        )
    }

    public var profilesDirectory: URL { layout.profilesDirectory }

    public func profileFile(id: UUID) -> URL {
        layout.profilesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return RegistryStore.defaultApplicationSupportDirectory()
    }

    // MARK: - Capture

    /// Pure capture: for .snapshot, copies the document verbatim. For .template, the
    /// intent is layout-only (session-state stripped) — but WorkspaceDocument is already
    /// layout-only. T13 session-state fields (scrollback on TerminalSessionDescriptor,
    /// interactionState on BrowserTile) live in ProjectStore sibling stores keyed by
    /// tile id, NOT on WorkspaceDocument. A WorkspaceProfile captures only the
    /// WorkspaceDocument, so snapshot and template currently produce byte-identical
    /// profiles. The captureMode field is persisted for future use when a session-state
    /// bridge is designed alongside document. At that point, .template would clear the
    /// bundle and .snapshot would include it.
    public func captureProfile(
        name: String,
        from document: WorkspaceDocument,
        mode: WorkspaceProfileCaptureMode,
        id: UUID = UUID(),
        now: Date
    ) -> WorkspaceProfile {
        let capturedDocument: WorkspaceDocument
        switch mode {
        case .snapshot:
            capturedDocument = document
        case .template:
            // ARCHITECTURE-NOTE: WorkspaceDocument contains only layout fields
            // (viewport, zones, zoneZOrder, lastActiveZoneId, ambientTiles). T13
            // session-state lives in ProjectStore sibling stores, not here. There is
            // nothing to strip from the document, so template is currently
            // layout-identical to snapshot. When a session-state bridge is added to
            // WorkspaceProfile, this branch should clear those fields.
            capturedDocument = document
        }
        return WorkspaceProfile(
            id: id,
            name: name,
            createdAt: now,
            captureMode: mode,
            document: capturedDocument
        )
    }

    // MARK: - Persistence

    public func saveProfile(_ profile: WorkspaceProfile) throws {
        let url = profileFile(id: profile.id)
        try writer.write(profile, to: url)
    }

    public func loadProfile(id: UUID) throws -> WorkspaceProfile {
        let url = profileFile(id: id)
        let profile: WorkspaceProfile = try writer.read(at: url)
        try profile.validateSchema(at: url)
        return profile
    }

    public func listProfiles() throws -> [WorkspaceProfile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: layout.profilesDirectory.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: layout.profilesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONCodec.makeDecoder()
        var profiles: [WorkspaceProfile] = []
        for entry in entries {
            guard entry.pathExtension == "json",
                  entry.lastPathComponent != "backups" else { continue }
            // Skip the backups subdirectory entry (it has no extension, but guard above handles it)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue { continue }

            guard let data = try? Data(contentsOf: entry),
                  let profile = try? decoder.decode(WorkspaceProfile.self, from: data) else {
                // Skip undecodable files (junk, truncated, wrong type).
                continue
            }
            profiles.append(profile)
        }

        // Sort by createdAt ascending, then by id for determinism.
        profiles.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return profiles
    }

    public func deleteProfile(id: UUID) throws {
        let url = profileFile(id: id)
        try FileManager.default.removeItem(at: url)
    }
}
