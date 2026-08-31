#!/usr/bin/env node

const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const cli = path.join(__dirname, "release-evidence.js");
const retainedRoot = process.env.RELEASE_EVIDENCE_RETAIN_VALID || "";
const scratch = retainedRoot ? path.dirname(retainedRoot) : fs.mkdtempSync(path.join(os.tmpdir(), "array-release-evidence-test-"));
let checks = 0;

function run(args, env = {}, cwd) {
  return spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env }, cwd
  });
}
function ok(condition, message) { checks += 1; assert.ok(condition, message); }
function json(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`); }
function text(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, value); }
function hash(file) { return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"); }
function png(file) {
  // Valid 1x1 transparent PNG.
  fs.writeFileSync(file, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X3RkAAAAAElFTkSuQmCC", "base64"));
}
function copyTree(source, destination) { fs.cpSync(source, destination, { recursive: true, dereference: false }); }
function artifactFixture(name, staleLog = false) {
  const root = path.join(scratch, name); fs.mkdirSync(root, { recursive: true });
  const repo = path.join(scratch, `${name}-source`); fs.mkdirSync(repo); text(path.join(repo, "source"), "source\n");
  for (const args of [["init", "-q"], ["add", "source"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "fixture"]]) { const result = spawnSync("git", args, { cwd: repo, encoding: "utf8" }); assert.strictEqual(result.status, 0, result.stderr); }
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: repo, encoding: "utf8" }).stdout.trim();
  const tools = path.join(root, "system-tools"); fs.mkdirSync(tools);
  text(path.join(tools, "codesign"), "#!/bin/sh\necho 'Authority=Developer ID Application: Fixture' >&2\necho 'TeamIdentifier=FIXTURETEAM' >&2\necho 'designated => identifier dev.arrayapp.macos and anchor apple generic' >&2\nexit 0\n");
  for (const name of ["xcrun", "spctl"]) text(path.join(tools, name), "#!/bin/sh\necho verified >&2\nexit 0\n");
  for (const name of ["codesign", "xcrun", "spctl"]) fs.chmodSync(path.join(tools, name), 0o755);
  ok(run(["init", "--run-id", name, "--root", root, "--base-sha", head]).status === 0, `${name}: artifact init`);
  const app = path.join(root, "Array.app"), macos = path.join(app, "Contents", "MacOS"); fs.mkdirSync(macos, { recursive: true });
  text(path.join(app, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Array</string><key>CFBundleIdentifier</key><string>dev.arrayapp.macos</string><key>CFBundleShortVersionString</key><string>0.8.0</string><key>CFBundleVersion</key><string>56</string></dict></plist>\n`);
  text(path.join(macos, "Array"), "canonical executable\n"); fs.chmodSync(path.join(macos, "Array"), 0o755);
  const dmg = path.join(root, "Array-0.8.0.dmg"); text(dmg, "canonical dmg bytes\n");
  const argv = path.join(root, "release.argv"); text(argv, "scripts/release-app.sh\0--set-version\00.8.0\0--set-build\056\0");
  const log = path.join(root, "release.log"); text(log, staleLog ? "old unrelated log\n" : "==> notarize app\nid: 11111111-1111-1111-1111-111111111111\nstatus: Accepted\n==> build DMG\n==> notarize DMG\nid: 22222222-2222-2222-2222-222222222222\nstatus: Accepted\n==> Gatekeeper verification\n");
  return { root, repo, tools, head, app, dmg, argv, log, manifest: path.join(root, "canonical.json") };
}
function baseReport(root, role = "lead") {
  const semantic = path.join(root, "semantic.json"); text(semantic, "{}\n");
  const log = path.join(root, "command.log"); text(log, "ok\n");
  const image = path.join(root, "actual.png"); png(image);
  return {
    workstream: "fixture", role, phase: "implementation", status: "PASS",
    base_sha: "a".repeat(40), candidate_sha: "b".repeat(40), worktree: root,
    branch: "fixture", summary: "fixture", owned_files_changed: role === "lead" ? [path.join(root, "owned")] : [],
    unexpected_files_changed: [], commands_run: [{ command: "fixture", exit_code: 0, log }],
    candidate_dirty_status: "clean", commits: role === "lead" ? [{ sha: "b".repeat(40), purpose: "implementation" }] : [],
    red_witness: role === "lead" ? { command: "fixture-red", exit_code: 1, log, expected_assertion: "reject", observed_failure: "rejected", infra_clean: true } : null,
    green_evidence: [{ command: "fixture", exit_code: 0, log }],
    tooth_proof: role === "lead" ? { method: "revert", red_log: log, restored_green_log: log } : null,
    review_findings: [],
    expected_visual_states: [{ visual_state_id: "main", appearances: ["aqua"], required_roles: ["actual"], semantic_assertion: "fixture visible" }],
    screenshots: [{ case_id: "visual", iteration: 1, visual_state_id: "main", role: "actual", path: image, sha256: hash(image), commit: "b".repeat(40), point_size: [1, 1], pixel_size: [1, 1], backing_scale: 1, appearance: "aqua", canvas_zoom: 1, tile_zoom: 1, baseline_path: null, baseline_sha: null, baseline_commit: null, actual_path: image, actual_sha: hash(image), diff_metric: 0, diff_status: "candidate_only", mask_path: null, mask_sha: null, mask_rationale: null, contact_sheet_members: [], primary: true, semantic_artifact: semantic, command_log: log, readiness: "fixture-ready", inspection: "NEEDS_JUDGMENT" }],
    semantic_artifacts: [semantic], expected_performance_cases: [], performance_artifacts: [], performance: [], known_red_observed: [], unexpected_failures: [], risks: [], gaps_or_skips: [], promotion_recommendation: "PROMOTE"
  };
}
function installInventory(root, report, overrides = {}) {
  const inventoryPath = path.join(root, "expected-inventory.json");
  const inventory = {
    candidate_sha: report.candidate_sha,
    workstreams: [{ workstream: report.workstream, base_sha: report.base_sha, roles: [{
      role: report.role,
      visual_states: JSON.parse(JSON.stringify(report.expected_visual_states)),
      performance_cases: JSON.parse(JSON.stringify(report.expected_performance_cases)),
      capture_manifests: []
    }] }],
    global_performance_identity: true,
    ...overrides
  };
  json(inventoryPath, inventory);
  const result = run(["inventory", "--root", root, "--file", inventoryPath]);
  ok(result.status === 0, `inventory locks: ${result.stderr}`);
}
function fixture(name, mutate, expected) {
  const root = path.join(scratch, name); fs.mkdirSync(root, { recursive: true });
  ok(run(["init", "--run-id", name, "--root", root, "--base-sha", "a".repeat(40)]).status === 0, `${name}: init`);
  const report = baseReport(root); installInventory(root, report); if (mutate) mutate(report, root);
  const reportPath = path.join(root, "report.json"); json(reportPath, report);
  const ingested = run(["ingest", "--root", root, "--report", reportPath]);
  if (expected === "ingest-fail") return ok(ingested.status !== 0, `${name}: ingestion should fail`);
  ok(ingested.status === 0, `${name}: ingestion: ${ingested.stderr}`);
  const result = run(["validate", "--root", root]);
  ok(expected === "pass" ? result.status === 0 : result.status !== 0, `${name}: expected ${expected}, got ${result.status}: ${result.stderr}`);
  return { root, reportPath, report };
}

