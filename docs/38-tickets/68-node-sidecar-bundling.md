# Node sidecar bundling — sign, notarize, and embed the managed-tier runtime

## What this delivers

After this ticket lands, the Continuum `.app` bundle ships a signed, notarized Node
Single Executable Application (SEA) at `Contents/MacOS/continuum-node-sidecar`. A Swift
shim in `AgentAdapterRegistry` locates the binary at runtime by walking `Bundle.main`'s
`Contents/MacOS` directory, verifies it is reachable and executable, then returns its
absolute path to each adapter factory. The ACP and Codex adapters — built in the next
ticket — accept this path and spawn the binary directly. The same binary runs on the VPS
when agents are remote; the only change there is that it arrives via the deploy script
rather than the `.app` bundle.

The user sees nothing new. From their perspective the managed-tier adapters they will use
in later tickets simply work. From the system's perspective, the dangerous question
"where is the Node runtime and is it correctly signed?" is answered once, in one place,
before any adapter ever touches it.

## How it fits

This ticket is the first concrete work of the managed tier, sitting immediately after the
adapter-protocol seam. That seam defines `AgentAdapter` as a Swift protocol and
`AgentRuntimeEvent` as the canonical event union; it leaves the question of "what
executable backs the TS drivers?" deliberately open. This ticket closes that question.

Nothing in the adapter-protocol seam produces a runnable binary — it is pure Swift types
and protocol stubs. This ticket produces the binary those stubs will spawn. It also
introduces `AgentAdapterRegistry`, the lightweight Swift type that every adapter factory
calls to resolve the sidecar path, so the path logic is tested once rather than duplicated
across four adapters.

What it unblocks: the ACP driver ticket — which spawns the sidecar with `["acp"]` —
cannot be written until the sidecar binary exists, is signed, and `AgentAdapterRegistry`
can locate it. Every subsequent managed-tier adapter depends on the same registry call,
so this ticket is the shared substrate they all consume.

## The approach

Node's SEA mechanism (stable since Node 22, production-quality in Node 24+) is the
chosen path. The build produces a blob from a minimal TypeScript "launcher" entry-point,
injects that blob into a copy of the Node 24 LTS binary using `postject`, strips the
original Apple ad-hoc signature, re-signs the result with the Developer ID Application
certificate under the Hardened Runtime, and notarizes. The launcher's only job at startup
is to dispatch on its first argument (`acp`, `codex-app-server`, `claude-sdk`, `opencode`)
and delegate to the corresponding t3code-derived TS driver. The TS source files are
bundled into the SEA blob at build time via `esbuild`; the final binary contains no
`node_modules` directory and requires no runtime npm access.

The Node binary used is `node-24-lts-macos-universal2` — the macOS universal binary
(arm64 + x86_64 in one fat binary) downloaded from the official Node release CDN and
checksum-verified before use. Pinning to Node 24 LTS means the binary is supported until
April 2028, giving a long maintenance window before a forced upgrade. The VPS deployment
uses the same SEA blob injected into the Linux arm64 (or x86_64) Node 24 LTS binary; the
two blobs are built from the same source and the same `esbuild` output, so behavior is
identical. The Swift-side path resolver is purely a path lookup — it does not fork or
execute the binary itself.

The Hardened Runtime requires `com.apple.security.cs.allow-jit` and
`com.apple.security.cs.allow-unsigned-executable-memory` because V8 uses JIT compilation.
These entitlements must appear in the `.entitlements` file that `codesign` receives at
re-signing time. They are well-understood by Apple's notarization service and do not
disqualify the app from distribution, but they must be declared explicitly — omitting them
causes the binary to crash at the first JIT compilation on a hardened-runtime system.

