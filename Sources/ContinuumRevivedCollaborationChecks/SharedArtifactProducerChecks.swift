import Foundation
import CryptoKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

/// COL-16 end to end on fixture repositories: the owner host's producer reads
/// a real checkout read-only, the real routes carry the revision, and the
/// recipient reads verified bytes while its own checkout stays byte-identical.
func runSharedArtifactProducerChecks() async throws {
    typealias A = Collaboration.Artifact
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-artifact-producer-\(UUID())")
    let ownerRoot = root.appendingPathComponent("owner-checkout"), recipientRoot = root.appendingPathComponent("recipient-checkout")
    try FileManager.default.createDirectory(at: ownerRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recipientRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    @discardableResult func git(_ repo: URL, _ args: String...) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        process.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = env
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CheckFailure(label: "fixture git \(args.joined(separator: " "))") }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    /// Every byte under a root, `.git` included, plus symlink targets.
    func tree(_ repo: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = repo.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])!
        for case let url as URL in walker {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { result[url.path] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }
            else if values.isRegularFile == true {
                result[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    // Owner fixture: committed history, then a working tree with every case.
    try git(ownerRoot, "init", "-q")
    try write(ownerRoot, "src/feature.swift", "let value = 1\n")
    try write(ownerRoot, "src/private.swift", "let token = \"unselected-secret-sentinel\"\n")
    try write(ownerRoot, "src/staged.swift", "let staged = 1\n")
    try write(ownerRoot, "big.txt", "small\n")
    try Data([0, 1, 2, 3, 0, 255]).write(to: ownerRoot.appendingPathComponent("logo.bin"))
    try git(ownerRoot, "add", "-A"); try git(ownerRoot, "commit", "-q", "-m", "base")
    try git(ownerRoot, "checkout", "-q", "-b", "feature")
    try write(ownerRoot, "src/committed.swift", "let committed = \"branch-commit-sentinel\"\n")
    try git(ownerRoot, "add", "-A"); try git(ownerRoot, "commit", "-q", "-m", "feature work")
    try write(ownerRoot, "src/feature.swift", "let value = 2 // working-change-sentinel\n")
    try write(ownerRoot, "src/private.swift", "let token = \"unselected-secret-sentinel-changed\"\n")
    try write(ownerRoot, "src/staged.swift", "let staged = 2 // staged-sentinel\n")
    try git(ownerRoot, "add", "src/staged.swift")
    try write(ownerRoot, "big.txt", String(repeating: "oversized line of text\n", count: 60_000))
    try Data([0, 9, 9, 9, 0, 255]).write(to: ownerRoot.appendingPathComponent("logo.bin"))
    try write(ownerRoot, "notes/new.md", "untracked-selected-sentinel\n")
    try write(ownerRoot, "notes/scratch.md", "untracked-unselected-sentinel\n")
    try FileManager.default.createSymbolicLink(atPath: ownerRoot.appendingPathComponent("escape.txt").path, withDestinationPath: "/etc/hosts")
    // Recipient fixture: an unrelated checkout holding the same paths.
    try git(recipientRoot, "init", "-q")
    try write(recipientRoot, "src/feature.swift", "recipient's own work\n")
    try git(recipientRoot, "add", "-A"); try git(recipientRoot, "commit", "-q", "-m", "recipient")
    try write(recipientRoot, "src/feature.swift", "recipient's uncommitted edit\n")

    // Stale stat info on an unchanged tracked file: a git that may take
    // optional locks would rewrite the owner's index to refresh it.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                                          ofItemAtPath: ownerRoot.appendingPathComponent("src/committed.swift").path)
    let producer = SharedArtifactProducer()
    let ownerBefore = try tree(ownerRoot), recipientBefore = try tree(recipientRoot)

    // Service + people, real routes.
    let key = Data(repeating: 47, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let base = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func enroll(_ label: String) async throws -> (Collaboration.Credential, CollaborationAPI) {
            let code = try await store.provisionPerson(label: label)
            let credential = try await store.redeem(.init(code: code.code, deviceLabel: label))
            return (credential, try CollaborationAPI(baseURL: base, credential: credential.token, allowsInsecureLoopback: true))
        }
        let (a, apiA) = try await enroll("Owner"), (b, apiB) = try await enroll("Recipient")
        let area = try await apiA.createArea().document.id.rawValue
        _ = try await apiB.accept(code: try await apiA.invite(area: area, request: .init(person: b.identity.person)).code)
        let host = try await apiA.registerHost()
        let item = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        _ = try await apiA.apply(area: area, mutation: .init(epoch: 1, command: .init(area: .init(area), expectedRevision: 0,
            edits: [.admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 640, height: 480)))])))

        // Working-tree diff: two selected tracked changes + one explicit untracked file.
        let selection = SharedArtifactProducer.Selection.diff(.workingTree,
            paths: ["src/feature.swift", "src/staged.swift", "big.txt", "logo.bin"], untracked: ["notes/new.md", "escape.txt"])
        let r1 = try producer.capture(root: ownerRoot, object: item.id, parent: nil, selection: selection)
        let coverage = Dictionary(uniqueKeysWithValues: r1.manifest.entries.map { ($0.path, $0.coverage) })
        try require(coverage["src/feature.swift"] == .included && coverage["src/staged.swift"] == .included && coverage["notes/new.md"] == .included,
            "selected staged, unstaged and explicitly selected untracked changes are included")
        try require(coverage["big.txt"] == .oversized && coverage["logo.bin"] == .binary && coverage["escape.txt"] == .symlink,
            "oversized, binary and symlinked selections are declared without bytes")
        let d = r1.manifest.declaration
        try require(d.range == .workingTree && d.includesStaged && d.includesUnstaged && !d.includesCommitted && d.includesUntracked
            && d.omittedChangedPaths == 1 && d.omittedUntrackedPaths == 1,
            "declaration counts the unselected change and the unselected untracked file without naming them")
        let published = String(decoding: try JSONEncoder().encode(r1.manifest), as: UTF8.self)
            + r1.blobs.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for absent in ["unselected-secret-sentinel", "untracked-unselected-sentinel", "src/private.swift", "notes/scratch.md",
                       ownerRoot.path, ownerRoot.resolvingSymlinksInPath().path, "branch-commit-sentinel"] {
            try require(!published.contains(absent), "excluded content or host path never enters the capture: \(absent.suffix(40))")
        }
        try require(published.contains("working-change-sentinel") && published.contains("staged-sentinel") && published.contains("untracked-selected-sentinel"),
            "the selected bytes are present")
        try require(try tree(ownerRoot) == ownerBefore, "capture leaves the owner checkout, index included, byte-identical")

        // Branch range is committed changes only.
        let branch = try producer.capture(root: ownerRoot, object: item.id, parent: nil, selection: .diff(.branch(base: "main"), paths: nil, untracked: []))
        let branchBytes = branch.blobs.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        try require(branch.manifest.declaration.includesCommitted && !branch.manifest.declaration.includesUnstaged
            && branch.manifest.base.mergeBase != nil && branchBytes.contains("branch-commit-sentinel") && !branchBytes.contains("working-change-sentinel"),
            "branch diff carries committed changes and never current working-tree edits")

        // Drift during capture: one change is retried into a coherent revision;
        // a source that never settles is refused.
        var edits = 0
        let racing = SharedArtifactProducer(betweenReadsForChecks: {
            edits += 1
            if edits == 1 { try? Data("let value = 3 // mid-capture-sentinel\n".utf8).write(to: ownerRoot.appendingPathComponent("src/feature.swift")) }
        })
        let settled = try racing.capture(root: ownerRoot, object: item.id, parent: nil, selection: .diff(.workingTree, paths: ["src/feature.swift"], untracked: []))
        try require(settled.blobs.values.contains { String(decoding: $0, as: UTF8.self).contains("mid-capture-sentinel") } && edits == 2,
            "a change between reads is re-read; the revision matches one consistent state")
        let restless = SharedArtifactProducer(betweenReadsForChecks: {
            try? Data("let value = \(UUID()) \n".utf8).write(to: ownerRoot.appendingPathComponent("src/feature.swift"))
        })
        do { _ = try restless.capture(root: ownerRoot, object: item.id, parent: nil, selection: .files(["src/feature.swift"])); throw CheckFailure(label: "unsettled source published") }
        catch SharedArtifactProducer.Failure.changedDuringCapture { try require(true, "a source changing on every read is refused, not published") }
        try write(ownerRoot, "src/feature.swift", "let value = 2 // working-change-sentinel\n")
        for bad in ["../outside", "/etc/passwd", ".git/config"] {
            do { _ = try producer.capture(root: ownerRoot, object: item.id, parent: nil, selection: .files([bad])); throw CheckFailure(label: "path \(bad) captured") }
            catch SharedArtifactProducer.Failure.invalidPath { try require(true, "producer refuses \(bad)") }
        }

        // Publish R1; the recipient reads exact bytes in memory only.
        _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: r1)
        let read = try await apiB.readArtifact(area: area, object: item.id.rawValue, revision: r1.manifest.id.rawValue)
        try require(read.bytes.count == 3 && read.bytes.allSatisfy { path, data in
            r1.manifest.entries.first { $0.path == path }?.blob == A.digest(data) }, "recipient reads every included patch, verified")
        try require(try tree(recipientRoot) == recipientBefore, "recipient checkout stays byte-identical after reading the artifact")

        // Changed during review: approval stays pinned and stops applying.
        _ = try await apiB.reviewArtifact(area: area, object: item.id.rawValue, request: .init(epoch: 1, revision: r1.manifest.id, verdict: .approve, note: "ok"))
        try require(try producer.applicability(of: r1.manifest, root: ownerRoot).applies, "unchanged source still applies")
        try write(ownerRoot, "src/feature.swift", "let value = 4 // edited-during-review\n")
        let probe = try producer.applicability(of: r1.manifest, root: ownerRoot)
        try require(!probe.applies && probe.changedPaths == 1 && !probe.baseMoved, "owner host detects the source edit against R1")
        _ = try await apiA.reportArtifactDrift(area: area, object: item.id.rawValue, revision: r1.manifest.id.rawValue,
                                               report: .init(epoch: 1, changedPaths: probe.changedPaths, baseMoved: probe.baseMoved))
        var state = try await apiB.artifactState(area: area, object: item.id.rawValue)
        if case .sourceChanged = state.reviews.first?.applicability { try require(true, "recipient sees the approval no longer applies") }
        else { throw CheckFailure(label: "approval still applies after edit during review") }
        let r2 = try producer.capture(root: ownerRoot, object: item.id, parent: r1.manifest.id, selection: selection)
        _ = try await apiA.publishArtifact(area: area, epoch: 1, capture: r2)
        state = try await apiB.artifactState(area: area, object: item.id.rawValue)
        try require(state.latest?.manifest.id == r2.manifest.id && state.reviews.first?.applicability == .superseded(by: r2.manifest.id)
            && state.reviews.allSatisfy { $0.review.revision == r1.manifest.id }, "R2 is live latest; the R1 approval is never carried to it")
        let pinned = try await apiB.readArtifact(area: area, object: item.id.rawValue, revision: r1.manifest.id.rawValue)
        try require(pinned.bytes == read.bytes, "R1 under review stays byte-identical after the source moved")
        try git(ownerRoot, "commit", "-q", "-am", "move head")
        try require(try producer.applicability(of: r2.manifest, root: ownerRoot).baseMoved, "a new commit marks the base moved")
        try require(try tree(recipientRoot) == recipientBefore, "recipient checkout still byte-identical at the end")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
    print("Shared artifact producer checks passed: fixture repositories, real routes, recipient checkout untouched.")
}
