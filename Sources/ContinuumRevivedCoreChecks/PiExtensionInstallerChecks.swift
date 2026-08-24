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

    print("PiExtensionInstaller checks passed: fresh install, byte-identical content, idempotent re-install, user-modified copy left alone, settings.json untouched, default destination pinned, installedExtensionPaths present/absent resolution")
}
