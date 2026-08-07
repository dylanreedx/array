import AppKit
import ContinuumRevivedAgentContent
import ImageIO
import Quartz

/// Narrow native preview seam for transcript media actions. The action owner
/// resolves an opaque image ID to a host-local file URL at click time, validates
/// that local file, then hands only that fresh capability here. Semantic display
/// names are never interpreted as paths and remote URLs are rejected.
@MainActor
final class AgentImageQuickPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private static var retainedControllers: [ObjectIdentifier: AgentImageQuickPreviewController] = [:]
    private var items: [AgentImageQuickPreviewItem] = []

    func preview(localFileURL: URL) {
        guard let validated = AgentImageFileValidator.validatedLocalImageFile(localFileURL) else { return }
        Self.retainedControllers[ObjectIdentifier(self)] = self
        items = [AgentImageQuickPreviewItem(url: validated)]
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.activateFileViewerSelecting([validated])
            Self.retainedControllers.removeValue(forKey: ObjectIdentifier(self))
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func canPreview(localFileURL: URL) -> Bool {
        AgentImageFileValidator.validatedLocalImageFile(localFileURL) != nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        Self.retainedControllers.removeValue(forKey: ObjectIdentifier(self))
    }
}

private final class AgentImageQuickPreviewItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { url.lastPathComponent }
}

struct AgentImageActionResource: Equatable {
    var attachmentID: AgentImageAttachmentID
    var localFileURL: URL
    var displayName: String?

    init?(attachmentID: AgentImageAttachmentID, localFileURL: URL, displayName: String? = nil) {
        guard let validated = AgentImageFileValidator.validatedLocalImageFile(localFileURL) else { return nil }
        self.attachmentID = attachmentID
        self.localFileURL = validated
        self.displayName = displayName
    }
}

enum AgentImageFileValidator {
    static func validatedLocalImageFile(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let standardized = url.standardizedFileURL
        let path = standardized.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        guard let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return nil }
        guard let source = CGImageSourceCreateWithURL(standardized as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else { return nil }
        return standardized
    }

    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        return left == right
    }
}

@MainActor
enum AgentImageAppKitActions {
    @discardableResult
    static func copy(_ resource: AgentImageActionResource, to pasteboard: NSPasteboard = .general) -> Bool {
        copyFileImageContent(localFileURL: resource.localFileURL, to: pasteboard)
    }

    @discardableResult
    static func copyFileImageContent(localFileURL: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = AgentImageFileValidator.validatedLocalImageFile(localFileURL),
              let image = NSImage(contentsOf: url) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    static func reveal(_ resource: AgentImageActionResource, workspace: NSWorkspace = .shared) {
        guard let url = AgentImageFileValidator.validatedLocalImageFile(resource.localFileURL) else { return }
        workspace.activateFileViewerSelecting([url])
    }

    static func saveAs(_ resource: AgentImageActionResource, from view: NSView? = nil) {
        guard let source = AgentImageFileValidator.validatedLocalImageFile(resource.localFileURL) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeSaveName(resource.displayName) ?? source.lastPathComponent
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do { try saveFileImageContent(from: source, to: destination) }
            catch { NSSound.beep() }
        }
        if let window = view?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @discardableResult
    static func saveFileImageContent(from source: URL, to destination: URL) throws -> Bool {
        guard let source = AgentImageFileValidator.validatedLocalImageFile(source), destination.isFileURL else { return false }
        let destination = destination.standardizedFileURL
        guard !AgentImageFileValidator.isSameFile(source, destination) else { return false }

        let fileManager = FileManager.default
        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory), destinationIsDirectory.boolValue {
            return false
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).continuum-\(UUID().uuidString).tmp")
        var tempCreated = false
        do {
            try fileManager.copyItem(at: source, to: temp)
            tempCreated = true
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temp,
                    backupItemName: nil,
                    options: []
                )
                tempCreated = false
            } else {
                try fileManager.moveItem(at: temp, to: destination)
                tempCreated = false
            }
            return true
        } catch {
            if tempCreated { try? fileManager.removeItem(at: temp) }
            throw error
        }
    }

    private static func safeSaveName(_ value: String?) -> String? {
        guard let value else { return nil }
        let singleLine = value.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? value
        let basename = (singleLine as NSString).lastPathComponent
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