The build pipeline lives in a new `scripts/build-node-sidecar.sh` that is called by
`scripts/make-app-bundle.sh` before it assembles `Contents/MacOS`. The CI workflow
(GitHub Actions `macos-latest`) treats the node-sidecar build as a step that must pass
before the bundle step; on local developer builds the same shell script runs identically.
The sidecar binary is not committed to the repository. Instead, `make-app-bundle.sh` calls
`build-node-sidecar.sh` on every invocation; the build is fast (the blob is the expensive
step, roughly 30 s; `postject` is seconds) and the output is reproducible given the same
Node 24 LTS pin and the same TS source hash.

## Where it lives

**New files:**

- `scripts/build-node-sidecar.sh` — the end-to-end build script: download Node universal
  binary + verify SHA-256, run `esbuild` to bundle TS launcher, run
  `node --experimental-sea-config sea-config.json` to produce the blob, `postject`, strip
  old signature, `codesign` with JIT entitlements, optionally `notarytool submit --wait`,
  produce `continuum-node-sidecar` as output.

- `NodeSidecar/launcher.ts` — the dispatcher entry-point bundled into the SEA blob.
  Dispatches on `process.argv[2]` to the correct driver export. No runtime file I/O, no
  network calls in the launcher itself — those live in the driver modules.

- `NodeSidecar/sea-config.json` — the SEA configuration, specifying `main: dist/launcher.js`,
  `output: continuum-node-sidecar.blob`, `disableExperimentalSEAWarning: true`.

- `NodeSidecar/node-sidecar.entitlements` — the `.entitlements` XML with
  `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory`
  set to `true`. Used by `codesign` when re-signing the sidecar.

- `Sources/ContinuumRevivedCore/AgentAdapterRegistry.swift` — the Swift registry type
  (pure logic, no AppKit, no Foundation singletons beyond `Bundle`). Owns the `sidecarPath`
  resolution function and exposes a checked `SidecarLocator` value type.

**Modified files:**

- `scripts/make-app-bundle.sh` — call `build-node-sidecar.sh --output
  "$OUTPUT/Contents/MacOS/continuum-node-sidecar"` before the bundle assembly step, then
  verify the binary exists and is executable before proceeding.

**Confirmed seams exist:**

- `Sources/ContinuumRevived/App/ContinuumApp.swift:603` — `@main enum ContinuumApp` is the
  app entry point. `AgentAdapterRegistry` is initialized lazily on first adapter-factory
  call, not at `main()` start, so there is no startup-time impact and no change to
  `ContinuumApp.swift` in this ticket.

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85-119` — `AgentStatus`
  and `AgentDescriptor` are already defined here. `AgentAdapterRegistry` lives in the same
  `ContinuumRevivedCore` module so future adapters can import it without a dependency on
  the app layer.

## Implementation breadcrumbs

### `build-node-sidecar.sh` — the full pipeline

```bash
#!/usr/bin/env bash
set -euo pipefail
# Pins — update together when upgrading Node.
NODE_VERSION="24.3.0"
NODE_SHA256_UNIVERSAL="<sha256 from nodejs.org/dist/v24.3.0/SHASUMS256.txt>"
ESBUILD_VERSION="0.24.2"

# 1. Download the macOS universal Node binary if not cached.
NODE_CACHE="$HOME/.cache/continuum-node-sea/node-${NODE_VERSION}-macos-universal"
if [[ ! -f "$NODE_CACHE" ]]; then
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-universal.tar.gz" \
        | tar xz -C "$(dirname "$NODE_CACHE")" --strip-components=2 "node-v${NODE_VERSION}-darwin-universal/bin/node"
    mv "$(dirname "$NODE_CACHE")/node" "$NODE_CACHE"
fi
echo "$NODE_SHA256_UNIVERSAL  $NODE_CACHE" | shasum -a 256 -c -

# 2. Bundle TS launcher with esbuild.
npx --yes "esbuild@${ESBUILD_VERSION}" NodeSidecar/launcher.ts \
    --bundle --platform=node --target=node24 --outfile=NodeSidecar/dist/launcher.js \
    --external:module  # keep Node built-ins external; bundle npm deps inline

