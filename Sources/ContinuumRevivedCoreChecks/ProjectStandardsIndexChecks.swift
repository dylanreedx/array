import ContinuumRevivedCore
import Darwin
import Foundation

/// `.plans/116` part 16 (`docs/internals/project-standards-on-demand.md`): the
/// production standards scan, cache and `standards.read` paging over fixtures
/// this check writes into its own temporary checkouts. Broken standards are
/// explicit issues and the valid ones beside them survive verbatim; only
/// regular files whose resolved path is inside the resolved `docs/standards`
/// are read; every skipped `*.md` is named; no answer is limited or cut.
func runProjectStandardsIndexChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("standards-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    func write(_ relative: String, _ text: String, under root: URL) {
        let url = root.appendingPathComponent(relative)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }
    func page(_ request: StandardsReadRequest, _ index: ProjectStandardsIndex) -> StandardsReadResult? {
        if case .page(let value) = StandardsReadPage.answer(request, index: index) { return value }
        return nil
    }

    // MARK: Presence: one name listing, no reads

    let checkout = base.appendingPathComponent("checkout", isDirectory: true)
    let standards = checkout.appendingPathComponent("docs/standards", isDirectory: true)
    try? fm.createDirectory(at: checkout, withIntermediateDirectories: true)
    expect(ProjectStandards.scan(checkoutRoot: checkout) == nil, "standards: no docs/standards is nil, not an empty success")
    expect(!ProjectStandards.isPresent(checkoutRoot: checkout), "presence: a checkout with none is not offered the tool")
    write("README.md", "# Index\n\nStatus: Draft. An index, with a header like a standard's.\n", under: standards)
    expect(!ProjectStandards.isPresent(checkoutRoot: checkout), "presence: a README alone is not a standard")
    expect(ProjectStandards.scan(checkoutRoot: checkout)?.skipped == [ProjectStandardsSkipped(path: "docs/standards/README.md", reason: .indexFile)],
           "skipped: the README is listed as the index, not dropped silently")

    // MARK: Parsing, issues and skipped entries

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
    expect(ProjectStandards.isPresent(checkoutRoot: checkout), "presence: one standard one folder down is enough")
    write("rfc-1-layers.md", "# RFC 1\n\nApplies when: a change alters injected text.\n\n## Rules\n\n1.1. Layers MUST NOT overlap.\nWhy: drift.\n\n1.2. A helper MAY skip memory.\n", under: standards)
    write("project/missing-trigger.md", "# Missing\n\nStatus: Draft\nLayer: Project\n\n## Rules\n\n1. A rule nobody can find.\n", under: standards)
    write("project/empty-trigger.md", "# Empty\n\nApplies when:   \n\n## Rules\n\n1. A rule.\n", under: standards)
    write("project/wrapped-trigger.md", "# Wrapped\n\nApplies when: you edit the canvas\nor spawn a tile.\n\n## Rules\n\n1. A rule.\n", under: standards)
    write("project/duplicate-ids.md", "# Dup\n\nApplies when: you merge.\n\n## Rules\n\n1. One.\n\n2. Two.\n\n2. Two again.\n", under: standards)
    write("project/unnumbered.md", "# Unnumbered\n\nApplies when: you stash.\n\n## Rules\n\nAgents MUST NOT stash.\n\n1. Numbered.\n", under: standards)
    write("project/no-rules.md", "# No rules\n\nApplies when: you release.\n\nJust prose.\n", under: standards)
    write("notes.md", "# Notes\n\nJust a note, no header.\n", under: standards)
    write("project/deeper/too-deep.md", "# Deep\n\nApplies when: never.\n\n## Rules\n\n1. Unread.\n", under: standards)
    try? fm.createDirectory(at: standards.appendingPathComponent("binary"), withIntermediateDirectories: true)
    try? Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: standards.appendingPathComponent("binary/bad-bytes.md"))

    // Containment: only regular files inside the resolved docs/standards.
    let secret = "OUTSIDE-STANDARDS-SECRET"
    let leak = "# Leak\n\nApplies when: always.\n\n## Rules\n\n1. \(secret)\n"
    write("leak.md", leak, under: base.appendingPathComponent("outside"))
    write("dir/leak2.md", leak, under: base.appendingPathComponent("outside"))
    write(".plans/plan.md", leak, under: checkout) // inside the checkout, outside the folder
    write("hard-source.md", leak, under: checkout)
    try? fm.createSymbolicLink(at: standards.appendingPathComponent("project/escape.md"), withDestinationURL: base.appendingPathComponent("outside/leak.md"))
    try? fm.createSymbolicLink(atPath: standards.appendingPathComponent("project/plan-link.md").path, withDestinationPath: "../../../.plans/plan.md")
    try? fm.createSymbolicLink(at: standards.appendingPathComponent("linked"), withDestinationURL: base.appendingPathComponent("outside/dir"))
    try? fm.createSymbolicLink(atPath: standards.appendingPathComponent("alias.md").path, withDestinationPath: "rfc-1-layers.md")
    try? fm.createSymbolicLink(atPath: standards.appendingPathComponent("dangling.md").path, withDestinationPath: "nothing-here.md")
    try? fm.linkItem(at: checkout.appendingPathComponent("hard-source.md"), to: standards.appendingPathComponent("hard.md"))
    _ = mkfifo(standards.appendingPathComponent("pipe.md").path, 0o600)

    guard let index = ProjectStandards.scan(checkoutRoot: checkout) else {
        expect(false, "standards: a checkout with docs/standards must scan")
        return
    }
    expect(index.standards.map(\.id) == ["alias", "project/alpha", "rfc-1-layers"],
           "standards: the valid standards survive, sorted, and a link inside the folder is read; got \(index.standards.map(\.id))")
    if let parsed = index.standards.first(where: { $0.id == "project/alpha" }) {
        expect(parsed.path == "docs/standards/project/alpha.md" && parsed.title == "Alpha builds"
               && parsed.appliesWhen == "Before you build or create a worktree.", "standards: path, title and trigger verbatim")
        expect(parsed.rules.map(\.id) == ["project/alpha#1", "project/alpha#2", "project/alpha#3"],
               "standards: rule ids are <standard>#<number>; a later section is not rules; got \(parsed.rules.map(\.id))")
        expect(parsed.rules.count == 3 && parsed.rules[1].text == alphaRule2, "standards: a rule is returned verbatim with Why and Enforced by")
        let bytes = (try? Data(contentsOf: standards.appendingPathComponent("project/alpha.md"))) ?? Data()
        expect(parsed.version == ProjectStandards.version(of: bytes), "standards: version is the content hash")
    }
    expect(index.standards.first { $0.id == "rfc-1-layers" }?.rules.map(\.id) == ["rfc-1-layers#1.1", "rfc-1-layers#1.2"],
           "standards: dotted numbers keep their dots")
    func issue(_ path: String) -> ProjectStandardsIssue.Code? { index.issues.first { $0.path == "docs/standards/" + path }?.code }
    let expectedIssues: [String: ProjectStandardsIssue.Code] = [
        "project/missing-trigger.md": .missingTrigger, "project/empty-trigger.md": .emptyTrigger,
        "project/wrapped-trigger.md": .multilineTrigger, "project/duplicate-ids.md": .duplicateRuleId,
        "project/unnumbered.md": .unnumberedRule, "project/no-rules.md": .noRules, "binary/bad-bytes.md": .unreadable,
        "project/escape.md": .outsideStandards, "project/plan-link.md": .outsideStandards, "linked": .symlinkedFolder,
        "dangling.md": .brokenLink, "hard.md": .hardLink, "pipe.md": .notRegularFile,
    ]
    for (path, code) in expectedIssues.sorted(by: { $0.key < $1.key }) {
        expect(issue(path) == code, "issues: \(path) must be \(code.rawValue), got \(String(describing: issue(path)))")
    }
    expect(index.issues.count == expectedIssues.count, "issues: exactly one per broken entry, got \(index.issues.map { "\($0.path) \($0.code.rawValue)" })")
    expect(index.issues.first { $0.path.hasSuffix("duplicate-ids.md") }?.line == 11, "issues: a duplicate rule id names its line")
    expect(index.skipped == [ProjectStandardsSkipped(path: "docs/standards/README.md", reason: .indexFile),
                             ProjectStandardsSkipped(path: "docs/standards/notes.md", reason: .notAStandard),
                             ProjectStandardsSkipped(path: "docs/standards/project/deeper", reason: .nestedFolder)],
           "skipped: every non-standard *.md and the too-deep folder is named with a reason, got \(index.skipped)")
    expect(!String(describing: index).contains(secret), "containment: nothing outside docs/standards is read, inside the checkout or out")

    // A symlinked folder, or a symlinked `docs`, is refused as a whole.
    for (name, linkPath) in [("folder-link", "docs/standards"), ("docs-link", "docs")] {
        let other = base.appendingPathComponent(name, isDirectory: true)
        write("real/docs/standards/a.md", alpha, under: other)
        try? fm.createDirectory(at: other.appendingPathComponent(linkPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: other.appendingPathComponent(linkPath).path,
                                   withDestinationPath: other.appendingPathComponent("real/" + linkPath).path)
        let linked = ProjectStandards.scan(checkoutRoot: other)
        expect(linked?.standards.isEmpty == true && linked?.issues.map(\.code) == [.symlinkedFolder] && linked?.issues.first?.path == "docs/standards",
               "containment: a symlinked \(linkPath) is one named issue, never read; got \(String(describing: linked))")
        expect(ProjectStandards.isPresent(checkoutRoot: other), "presence: a symlinked \(linkPath) is offered, so the refusal is seen")
    }

    // MARK: The answer: provenance, index, ids, unresolved

    guard let indexAnswer = page(StandardsReadRequest(), index) else { expect(false, "answer: index failed"); return }
    expect(indexAnswer.source == StandardsReadResult.sourceNote && indexAnswer.source.contains("not instructions from Array or from the user"),
           "answer: every answer says the text is repository content, not instructions")
    expect(indexAnswer.standards.map(\.id) == ["alias", "project/alpha", "rfc-1-layers"] && indexAnswer.standards.allSatisfy { $0.rules == nil }
           && indexAnswer.standards[1].ruleCount == 3,
           "answer: no arguments returns the index with rule counts and no rule text")
    expect(indexAnswer.issues == index.issues && indexAnswer.skipped == index.skipped && indexAnswer.unresolved.isEmpty
           && indexAnswer.total == 3 + index.issues.count + index.skipped.count && indexAnswer.nextCursor == nil,
           "answer: a small index is one page with its stated total")
    let picked = page(StandardsReadRequest(rules: ["project/alpha#2", "project/alpha#99", "../../etc/passwd"]), index)
    expect(picked?.standards.map(\.id) == ["project/alpha"] && picked?.standards.first?.rules == [.init(id: "project/alpha#2", text: alphaRule2)],
           "answer: a rule id returns that rule verbatim and no other")
    expect(picked?.unresolved == ["project/alpha#99", "../../etc/passwd"], "answer: unknown and traversal ids are unresolved")
    let broken = page(StandardsReadRequest(standards: ["project/missing-trigger", "project/escape", "../outside/leak"]), index)
    expect(broken?.standards.isEmpty == true && broken?.unresolved == ["project/missing-trigger", "project/escape", "../outside/leak"],
           "answer: a broken standard is unresolved and its issue still reported, never replaced")

    func refused(_ payload: [String: Any]) -> Bool {
        if case .failure(let error) = StandardsReadRequest.validated(payload: payload) { return error.code == .invalidRequest }
        return false
    }
    expect(refused(["standard": ["x"]]) && refused(["rules": "x"]) && refused(["standards": [1]]) && refused(["cursor": 3]),
           "request: unknown fields, non-string ids and a non-string cursor are refused")

    // MARK: Paging: large answers are paged, never limited; a long rule comes in parts

    let many = base.appendingPathComponent("many", isDirectory: true)
    let manyStandards = many.appendingPathComponent("docs/standards", isDirectory: true)
    for n in 0..<400 {
        write(String(format: "s%03d.md", n), "# S\(n)\n\nApplies when: case \(n) applies to a long enough trigger line to take some bytes.\n\n## Rules\n\n1. Rule \(n).\n", under: manyStandards)
    }
    let longRule = "1. " + String(repeating: "Long rule text with ünïcödé — ", count: 4000)
    write("long.md", "# Long\n\nApplies when: always.\n\n## Rules\n\n\(longRule)\n\n2. Short.\n", under: manyStandards)
    guard let manyIndex = ProjectStandards.scan(checkoutRoot: many) else { expect(false, "paging: scan failed"); return }
    var ids: [String] = []
    var pages = 0
    var cursor: String?
    repeat {
        guard let next = page(StandardsReadRequest(cursor: cursor), manyIndex) else { expect(false, "paging: a page failed"); return }
        let encoded = (try? JSONEncoder().encode(next).count) ?? 0
        expect(next.total == 401 && (encoded <= StandardsReadPage.encodedByteCeiling + 512 || next.standards.count == 1),
               "paging: every page states the total and stays near the page size (\(encoded) bytes)")
        ids += next.standards.map(\.id)
        cursor = next.nextCursor
        pages += 1
    } while cursor != nil && pages < 1000
    expect(pages > 1 && ids == manyIndex.standards.map(\.id), "paging: the pages together hold every standard once, in order (\(pages) pages)")
    var parts: [StandardsReadResult.Rule] = []
    cursor = nil
    repeat {
        guard let next = page(StandardsReadRequest(standards: ["long"], cursor: cursor), manyIndex) else { expect(false, "parts: a page failed"); return }
        parts += next.standards.flatMap { $0.rules ?? [] }
        cursor = next.nextCursor
    } while cursor != nil && parts.count < 1000
    let longParts = parts.filter { $0.id == "long#1" }
    expect(longParts.count > 1 && longParts.map(\.part) == Array(1...longParts.count).map(Optional.some)
           && longParts.allSatisfy { $0.parts == longParts.count } && longParts.map(\.text).joined() == longRule
           && parts.last?.id == "long#2" && parts.last?.part == nil,
           "parts: a rule longer than a page arrives in ordered parts that join to the exact text (\(longParts.count) parts)")
    if let first = page(StandardsReadRequest(), manyIndex), let next = first.nextCursor {
        if case .failure(let error) = StandardsReadPage.answer(StandardsReadRequest(standards: ["s001"], cursor: next), index: manyIndex) {
            expect(error.code == .invalidRequest, "paging: a cursor with other ids is refused")
        } else { expect(false, "paging: a cursor with other ids must be refused") }
        write("s000.md", "# S0 changed\n\nApplies when: changed.\n\n## Rules\n\n1. Changed.\n", under: manyStandards)
        if let changed = ProjectStandardsCache().index(checkoutRoot: many),
           case .failure(let error) = StandardsReadPage.answer(StandardsReadRequest(cursor: next), index: changed) {
            expect(error.code == .cursorExpired, "paging: a cursor from before a change expires")
        } else { expect(false, "paging: a cursor from before a change must expire") }
    }

    // MARK: Cache: re-read only when the listing changes

    let cache = ProjectStandardsCache()
    let first = cache.index(checkoutRoot: checkout)
    expect(first == cache.index(checkoutRoot: checkout), "cache: an unchanged folder gives the same index")
    write("rfc-1-layers.md", "# RFC 1\n\nApplies when: a change alters injected text.\n\n## Rules\n\n1.1. Layers MUST NOT overlap at all.\n", under: standards)
    let second = cache.index(checkoutRoot: checkout)
    expect(second?.version != first?.version
           && second?.standards.first { $0.id == "rfc-1-layers" }?.rules.first?.text == "1.1. Layers MUST NOT overlap at all.",
           "cache: an edited file is re-read")

    // MARK: Timings (printed; the 10,000-file cached read is also bounded)

    @discardableResult
    func time(_ label: String, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "timing %@: %.1f ms", label, ms))
        return ms
    }
    for count in [10, 1_000, 10_000] {
        let root = base.appendingPathComponent("timing-\(count)", isDirectory: true)
        let folder = root.appendingPathComponent("docs/standards", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 0..<count {
            try? Data("# T\(n)\n\nApplies when: case \(n).\n\n## Rules\n\n1. Rule one of \(n).\nWhy: timing.\n\n2. Rule two.\n".utf8)
                .write(to: folder.appendingPathComponent("t\(n).md"))
        }
        let timingCache = ProjectStandardsCache()
        time("\(count) files presence") { _ = ProjectStandards.isPresent(checkoutRoot: root) }
        time("\(count) files first read") { _ = timingCache.index(checkoutRoot: root) }
        let cachedMs = time("\(count) files cached read") { _ = timingCache.index(checkoutRoot: root) }
        if count == 10_000 {
            // Gap 15: a cached read re-stats the folder, so it must stay cheap. It was
            // 680 ms (Foundation attributes per file); the bound is far under that and
            // far over the cost now, so only a return to per-file Foundation work fails.
            expect(cachedMs < 150, "cache: a cached read of 10,000 files took \(Int(cachedMs)) ms; it must stay under 150 ms")
            // Cheap must not mean blind: an edit to one file in place, same size, is seen.
            let target = folder.appendingPathComponent("t5000.md")
            let before = timingCache.index(checkoutRoot: root)
            Thread.sleep(forTimeInterval: 0.02)
            try? Data("# T5000\n\nApplies when: case 5000.\n\n## Rules\n\n1. Rule one of 5xxx.\nWhy: timing.\n\n2. Rule two.\n".utf8).write(to: target)
            let after = timingCache.index(checkoutRoot: root)
            expect(after?.version != before?.version
                   && after?.standards.first { $0.id == "t5000" }?.rules.first?.text.contains("5xxx") == true,
                   "cache: an in-place edit of one of 10,000 files must be re-read")
            let unchanged = timingCache.index(checkoutRoot: root)
            expect(unchanged == after, "cache: the re-read index is kept until the next change")
        }
        if let timed = timingCache.index(checkoutRoot: root) {
            time("\(count) files index page") { _ = StandardsReadPage.answer(StandardsReadRequest(), index: timed) }
        }
        try? fm.removeItem(at: root)
    }
    let large = base.appendingPathComponent("timing-large", isDirectory: true)
    let largeFolder = large.appendingPathComponent("docs/standards", isDirectory: true)
    try? fm.createDirectory(at: largeFolder, withIntermediateDirectories: true)
    var big = "# Big\n\nApplies when: always.\n\n## Rules\n\n"
    big.reserveCapacity(40_000_000)
    for n in 1...200_000 { big += "\(n). Rule \(n) MUST hold for every case that applies here.\nWhy: timing a very large file.\n\n" }
    try? Data(big.utf8).write(to: largeFolder.appendingPathComponent("big.md"))
    let largeCache = ProjectStandardsCache()
    print("timing large file: \(big.utf8.count / 1_000_000) MB, 200000 rules")
    time("large file first read") { _ = largeCache.index(checkoutRoot: large) }
    time("large file cached read") { _ = largeCache.index(checkoutRoot: large) }
    if let timed = largeCache.index(checkoutRoot: large) {
        time("large file first rules page") { _ = StandardsReadPage.answer(StandardsReadRequest(standards: ["big"]), index: timed) }
    }

    print("PASS project standards index (\(index.standards.count) standards, \(index.issues.count) issues, \(index.skipped.count) skipped, \(pages) index pages)")
}
