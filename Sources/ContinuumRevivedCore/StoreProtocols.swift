import Foundation

// Both concrete structs are already Sendable; this constraint is intentional so a
// future synced implementation must satisfy it explicitly, not by surprise.
public protocol ProjectStoring: Sendable {
    // Project
    func saveProject(_ project: Project) throws
    func loadProject() throws -> Project
    func tryLoadProject() throws -> Project?

    // Canvas
    func saveCanvas(_ canvas: CanvasState) throws
    func loadCanvas() throws -> CanvasState
    func loadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult
    func tryLoadCanvas() throws -> CanvasState?
    func tryLoadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult?

    // Sessions
    func saveSession(_ descriptor: TerminalSessionDescriptor) throws
    func loadSession(id: UUID) throws -> TerminalSessionDescriptor
    func deleteSession(id: UUID) throws
    func listSessions() throws -> [TerminalSessionDescriptor]

    // Browser
    func saveBrowserState(_ state: BrowserState) throws
    func loadBrowserState() throws -> BrowserState
    func tryLoadBrowserState() throws -> BrowserState?
    func browserStateFileExists() -> Bool          // NEW — replaces layout.browserFile probe

    // File tree
    func saveFileTreeState(_ state: FileTreeState) throws
    func loadFileTreeState() throws -> FileTreeState
    func tryLoadFileTreeState() throws -> FileTreeState?
    func fileTreeStateFileExists() -> Bool         // NEW — replaces layout.fileTreeIndexFile probe

    // Notes
    func saveNoteState(_ state: NoteState) throws
    func loadNoteState() throws -> NoteState
    func tryLoadNoteState() throws -> NoteState?
    func saveNoteBody(id: UUID, text: String) throws
    func loadNoteBody(id: UUID) throws -> String
    func tryLoadNoteBody(id: UUID) -> String?
    func deleteNoteBody(id: UUID) throws           // NEW — replaces layout.noteFile removal

    // Reviews
    func saveReviewCommentState(_ state: ReviewCommentState) throws
    func loadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState
    func tryLoadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState?
    func deleteReviewCommentState(reviewId: UUID) throws  // NEW — replaces layout.reviewFile removal

    // NOTE: `layout` and the path helpers (noteFile/reviewFile/sessionFile) are
    // deliberately NOT on this protocol — they are local-JSON path detail.
}

public protocol WorkspaceStoring: Sendable {
    func save(_ document: WorkspaceDocument) throws
    func load() throws -> WorkspaceDocument
    func tryLoad() throws -> WorkspaceDocument?
    func deleteDocument() throws
}
