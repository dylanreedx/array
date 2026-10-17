import ContinuumRevivedCore
import Foundation

/// `--cli-install-owner-check` — who owns each CLI binary, decided on fake
/// layouts built in a temp dir with the same symlink shapes as real installs
/// (native claude, nvm npm, a plain npm prefix, a Homebrew cask and formula,
/// codex standalone, mise, unknown, unwritable). Asserts the owner and the
/// EXACT argv, that unknown/mise/unwritable produce no runnable command but do
/// produce guidance, and that no argv anywhere contains sudo. Nothing here runs
/// a binary; classification is file stats only.
func runAgentCLIInstallOwnerChecks() {
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appendingPathComponent("cli-owner-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    // Classification compares REAL paths, and the temp dir itself sits behind
    // the /var → /private/var symlink.
    let root = AgentCLIFileSystem.live.realPath(scratch.path)
    var lockedDirs: [String] = []
    defer {
        for dir in lockedDirs { chmod(dir, 0o755) }
        try? fileManager.removeItem(at: scratch)
    }

    func file(_ relative: String, executable: Bool = true, contents: String = "#!/bin/sh\necho 0.0.1\n") -> String {
        let path = root + "/" + relative
        try? fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fileManager.createFile(atPath: path, contents: Data(contents.utf8))
        if executable { chmod(path, 0o755) }
        return path
    }
    func link(_ relative: String, to destination: String) -> String {
        let path = root + "/" + relative
        try? fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fileManager.removeItem(atPath: path)
        do { try fileManager.createSymbolicLink(atPath: path, withDestinationPath: destination) }
        catch { expect(false, "cli-owner: could not create symlink \(relative): \(error)") }
        return path
    }
    var plans: [String: AgentCLIUpdatePlan] = [:]
    func plan(_ name: String, _ harness: AgentHarness, _ path: String) -> AgentCLIUpdatePlan {
        guard let plan = AgentCLIInstallOwnerResolver.plan(harness: harness, resolvedPath: path) else {
            expect(false, "cli-owner[\(name)]: an absolute binary must always get a plan")
            fatalError()
        }
        plans[name] = plan
        return plan
    }
    func expectNoCommand(_ name: String, _ plan: AgentCLIUpdatePlan) {
        expect(plan.argv == nil && !plan.isRunnable, "cli-owner[\(name)]: must offer NO runnable command; got \(plan.argv ?? [])")
        expect(!(plan.guidance ?? "").isEmpty, "cli-owner[\(name)]: a plan without a command must explain what to do instead")
    }

    // 1. Native claude: ~/.local/bin/claude -> ~/.local/share/claude/versions/<v>.
    let claudeVersion = file("home/.local/share/claude/versions/2.1.300")
    let nativeClaude = link("home/.local/bin/claude", to: claudeVersion)
    let native = plan("native claude", .claudeCode, nativeClaude)
    expect(native.owner == .nativeClaude, "cli-owner[native claude]: owner \(native.owner)")
    expect(native.realPath == claudeVersion, "cli-owner[native claude]: real path \(native.realPath), want \(claudeVersion)")
    expect(native.argv == [nativeClaude, "update"], "cli-owner[native claude]: argv \(native.argv ?? [])")
    expect(native.lockKey == "claude-native" && native.latestSource == .npm(package: "@anthropic-ai/claude-code"),
           "cli-owner[native claude]: lock \(native.lockKey) source \(native.latestSource)")
    expect(!native.replacesRunningBinary, "cli-owner[native claude]: the native installer keeps old versions side by side")

    // 2-3. nvm npm: codex through npm, pi through its own `update --self`; one prefix, one lock.
    let nvm = root + "/home/.nvm/versions/node/v22.22.2"
    _ = file("home/.nvm/versions/node/v22.22.2/bin/npm")
    _ = file("home/.nvm/versions/node/v22.22.2/lib/node_modules/@openai/codex/bin/codex.js")
    let nvmCodex = link("home/.nvm/versions/node/v22.22.2/bin/codex", to: "../lib/node_modules/@openai/codex/bin/codex.js")
    let codex = plan("nvm codex", .codex, nvmCodex)
    expect(codex.owner == .npm(prefix: nvm, package: "@openai/codex"), "cli-owner[nvm codex]: owner \(codex.owner)")
    expect(codex.argv == [nvm + "/bin/npm", "install", "-g", "--prefix", nvm,
                          "--allow-scripts=@openai/codex", "@openai/codex@latest"],
           "cli-owner[nvm codex]: argv \(codex.argv ?? [])")
    expect(codex.lockKey == "npm:\(nvm)" && codex.replacesRunningBinary, "cli-owner[nvm codex]: lock \(codex.lockKey)")
    _ = file("home/.nvm/versions/node/v22.22.2/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
    let nvmPi = link("home/.nvm/versions/node/v22.22.2/bin/pi", to: "../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
    let pi = plan("nvm pi", .pi, nvmPi)
    expect(pi.owner == .npm(prefix: nvm, package: "@earendil-works/pi-coding-agent"), "cli-owner[nvm pi]: owner \(pi.owner)")
    expect(pi.argv == [nvmPi, "update", "--self"], "cli-owner[nvm pi]: pi's own updater, argv \(pi.argv ?? [])")
    expect(pi.lockKey == codex.lockKey, "cli-owner[nvm pi]: one npm prefix is one installer; locks \(pi.lockKey) vs \(codex.lockKey)")
    expect(pi.latestSource == .piRelease && pi.replacesRunningBinary, "cli-owner[nvm pi]: source \(pi.latestSource)")

    // 4. A plain npm prefix (npm config prefix ~/.npm-global).
    let plainPrefix = root + "/npm-global"
    _ = file("npm-global/bin/npm")
    _ = file("npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js")
    let plainClaude = link("npm-global/bin/claude", to: "../lib/node_modules/@anthropic-ai/claude-code/cli.js")
    let plain = plan("plain npm claude", .claudeCode, plainClaude)
    expect(plain.owner == .npm(prefix: plainPrefix, package: "@anthropic-ai/claude-code"), "cli-owner[plain npm]: owner \(plain.owner)")
    expect(plain.argv == [plainPrefix + "/bin/npm", "install", "-g", "--prefix", plainPrefix,
                          "--allow-scripts=@anthropic-ai/claude-code", "@anthropic-ai/claude-code@latest"],
           "cli-owner[plain npm]: argv \(plain.argv ?? [])")

    // 5-6. Homebrew: a cask (claude-code) and a formula (codex), each upgraded by the keg's own brew.
    let brewPrefix = root + "/homebrew"
    let brew = file("homebrew/bin/brew")
    _ = file("homebrew/Caskroom/claude-code/2.1.300/claude")
    let caskClaude = link("homebrew/bin/claude", to: "../Caskroom/claude-code/2.1.300/claude")
    let cask = plan("brew cask", .claudeCode, caskClaude)
    expect(cask.owner == .homebrew(kind: .cask, name: "claude-code", prefix: brewPrefix), "cli-owner[brew cask]: owner \(cask.owner)")
    expect(cask.argv == [brew, "upgrade", "--cask", "claude-code"], "cli-owner[brew cask]: argv \(cask.argv ?? [])")
    expect(cask.latestSource == .homebrew(brew: brew, kind: .cask, name: "claude-code") && cask.lockKey == "homebrew:\(brewPrefix)",
           "cli-owner[brew cask]: source \(cask.latestSource) lock \(cask.lockKey)")
    _ = file("homebrew/Cellar/codex/0.159.3/bin/codex")
    let formulaCodex = link("homebrew/bin/codex", to: "../Cellar/codex/0.159.3/bin/codex")
    let formula = plan("brew formula", .codex, formulaCodex)
    expect(formula.owner == .homebrew(kind: .formula, name: "codex", prefix: brewPrefix), "cli-owner[brew formula]: owner \(formula.owner)")
    expect(formula.argv == [brew, "upgrade", "codex"], "cli-owner[brew formula]: argv \(formula.argv ?? [])")
    // A keg whose prefix has no brew of its own: Array will not borrow another Homebrew.
    _ = file("orphan-brew/Cellar/codex/0.159.3/bin/codex")
    let orphan = plan("brew without its brew", .codex, link("orphan-brew/bin/codex", to: "../Cellar/codex/0.159.3/bin/codex"))
    expectNoCommand("brew without its brew", orphan)

    // 7. Codex standalone.
    let standaloneBinary = file("home/.codex/packages/standalone/0.159.3/bin/codex")
    let standaloneLink = link("home/.local/bin/codex", to: standaloneBinary)
    let standalone = plan("codex standalone", .codex, standaloneLink)
    expect(standalone.owner == .codexStandalone && standalone.argv == [standaloneLink, "update"],
           "cli-owner[codex standalone]: owner \(standalone.owner) argv \(standalone.argv ?? [])")
    expect(standalone.lockKey == "codex-standalone" && standalone.latestSource == .npm(package: "@openai/codex"),
           "cli-owner[codex standalone]: lock \(standalone.lockKey)")

    // 8. mise: an installs path, a shim, a wrapper script, and its npm backend's
    // global-looking layout — none of them npm's or brew's to update.
    let miseInstall = file("home/.local/share/mise/installs/codex/0.159.3/bin/codex")
    let mise1 = plan("mise install", .codex, link("misebin/codex", to: miseInstall))
    expect(mise1.owner == .mise, "cli-owner[mise install]: owner \(mise1.owner)")
    expectNoCommand("mise install", mise1)
    expect(mise1.manualCommand == nil, "cli-owner[mise install]: there is no command Array can vouch for")
    let mise2 = plan("mise shim", .pi, file("home/.local/share/mise/shims/pi"))
    expect(mise2.owner == .mise, "cli-owner[mise shim]: owner \(mise2.owner)")
    expectNoCommand("mise shim", mise2)
    let mise3 = plan("mise wrapper", .claudeCode, file("wrappers/claude", contents: "#!/bin/sh\nexec mise x claude -- claude \"$@\"\n"))
    expect(mise3.owner == .mise, "cli-owner[mise wrapper]: owner \(mise3.owner)")
    expectNoCommand("mise wrapper", mise3)
    let miseNpm = file("home/.local/share/mise/installs/npm-anthropic-ai-claude-code/2.1.300/lib/node_modules/@anthropic-ai/claude-code/cli.js")
    let mise4 = plan("mise npm backend", .claudeCode, link("misebin/claude", to: miseNpm))
    expect(mise4.owner == .mise, "cli-owner[mise npm backend]: not npm's global install; owner \(mise4.owner)")
    expectNoCommand("mise npm backend", mise4)

    // 9. Unknown: a hand-placed binary, and a project-local node_modules.
    let custom = plan("unknown custom", .claudeCode, file("custom/tools/claude"))
    expect(custom.owner == .unknown, "cli-owner[unknown custom]: owner \(custom.owner)")
    expectNoCommand("unknown custom", custom)
    expect(custom.manualCommand == nil, "cli-owner[unknown custom]: no command to show")
    _ = file("project/node_modules/@openai/codex/bin/codex.js")
    let local = plan("unknown node_modules", .codex, link("project/node_modules/.bin/codex", to: "../@openai/codex/bin/codex.js"))
    expect(local.owner == .unknown, "cli-owner[unknown node_modules]: a project's node_modules is not a global install; owner \(local.owner)")
    expectNoCommand("unknown node_modules", local)
    // The wrong package under a global prefix proves nothing about this CLI.
    _ = file("npm-global/lib/node_modules/some-wrapper/bin/codex.js")
    let wrongPackage = plan("unknown package", .codex, link("npm-global/bin/codex", to: "../lib/node_modules/some-wrapper/bin/codex.js"))
    expect(wrongPackage.owner == .unknown, "cli-owner[unknown package]: owner \(wrongPackage.owner)")
    expectNoCommand("unknown package", wrongPackage)

    // 10. Unwritable: an npm prefix Array may not write (a root-owned /usr/local).
    let lockedPrefix = root + "/locked"
    _ = file("locked/bin/npm")
    _ = file("locked/lib/node_modules/@openai/codex/bin/codex.js")
    let lockedCodex = link("locked/bin/codex", to: "../lib/node_modules/@openai/codex/bin/codex.js")
    for dir in [lockedPrefix + "/lib/node_modules", lockedPrefix + "/bin"] {
        chmod(dir, 0o555)
        lockedDirs.append(dir)
    }
    let locked = plan("unwritable npm", .codex, lockedCodex)
    expect(locked.owner == .npm(prefix: lockedPrefix, package: "@openai/codex"), "cli-owner[unwritable npm]: owner \(locked.owner)")
    expectNoCommand("unwritable npm", locked)
    expect(locked.manualCommand == AgentCLIInstallOwnerResolver.shellQuoted(
        [lockedPrefix + "/bin/npm", "install", "-g", "--prefix", lockedPrefix, "--allow-scripts=@openai/codex", "@openai/codex@latest"]),
           "cli-owner[unwritable npm]: must show the exact command to run; got \(locked.manualCommand ?? "nothing")")
    expect((locked.guidance ?? "").contains("sudo"), "cli-owner[unwritable npm]: guidance must say Array never uses sudo; got \(locked.guidance ?? "")")

    // No binary means no plan at all.
    expect(AgentCLIInstallOwnerResolver.plan(harness: .codex, resolvedPath: nil) == nil, "cli-owner: no binary, no plan")

    // Never sudo, anywhere: not in an argv, not as an executable, not in a shown command.
    for (name, plan) in plans {
        let words = (plan.argv ?? []) + (plan.manualCommand.map { [$0] } ?? [])
        expect(!words.contains { $0 == "sudo" || $0.hasSuffix("/sudo") || $0.hasPrefix("sudo ") || $0.contains(" sudo ") },
               "cli-owner[\(name)]: sudo in \(words)")
        if let executable = plan.argv?.first {
            expect(executable.hasPrefix("/"), "cli-owner[\(name)]: the executable must be absolute, never a PATH lookup: \(executable)")
        }
    }

    // Version parsing and ordering, from the banners the three CLIs print.
    expect(AgentCLIVersion.parse(versionOutput: "2.1.302 (Claude Code)\n") == "2.1.302", "cli-version: claude banner")
    expect(AgentCLIVersion.parse(versionOutput: "codex-cli 0.159.3\n") == "0.159.3", "cli-version: codex banner")
    expect(AgentCLIVersion.parse(versionOutput: "0.85.0\n") == "0.85.0", "cli-version: pi banner")
    expect(AgentCLIVersion.parse(versionOutput: "command not found") == nil, "cli-version: no version, no number")
    expect(AgentCLIVersion.isNewer("2.1.305", than: "2.1.302"), "cli-version: 2.1.305 > 2.1.302")
    expect(AgentCLIVersion.isNewer("0.10.0", than: "0.9.9"), "cli-version: numeric, not lexical")
    expect(!AgentCLIVersion.isNewer("2.1.302", than: "2.1.302"), "cli-version: equal is not newer")
    expect(!AgentCLIVersion.isNewer("1.0.0-beta.1", than: "1.0.0"), "cli-version: a prerelease precedes its release")
    expect(!AgentCLIVersion.isNewer("garbage", than: "1.0.0") && !AgentCLIVersion.isNewer("1.0.0", than: nil),
           "cli-version: unparseable is never newer")

    // The bundled "tested with" versions are the newest recorded fixture per CLI.
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/context-meter")
    var newest: [AgentHarness: AgentCLIVersion] = [:]
    let cliNames: [String: AgentHarness] = ["claude": .claudeCode, "codex": .codex, "pi": .pi]
    for name in (try? fileManager.contentsOfDirectory(atPath: fixtures.path)) ?? [] where name.hasSuffix(".meta.json") {
        guard let data = fileManager.contents(atPath: fixtures.appendingPathComponent(name).path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cli = object["cli"] as? String, let harness = cliNames[cli],
              let version = (object["version"] as? String).flatMap(AgentCLIVersion.init) else { continue }
        if newest[harness].map({ version > $0 }) ?? true { newest[harness] = version }
    }
    expect(newest.count == 3, "cli-tested: every CLI must have a recorded fixture; found \(newest)")
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../ContinuumRevivedCore/Resources/\(AgentCLITestedVersions.resourceName)").standardized
    let declared = fileManager.contents(atPath: source.path).map(AgentCLITestedVersions.decode) ?? [:]
    let expected = newest.mapValues(\.text)
    expect(declared == expected, "cli-tested: \(AgentCLITestedVersions.resourceName) says \(declared), the fixtures say \(expected)")
    expect(AgentCLITestedVersions.bundled() == expected,
           "cli-tested: the Core resource bundle must ship the tested versions; bundled \(AgentCLITestedVersions.bundled())")

    print("PASS: cli-install-owner — native claude, nvm/plain npm, brew cask/formula, codex standalone, mise, unknown, unwritable; exact argv, no sudo")
}
