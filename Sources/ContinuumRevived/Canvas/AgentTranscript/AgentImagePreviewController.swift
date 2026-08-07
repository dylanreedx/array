import AppKit
import Quartz

/// Narrow native preview seam for transcript media actions. The action owner
/// resolves an opaque image ID to a host-local file URL, then hands only that
/// local file capability here; semantic metadata is never interpreted as a path
/// and remote URLs are rejected by construction.
@MainActor
final class AgentImageQuickPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var items: [AgentImageQuickPreviewItem] = []

    func preview(localFileURL: URL) {
        guard canPreview(localFileURL: localFileURL) else { return }
        items = [AgentImageQuickPreviewItem(url: localFileURL)]
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.activateFileViewerSelecting([localFileURL])
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func canPreview(localFileURL: URL) -> Bool {
        localFileURL.isFileURL
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
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

@MainActor
enum AgentImageAppKitActions {
    static func copy(_ resource: AgentResolvedImageResource, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if let image = resource.image {
            pasteboard.writeObjects([image])
        } else if let url = resource.localFileURL {
            pasteboard.writeObjects([url as NSURL])
        }
    }

    static func reveal(_ resource: AgentResolvedImageResource, workspace: NSWorkspace = .shared) {
        guard let url = resource.localFileURL else { return }
        workspace.activateFileViewerSelecting([url])
    }

    static func saveAs(_ resource: AgentResolvedImageResource, from view: NSView? = nil) {
        guard resource.hasLocalResource else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = resource.displayName ?? resource.localFileURL?.lastPathComponent ?? "Image"
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if let source = resource.localFileURL {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                } else if let tiff = resource.image?.tiffRepresentation {
                    try tiff.write(to: destination, options: .atomic)
                }
            } catch {
                NSSound.beep()
            }
        }
        if let window = view?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
