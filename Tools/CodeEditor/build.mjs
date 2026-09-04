import {build} from "esbuild"
import {cp, mkdir, rm, writeFile} from "node:fs/promises"
import {dirname, resolve} from "node:path"
import {fileURLToPath} from "node:url"

const root = dirname(fileURLToPath(import.meta.url))
const output = resolve(root, "../../Sources/ContinuumRevived/Resources/CodeEditor")

await rm(output, {recursive: true, force: true})
await mkdir(output, {recursive: true})
await build({
  entryPoints: [resolve(root, "src/editor.js")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "safari17",
  minify: true,
  legalComments: "external",
  outfile: resolve(output, "editor.js")
})
await cp(resolve(root, "src/index.html"), resolve(output, "index.html"))
await cp(resolve(root, "src/editor.css"), resolve(output, "editor.css"))
await cp(resolve(root, "../../LICENSES/CodeMirror.txt"), resolve(output, "LICENSE.txt"))
await cp(resolve(root, "../../LICENSES/CodeMirror-Vim.txt"), resolve(output, "VIM-LICENSE.txt"))
await writeFile(resolve(output, "ASSET_VERSION"), "1\n")
