import Foundation

public enum ProjectStoreError: Error, Equatable {
    case missingFile(path: String)
    case unknownFutureSchema(path: String, version: Int, supported: Int)
}

public struct ProjectStoreLayout: Sendable {
    public let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    public var stateRoot: URL {
        projectRoot.appendingPathComponent(".continuum-revived", isDirectory: true)
    }

    public var projectFile: URL {
        stateRoot.appendingPathComponent("project.json", isDirectory: false)
    }

    public var canvasFile: URL {
        stateRoot.appendingPathComponent("canvas.json", isDirectory: false)
    }

    public var sessionsDirectory: URL {
        stateRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    public var browserDirectory: URL {
        stateRoot.appendingPathComponent("browser", isDirectory: true)
    }

    public var browserFile: URL {
        browserDirectory.appendingPathComponent("tiles.json", isDirectory: false)
    }

    public var backupsDirectory: URL {
        stateRoot.appendingPathComponent("backups", isDirectory: true)
    }

    public func sessionFile(id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}

public struct ProjectStore: Sendable {
    public let layout: ProjectStoreLayout
    private let writer: AtomicWriter

    public init(projectRoot: URL, retainedBackups: Int = 3) {
        let layout = ProjectStoreLayout(projectRoot: projectRoot)
        self.layout = layout
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups
        )
    }

    // MARK: - Project

    public func saveProject(_ project: Project) throws {
        try writer.write(project, to: layout.projectFile)
    }

    public func loadProject() throws -> Project {
        let project: Project = try writer.read(at: layout.projectFile)
        try checkSchema(project.schemaVersion, supported: Project.currentSchemaVersion, at: layout.projectFile)
        return project
    }

    public func tryLoadProject() throws -> Project? {
        do { return try loadProject() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    // MARK: - Canvas

    public func saveCanvas(_ canvas: CanvasState) throws {
        try writer.write(canvas, to: layout.canvasFile)
    }

    public func loadCanvas() throws -> CanvasState {
        let canvas: CanvasState = try writer.read(at: layout.canvasFile)
        try checkSchema(canvas.schemaVersion, supported: CanvasState.currentSchemaVersion, at: layout.canvasFile)
        return canvas
    }

    public func tryLoadCanvas() throws -> CanvasState? {
        do { return try loadCanvas() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    // MARK: - Sessions

    public func saveSession(_ descriptor: TerminalSessionDescriptor) throws {
        try writer.write(descriptor, to: layout.sessionFile(id: descriptor.id))
    }

    public func loadSession(id: UUID) throws -> TerminalSessionDescriptor {
        let descriptor: TerminalSessionDescriptor = try writer.read(at: layout.sessionFile(id: id))
        try checkSchema(
            descriptor.schemaVersion,
            supported: TerminalSessionDescriptor.currentSchemaVersion,
            at: layout.sessionFile(id: id)
        )
        return descriptor
    }

    public func deleteSession(id: UUID) throws {
        let url = layout.sessionFile(id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func listSessions() throws -> [TerminalSessionDescriptor] {
        let dir = layout.sessionsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var sessions: [TerminalSessionDescriptor] = []
        for entry in entries where entry.pathExtension == "json" {
            do {
                let descriptor: TerminalSessionDescriptor = try writer.read(at: entry)
                try checkSchema(
                    descriptor.schemaVersion,
                    supported: TerminalSessionDescriptor.currentSchemaVersion,
                    at: entry
                )
                sessions.append(descriptor)
            } catch {
                // Skip unreadable session files; surface higher-level recovery
                // through the project's UI when we wire that up.
                continue
            }
        }
        return sessions
    }

    // MARK: - Browser

    public func saveBrowserState(_ state: BrowserState) throws {
        try writer.write(state, to: layout.browserFile)
    }

    public func loadBrowserState() throws -> BrowserState {
        let state: BrowserState = try writer.read(at: layout.browserFile)
        try checkSchema(state.schemaVersion, supported: BrowserState.currentSchemaVersion, at: layout.browserFile)
        return state
    }

    public func tryLoadBrowserState() throws -> BrowserState? {
        do { return try loadBrowserState() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    // MARK: - Schema gate

    private func checkSchema(_ version: Int, supported: Int, at url: URL) throws {
        if version > supported {
            throw ProjectStoreError.unknownFutureSchema(
                path: url.path,
                version: version,
                supported: supported
            )
        }
    }
}
