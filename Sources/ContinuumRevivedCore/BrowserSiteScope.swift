import Foundation

/// Permission sites use the bundled Mozilla Public Suffix List, including its
/// private section: two github.io tenants must never share a browser grant.
public enum BrowserSiteScope {
    private static let rules: Set<String> = {
        guard let url = Bundle.module.url(forResource: "PublicSuffixList", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { return nil }
            let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
            let host = String(rule.dropFirst(prefix.count))
            return prefix + (URL(string: "https://" + host)?.host ?? host).lowercased()
        })
    }()

    public static func site(for host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        let labels = host.split(separator: ".").map(String.init)
        // Missing data fails closed to exact hosts. IP addresses are never sites.
        guard !rules.isEmpty, labels.count > 1, !host.contains(":"),
              !labels.allSatisfy({ UInt8($0) != nil }) else { return host }
        var suffixCount = 1
        for i in labels.indices {
            let suffix = labels[i...].joined(separator: ".")
            if rules.contains("!" + suffix) { suffixCount = labels.count - i - 1; break }
            if rules.contains(suffix) { suffixCount = max(suffixCount, labels.count - i) }
            if i > 0, rules.contains("*." + suffix) { suffixCount = max(suffixCount, labels.count - i + 1) }
        }
        guard labels.count > suffixCount else { return host }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
