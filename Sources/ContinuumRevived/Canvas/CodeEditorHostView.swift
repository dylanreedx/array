import AppKit
import Foundation
import ContinuumRevivedCore
@preconcurrency import WebKit

struct CodeEditorTextChange: Equatable, Sendable {
    let fromUTF16: Int
    let toUTF16: Int
    let insertedText: String
}

struct CodeEditorDocumentChange: Equatable, Sendable {
    let documentID: String
    let baseRevision: UInt64
    let revision: UInt64
    let changes: [CodeEditorTextChange]
}

struct CodeEditorSnapshot: Equatable, Sendable {
    let documentID: String
    let revision: UInt64
    let text: String
}

struct CodeEditorViewState: Equatable, Sendable {
    let line: Int
    let column: Int
    let scrollTop: Double
    let scrollLeft: Double
}

struct CodeEditorPositionRequest: Equatable, Sendable {
    let documentID: String
    let revision: UInt64
    let offsetUTF16: Int
    /// Zero-based line number.
    let line: Int
    /// Zero-based UTF-16 column.
    let columnUTF16: Int
    let requestID: UInt64
}

struct CodeEditorCompletionItem: Equatable, Sendable {
    let label: String
    let detail: String?
    let insertText: String?
    /// CodeMirror completion type, such as `function`, `variable`, or `class`.
    let kind: String?

    init(label: String, detail: String? = nil, insertText: String? = nil, kind: String? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.kind = kind
    }
}

struct CodeEditorDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable {
        case error, warning, info, hint
    }

    let fromUTF16: Int
    let toUTF16: Int
    let severity: Severity
    let message: String
}

enum CodeEditorHostError: Error, Equatable, LocalizedError {
    case assetsUnavailable
    case bridgeUnavailable
    case invalidBridgeReply
    case rejectedEdit(reason: String, revision: UInt64)
    case javaScript(String)

    var errorDescription: String? {
        switch self {
        case .assetsUnavailable: return "The bundled code editor assets are unavailable."
        case .bridgeUnavailable: return "The code editor bridge is not ready."
        case .invalidBridgeReply: return "The code editor returned an invalid reply."
        case let .rejectedEdit(reason, revision): return "The editor rejected the change (\(reason), revision \(revision))."
        case let .javaScript(message): return "The code editor failed: \(message)"
        }
    }
}

/// A local-only CodeMirror surface. File I/O and conflict ownership stay with
/// the native document controller; this view exchanges revisioned UTF-16 edits.
@MainActor
final class CodeEditorHostView: NSView {
    typealias Completion<T> = (Result<T, CodeEditorHostError>) -> Void