# 3. Generate the SEA blob.
cp "$NODE_CACHE" "$OUTPUT.tmp"
"$NODE_CACHE" --experimental-sea-config NodeSidecar/sea-config.json

# 4. Inject blob into the copied Node binary.
npx postject "$OUTPUT.tmp" NODE_SEA_BLOB NodeSidecar/continuum-node-sidecar.blob \
    --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 \
    --macho-segment-name NODE_SEA

# 5. Strip the original Apple ad-hoc signature (postject invalidates it).
codesign --remove-signature "$OUTPUT.tmp"

# 6. Re-sign with Developer ID and JIT entitlements.
codesign --sign "$DEVELOPER_ID_CERT" \
         --entitlements NodeSidecar/node-sidecar.entitlements \
         --options runtime \
         --timestamp \
         --force \
         "$OUTPUT.tmp"

mv "$OUTPUT.tmp" "$OUTPUT"
echo "built: $OUTPUT"
```

The `DEVELOPER_ID_CERT` env var is the cert identity string (`"Developer ID Application:
Dylan Reed (TEAMID)"`), populated from the keychain in CI via the standard temp-keychain
pattern and available from `~/.signing-config` in local builds.

### `NodeSidecar/launcher.ts` — the dispatcher

```typescript
import { runAcp } from "./drivers/acpDriver.js";
import { runCodexAppServer } from "./drivers/codexDriver.js";
import { runClaudeSdk } from "./drivers/claudeDriver.js";

const [, , subcommand, ...rest] = process.argv;
switch (subcommand) {
  case "acp":             await runAcp(rest);              break;
  case "codex-app-server": await runCodexAppServer(rest);  break;
  case "claude-sdk":      await runClaudeSdk(rest);        break;
  default:
    console.error(`continuum-node-sidecar: unknown subcommand '${subcommand}'`);
    process.exit(1);
}
```

Each driver module (`acpDriver.ts`, `codexDriver.ts`, `claudeDriver.ts`) is a thin
wrapper around the corresponding t3code TS driver, re-exported without modification. The
drivers expect their arguments on `process.argv[3:]` and communicate with the Swift parent
process over stdin/stdout JSON-RPC — the exact same protocol the adapter tickets will
establish. The launcher adds nothing to that protocol; it only routes.

### `AgentAdapterRegistry.swift` — the path resolver

```swift
// In Sources/ContinuumRevivedCore/AgentAdapterRegistry.swift

public struct SidecarLocator: Sendable {
    /// Absolute path to the signed `continuum-node-sidecar` binary inside the app bundle
    /// (or a developer override via `CONTINUUM_NODE_SIDECAR_PATH`).
    public let path: String
}

public enum SidecarLocatorError: Error, CustomStringConvertible {
    case notFound(searchedAt: String)
    case notExecutable(path: String)

    public var description: String {
        switch self {
        case .notFound(let p):    return "continuum-node-sidecar not found at \(p)"
        case .notExecutable(let p): return "continuum-node-sidecar at \(p) is not executable"
        }
    }
}

public enum AgentAdapterRegistry {
    /// Resolve the sidecar path. Call once per adapter factory; cache the result.
    /// Pure: no I/O beyond a stat(2) call.
    public static func resolveSidecar(bundle: Bundle = .main) throws -> SidecarLocator {
        // Developer escape hatch (CI and integration tests use this to point at a
        // local debug build without re-bundling the app).
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_NODE_SIDECAR_PATH"] {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw SidecarLocatorError.notExecutable(path: override)
            }
            return SidecarLocator(path: override)
        }

        // Production: binary sits beside the main executable in Contents/MacOS/.
        let macosDir = (bundle.executableURL?.deletingLastPathComponent())
            .map(\.path) ?? ""
        let candidate = (macosDir as NSString).appendingPathComponent("continuum-node-sidecar")
        guard FileManager.default.fileExists(atPath: candidate) else {
            throw SidecarLocatorError.notFound(searchedAt: candidate)
        }
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw SidecarLocatorError.notExecutable(path: candidate)
        }
        return SidecarLocator(path: candidate)
    }
}
```

