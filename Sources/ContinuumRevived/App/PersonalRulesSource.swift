import Foundation

/// Read-only, launch-local experiment. Never consult CLI homes or memory.
/// An unavailable cache never delays or refuses a launch. Restart to reload.
final class PersonalRulesSource: @unchecked Sendable {
    static let shared = PersonalRulesSource(environment: ProcessInfo.processInfo.environment)
    private let lock = NSLock()
    private var text: String?
    private var state = "disabled"
    static let byteLimit = 65_536

    init(environment: [String: String]) {
        guard environment["CONTINUUM_PERSONAL_RULES_ENABLED"] == "1",
              let path = environment["CONTINUUM_PERSONAL_RULES_FILE"], !path.isEmpty else { return }
        state = "loading"
        DispatchQueue.global(qos: .utility).async { [self] in
            let result: (String?, String)
            do {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                let bytes = try file.read(upToCount: Self.byteLimit + 1) ?? Data()
                if bytes.count > Self.byteLimit { result = (nil, "oversized") }
                else if let value = String(data: bytes, encoding: .utf8) {
                    result = (value.isEmpty ? nil : "Personal working rules:\n" + value, "loaded")
                } else { result = (nil, "invalid-utf8") }
            } catch { result = (nil, "unavailable") }
            lock.lock(); text = result.0; state = result.1; lock.unlock()
            // Status only: neither the path nor personal contents enter diagnostics.
            fputs("Personal rules: \(result.1)\n", stderr)
        }
    }

    var status: String { lock.lock(); defer { lock.unlock() }; return state }
    func arguments(codex: Bool) -> [String] {
        lock.lock(); let value = text; lock.unlock()
        guard let value else { return [] }
        if codex {
            // JSON string syntax is valid TOML basic-string syntax for this payload.
            guard let bytes = try? { () throws -> Data in let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes; return try encoder.encode(value) }(),
                  let quoted = String(data: bytes, encoding: .utf8) else { return [] }
            return ["-c", "developer_instructions=\(quoted)"]
        }
        return ["--append-system-prompt", value]
    }
}
