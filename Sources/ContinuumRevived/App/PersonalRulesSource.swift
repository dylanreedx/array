import Foundation

/// Read-only, launch-local experiment. Never consult CLI homes or memory.
/// An unavailable cache never delays or refuses a launch. Restart to reload.
final class PersonalRulesSource: HostLaunchInstructionSource, @unchecked Sendable {
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
                    result = (value.isEmpty ? nil : value, "loaded")
                } else { result = (nil, "invalid-utf8") }
            } catch { result = (nil, "unavailable") }
            lock.lock(); text = result.0; state = result.1; lock.unlock()
            // Status only: neither the path nor personal contents enter diagnostics.
            fputs("Personal rules: \(result.1)\n", stderr)
        }
    }

    var status: String { lock.lock(); defer { lock.unlock() }; return state }
    var launchInstructionBlock: HostLaunchInstructionBlock? {
        lock.lock(); let value = text; lock.unlock()
        guard let value else { return nil }
        return HostLaunchInstructionBlock(name: "personal-rules", label: "Personal working rules", text: value)
    }
}

/// Each layer retains its own bytes and identity. Only argv rendering joins them.
struct HostLaunchInstructionBlock: Sendable, Equatable {
    let name: String
    let label: String
    let text: String
}

protocol HostLaunchInstructionSource: Sendable {
    var launchInstructionBlock: HostLaunchInstructionBlock? { get }
}

/// The host's registration order is the delivery order, independent of load timing.
/// Keep sources separate; a future host-owned layer registers its own source here.
struct HostLaunchInstructions: Sendable {
    static let shared = HostLaunchInstructions(sources: [PersonalRulesSource.shared])
    let sources: [any HostLaunchInstructionSource]

    var blocks: [HostLaunchInstructionBlock] {
        var names = Set<String>()
        return sources.compactMap { $0.launchInstructionBlock }.filter { names.insert($0.name).inserted }
    }

    func arguments(codex: Bool) -> [String] {
        let rendered = blocks.map { $0.label + ":\n" + $0.text }.joined(separator: "\n\n")
        guard !rendered.isEmpty else { return [] }
        if codex {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let bytes = try? encoder.encode(rendered),
                  let quoted = String(data: bytes, encoding: .utf8) else { return [] }
            return ["-c", "developer_instructions=\(quoted)"]
        }
        return ["--append-system-prompt", rendered]
    }
}

/// Fixture-only second source: no additional production instruction block exists.
enum HostLaunchInstructionChecks {
    private struct FixtureSource: HostLaunchInstructionSource {
        let launchInstructionBlock: HostLaunchInstructionBlock?
    }

    static func run() throws {
        func expect(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "HostLaunchInstructionChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let first = HostLaunchInstructionBlock(name: "first-fixture", label: "First fixture", text: "one\n  unchanged")
        let second = HostLaunchInstructionBlock(name: "second-fixture", label: "Second fixture", text: "two / \"quoted\"")
        let sources = [FixtureSource(launchInstructionBlock: first), FixtureSource(launchInstructionBlock: nil),
                       FixtureSource(launchInstructionBlock: second), FixtureSource(launchInstructionBlock: first)]
        let instructions = HostLaunchInstructions(sources: sources)
        try expect(instructions.blocks == [first, second], "named blocks lost order or were duplicated")
        let expected = "First fixture:\n" + first.text + "\n\nSecond fixture:\n" + second.text
        try expect(instructions.arguments(codex: false) == ["--append-system-prompt", expected], "Pi block rendering changed")
        let codex = instructions.arguments(codex: true)
        try expect(codex.count == 2 && codex[0] == "-c", "Codex instruction switch changed")
        let prefix = "developer_instructions="
        try expect(codex[1].hasPrefix(prefix), "Codex instruction key changed")
        let decoded = try JSONDecoder().decode(String.self, from: Data(codex[1].dropFirst(prefix.count).utf8))
        try expect(decoded == expected, "Codex block rendering changed")
        try expect(sources[0].launchInstructionBlock == first && sources[2].launchInstructionBlock == second,
                   "renderer changed a source")
        try expect(HostLaunchInstructions(sources: []).arguments(codex: true).isEmpty, "empty host changed launch")
    }
}
