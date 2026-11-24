import AppKit
import AVKit
import ContinuumRevivedAgentUI
import PDFKit

/// PDF in a file tile. One `PDFView` (PDFKit virtualizes its pages), no
/// measurement in `layout()`, and the document is dropped on `dispose()`.
@MainActor
final class FilePDFRenderer: NSView, FileTileRenderer {
    var view: NSView { self }
    var focusView: NSView { pdfView }
    private(set) var revision: UInt64 = 0
    var scrollOffsets: [CGPoint] { [] }
    var onRevisionChange: (() -> Void)?
    private let pdfView = PDFView()
    private var pageObserver: NSObjectProtocol?

    init(document: PDFDocument) {
        super.init(frame: .zero)
        clipsToBounds = true
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        addSubview(pdfView)
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revision &+= 1
                self.onRevisionChange?()
            }
        }
        setAccessibilityLabel("PDF document, \(document.pageCount) pages")
        applyTheme()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if pdfView.frame != bounds { pdfView.frame = bounds }
    }
    func applyTheme() { pdfView.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self) }
    func setVisible(_ visible: Bool) { isHidden = !visible }
    func dispose() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        pdfView.document = nil
        onRevisionChange = nil
    }
    var qaPageCount: Int { pdfView.document?.pageCount ?? 0 }
}

/// A plain AVKit player for a local video file. Never autoplays; pauses when the
/// tile is hidden and releases the player on `dispose()`.
@MainActor
final class FileVideoRenderer: NSView, FileTileRenderer {
    var view: NSView { self }
    var focusView: NSView { playerView }
    private(set) var revision: UInt64 = 0
    var scrollOffsets: [CGPoint] { [] }
    var onRevisionChange: (() -> Void)?
    private let playerView = AVPlayerView()

    init(url: URL) {
        super.init(frame: .zero)
        clipsToBounds = true
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        addSubview(playerView)
        setAccessibilityLabel("Video, \(url.lastPathComponent)")
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if playerView.frame != bounds { playerView.frame = bounds }
    }
    func applyTheme() {}
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if !visible { playerView.player?.pause() }
    }
    func dispose() {
        playerView.player?.pause()
        playerView.player = nil
        onRevisionChange = nil
    }
    var qaPlayerURL: URL? { (playerView.player?.currentItem?.asset as? AVURLAsset)?.url }
}
