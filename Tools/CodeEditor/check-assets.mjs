import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import {dirname, resolve} from "node:path"
import {fileURLToPath} from "node:url"

const root = dirname(fileURLToPath(import.meta.url))
const output = resolve(root, "../../Sources/ContinuumRevived/Resources/CodeEditor")
const [html, js, css, license, version] = await Promise.all([
  readFile(resolve(output, "index.html"), "utf8"),
  readFile(resolve(output, "editor.js"), "utf8"),
  readFile(resolve(output, "editor.css"), "utf8"),
  readFile(resolve(output, "LICENSE.txt"), "utf8"),
  readFile(resolve(output, "ASSET_VERSION"), "utf8")
])
assert.match(html, /default-src 'none'/)
assert.match(html, /editor\.js/)
assert.match(js, /arrayEditor/)
for (const bridgeMethod of ["provideCompletions", "setDiagnostics", "provideHover", "definitionRequest", "setPreferences", "vimModeChanged", "resumeEditing", "saveRequest"]) {
  assert.match(js, new RegExp(bridgeMethod))
}
assert.match(css, /\.cm-editor/)
assert.match(license, /MIT License/)
assert.equal(version, "1\n")

assert.match(await readFile(resolve(output, "VIM-LICENSE.txt"), "utf8"), /MIT License/)
