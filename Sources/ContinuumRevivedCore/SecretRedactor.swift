import Foundation

public enum SecretRedactor {
    public static func redact(_ text: String, explicitSecrets: [String] = []) -> String {
        var redacted = text
        for secret in explicitSecrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        redacted = replace(redacted, pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, template: "$1[REDACTED]")
        redacted = replace(redacted, pattern: #"(?i)(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, template: "$1[REDACTED]")
        redacted = replace(redacted, pattern: #"(?i)(password|passwd|pwd|secret|token|api[_-]?key|authorization)(\s*[=:]\s*)([^\s\"'&,}]+)"#, template: "$1$2[REDACTED]")
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
