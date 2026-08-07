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
        redacted = replace(redacted, pattern: #"(?i)(password|passwd|pwd|secret|token|api[_-]?key|authorization|auth|credential|credentials|cookie|session|signing[_-]?key|signature|private[_-]?key|access[_-]?key|refresh[_-]?key|client[_-]?secret|ssh[_-]?key|jwt)(\s*[=:]\s*)([^\s\"'&,}]+)"#, template: "$1$2[REDACTED]")
        // Providers commonly serialize argv as `--token value`, not only as
        // `--token=value`. Redact the following token as one fail-closed unit.
        redacted = replace(redacted, pattern: #"(?i)(^|[\s])(--?(?:password|passwd|pwd|secret|token|api[-_]?key|authorization|auth|credential|credentials|cookie|session|signing[-_]?key|signature|private[-_]?key|access[-_]?key|refresh[-_]?key|client[-_]?secret|ssh[-_]?key|jwt|bearer)(?:\s+|=))(\"[^\"]*\"|'[^']*'|[^\s]+)"#, template: "$1$2[REDACTED]")
        redacted = replace(redacted, pattern: #"(?i)(document\.querySelector\([^\n]+\)\.value\s*=\s*)['\"][^'\"]+['\"]"#, template: "$1'[REDACTED]'")
        redacted = replace(redacted, pattern: #"([?&][^=&#]+)=([^&#]*)"#, template: "$1=[REDACTED]")
        return redacted
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