The `CONTINUUM_NODE_SIDECAR_PATH` override is the integration test escape hatch and the
local developer shortcut — during development you can build the sidecar once and point at
it without running `make-app-bundle.sh` every time. It is not a user-facing feature and
carries no security privilege.

## How we test it

### Logic (pure Core checks)

Add a check entry-point `--sidecar-registry-check` in `ContinuumRevivedCoreChecks`, following
the existing pattern at `ContinuumApp.swift:603`. The check does three things:

1. **Override path found and executable.** Set `CONTINUUM_NODE_SIDECAR_PATH` to a
   temporary file created with `0755` permissions. Call `AgentAdapterRegistry.resolveSidecar`
   using the default bundle; assert it returns the override path.

2. **Override path not executable.** Set the env var to a file with `0644` permissions.
   Assert the call throws `SidecarLocatorError.notExecutable`.

3. **Bundle path missing.** Set a fake `Bundle` stub (or unset the env var with no binary
   present). Assert the call throws `SidecarLocatorError.notFound`.

These three cases cover every branch in the resolution function without touching a real
app bundle or spawning a process. The check is a pure file-system manipulation; it runs
in the Swift test harness under `swift test` with no additional setup.

### Backend (real-path integration, not bypassed)

Run `scripts/make-app-bundle.sh --configuration release --output /tmp/ContinuumTest.app`
in a clean checkout (CI or a local Mac with the Developer ID cert available). Then:

1. Confirm `continuum-node-sidecar` is present at
   `/tmp/ContinuumTest.app/Contents/MacOS/continuum-node-sidecar`.

2. Run `codesign --verify --deep --strict /tmp/ContinuumTest.app` and assert exit code 0.
   The `--deep` flag traverses every embedded binary, including the sidecar, so this is
   not a shallow check.

3. Run `spctl --assess --type execute /tmp/ContinuumTest.app` and assert exit code 0
   (Gatekeeper accepts the signed binary). This is the local notarization-skip gate;
   notarization proper happens in CI on a tagged release.

4. Spawn the sidecar directly and send it an unknown subcommand:
   `echo "" | /tmp/ContinuumTest.app/Contents/MacOS/continuum-node-sidecar unknown-cmd`
   Assert it exits with code 1 and writes `"unknown subcommand"` to stderr. This proves
   the SEA blob loaded correctly and the launcher runs.

5. Spawn with the `acp` subcommand and send a malformed JSON-RPC frame:
   `echo 'not-json' | /tmp/ContinuumTest.app/Contents/MacOS/continuum-node-sidecar acp`
   Assert it exits with a non-zero code and a JSON-RPC parse-error frame on stdout. This
   proves the ACP driver module loaded and the JSON-RPC framing is active. (The ACP driver
   itself is from t3code; this test confirms it is present in the blob and responds
   correctly to bad input, not that the full ACP session works — that belongs to the ACP
   driver ticket.)

The VPS integration test is: `scp` the sidecar binary to a Hetzner CX32 running Ubuntu 24
LTS, run the same unknown-subcommand smoke test under `CONTINUUM_TEST=1`. Assert exit code
1 and the error message. This proves the Linux SEA blob (built separately by
`build-node-sidecar.sh --platform linux-x64`) executes correctly on the target OS.

### UX (visual gate + dogfood snippet)

**Visual gate.** There is no user-facing UI change in this ticket. The visual gate is the
Component Lab "managed adapter registry" fixture, which will be added in the ACP driver
ticket. This ticket's UX commitment is that it does not regress the existing app launch:

