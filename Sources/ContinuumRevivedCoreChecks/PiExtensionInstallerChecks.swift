import ContinuumRevivedCore
import Foundation

// Ticket: C8 — installer half of pi subagent spawning. Drives the real
// production entry point (`PiExtensionInstaller.install`) with an injected
// throwaway `/tmp` destination — NEVER the real `~/.pi/agent/extensions`,
// which would make this check depend on (and potentially corrupt) host state.
//
// Deliberately NOT witnessed: whether the file reaches the real
// `~/.pi/agent/extensions/` on this machine. That is host state outside the
// matrix's remit; asserting it would make a CI run depend on a home
// directory that may not exist, may be read-only, or may already hold a
// user's own extension.
func runPiExtensionInstallerChecks() {
    let ourContent = Data("export default function ours() {}\n".utf8)

    // 1. Fresh install: no existing file. Must write our content and report
    // .installed, using the injected destination — never the real ~/.pi.
    let freshDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuum-c8-installer-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: freshDir) }

    let firstResult = PiExtensionInstaller.install(sourceContent: ourContent, destinationDirectory: freshDir)
    expect(firstResult == .installed, "fresh install must report .installed, got \(firstResult)")
    let installedURL = freshDir.appendingPathComponent(PiExtensionInstaller.extensionFileName)
    let installedContent = try? Data(contentsOf: installedURL)
    expect(installedContent == ourContent,
           "installed file must be byte-identical to the source content, got \(installedContent.map(String.init(describing:)) ?? "nil")")

    // 2. Idempotence: installing again over our own prior copy must not
    // change anything and must report .alreadyCurrent, not re-.installed.
    let secondResult = PiExtensionInstaller.install(sourceContent: ourContent, destinationDirectory: freshDir)
    expect(secondResult == .alreadyCurrent, "re-install over our own copy must report .alreadyCurrent, got \(secondResult)")
    let contentAfterSecondInstall = try? Data(contentsOf: installedURL)
    expect(contentAfterSecondInstall == ourContent, "idempotent re-install must not alter the file's bytes")

    // 3. A user-modified copy must be left alone, not clobbered, and the
    // installer must SAY so rather than silently overwriting.
    let userModifiedDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuum-c8-installer-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: userModifiedDir) }
    try! FileManager.default.createDirectory(at: userModifiedDir, withIntermediateDirectories: true)
    let userContent = Data("// hand-edited by a user, do not touch\n".utf8)
    let userFileURL = userModifiedDir.appendingPathComponent(PiExtensionInstaller.extensionFileName)
    try! userContent.write(to: userFileURL)

    let thirdResult = PiExtensionInstaller.install(sourceContent: ourContent, destinationDirectory: userModifiedDir)
    expect(thirdResult == .leftUserModifiedCopy, "a user-modified copy must be left alone and reported, got \(thirdResult)")
    let contentAfterThirdInstall = try? Data(contentsOf: userFileURL)
    expect(contentAfterThirdInstall == userContent, "a user-modified copy's bytes must never be overwritten")

    // 3b. A PRIOR shipped version of our own file must be UPDATED, not treated
    // as a user's edit — otherwise a shipped fix to the extension never reaches
    // an existing install (this is exactly what stranded fire-and-forget
    // spawn_agent on machines that already had the file). The allowlist is
    // injected here so the check owns both sides of the hash; production's
    // default is `knownPriorContentHashes`, whose behavior over unknown bytes
    // is act 3 above.
    let priorDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuum-c8-installer-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: priorDir) }
    try! FileManager.default.createDirectory(at: priorDir, withIntermediateDirectories: true)
    let priorContent = Data("export default function priorShippedVersion() {}\n".utf8)
    let priorFileURL = priorDir.appendingPathComponent(PiExtensionInstaller.extensionFileName)
    try! priorContent.write(to: priorFileURL)
    let priorHash = PiExtensionInstaller.sha256Hex(priorContent)
    let updateResult = PiExtensionInstaller.install(
        sourceContent: ourContent, destinationDirectory: priorDir, knownPriorHashes: [priorHash])
    expect(updateResult == .installed,
           "a copy matching a known prior shipped hash must be updated and report .installed, got \(updateResult)")
    let contentAfterUpdate = try? Data(contentsOf: priorFileURL)
    expect(contentAfterUpdate == ourContent,
           "the prior shipped copy's bytes must be replaced with the current version")

    // 3c. The same bytes with the allowlist EMPTY are somebody else's file:
    // the overwrite in 3b must be attributable to the hash match and nothing
    // else, or the installer has become a clobberer with extra steps.
    let strangerDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuum-c8-installer-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: strangerDir) }
    try! FileManager.default.createDirectory(at: strangerDir, withIntermediateDirectories: true)
    let strangerFileURL = strangerDir.appendingPathComponent(PiExtensionInstaller.extensionFileName)
    try! priorContent.write(to: strangerFileURL)
    let strangerResult = PiExtensionInstaller.install(
        sourceContent: ourContent, destinationDirectory: strangerDir, knownPriorHashes: [])
    expect(strangerResult == .leftUserModifiedCopy,
           "bytes whose hash is NOT allowlisted must be left alone, got \(strangerResult)")
    expect((try? Data(contentsOf: strangerFileURL)) == priorContent,
           "non-allowlisted bytes must never be overwritten")

    // 3d. The shipped allowlist itself carries the one prior version that ever
    // shipped, so a real install that still has it will take this update.
    expect(PiExtensionInstaller.knownPriorContentHashes.contains(
        "3e536320b6c99957255bb26b7709acdf838b075c99212c57211cf5f34831bd5a"),
        "the fire-and-forget spawn_agent's hash must be in the prior-version allowlist or existing installs never update")

    // 4. Never touches settings.json: the install call must not create ANY
    // other file in the destination directory besides the extension itself.
    let settingsPath = freshDir.appendingPathComponent("settings.json")
    expect(!FileManager.default.fileExists(atPath: settingsPath.path),
           "install must never create or touch settings.json")

    // 5. Default destination is pi's own auto-discovered extensions root
    // (confirmed against pi's resource-loader.js: getAgentDir() + "extensions"),
    // derived from an injected home directory — never read from the real
    // environment inside this check.
    let fakeHome = "/private/tmp/continuum-c8-fake-home"
    let defaultDir = PiExtensionInstaller.defaultExtensionsDirectory(homeDirectory: fakeHome)
    expect(defaultDir.path == "\(fakeHome)/.pi/agent/extensions",
           "default extensions directory must be ~/.pi/agent/extensions, got \(defaultDir.path)")

    // 6. PiAgentRunner.installedExtensionPaths resolves the real `-e` argument
    // for a live spawn: present on disk -> the path; absent -> [] (never a
    // `-e` pointed at a file that doesn't exist). Injected `fileExists`
    // keeps this deterministic — no real ~/.pi touched.
    let expectedPath = PiExtensionInstaller.defaultExtensionsDirectory()
        .appendingPathComponent(PiExtensionInstaller.extensionFileName).path
    let presentPaths = PiAgentRunner.installedExtensionPaths(fileExists: { $0 == expectedPath })
    expect(presentPaths == [expectedPath], "installedExtensionPaths must return the path when the file exists, got \(presentPaths)")
    let absentPaths = PiAgentRunner.installedExtensionPaths(fileExists: { _ in false })
    expect(absentPaths == [], "installedExtensionPaths must return [] rather than a -e pointed at a missing file, got \(absentPaths)")

    print("PiExtensionInstaller checks passed: fresh install, byte-identical content, idempotent re-install, user-modified copy left alone, known-prior version updated (and only via the hash allowlist), settings.json untouched, default destination pinned, installedExtensionPaths present/absent resolution")
}
