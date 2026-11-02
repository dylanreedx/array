import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import WebKit

/// Floats at the top of a browser tile after a page's passkey request fails
/// (see `BrowserPasskeySupport`). Drawn with the shared tokens, like
/// `SharedAgentArrivalBanner`; clicking anywhere dismisses it.
@MainActor
final class BrowserPasskeyNotice: NSView {
    static let title = "Passkeys don’t work in Array browsers yet."
    static let detail = "Choose “Try another way” on this page to sign in with your password or a code."
    static let dismiss = "Dismiss"

    var onDismiss: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.title + " " + Self.detail)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.label), .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]
    }
    private var detailAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.caption), .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)]
    }
    private var dismissAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.label), .foregroundColor: AccentToken.accentWorking.color.nsColor(in: self)]
    }

    static let preferredHeight: CGFloat = 48

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        SurfaceToken.overlay.color.nsColor(in: self).setFill(); card.fill()
        LineToken.border.color.nsColor(in: self).setStroke(); card.lineWidth = 1; card.stroke()
        let dismissSize = (Self.dismiss as NSString).size(withAttributes: dismissAttributes)
        let textWidth = max(0, bounds.width - dismissSize.width - 40)
        let titleRect = NSRect(x: 14, y: 8, width: textWidth, height: 16)
        let detailRect = NSRect(x: 14, y: 26, width: textWidth, height: 15)
        let truncating: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        (Self.title as NSString).draw(with: titleRect, options: truncating, attributes: titleAttributes)
        (Self.detail as NSString).draw(with: detailRect, options: truncating, attributes: detailAttributes)
        (Self.dismiss as NSString).draw(at: NSPoint(x: bounds.width - dismissSize.width - 14, y: bounds.midY - dismissSize.height / 2), withAttributes: dismissAttributes)
    }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func accessibilityPerformPress() -> Bool { onDismiss?(); return true }
}