Run `scripts/make-app-bundle.sh` and open the assembled `.app`. The app must reach the
normal workspace state (canvas renders, terminal tiles respond) without crash or hang.
Confirm in Console.app that no `continuum-node-sidecar` error messages appear at startup
— because `AgentAdapterRegistry.resolveSidecar()` is lazy and not called at launch time,
the binary's presence (or absence in a debug build) is silent until an adapter is actually
instantiated.

**Dogfood snippet.** Build the app bundle locally with `scripts/make-app-bundle.sh
--configuration release --output /tmp/Continuum.app`. Open the assembled app from Finder
(not Xcode, to exercise Gatekeeper). The app opens normally to the canvas. Open Terminal
and run: `codesign -d -vv /tmp/Continuum.app/Contents/MacOS/continuum-node-sidecar 2>&1`.
You should see the `Identifier`, `TeamIdentifier`, and `Entitlements` block showing
`com.apple.security.cs.allow-jit = true` and
`com.apple.security.cs.allow-unsigned-executable-memory = true`. You will also see
`Runtime Version` confirming the Hardened Runtime flag. If any of those are absent, the
re-sign step failed silently.

## Execution mode

This ticket is **needs-substrate** because three of its verification steps require real
infrastructure that cannot be faked:

- Re-signing with `codesign` requires an actual Developer ID Application certificate in a
  macOS keychain. A CI runner without the cert imported cannot produce a correctly signed
  binary; `codesign` will fail at the signing step.
- Gatekeeper assessment (`spctl --assess`) checks Apple's revocation database and requires
  the binary to have been signed by a known certificate. An ad-hoc-signed or unsigned
  binary returns a non-zero exit code regardless of how the logic check goes.
- Notarization (`notarytool submit --wait`) requires an Apple Developer account, a valid
  App Store Connect API key, and a round-trip to Apple's notarization service. This cannot
  be mocked.

The logic check in `ContinuumRevivedCoreChecks` and the unknown-subcommand smoke test can
run autonomously in a CI environment that has the cert; but the end-to-end "sign, assess,
notarize" verification is substrate-gated.

## Done when

- [ ] `scripts/build-node-sidecar.sh` exists, runs to completion on macOS arm64 with a
  valid `DEVELOPER_ID_CERT` environment variable, and produces a file named
  `continuum-node-sidecar` at the path specified by `--output`.

- [ ] `scripts/make-app-bundle.sh` calls `build-node-sidecar.sh` and the resulting bundle
  contains `Contents/MacOS/continuum-node-sidecar` as an executable file.

- [ ] `codesign --verify --deep --strict <bundle>.app` exits 0. The `--deep` traversal
  finds and verifies the sidecar, confirming it is correctly embedded and signed.

- [ ] `codesign -d -vv continuum-node-sidecar 2>&1` shows `allow-jit` and
  `allow-unsigned-executable-memory` in the entitlements block.

- [ ] The unknown-subcommand smoke test exits 1 and writes `"unknown subcommand"` to
  stderr. The ACP-driver smoke test exits non-zero and returns a JSON-RPC parse-error frame.

- [ ] The sidecar-registry logic check (`--sidecar-registry-check`) passes all three
  branches (override found, override not executable, bundle path missing) under
  `swift test` with no real app bundle.

- [ ] The `CONTINUUM_NODE_SIDECAR_PATH` override resolves correctly in an integration
  test that sets the variable to a known temp file.

- [ ] The assembled app opens normally on macOS without crash or Console errors related to
  the sidecar at launch time.

- [ ] On a Hetzner CX32 running Ubuntu 24 LTS, the Linux-targeted sidecar binary (built
  with `--platform linux-x64`) executes the unknown-subcommand smoke test and exits 1 with
  the expected error message.

- [ ] Notarization completes (Apple notary service returns `Accepted`) and
  `xcrun stapler staple <bundle>.app` succeeds.

## Depends on / unblocks