    let webView: WKWebView
    var onReady: (() -> Void)?
    var onSaveRequest: (() -> Void)?
    var onVimModeChange: ((String) -> Void)?
    private(set) var activeDocumentID: String?
    var onDocumentChange: ((CodeEditorDocumentChange) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onViewStateChange: ((CodeEditorViewState) -> Void)?
    var onCompletionRequest: ((CodeEditorPositionRequest) -> Void)?
    var onHoverRequest: ((CodeEditorPositionRequest) -> Void)?
    var onDefinitionRequest: ((CodeEditorPositionRequest) -> Void)?
    var onProcessTerminated: (() -> Void)?
    var onBridgeError: ((CodeEditorHostError) -> Void)?

    private static let messageHandlerName = "codeEditor"
    private static let resourceBundleName = "continuum-revived_ContinuumRevived.bundle"
    private let messageProxy = WeakCodeEditorMessageHandler()
    private var bridgeReady = false
    private var bridgeTask: Task<Void, Never>?
    private var pendingCalls: [() -> Void] = []

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        messageProxy.owner = self
        configuration.userContentController.add(messageProxy, name: Self.messageHandlerName)
        webView.navigationDelegate = messageProxy
        loadBundledEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func loadDocument(
        documentID: String,
        text: String,
        language: String,
        revision: UInt64,
        completion: Completion<UInt64>? = nil
    ) {
        activeDocumentID = documentID
        invoke(
            method: "loadDocument",
            payload: ["documentId": documentID, "text": text, "language": language, "revision": revision],
            completion: completion
        ) { reply in
            guard let revision = Self.uint64(reply["revision"]) else { throw CodeEditorHostError.invalidBridgeReply }
            return revision
        }
    }

    func applyEdits(
        documentID: String,
        expectedRevision: UInt64,
        revision: UInt64,
        changes: [CodeEditorTextChange],
        completion: Completion<UInt64>? = nil
    ) {
        let encodedChanges = changes.map {
            ["from": $0.fromUTF16, "to": $0.toUTF16, "insert": $0.insertedText] as [String: Any]
        }
        invoke(
            method: "applyEdits",
            payload: [
                "documentId": documentID,
                "expectedRevision": expectedRevision,
                "revision": revision,
                "changes": encodedChanges
            ],
            completion: completion
        ) { reply in
            guard let currentRevision = Self.uint64(reply["revision"]) else { throw CodeEditorHostError.invalidBridgeReply }
            guard reply["accepted"] as? Bool == true else {
                throw CodeEditorHostError.rejectedEdit(
                    reason: reply["reason"] as? String ?? "unknown",
                    revision: currentRevision
                )
            }
            return currentRevision
        }
    }

    func setLanguage(documentID: String, language: String, completion: Completion<Void>? = nil) {
        invoke(
            method: "setLanguage",
            payload: ["documentId": documentID, "name": language],
            completion: completion
        ) { _ in () }
    }

    func requestSnapshot(documentID: String, freeze: Bool = false, completion: @escaping Completion<CodeEditorSnapshot>) {
        invoke(method: "snapshot", payload: ["documentId": documentID, "freeze": freeze], completion: completion) { reply in
            guard let documentID = reply["documentId"] as? String,
                  let revision = Self.uint64(reply["revision"]),
                  let text = reply["text"] as? String else {
                throw CodeEditorHostError.invalidBridgeReply
            }
            return CodeEditorSnapshot(documentID: documentID, revision: revision, text: text)
        }
    }

    func provideCompletions(
        documentID: String,
        requestID: UInt64,
        items: [CodeEditorCompletionItem],
        isIncomplete: Bool = false,
        completion: Completion<Bool>? = nil
    ) {
        let encodedItems = items.map { item -> [String: Any] in
            var encoded: [String: Any] = ["label": item.label]
            if let detail = item.detail { encoded["detail"] = detail }
            if let insertText = item.insertText { encoded["insertText"] = insertText }
            if let kind = item.kind { encoded["kind"] = kind }
            return encoded
        }
        invoke(
            method: "provideCompletions",
            payload: [
                "documentId": documentID,
                "requestId": requestID,
                "items": encodedItems,
                "isIncomplete": isIncomplete
            ],
            completion: completion
        ) { reply in reply["accepted"] as? Bool ?? false }
    }

    func setDiagnostics(
        documentID: String,
        revision: UInt64,
        diagnostics: [CodeEditorDiagnostic],
        completion: Completion<Bool>? = nil
    ) {
        let encodedDiagnostics = diagnostics.map { diagnostic in
            [
                "from": diagnostic.fromUTF16,
                "to": diagnostic.toUTF16,
                "severity": diagnostic.severity.rawValue,
                "message": diagnostic.message
            ] as [String: Any]
        }
        invoke(
            method: "setDiagnostics",
            payload: ["documentId": documentID, "revision": revision, "diagnostics": encodedDiagnostics],
            completion: completion
        ) { reply in reply["accepted"] as? Bool ?? false }
    }

    func provideHover(
        documentID: String,
        requestID: UInt64,
        text: String?,
        completion: Completion<Bool>? = nil
    ) {
        invoke(
            method: "provideHover",
            payload: ["documentId": documentID, "requestId": requestID, "text": text ?? NSNull()],
            completion: completion
        ) { reply in reply["accepted"] as? Bool ?? false }
    }

    func focusEditor(documentID: String) {
        invoke(
            method: "runCommand",
            payload: ["documentId": documentID, "command": "focus"],
            completion: nil
        ) { _ in () }
    }

    func reveal(documentID: String, line: Int, column: Int?) {
        invoke(
            method: "runCommand",
            payload: [
                "documentId": documentID,
                "command": "reveal",
                "line": line,
                "column": column ?? 1
            ],
            completion: nil
        ) { _ in () }
    }

    func restoreViewState(documentID: String, state: CodeEditorViewState) {
        invoke(
            method: "runCommand",
            payload: [
                "documentId": documentID, "command": "restoreViewState",
                "line": state.line, "column": state.column,
                "scrollTop": state.scrollTop, "scrollLeft": state.scrollLeft
            ],
            completion: nil
        ) { _ in () }
    }

    func runCommand(documentID: String, command: String) {
        invoke(method: "runCommand", payload: ["documentId": documentID, "command": command], completion: nil) { _ in () }
    }

    func setPreferences(_ preferences: EditorPreferences, isDark: Bool) {
        invoke(method: "setPreferences", payload: [
            "appearance": isDark ? "dark" : "light",
            "fontFamily": preferences.fontFamily == EditorPreferences.defaultFontFamily ? "ui-monospace, SFMono-Regular, Menlo, monospace" : preferences.fontFamily,
            "fontSize": preferences.fontSize,
            "lineHeight": preferences.lineHeight,
            "lineNumbers": preferences.lineNumbers,
            "wordWrap": preferences.wordWrap,
            "vimEnabled": preferences.vimEnabled
        ], completion: nil) { _ in () }
    }

    func setAppearance(_ appearance: String) {
        invoke(
            method: "setAppearance",
            payload: ["appearance": appearance],
            completion: nil
        ) { _ in () }
    }

    func tearDown() {
        bridgeTask?.cancel()
        bridgeTask = nil
        pendingCalls.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        messageProxy.owner = nil
        onReady = nil
        onDocumentChange = nil
        onFocusChange = nil
        onViewStateChange = nil
        onCompletionRequest = nil
        onHoverRequest = nil
        onDefinitionRequest = nil
        onProcessTerminated = nil
        onBridgeError = nil
    }

    private func loadBundledEditor() {
        let bundleCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(Self.resourceBundleName, isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent(Self.resourceBundleName, isDirectory: true)
        ].compactMap { $0 }
        guard let resourceBundle = bundleCandidates.lazy.compactMap(Bundle.init(url:)).first,
              let indexURL = resourceBundle.url(forResource: "index", withExtension: "html", subdirectory: "CodeEditor") else {
            report(.assetsUnavailable)
            return
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    fileprivate func recoverAfterWebProcessTermination() {
        bridgeReady = false
        pendingCalls.removeAll()
        loadBundledEditor()
        onProcessTerminated?()
    }

    private func invoke<T>(
        method: String,
        payload: [String: Any],
        completion: Completion<T>?,
        decode: @escaping ([String: Any]) throws -> T
    ) {
        let call = { [weak self] in
            guard let self else { return }
            let previous = self.bridgeTask
            self.bridgeTask = Task { @MainActor in
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    let raw = try await self.webView.callAsyncJavaScript(
                        "return window.arrayEditor[method](payload)",
                        arguments: ["method": method, "payload": payload],
                        in: nil,
                        contentWorld: .page
                    )
                    guard let reply = raw as? [String: Any] else { throw CodeEditorHostError.invalidBridgeReply }
                    completion?(.success(try decode(reply)))
                } catch let error as CodeEditorHostError {
                    completion?(.failure(error))
                    self.report(error)
                } catch {
                    let wrapped = CodeEditorHostError.javaScript(error.localizedDescription)
                    completion?(.failure(wrapped))
                    self.report(wrapped)
                }
            }
        }
        if bridgeReady { call() } else { pendingCalls.append(call) }
    }

    fileprivate func receiveBridgeMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else {
            report(.invalidBridgeReply)
            return
        }
        if type != "ready", let identity = message["documentId"] as? String,
           identity != activeDocumentID { return }
        switch type {
        case "saveRequest": onSaveRequest?()
        case "vimModeChanged": onVimModeChange?(message["mode"] as? String ?? "off")
        case "ready":
            bridgeReady = true
            let calls = pendingCalls
            pendingCalls.removeAll()
            calls.forEach { $0() }
            onReady?()
        case "focusChanged":
            if let focused = message["focused"] as? Bool { onFocusChange?(focused) }
        case "viewState":
            guard let line = Self.int(message["line"]),
                  let column = Self.int(message["column"]),
                  let scrollTop = (message["scrollTop"] as? NSNumber)?.doubleValue,
                  let scrollLeft = (message["scrollLeft"] as? NSNumber)?.doubleValue else {
                report(.invalidBridgeReply); return
            }
            onViewStateChange?(CodeEditorViewState(
                line: line, column: column, scrollTop: scrollTop, scrollLeft: scrollLeft
            ))
        case "changed":
            guard let documentID = message["documentId"] as? String,
                  let baseRevision = Self.uint64(message["baseRevision"]),
                  let revision = Self.uint64(message["revision"]),
                  let rawChanges = message["changes"] as? [[String: Any]] else {
                report(.invalidBridgeReply)
                return
            }
            let changes = rawChanges.compactMap { raw -> CodeEditorTextChange? in
                guard let from = Self.int(raw["from"]),
                      let to = Self.int(raw["to"]),
                      let insert = raw["insert"] as? String else { return nil }
                return CodeEditorTextChange(fromUTF16: from, toUTF16: to, insertedText: insert)
            }
            guard changes.count == rawChanges.count else { report(.invalidBridgeReply); return }
            onDocumentChange?(CodeEditorDocumentChange(
                documentID: documentID,
                baseRevision: baseRevision,
                revision: revision,
                changes: changes
            ))
        case "completionRequest":
            if let request = Self.positionRequest(message) {
                if let onCompletionRequest { onCompletionRequest(request) }
                else { provideCompletions(documentID: request.documentID, requestID: request.requestID, items: []) }
            } else { report(.invalidBridgeReply) }
        case "hoverRequest":
            if let request = Self.positionRequest(message) {
                if let onHoverRequest { onHoverRequest(request) }
                else { provideHover(documentID: request.documentID, requestID: request.requestID, text: nil) }
            } else { report(.invalidBridgeReply) }
        case "definitionRequest":
            if let request = Self.positionRequest(message) { onDefinitionRequest?(request) }
            else { report(.invalidBridgeReply) }
        default:
            break
        }
    }

    private func report(_ error: CodeEditorHostError) { onBridgeError?(error) }

    private static func uint64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func positionRequest(_ message: [String: Any]) -> CodeEditorPositionRequest? {
        guard let documentID = message["documentId"] as? String,
              let revision = uint64(message["revision"]),
              let offset = int(message["offset"]),
              let line = int(message["line"]),
              let column = int(message["column"]),
              let requestID = uint64(message["requestId"]) else { return nil }
        return CodeEditorPositionRequest(
            documentID: documentID,
            revision: revision,
            offsetUTF16: offset,
            line: line,
            columnUTF16: column,
            requestID: requestID
        )
    }
}

@MainActor
private final class WeakCodeEditorMessageHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var owner: CodeEditorHostView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveBridgeMessage(message.body)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.recoverAfterWebProcessTermination()
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let allowed = navigationAction.request.url?.isFileURL == true
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
