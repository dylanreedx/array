import Foundation

public enum LSPValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([LSPValue]), object([String: LSPValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LSPValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LSPValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}

public struct LSPPosition: Codable, Equatable, Sendable { public var line, character: Int; public init(line: Int, character: Int) { self.line = line; self.character = character } }
public struct LSPRange: Codable, Equatable, Sendable { public var start, end: LSPPosition; public init(start: LSPPosition, end: LSPPosition) { self.start = start; self.end = end } }
public struct LSPDiagnostic: Codable, Equatable, Sendable { public var range: LSPRange; public var severity: Int?; public var message: String }
public struct LSPCompletionItem: Codable, Equatable, Sendable { public var label: String; public var detail: String?; public var insertText: String? }
public struct LSPLocation: Codable, Equatable, Sendable { public var uri: String; public var range: LSPRange }

public protocol LanguageServerTransport: Sendable {
    func request(method: String, params: LSPValue) async throws -> LSPValue
    func notify(method: String, params: LSPValue) async throws
    func stop() async
    func setNotificationHandler(_ handler: (@Sendable (String, LSPValue) -> Void)?) async
}

public protocol LanguageServerByteStream: Sendable {
    func start(_ receive: @escaping @Sendable (Data) -> Void, _ terminated: @escaping @Sendable (Error?) -> Void) async throws
    func write(_ data: Data) async throws
    func stop() async
}

public enum LanguageServerTransportError: Error, Equatable { case stopped, invalidResponse(String), serverError(code: Int, message: String) }

/// JSON-RPC 2.0 over the LSP Content-Length wire format. The byte stream is
/// injected so tests never spawn a server and the production Process adapter can
/// remain owned by the macOS app target.
public actor JSONRPCLanguageServerTransport: LanguageServerTransport {
    private let stream: any LanguageServerByteStream
    private var framer = LSPContentLengthFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<LSPValue, Error>] = [:]
    private var notificationHandler: (@Sendable (String, LSPValue) -> Void)?
    private var started = false

    public init(stream: any LanguageServerByteStream) { self.stream = stream }
    public func setNotificationHandler(_ handler: (@Sendable (String, LSPValue) -> Void)?) { notificationHandler = handler }

    public func request(method: String, params: LSPValue) async throws -> LSPValue {
        try await ensureStarted()
        let id = nextID; nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do { try await stream.write(try Self.message(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])) }
                    catch { self.fail(id: id, error: error) }
                }
            }
        } onCancel: { Task { await self.fail(id: id, error: CancellationError()) } }
    }

    public func notify(method: String, params: LSPValue) async throws {
        try await ensureStarted()
        try await stream.write(try Self.message(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    public func stop() async { failAll(LanguageServerTransportError.stopped); await stream.stop(); started = false }

    private func ensureStarted() async throws {
        guard !started else { return }; started = true
        do {
            try await stream.start({ [weak self] data in Task { await self?.receive(data) } }, { [weak self] error in Task { await self?.terminated(error) } })
        } catch { started = false; throw error }
    }
    private func receive(_ data: Data) {
        do { for body in try framer.append(data) { handle(body) } } catch { failAll(error) }
    }
    private func handle(_ data: Data) {
        guard let value = try? JSONDecoder().decode(LSPValue.self, from: data), case .object(let object) = value else { return }
        if case .number(let rawID) = object["id"], let continuation = pending.removeValue(forKey: Int(rawID)) {
            if case .object(let error) = object["error"], case .number(let code) = error["code"], case .string(let message) = error["message"] { continuation.resume(throwing: LanguageServerTransportError.serverError(code: Int(code), message: message)) }
            else if let result = object["result"] { continuation.resume(returning: result) }
            else { continuation.resume(throwing: LanguageServerTransportError.invalidResponse("Response has neither result nor error")) }
        } else if case .string(let method) = object["method"] {
            notificationHandler?(method, object["params"] ?? .null)
            // LSP servers may issue optional client requests (commonly
            // workspace/configuration). A null response is protocol-valid and
            // prevents the server from waiting forever until Array supports it.
            if let id = object["id"] {
                Task { try? await stream.write(try Self.message(["jsonrpc": .string("2.0"), "id": id, "result": .null])) }
            }
        }
    }
    private func fail(id: Int, error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private func terminated(_ error: Error?) { failAll(error ?? LanguageServerTransportError.stopped); started = false }
    private func failAll(_ error: Error) { let current = pending; pending.removeAll(); for continuation in current.values { continuation.resume(throwing: error) } }
    private static func message(_ object: [String: LSPValue]) throws -> Data { LSPContentLengthFramer.frame(try JSONEncoder().encode(LSPValue.object(object))) }
}

public struct LanguageDocumentSnapshot: Equatable, Sendable {
    public var uri, languageId, text: String; public var version: Int
    public init(uri: String, languageId: String, text: String, version: Int) { self.uri = uri; self.languageId = languageId; self.text = text; self.version = version }
}

public actor LanguageServiceCoordinator {
    public let projectRoot: URL
    private let transport: any LanguageServerTransport
    private var documents: [String: LanguageDocumentSnapshot] = [:]
    public var onDiagnostics: (@Sendable (String, [LSPDiagnostic]) -> Void)?

    public init(projectRoot: URL, transport: any LanguageServerTransport) { self.projectRoot = projectRoot.standardizedFileURL; self.transport = transport }
    public func setDiagnosticsHandler(_ handler: (@Sendable (String, [LSPDiagnostic]) -> Void)?) {
        onDiagnostics = handler
    }

    public func initialize(processId: Int? = nil) async throws {
        await transport.setNotificationHandler { [weak self] method, params in
            guard method == "textDocument/publishDiagnostics" else { return }
            Task { await self?.publishDiagnostics(params) }
        }
        let root = projectRoot.absoluteString
        _ = try await transport.request(method: "initialize", params: .object([
            "processId": processId.map { .number(Double($0)) } ?? .null,
            "rootUri": .string(root), "capabilities": .object([:])
        ]))
        try await transport.notify(method: "initialized", params: .object([:]))
    }

    public func open(_ document: LanguageDocumentSnapshot) async throws {
        documents[document.uri] = document
        try await transport.notify(method: "textDocument/didOpen", params: .object(["textDocument": documentValue(document)]))
    }

    public func change(uri: String, text: String, version: Int) async throws {
        guard var document = documents[uri], version > document.version else { return }
        document.text = text; document.version = version; documents[uri] = document
        try await transport.notify(method: "textDocument/didChange", params: .object([
            "textDocument": .object(["uri": .string(uri), "version": .number(Double(version))]),
            "contentChanges": .array([.object(["text": .string(text)])])
        ]))
    }

    public func save(uri: String) async throws {
        guard let document = documents[uri] else { return }
        try await transport.notify(method: "textDocument/didSave", params: .object([
            "textDocument": .object(["uri": .string(uri)]),
            "text": .string(document.text)
        ]))
    }

    public func close(uri: String) async throws {
        guard documents.removeValue(forKey: uri) != nil else { return }
        try await transport.notify(method: "textDocument/didClose", params: .object(["textDocument": .object(["uri": .string(uri)])]))
    }

    public func completion(uri: String, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let result = try await positionRequest("textDocument/completion", uri: uri, position: position)
        let values: [LSPValue]
        switch result { case .array(let a): values = a; case .object(let o): if case .array(let a) = o["items"] { values = a } else { values = [] }; default: values = [] }
        return decode(values, as: LSPCompletionItem.self)
    }

    public func hover(uri: String, position: LSPPosition) async throws -> LSPValue { try await positionRequest("textDocument/hover", uri: uri, position: position) }
    public func definition(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        let value = try await positionRequest("textDocument/definition", uri: uri, position: position)
        if case .array(let values) = value { return decode(values, as: LSPLocation.self) }
        return decode([value], as: LSPLocation.self)
    }
    public func publishDiagnostics(_ params: LSPValue) {
        guard case .object(let object) = params, case .string(let uri) = object["uri"], case .array(let values) = object["diagnostics"] else { return }
        onDiagnostics?(uri, decode(values, as: LSPDiagnostic.self))
    }
    public func shutdown() async { _ = try? await transport.request(method: "shutdown", params: .null); try? await transport.notify(method: "exit", params: .null); await transport.setNotificationHandler(nil); await transport.stop() }

    private func positionRequest(_ method: String, uri: String, position: LSPPosition) async throws -> LSPValue {
        try await transport.request(method: method, params: .object(["textDocument": .object(["uri": .string(uri)]), "position": encode(position)]))
    }
    private func documentValue(_ d: LanguageDocumentSnapshot) -> LSPValue { .object(["uri": .string(d.uri), "languageId": .string(d.languageId), "version": .number(Double(d.version)), "text": .string(d.text)]) }
    private func encode<T: Encodable>(_ value: T) -> LSPValue { (try? JSONDecoder().decode(LSPValue.self, from: JSONEncoder().encode(value))) ?? .null }
    private func decode<T: Decodable>(_ values: [LSPValue], as: T.Type) -> [T] { values.compactMap { try? JSONDecoder().decode(T.self, from: JSONEncoder().encode($0)) } }
}

public struct LSPContentLengthFramer: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data); var messages: [Data] = []
        while let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)), length >= 0 else { throw FramingError.invalidHeader }
            let bodyStart = boundary.upperBound; guard buffer.count - bodyStart >= length else { break }
            messages.append(buffer.subdata(in: bodyStart..<(bodyStart + length)))
            buffer.removeSubrange(0..<(bodyStart + length))
        }
        if buffer.count > 16 * 1_024 * 1_024 { throw FramingError.frameTooLarge }
        return messages
    }
    public enum FramingError: Error { case invalidHeader, frameTooLarge }
    public static func frame(_ body: Data) -> Data { Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
}