**Depends on:** the adapter-protocol seam, which defines `AgentAdapter`, `AgentKind`, and
`AgentRuntimeEvent` in `ContinuumRevivedCore`. `AgentAdapterRegistry` sits in that same
module and must be consistent with those types. Technically this ticket could be authored
before the adapter protocol is complete, because `AgentAdapterRegistry.swift` itself
contains no reference to `AgentAdapter` — but the smoke tests for the ACP driver
subcommand confirm that the TS driver module the adapter will eventually call is present in
the blob. For sequencing clarity: finish the adapter protocol first, then bundle.

Also depends on: an active Apple Developer Program enrollment (for the Developer ID cert
and notarization credentials). Without these, the backend and UX checks are blocked.

**Unblocks:** the ACP driver ticket, which spawns
`continuum-node-sidecar acp` as a child process and opens a JSON-RPC channel over its
stdio. That ticket can only be written once the binary exists and the registry call is
proven. Every subsequent managed adapter — the Codex app-server driver, the Claude SDK
driver — calls the same `AgentAdapterRegistry.resolveSidecar()` and passes the resulting
path to `Process`. None of those tickets touch the build pipeline; they only consume the
output of this one.

Also unblocks: any CI workflow that validates the signed `.app` bundle end-to-end. The
`codesign --verify --deep` check is worthless without the sidecar present, because
`--deep` would trivially pass on a bundle with no embedded executables.

## Watch out for

**The single most dangerous step is `postject` invalidating the original signature and you
forgetting to strip it before re-signing.** If you call `codesign` after `postject`
without first running `codesign --remove-signature`, you get a binary with two signature
regions. macOS will accept it locally (because the outer signature is valid) but Apple's
notarization service does a deeper check and will reject it with a cryptic "invalid binary"
error. The shell script must run `codesign --remove-signature` before the re-sign step,
unconditionally, every time. Do not conditionalize this on whether the binary "seems to
have a signature" — always strip, always re-sign.

**The JIT entitlements must cover both `allow-jit` and `allow-unsigned-executable-memory`.**
In early 2026, several projects bundling Node SEA discovered that including only
`allow-jit` was insufficient on certain macOS versions (the second entitlement gates
executable-memory mapping separately from JIT). Omitting the second causes V8 to crash
with `SIGBUS` or `SIGSEGV` on the first code-generation call. Both must be present in
`node-sidecar.entitlements`.

**The Universal 2 binary is larger than you expect.** The `node-24-lts-macos-universal`
fat binary is approximately 90 MB before the blob is injected. After `postject`, add 5–20
MB for the bundled TS. The final sidecar is roughly 95–115 MB. The SEA blob must be
generated for each architecture separately if you ever switch from the universal binary to
per-arch builds; stick with the universal binary to avoid architecture-mismatch errors on
Intel Macs.

**Apple's notarization service had multi-hour queue stalls in early 2026.** Do not gate a
release branch or a hard deadline immediately after a `notarytool submit --wait` call. CI
should set `--timeout 30m` on the notarize step and fail fast rather than blocking the
runner for hours; the local-notarize escape hatch (notarize from the developer's Mac
outside CI) is always available.

**The `CONTINUUM_NODE_SIDECAR_PATH` override must never be granted elevated trust.** It is
a developer convenience, not a user-accessible feature. The Swift code must not log the
override path in release builds, must not expose it in any user-visible diagnostic, and
must not accept it if the app is running under sandbox (check for the sandbox entitlement
and silently ignore the override if present). This prevents a malicious local process from
pointing the override at an arbitrary executable.

**The VPS deploy script is not in scope for this ticket but must be named.** The sidecar
is built for `linux-x64` (and optionally `linux-arm64`) by passing `--platform linux-x64`
to `build-node-sidecar.sh`. That flag switches the Node binary download URL and the
`postject` target architecture. The resulting Linux binary is uploaded to the VPS via the
deploy script, which is a separate concern. Do not conflate the two builds; the macOS
universal and the Linux x64 are distinct outputs, and `make-app-bundle.sh` only calls the
macOS build.