extension BrowserTileNSView {
    /// `--browser-passkey-notice-check`. Drives a real WKWebView page whose
    /// `navigator.credentials.get` WebKit rejects, and expects the tile to
    /// explain it; renders the notice in light and dark into `outputDir`.
    static func runPasskeyNoticeSelfCheck(outputDir: URL) throws -> [String: Any] {
        struct CheckError: Error, CustomStringConvertible { let description: String }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError(description: message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return condition()
        }
        func evaluate(_ webView: WKWebView, _ body: String) throws -> Any? {
            var outcome: Result<Any, Error>?
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0 }
            guard waitUntil(10, { outcome != nil }) else { throw CheckError(description: "page script timed out: \(body.prefix(60))") }
            return try outcome?.get()
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let tileId = TileID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let runtime = WKWebViewBrowserRuntime(tileId: tileId, webView: webView, initialURL: "about:blank")
        let tile = Tile(
            id: tileId, kind: .browser, title: "Browser",
            frame: TileFrame(x: 0, y: 0, width: 640, height: 420),
            zPosition: .fromLegacyRank(0), runtimeRef: nil,
            metadata: TileMetadata(url: "https://fixture.test/signin")
        )
        let browserTile = BrowserTileNSView(tile: tile, runtime: runtime)
        browserTile.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        browserTile.layoutSubtreeIfNeeded()

        if BrowserPasskeySupport.processIsEntitled {
            // A provisioned release: WebKit handles passkeys, so the tile must
            // leave the page's credentials calls alone.
            try expect(!runtime.passkeyFailureWatchInstalledForQA, "an entitled build must not wrap navigator.credentials")
            runtime.terminate(policy: .force)
            return ["processIsEntitled": true]
        }
        try expect(runtime.passkeyFailureWatchInstalledForQA, "an unentitled tile must watch for passkey failures")

        webView.loadHTMLString("<html><head><title>Sign in</title></head><body><button id='passkey'>Use a passkey</button></body></html>", baseURL: URL(string: "https://fixture.test/signin"))
        try expect(waitUntil { !webView.isLoading && webView.url?.host == "fixture.test" }, "fixture page did not load")
        try expect(!browserTile.passkeyNoticeVisibleForQA, "notice must not show before any passkey request")

        // What a page sees today. WebKit also reports no platform
        // authenticator to an app without the entitlement.
        let platformAvailable = try evaluate(webView, "return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();") as? Bool
        let rejection = try evaluate(webView, """
            try {
              await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32), rpId: 'fixture.test', timeout: 5000, userVerification: 'preferred' } });
              return 'resolved';
            } catch (error) { return error.name + ': ' + error.message; }
            """) as? String ?? ""
        try expect(rejection.hasPrefix("NotAllowedError"), "the page's passkey request should reject with NotAllowedError, got \(rejection)")
        try expect(waitUntil { browserTile.passkeyNoticeVisibleForQA }, "a rejected passkey request must show the passkey notice on the tile")
        browserTile.layoutSubtreeIfNeeded()
        let noticeFrame = browserTile.passkeyNoticeFrameForQA
        try expect(noticeFrame.height >= BrowserPasskeyNotice.preferredHeight && noticeFrame.width > 200, "notice must be laid out on the tile, got \(noticeFrame)")

        browserTile.dismissPasskeyNoticeForQA()
        try expect(!browserTile.passkeyNoticeVisibleForQA, "dismiss must hide the notice")

        // Control: a non-WebAuthn credentials call is not a passkey failure.
        _ = try evaluate(webView, "try { await navigator.credentials.get({ password: true }); } catch (_) {} return 'done';")
        _ = waitUntil(0.5) { browserTile.passkeyNoticeVisibleForQA }
        try expect(!browserTile.passkeyNoticeVisibleForQA, "a non-passkey credentials call must not show the notice")

        // Light and dark rendering of the notice itself.
        var renders: [String: String] = [:]
        var inks: [String: Int] = [:]
        var corners: [String: [CGFloat]] = [:]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let notice = BrowserPasskeyNotice(frame: NSRect(x: 0, y: 0, width: 520, height: BrowserPasskeyNotice.preferredHeight))
            notice.appearance = NSAppearance(named: appearanceName)
            guard let rep = notice.bitmapImageRepForCachingDisplay(in: notice.bounds) else { throw CheckError(description: "no bitmap for \(name)") }
            notice.cacheDisplay(in: notice.bounds, to: rep)
            let fill = rep.colorAt(x: 8, y: Int(rep.pixelsHigh / 2))?.usingColorSpace(.sRGB)
            var ink = 0
            for x in stride(from: 14, to: rep.pixelsWide - 80, by: 2) {
                for y in stride(from: 6, to: rep.pixelsHigh - 6, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let f = fill else { continue }
                    if abs(c.brightnessComponent - f.brightnessComponent) > 0.25 { ink += 1 }
                }
            }
            inks[name] = ink
            corners[name] = [fill?.redComponent ?? -1, fill?.greenComponent ?? -1, fill?.blueComponent ?? -1]
            let url = outputDir.appendingPathComponent("passkey-notice-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            renders[name] = url.path
        }
        try expect((inks["light"] ?? 0) > 50 && (inks["dark"] ?? 0) > 50, "notice text must render in both appearances, ink \(inks)")
        let lightFill = corners["light"]?.reduce(0, +) ?? 0, darkFill = corners["dark"]?.reduce(0, +) ?? 0
        try expect(lightFill > darkFill + 0.6, "light fill must be lighter than dark fill, got \(corners)")

        runtime.terminate(policy: .force)
        return [
            "processIsEntitled": BrowserPasskeySupport.processIsEntitled,
            "isUserVerifyingPlatformAuthenticatorAvailable": platformAvailable as Any,
            "pageRejection": rejection,
            "noticeFrame": NSStringFromRect(noticeFrame),
            "renders": renders,
            "ink": inks
        ]
    }
}
