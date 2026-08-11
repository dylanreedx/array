import AppKit
import ContinuumRevivedCore

/// A synchronous snapshot of everything the composer can consume from one
/// pasteboard event. AppKit pasteboards may vend promised data lazily, so the
/// raw pasteboard never crosses into the composer's asynchronous import work.
struct ComposerPasteboardIntake {
    var images: [ComposerDecodedImagePasteboardItem]
    var fileReferences: [AgentPromptFileReference]

    init(from pasteboard: NSPasteboard) {
        images = ComposerImagePasteboardDecoder.decodedItems(from: pasteboard)
        fileReferences = ComposerFileReferencePasteboardDecoder.decodedReferences(from: pasteboard)
    }

    var isEmpty: Bool {
        images.isEmpty && fileReferences.isEmpty
    }
}