try {
  const valid = fixture(retainedRoot ? path.basename(retainedRoot) : "valid", null, "pass");
  fixture("explicit-zero-inventory", report => { report.expected_visual_states = []; report.screenshots = []; }, "fail");
  for (const role of ["reviewer", "tester", "auditor"]) fixture(`null-${role}`, (report, root) => Object.assign(report, baseReport(root, role)), "pass");
  const duplicate = run(["ingest", "--root", valid.root, "--report", valid.reportPath]);
  ok(duplicate.status === 0, "duplicate ingestion is idempotent");
  ok(JSON.parse(fs.readFileSync(path.join(valid.root, "manifest.json"))).reports.length === 1, "duplicate did not append");
  fixture("missing-file", report => { report.semantic_artifacts = [path.join(report.worktree, "missing.json")]; }, "fail");
  fixture("relative-path", report => { report.semantic_artifacts = ["relative.json"]; }, "fail");
  fixture("out-of-root", report => { report.semantic_artifacts = [__filename]; }, "fail");
  fixture("hash-mismatch", report => { report.screenshots[0].sha256 = "0".repeat(64); }, "fail");
  fixture("non-png", (report, root) => { const p = path.join(root, "fake.png"); text(p, "not png"); report.screenshots[0].path = p; report.screenshots[0].actual_path = p; report.screenshots[0].sha256 = hash(p); report.screenshots[0].actual_sha = hash(p); }, "fail");
  fixture("missing-state", report => { report.screenshots = []; }, "fail");
  fixture("nonzero-no-diff", report => { report.screenshots[0].diff_status = "nonzero"; report.screenshots[0].diff_metric = 1; }, "fail");
  fixture("bad-baseline", report => { report.screenshots[0].role = "baseline"; report.screenshots[0].baseline_path = null; }, "fail");
  fixture("bad-mask", report => { report.screenshots[0].mask_path = report.screenshots[0].path; report.screenshots[0].mask_sha = hash(report.screenshots[0].path); }, "fail");
  fixture("capture-unavailable", report => { report.status = "DISPLAY_DEFERRED"; report.screenshots = [{ case_id: "visual", iteration: 1, visual_state_id: "main", role: "failure", failure_reason: "capture_unavailable", path: null, semantic_artifact: report.semantic_artifacts[0], command_log: report.commands_run[0].log }]; }, "pass");
  fixture("aborted-no-image", report => { report.status = "FAIL"; report.screenshots = [{ case_id: "visual", iteration: 1, visual_state_id: "main", role: "failure", failure_reason: "flow_aborted", path: null, semantic_artifact: report.semantic_artifacts[0], command_log: report.commands_run[0].log }]; }, "fail");
  fixture("perf-missing", report => { report.expected_performance_cases = [{ case_id: "perf", repetitions: 2, required_roles: ["raw_run"], configuration: "release", seed: "7" }]; }, "fail");
  fixture("perf-extra", (report, root) => { const p = path.join(root, "raw.json"); json(p, { value: 1 }); report.performance_artifacts = [{ case_id: "perf", iteration: 1, role: "raw_run", path: p, sha256: hash(p), binary_sha256: "c".repeat(64), configuration: "release", seed: "7", derived_summary: null }]; }, "fail");
  fixture("summary-raw-mismatch", (report, root) => { const raw = path.join(root, "raw.json"); const summary = path.join(root, "summary.json"); json(raw, {}); json(summary, { raw_inputs: [raw], sample_count: 2 }); report.expected_performance_cases = [{ case_id: "perf", repetitions: 1, required_roles: ["raw_run", "soak_summary"], configuration: "release", seed: "7" }]; report.performance_artifacts = ["raw_run", "soak_summary"].map(role => ({ case_id: "perf", iteration: 1, role, path: role === "raw_run" ? raw : summary, sha256: hash(role === "raw_run" ? raw : summary), binary_sha256: "c".repeat(64), configuration: "release", seed: "7", derived_summary: role === "soak_summary" ? summary : null })); }, "fail");
  const symlinkRoot = path.join(scratch, "symlink"); fs.mkdirSync(symlinkRoot); const outside = path.join(scratch, "outside.json"); text(outside, "{}"); fs.symlinkSync(outside, path.join(symlinkRoot, "escape.json")); fixture("symlink-escape", (report, root) => { fs.symlinkSync(outside, path.join(root, "escape.json")); report.semantic_artifacts = [path.join(root, "escape.json")]; }, "fail");
  const malformedRoot = path.join(scratch, "malformed"); fs.mkdirSync(malformedRoot); ok(run(["init", "--run-id", "malformed", "--root", malformedRoot, "--base-sha", "a".repeat(40)]).status === 0, "malformed init"); const malformed = path.join(malformedRoot, "report.json"); text(malformed, "{"); ok(run(["ingest", "--root", malformedRoot, "--report", malformed]).status !== 0, "malformed JSON rejected");
  const isolatedA = path.join(scratch, "isolate-a"), isolatedB = path.join(scratch, "isolate-b");
  ok(run(["init", "--run-id", "A", "--root", isolatedA, "--base-sha", "a".repeat(40)]).status === 0 && run(["init", "--run-id", "B", "--root", isolatedB, "--base-sha", "a".repeat(40)]).status === 0, "run roots initialize independently");
  ok(JSON.parse(fs.readFileSync(path.join(isolatedA, "manifest.json"))).run_id === "A" && JSON.parse(fs.readFileSync(path.join(isolatedB, "manifest.json"))).run_id === "B", "run roots cannot overwrite each other");
  const interrupted = path.join(scratch, "interrupted"); fs.mkdirSync(interrupted); const interruptedResult = run(["init", "--run-id", "interrupted", "--root", interrupted, "--base-sha", "a".repeat(40)], { RELEASE_EVIDENCE_INTERRUPT_AT: "manifest" }); ok(interruptedResult.status !== 0 && !fs.existsSync(path.join(interrupted, "manifest.json")), "interrupted manifest write leaves no partial success");
  const summaryPath = path.join(valid.root, "summary.md"), summaryResult = run(["summary", "--root", valid.root, "--output", summaryPath]); ok(summaryResult.status === 0 && fs.existsSync(summaryPath) && fs.readFileSync(summaryPath, "utf8").includes("Reports: 1"), `summary validates and writes atomically: ${summaryResult.stderr}`);

  const canonical = artifactFixture("canonical");
  const createArgs = ["artifact-create", "--root", canonical.root, "--candidate-sha", canonical.head, "--release-argv", canonical.argv, "--release-log", canonical.log, "--app", canonical.app, "--dmg", canonical.dmg, "--output", canonical.manifest];
  const systemEnv = { RELEASE_EVIDENCE_SYSTEM_TOOLS: canonical.tools };
  const created = run(createArgs, systemEnv, canonical.repo); ok(created.status === 0, `canonical artifact creates: ${created.stderr}`);
  const mounted = path.join(canonical.root, "mounted", "Array.app"); copyTree(canonical.app, mounted);
  const verified = path.join(canonical.root, "verified.json"); ok(run(["artifact-verify", "--manifest", canonical.manifest, "--candidate-sha", canonical.head, "--dmg", canonical.dmg, "--mounted-app", mounted, "--output", verified], systemEnv).status === 0, "canonical mounted artifact verifies");
  text(path.join(mounted, "Contents", "MacOS", "Array"), "modified after signing\n"); ok(run(["artifact-verify", "--manifest", canonical.manifest, "--candidate-sha", canonical.head, "--dmg", canonical.dmg, "--mounted-app", mounted, "--output", verified], systemEnv).status !== 0, "modified executable after signing is rejected");
  fs.rmSync(path.dirname(mounted), { recursive: true }); copyTree(canonical.app, mounted); text(canonical.dmg, "renamed-only impostor bytes\n"); ok(run(["artifact-verify", "--manifest", canonical.manifest, "--candidate-sha", canonical.head, "--dmg", canonical.dmg, "--mounted-app", mounted, "--output", verified], systemEnv).status !== 0, "renamed-only DMG impostor is rejected");
  text(canonical.dmg, "canonical dmg bytes\n"); text(path.join(canonical.root, "SHA256SUMS"), `${"0".repeat(64)}  Array-0.8.0.dmg\n`); ok(run(["artifact-verify", "--manifest", canonical.manifest, "--candidate-sha", canonical.head, "--dmg", canonical.dmg, "--mounted-app", mounted, "--output", verified], systemEnv).status !== 0, "mismatched checksum is rejected");
  ok(run(["artifact-verify", "--manifest", canonical.manifest, "--candidate-sha", "f".repeat(40), "--dmg", canonical.dmg, "--mounted-app", mounted, "--output", verified], systemEnv).status !== 0, "wrong source SHA is rejected");
  ok(run([...createArgs.slice(0, -1), path.join(canonical.root, "second.json")], systemEnv, canonical.repo).status !== 0, "second canonical conflict is rejected");
  const interruptedChecksum = artifactFixture("interrupted-checksum"); ok(run(["artifact-create", "--root", interruptedChecksum.root, "--candidate-sha", interruptedChecksum.head, "--release-argv", interruptedChecksum.argv, "--release-log", interruptedChecksum.log, "--app", interruptedChecksum.app, "--dmg", interruptedChecksum.dmg, "--output", interruptedChecksum.manifest], { RELEASE_EVIDENCE_INTERRUPT_AT: "checksum", RELEASE_EVIDENCE_SYSTEM_TOOLS: interruptedChecksum.tools }, interruptedChecksum.repo).status !== 0 && !fs.existsSync(path.join(interruptedChecksum.root, "SHA256SUMS")), "interrupted checksum write leaves no partial checksum");
  const stale = artifactFixture("stale-notary", true); ok(run(["artifact-create", "--root", stale.root, "--candidate-sha", stale.head, "--release-argv", stale.argv, "--release-log", stale.log, "--app", stale.app, "--dmg", stale.dmg, "--output", stale.manifest], { RELEASE_EVIDENCE_SYSTEM_TOOLS: stale.tools }, stale.repo).status !== 0, "stale notary log is rejected");
  console.log(`release-evidence checks passed (${checks})`);
} finally {
  if (!retainedRoot) fs.rmSync(scratch, { recursive: true, force: true });
}
