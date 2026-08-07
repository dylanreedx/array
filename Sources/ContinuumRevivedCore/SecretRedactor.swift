import Foundation

public enum SecretRedactor {
    public static func redact(_ text: String, explicitSecrets: [String] = []) -> String {
        var redacted = text
        for secret in explicitSecrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        // Redact URL userinfo before any value is retained. This is deliberately
        // conservative: a URL with credentials is never allowed to keep the
        // user/password pair in a detail string.
        redacted = replace(redacted, pattern: #"(?i)([a-z][a-z0-9+.-]*://)([^/@\s]*(?::[^/@\s]*)?)@"#, template: "$1[REDACTED]@")
        redacted = replace(redacted, pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, template: "$1[REDACTED]")
        redacted = replace(redacted, pattern: #"(?i)(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, template: "$1[REDACTED]")
        // Cover both shell-ish key=value syntax and JSON's quoted
        // sensitive-key/value form. The latter must run before generic query
        // redaction so a quoted value can never survive as provider text.
        redacted = replace(redacted, pattern: #"(?i)([\"']?(?:password|passwd|pwd|secret|token|api[_-]?key|authorization|auth|credential|credentials|cookie|session|signing[_-]?key|signature|private[_-]?key|access[_-]?key|refresh[_-]?key|client[_-]?secret|ssh[_-]?key|jwt|bearer)[\"']?\s*:\s*)(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^,}\]\s]+)"#, template: "$1\"[REDACTED]\"")
        // Providers commonly serialize argv as `--token value`, not only as
        // `--token=value`. Parse an option/value pair with a bounded value and
        // redact only names made from credential words; near matches such as
        // `--tokenize` and `--monkey` remain ordinary arguments.
        redacted = redactSensitiveArguments(redacted)
        redacted = replace(redacted, pattern: #"(?i)(password|passwd|pwd|secret|token|api[_-]?key|authorization|auth|credential|credentials|cookie|session|signing[_-]?key|signature|private[_-]?key|access[_-]?key|refresh[_-]?key|client[_-]?secret|ssh[_-]?key|jwt)(\s*[=:]\s*)([^\s\"'&,}]+)"#, template: "$1$2[REDACTED]")
        redacted = replace(redacted, pattern: #"(?i)(document\.querySelector\([^\n]+\)\.value\s*=\s*)['\"][^'\"]+['\"]"#, template: "$1'[REDACTED]'")
        redacted = replace(redacted, pattern: #"([?&][^=&#]+)=([^&#]*)"#, template: "$1=[REDACTED]")
        return redacted
    }

    /// Extracts credential values from provider text for same-event privacy
    /// decisions. Results are bounded and are consumed immediately; callers
    /// must not retain them as detail payload.
    static func discoveredSensitiveValues(in text: String) -> [String] {
        var values: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               ((value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'")) {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.isEmpty, value.utf8.count <= 4_096, seen.insert(value).inserted else { return }
            values.append(value)
        }
        func appendMatchValues(_ pattern: String, _ indexes: [Int], keyIndex: Int? = nil) {
            for match in matches(in: text, pattern: pattern) {
                if let keyIndex,
                   let keyRange = Range(match.range(at: keyIndex), in: text),
                   !isSensitiveName(String(text[keyRange])) {
                    continue
                }
                for index in indexes {
                    guard match.range(at: index).location != NSNotFound,
                          let range = Range(match.range(at: index), in: text) else { continue }
                    append(String(text[range]))
                }
            }
        }

        // Header/JSON/shell key-value forms, including names such as
        // X-Api-Key and private-signing-key.
        appendMatchValues(
            #"(?i)([\"']?[-A-Za-z][A-Za-z0-9_-]*[\"']?\s*[:=]\s*)(?:\"([^\"\\]*(?:\\.[^\"\\]*)*)\"|'([^']*)'|([^\s\"',}&\]]+))"#,
            [2, 3, 4],
            keyIndex: 1
        )
        // Bearer headers and bearer-shaped output have no key/value separator.
        appendMatchValues(#"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]+)"#, [1])
        // A URL's userinfo is credential-bearing even when no explicit secret
        // was supplied. The whole userinfo is used only as an omission signal.
        appendMatchValues(#"(?i)[a-z][a-z0-9+.-]*://([^/@\s]+)@"#, [1])
        // Only sensitive query names contribute implicit secrets; ordinary
        // search/query parameters must not make every affected path disappear.
        for match in matches(in: text, pattern: #"(?i)[?&]([^=&#\s]+)=([^&#]*)"#) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  isSensitiveName(String(text[keyRange])),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            append(String(text[valueRange]))
        }
        // The argv parser is shared with redaction, so discovery and storage
        // use precisely the same bounded, false-positive-aware option grammar.
        for match in argvMatches(in: text) {
            guard let optionRange = Range(match.range(at: 2), in: text),
                  isSensitiveOptionName(String(text[optionRange])),
                  let valueRange = Range(match.range(at: 4), in: text) else { continue }
            append(String(text[valueRange]))
        }
        return values
    }

    static func isSensitiveName(_ raw: String) -> Bool {
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let sensitiveFragments = [
            "password", "passwd", "pwd", "secret", "token", "apikey", "authorization",
            "auth", "credential", "credentials", "cookie", "session", "signin", "signing",
            "signature", "private", "privatekey", "access", "accesskey", "refreshkey", "clientsecret",
            "sshkey", "jwt", "bearer"
        ]
        return sensitiveFragments.contains { normalized.contains($0) }
    }

    private static func redactSensitiveArguments(_ text: String) -> String {
        var result = text
        for match in argvMatches(in: text).reversed() {
            guard let optionRange = Range(match.range(at: 2), in: text),
                  isSensitiveOptionName(String(text[optionRange])),
                  let resultRange = Range(match.range(at: 4), in: result) else { continue }
            result.replaceSubrange(resultRange, with: "[REDACTED]")
        }
        return result
    }

    private static func argvMatches(in text: String) -> [NSTextCheckingResult] {
        matches(
            in: text,
            pattern: #"(?i)(^|[\s])(--?[A-Za-z0-9][A-Za-z0-9_-]{0,79})(=|[\t ]+)(\"(?:\\.|[^\"]){0,4095}\"|'(?:\\.|[^']){0,4095}'|[^\s-][^\s]{0,4095})"#
        )
    }

    private static func isSensitiveOptionName(_ raw: String) -> Bool {
        let name = raw.drop { $0 == "-" }
        var components: [String] = []
        for piece in name.split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            var current = ""
            for character in piece {
                if character.isUppercase, !current.isEmpty {
                    components.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            }
            if !current.isEmpty { components.append(current.lowercased()) }
        }
        let sensitiveComponents: Set<String> = [
            "password", "passwd", "pwd", "secret", "token", "key", "apikey", "authorization", "auth",
            "credential", "credentials", "cookie", "session", "signature", "signing", "private",
            "access", "refresh", "client", "ssh", "jwt", "bearer"
        ]
        return components.contains(where: sensitiveComponents.contains)
    }

    private static func matches(in text: String, pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range)
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
