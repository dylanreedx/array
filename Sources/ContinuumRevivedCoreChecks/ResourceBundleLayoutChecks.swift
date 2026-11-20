import Foundation
import ContinuumRevivedCore

/// Both SwiftPM resource-bundle layouts (flat, and Swift 6.4's
/// `Contents/Resources`) must resolve through the production lookups.
func runResourceBundleLayoutChecks() {
    func fail(_ m: String) -> Never { print("FAIL resource-bundle-layout: \(m)"); Foundation.exit(1) }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("rbl-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    for (layout, prefix) in [("flat", ""), ("nested", "Contents/Resources/")] {
        let root = tmp.appendingPathComponent(layout)
        let dir = root.appendingPathComponent("\(ResourceBundleLocator.coreBundleName)/\(prefix)PiExtensions")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = WorkspaceMCPToolCatalog.fileName
        fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("{}".utf8))
        guard let url = PiExtensionInstaller.bundledExtensionURL(fileName: name, roots: [root]) else {
            fail("\(layout) layout: bundledExtensionURL did not resolve")
        }
        guard url.path.hasPrefix(root.path) || url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path) else {
            fail("\(layout): resolved outside fixture \(url.path)")
        }
        if PiExtensionInstaller.bundledExtensionURL(fileName: "missing.ts", roots: [root]) != nil {
            fail("\(layout): resolved a missing file")
        }
    }
    print("PASS resource-bundle-layout (flat + nested)")
}
