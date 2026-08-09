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
        projectRoot.appendingPathComponent(".array", isDirectory: true)
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

    public var managedSessionsDirectory: URL {
        stateRoot.appendingPathComponent("managed-sessions", isDirectory: true)
    }

    public var browserDirectory: URL {
        stateRoot.appendingPathComponent("browser", isDirectory: true)
    }

    public var browserFile: URL {
        browserDirectory.appendingPathComponent("tiles.json", isDirectory: false)
    }

    public var fileTreeDirectory: URL {
        stateRoot.appendingPathComponent("file-tree", isDirectory: true)
    }

    public var fileTreeIndexFile: URL {
        fileTreeDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    public var notesDirectory: URL {
        stateRoot.appendingPathComponent("notes", isDirectory: true)
    }

    public var notesIndexFile: URL {
        notesDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    public func noteFile(id: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(id.uuidString).md", isDirectory: false)
    }

    public var reviewsDirectory: URL {
        stateRoot.appendingPathComponent("reviews", isDirectory: true)
    }

    public func reviewFile(id: UUID) -> URL {
        reviewsDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    public var backupsDirectory: URL {
        stateRoot.appendingPathComponent("backups", isDirectory: true)
    }

    public func sessionFile(id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    public func managedSessionFile(tileId: UUID) -> URL {
        managedSessionsDirectory.appendingPathComponent("\(tileId.uuidString).json", isDirectory: false)
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
        let canvas: CanvasState = try writer.read(at: layout.canvasFile, decoder: JSONCodec.makeCanvasDecoder())
        try checkSchema(canvas.schemaVersion, supported: CanvasState.currentSchemaVersion, at: layout.canvasFile)
        return CanvasEngine.sanitizePersistedCanvas(canvas).canvas
    }

    public func loadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult {
        let canvas: CanvasState = try writer.read(at: layout.canvasFile, decoder: JSONCodec.makeCanvasDecoder())
        try checkSchema(canvas.schemaVersion, supported: CanvasState.currentSchemaVersion, at: layout.canvasFile)
        return CanvasEngine.sanitizePersistedCanvas(canvas)
    }

    public func tryLoadCanvas() throws -> CanvasState? {
        do { return try loadCanvas() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    public func tryLoadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult? {
        do { return try loadCanvasWithSanitizationResult() }
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
        return descriptor.restoredForBoot()
    }

    public func deleteSession(id: UUID) throws {
        let url = layout.sessionFile(id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func browserStateFileExists() -> Bool {
        FileManager.default.fileExists(atPath: layout.browserFile.path)
    }

    public func fileTreeStateFileExists() -> Bool {
        FileManager.default.fileExists(atPath: layout.fileTreeIndexFile.path)
    }

    public func deleteNoteBody(id: UUID) throws {
        let url = layout.noteFile(id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func deleteReviewCommentState(reviewId: UUID) throws {
        let url = layout.reviewFile(id: reviewId)
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
                sessions.append(descriptor.restoredForBoot())
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

    // MARK: - File Tree

    public func saveFileTreeState(_ state: FileTreeState) throws {
        try writer.write(state, to: layout.fileTreeIndexFile)
    }

    public func loadFileTreeState() throws -> FileTreeState {
        let state: FileTreeState = try writer.read(at: layout.fileTreeIndexFile)
        try checkSchema(state.schemaVersion, supported: FileTreeState.currentSchemaVersion, at: layout.fileTreeIndexFile)
        return state
    }

    public func tryLoadFileTreeState() throws -> FileTreeState? {
        do { return try loadFileTreeState() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    // MARK: - Notes

    public func saveNoteState(_ state: NoteState) throws {
        try FileManager.default.createDirectory(
            at: layout.notesDirectory,
            withIntermediateDirectories: true,
            attributes: nil)
        try writer.write(state, to: layout.notesIndexFile)
    }

    public func loadNoteState() throws -> NoteState {
        let state: NoteState = try writer.read(at: layout.notesIndexFile)
        try checkSchema(
            state.schemaVersion,
            supported: NoteState.currentSchemaVersion,
            at: layout.notesIndexFile)
        return state
    }

    public func tryLoadNoteState() throws -> NoteState? {
        do { return try loadNoteState() }
        catch AtomicWriterError.noValidBackup { return nil }
    }

    public func saveNoteBody(id: UUID, text: String) throws {
        try FileManager.default.createDirectory(
            at: layout.notesDirectory,
            withIntermediateDirectories: true,
            attributes: nil)
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: layout.noteFile(id: id), options: .atomic)
    }

    public func loadNoteBody(id: UUID) throws -> String {
        let data = try Data(contentsOf: layout.noteFile(id: id))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    public func tryLoadNoteBody(id: UUID) -> String? {
        guard let data = try? Data(contentsOf: layout.noteFile(id: id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Review Comments

    public func saveReviewCommentState(_ state: ReviewCommentState) throws {
        try FileManager.default.createDirectory(
            at: layout.reviewsDirectory,
            withIntermediateDirectories: true,
            attributes: nil)
        try writer.write(state, to: layout.reviewFile(id: state.reviewId))
    }

    public func loadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState {
        let state: ReviewCommentState = try writer.read(at: layout.reviewFile(id: reviewId))
        try checkSchema(
            state.schemaVersion,
            supported: ReviewCommentState.currentSchemaVersion,
            at: layout.reviewFile(id: reviewId))
        return state
    }

    public func tryLoadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState? {
        do { return try loadReviewCommentState(reviewId: reviewId) }
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

extension ProjectStore: ProjectStoring {}
