import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 16, step 1 (`docs/internals/project-standards-on-demand.md`):
/// the production standards parser and `standards.read` answer over fixtures
/// this check writes into its own temporary checkout. Broken standards must be
/// explicit issues; the valid ones beside them must survive verbatim; nothing
/// outside the checkout may be read. RED before the parser existed: `scan`
/// returned nil and every standard was invisible.
func runProjectStandardsIndexChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("standards-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let checkout = base.appendingPathComponent("checkout", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    let standards = checkout.appendingPathComponent("docs/standards", isDirectory: true)
    func write(_ relative: String, _ text: String, under root: URL) {
        let url = root.appendingPathComponent(relative)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    // A checkout with no standards is unchanged: nothing found, nothing offered.
    try? fm.createDirectory(at: checkout, withIntermediateDirectories: true)
    expect(ProjectStandards.scan(checkoutRoot: checkout) == nil, "standards: no docs/standards is nil, not an empty success")
    expect(!ProjectStandards.isPresent(checkoutRoot: checkout), "standards: a checkout with none is not offered the tool")
    try? fm.createDirectory(at: standards, withIntermediateDirectories: true)
    write("README.md", "# Index\n\nStatus: Draft. An index, with a header like a standard's.\n", under: standards)
    expect(!ProjectStandards.isPresent(checkoutRoot: checkout), "standards: an index file alone is not a standard")

    let alphaRule2 = "2. Agents MUST NOT run the build in the main checkout.\nWhy: two builds race on one `.build`.\nEnforced by: nothing yet."
    let alpha = """
    # Alpha builds

    Status: Draft
    Layer: Project
    Applies when: Before you build or create a worktree.

    Terms. A bench is a worktree.

    ## Rules

    1. Agents MUST build in their own worktree.
    Why: shared state.
    Enforced by: nothing yet.

    \(alphaRule2)

    3. Agents SHOULD return the bench.

    ## Conflict for the owner

    1. Not a rule: a later section.
    """
    write("project/alpha.md", alpha, under: standards)
    write("rfc-1-layers.md", "# RFC 1\n\nApplies when: a change alters injected text.\n\n## Rules\n\n1.1. Layers MUST NOT overlap.\nWhy: drift.\n\n1.2. A helper MAY skip memory.\n", under: standards)
    write("project/missing-trigger.md", "# Missing\n\nStatus: Draft\nLayer: Project\n\n## Rules\n\n1. A rule nobody can find.\n", under: standards)
    write("project/empty-trigger.md", "# Empty\n\nApplies when:   \n\n## Rules\n\n1. A rule.\n", under: standards)
    write("project/wrapped-trigger.md", "# Wrapped\n\nApplies when: you edit the canvas\nor spawn a tile.\n\n## Rules\n\n1. A rule.\n", under: standards)
    write("project/duplicate-ids.md", "# Dup\n\nApplies when: you merge.\n\n## Rules\n\n1. One.\n\n2. Two.\n\n2. Two again.\n", under: standards)
    write("project/unnumbered.md", "# Unnumbered\n\nApplies when: you stash.\n\n## Rules\n\nAgents MUST NOT stash.\n\n1. Numbered.\n", under: standards)
    write("project/no-rules.md", "# No rules\n\nApplies when: you release.\n\nJust prose.\n", under: standards)
    try? fm.createDirectory(at: standards.appendingPathComponent("binary"), withIntermediateDirectories: true)
    try? Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: standards.appendingPathComponent("binary/bad-bytes.md"))
    // Escapes: a file and a directory linked out of the checkout.
    let secret = "OUTSIDE-SECRET-RULE"
    write("leak.md", "# Leak\n\nApplies when: always.\n\n## Rules\n\n1. \(secret)\n", under: outside)
    write("dir/leak2.md", "# Leak2\n\nApplies when: always.\n\n## Rules\n\n1. \(secret)\n", under: outside)
    try? fm.createSymbolicLink(at: standards.appendingPathComponent("project/escape.md"), withDestinationURL: outside.appendingPathComponent("leak.md"))
    try? fm.createSymbolicLink(at: standards.appendingPathComponent("linked"), withDestinationURL: outside.appendingPathComponent("dir"))

    guard let index = ProjectStandards.scan(checkoutRoot: checkout) else {
        expect(false, "standards: a checkout with docs/standards must scan")
        return
    }
    expect(ProjectStandards.isPresent(checkoutRoot: checkout), "standards: a checkout with standards is offered the tool")

    // Retained: the valid standards, verbatim, beside every broken one.
    expect(index.standards.map(\.id) == ["project/alpha", "rfc-1-layers"],
           "standards: exactly the two valid standards survive, sorted by id; got \(index.standards.map(\.id))")
    if let parsed = index.standards.first(where: { $0.id == "project/alpha" }) {
        expect(parsed.path == "docs/standards/project/alpha.md", "standards: path is checkout-relative, got \(parsed.path)")
        expect(parsed.title == "Alpha builds", "standards: title from the heading, got \(parsed.title)")
        expect(parsed.appliesWhen == "Before you build or create a worktree.", "standards: trigger verbatim, got \(parsed.appliesWhen)")
        expect(parsed.rules.map(\.id) == ["project/alpha#1", "project/alpha#2", "project/alpha#3"],
               "standards: rule ids are <standard>#<number>, and a later section's numbers are not rules; got \(parsed.rules.map(\.id))")
        expect(parsed.rules.count == 3 && parsed.rules[1].text == alphaRule2,
               "standards: a rule is returned verbatim with Why and Enforced by, got \(parsed.rules.dropFirst().first?.text ?? "nil")")
        let bytes = (try? Data(contentsOf: standards.appendingPathComponent("project/alpha.md"))) ?? Data()
        expect(parsed.version == ProjectStandards.version(of: bytes) && parsed.version.hasPrefix("sha256:") && parsed.version.count == 23,
               "standards: version is the content hash, got \(parsed.version)")
    }
    expect(index.standards.first { $0.id == "rfc-1-layers" }?.rules.map(\.id) == ["rfc-1-layers#1.1", "rfc-1-layers#1.2"],
           "standards: dotted numbers keep their dots")

    // Explicit failures, one per broken file, with the reason.
    func issue(_ path: String) -> ProjectStandardsIssue.Code? { index.issues.first { $0.path == path }?.code }
    expect(issue("docs/standards/project/missing-trigger.md") == .missingTrigger, "standards: a header without Applies when is missing_trigger")
    expect(issue("docs/standards/project/empty-trigger.md") == .emptyTrigger, "standards: a blank trigger is empty_trigger")
    expect(issue("docs/standards/project/wrapped-trigger.md") == .multilineTrigger, "standards: a wrapped trigger is refused, not truncated")
    expect(issue("docs/standards/project/duplicate-ids.md") == .duplicateRuleId
           && index.issues.first { $0.path == "docs/standards/project/duplicate-ids.md" }?.line == 11,
           "standards: a duplicate rule id names its line; got \(index.issues.filter { $0.path.hasSuffix("duplicate-ids.md") })")
    expect(issue("docs/standards/project/unnumbered.md") == .unnumberedRule, "standards: text before the first number is an unnumbered rule")
    expect(issue("docs/standards/project/no-rules.md") == .noRules, "standards: a standard with no rules section is no_rules")
    expect(issue("docs/standards/binary/bad-bytes.md") == .unreadable, "standards: non-UTF-8 bytes are unreadable")
    expect(issue("docs/standards/project/escape.md") == .outsideCheckout, "standards: a file linked out is outside_checkout")
    expect(issue("docs/standards/linked") == .outsideCheckout, "standards: a directory linked out is outside_checkout")
    expect(issue("docs/standards/README.md") == nil, "standards: an index file is skipped, not an issue")
    expect(index.issues.count == 9, "standards: nine issues, got \(index.issues.map { "\($0.path) \($0.code.rawValue)" })")
    let everything = String(describing: index)
    expect(!everything.contains(secret), "standards: nothing outside the checkout is ever read")

    // The answer to standards.read over that index.
    let indexAnswer = StandardsReadResult.answer(StandardsReadRequest(), index: index)
    expect(indexAnswer.standards.count == 2 && indexAnswer.standards.allSatisfy { $0.rules == nil }
           && indexAnswer.standards.first?.ruleIds == ["project/alpha#1", "project/alpha#2", "project/alpha#3"],
           "answer: no arguments returns the index with rule ids and no rule text")
    expect(indexAnswer.issues == index.issues && indexAnswer.unresolved.isEmpty && indexAnswer.root == "docs/standards",
           "answer: the index carries every issue")
    let whole = StandardsReadResult.answer(StandardsReadRequest(standards: ["rfc-1-layers"]), index: index)
    expect(whole.standards.map(\.id) == ["rfc-1-layers"] && whole.standards.first?.rules?.count == 2,
           "answer: a standard id returns every rule of that standard only")
    let picked = StandardsReadResult.answer(
        StandardsReadRequest(rules: ["project/alpha#2", "project/alpha#99", "../../etc/passwd"]), index: index)
    expect(picked.standards.map(\.id) == ["project/alpha"] && picked.standards.first?.rules == [ProjectStandardRule(id: "project/alpha#2", text: alphaRule2)],
           "answer: a rule id returns that rule verbatim and no other")
    expect(picked.unresolved == ["project/alpha#99", "../../etc/passwd"], "answer: unknown and traversal ids are unresolved, got \(picked.unresolved)")
    let broken = StandardsReadResult.answer(StandardsReadRequest(standards: ["project/missing-trigger", "project/escape", "../outside/leak"]), index: index)
    expect(broken.standards.isEmpty && broken.unresolved == ["project/missing-trigger", "project/escape", "../outside/leak"]
           && broken.issues.count == 9,
           "answer: a broken standard is unresolved and its issue still reported, never replaced")

    // Request validation.
    func refused(_ payload: [String: Any]) -> Bool {
        if case .failure(let error) = StandardsReadRequest.validated(payload: payload) { return error.code == .invalidRequest }
        return false
    }
    expect(refused(["standard": ["x"]]) && refused(["rules": "x"]) && refused(["standards": [1]]), "request: unknown fields and non-string ids are refused")
    if case .success(let request) = StandardsReadRequest.validated(payload: ["rules": ["a#1"]]) {
        expect(request.rules == ["a#1"] && request.standards.isEmpty && !request.isIndex, "request: rules decode")
    } else { expect(false, "request: a rules list is valid") }

    print("PASS project standards index (\(index.standards.count) standards, \(index.issues.count) issues)")
}
