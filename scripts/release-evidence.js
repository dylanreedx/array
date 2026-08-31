#!/usr/bin/env node

"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const SHA40 = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const ROLES = new Set(["lead", "auditor", "reviewer", "tester"]);
const STATUSES = new Set(["PASS", "FAIL", "BLOCKED", "NEEDS_JUDGMENT", "DISPLAY_DEFERRED"]);
const PERF_ROLES = new Set(["raw_run", "trace", "signpost", "sample", "vmmap", "soak_samples", "soak_summary", "diagnostic_before", "diagnostic_after", "diagnostic_diff", "visual_boundary"]);

function die(message, code = 1) { console.error(`release-evidence: ${message}`); process.exit(code); }
function sha256File(file) {
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(file, "r");
  try { const buffer = Buffer.alloc(1024 * 1024); let count; while ((count = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, count)); }
  finally { fs.closeSync(fd); }
  return hash.digest("hex");
}
function sha256Text(value) { return crypto.createHash("sha256").update(value).digest("hex"); }
function readJSON(file, label = file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { throw new Error(`${label} is not valid JSON: ${error.message}`); }
}
function atomicWrite(file, contents, kind = "manifest") {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temporary, "wx", 0o600); fs.writeFileSync(fd, contents); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    if (process.env.RELEASE_EVIDENCE_INTERRUPT_AT === kind) throw new Error(`simulated interrupted ${kind} write`);
    fs.renameSync(temporary, file);
    const dir = fs.openSync(path.dirname(file), "r"); try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  } finally { if (fd !== undefined) fs.closeSync(fd); try { fs.unlinkSync(temporary); } catch (_) {} }
}
function atomicJSON(file, value, kind) { atomicWrite(file, `${JSON.stringify(value, null, 2)}\n`, kind); }
function argumentsFor(argv) {
  const values = { "capture-manifest": [] };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i]; if (!key.startsWith("--")) throw new Error(`unexpected argument: ${key}`);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) throw new Error(`missing value for ${key}`);
    const name = key.slice(2), value = argv[++i];
    if (name === "capture-manifest") values[name].push(value); else if (Object.hasOwn(values, name)) throw new Error(`duplicate option: ${key}`); else values[name] = value;
  }
  return values;
}
function requireOptions(options, names) { for (const name of names) if (!options[name]) throw new Error(`missing --${name}`); }
function absolute(value, label) { if (typeof value !== "string" || !path.isAbsolute(value)) throw new Error(`${label} must be an absolute path`); return path.resolve(value); }
function rootInfo(rootArg, mustExist = true) {
  const root = absolute(rootArg, "--root");
  if (mustExist && !fs.existsSync(root)) throw new Error(`run root does not exist: ${root}`);
  return { root, real: mustExist ? fs.realpathSync(root) : root };
}
function contained(root, candidate, label, mustExist = true) {
  const absolutePath = absolute(candidate, label);
  if (mustExist && !fs.existsSync(absolutePath)) throw new Error(`${label} does not exist: ${absolutePath}`);
  const resolved = mustExist ? fs.realpathSync(absolutePath) : path.join(fs.realpathSync(path.dirname(absolutePath)), path.basename(absolutePath));
  if (resolved !== root.real && !resolved.startsWith(`${root.real}${path.sep}`)) throw new Error(`${label} escapes run root: ${absolutePath}`);
  return absolutePath;
}
function verifyFile(root, file, label, expectedHash, png = false) {
  const absolutePath = contained(root, file, label);
  if (!fs.statSync(absolutePath).isFile()) throw new Error(`${label} is not a regular file: ${absolutePath}`);
  const actual = sha256File(absolutePath);
  if (expectedHash !== undefined && (!SHA256.test(expectedHash) || actual !== expectedHash)) throw new Error(`${label} SHA-256 mismatch`);
  if (png) { const header = Buffer.alloc(8), fd = fs.openSync(absolutePath, "r"); try { fs.readSync(fd, header, 0, 8, 0); } finally { fs.closeSync(fd); } if (!header.equals(PNG)) throw new Error(`${label} is not a PNG`); }
  return { path: absolutePath, sha256: actual, size: fs.statSync(absolutePath).size };
}
function loadManifest(root) {
  const file = path.join(root.root, "manifest.json");
  const manifest = readJSON(file, "manifest");
  if (manifest.schema_version !== 1 || manifest.root !== root.root || manifest.run_id === undefined || !SHA40.test(manifest.base_sha || "") || !Array.isArray(manifest.reports) || !Array.isArray(manifest.capture_manifests) || !Array.isArray(manifest.canonical_artifacts)) throw new Error("manifest schema is invalid");
  return { file, manifest };
}
function init(options) {
  requireOptions(options, ["run-id", "root", "base-sha"]); if (!SHA40.test(options["base-sha"])) throw new Error("--base-sha must be a 40-character lowercase SHA");
  const root = rootInfo(options.root, false); fs.mkdirSync(root.root, { recursive: true });
  const file = path.join(root.root, "manifest.json");
  if (fs.existsSync(file)) { const existing = readJSON(file); if (existing.run_id === options["run-id"] && existing.root === root.root && existing.base_sha === options["base-sha"]) return; throw new Error("run root already belongs to another run"); }
  atomicJSON(file, { schema_version: 1, run_id: options["run-id"], root: root.root, base_sha: options["base-sha"], reports: [], capture_manifests: [], canonical_artifacts: [], validated_at: null }, "manifest");
}
function ingest(options) {
  requireOptions(options, ["root", "report"]); const root = rootInfo(options.root); const loaded = loadManifest(root);
  const reportPath = contained(root, options.report, "report"); const report = readJSON(reportPath, "report");
  validateReportShape(report, root, false);
  const entry = { path: reportPath, sha256: sha256File(reportPath), workstream: report.workstream, role: report.role, candidate_sha: report.candidate_sha };
  const same = loaded.manifest.reports.find(item => item.path === entry.path);
  if (same && same.sha256 !== entry.sha256) throw new Error("an ingested report changed in place");
  if (!same) loaded.manifest.reports.push(entry);
  for (const capturePathArg of options["capture-manifest"] || []) {
    const capturePath = contained(root, capturePathArg, "capture manifest"); readJSON(capturePath, "capture manifest"); const capture = { path: capturePath, sha256: sha256File(capturePath) };
    const prior = loaded.manifest.capture_manifests.find(item => item.path === capture.path);
    if (prior && prior.sha256 !== capture.sha256) throw new Error("an ingested capture manifest changed in place"); if (!prior) loaded.manifest.capture_manifests.push(capture);
  }
  loaded.manifest.reports.sort((a, b) => a.path.localeCompare(b.path)); loaded.manifest.capture_manifests.sort((a, b) => a.path.localeCompare(b.path)); loaded.manifest.validated_at = null;
  atomicJSON(loaded.file, loaded.manifest, "manifest");
}
function requireArray(report, name) { if (!Array.isArray(report[name])) throw new Error(`report.${name} must be an array`); }
function validateReportShape(report, root, deep = true) {
  const requiredStrings = ["workstream", "phase", "worktree", "branch", "summary", "candidate_dirty_status", "promotion_recommendation"];
  for (const field of requiredStrings) if (typeof report[field] !== "string" || !report[field]) throw new Error(`report.${field} is required`);
  if (!ROLES.has(report.role)) throw new Error("report.role is invalid"); if (!STATUSES.has(report.status)) throw new Error("report.status is invalid");
  if (!SHA40.test(report.base_sha || "") || !SHA40.test(report.candidate_sha || "")) throw new Error("report Git SHAs are invalid");
  for (const field of ["owned_files_changed", "unexpected_files_changed", "commands_run", "commits", "green_evidence", "review_findings", "expected_visual_states", "screenshots", "semantic_artifacts", "expected_performance_cases", "performance_artifacts", "performance", "known_red_observed", "unexpected_failures", "risks", "gaps_or_skips"]) requireArray(report, field);
  if (report.role === "lead") { if (!report.red_witness || !report.tooth_proof) throw new Error("lead report requires red_witness and tooth_proof"); }
  else if (report.commits.length || report.red_witness !== null || report.tooth_proof !== null || report.owned_files_changed.length) throw new Error(`${report.role} report must have null lead-only fields and no owned changes`);
  if (!deep) return;
  for (const [index, item] of report.commands_run.entries()) verifyFile(root, item.log, `commands_run[${index}].log`);
  for (const [index, item] of report.green_evidence.entries()) verifyFile(root, item.log, `green_evidence[${index}].log`);
  if (report.red_witness) verifyFile(root, report.red_witness.log, "red_witness.log");
  if (report.tooth_proof) { verifyFile(root, report.tooth_proof.red_log, "tooth_proof.red_log"); verifyFile(root, report.tooth_proof.restored_green_log, "tooth_proof.restored_green_log"); }
  for (const [index, item] of report.semantic_artifacts.entries()) verifyFile(root, item, `semantic_artifacts[${index}]`);
  validateVisuals(report, root); validatePerformance(report, root);
}
function validateVisuals(report, root) {
  const expected = new Set();
  for (const state of report.expected_visual_states) { if (!state.visual_state_id || !Array.isArray(state.appearances) || !state.appearances.length || !state.semantic_assertion) throw new Error("expected visual state schema is invalid"); for (const appearance of state.appearances) expected.add(`${state.visual_state_id}\0${appearance}`); }
  const covered = new Set();
  for (const [index, image] of report.screenshots.entries()) {
    const label = `screenshots[${index}]`;
    if (image.failure_reason === "capture_unavailable") { if (report.status !== "DISPLAY_DEFERRED" || image.role !== "failure") throw new Error(`${label} capture_unavailable requires DISPLAY_DEFERRED failure`); verifyFile(root, image.semantic_artifact, `${label}.semantic_artifact`); verifyFile(root, image.command_log, `${label}.command_log`); continue; }
    if (image.role === "failure") { if (!image.failure_reason || !image.path) throw new Error(`${label} aborted visual failure requires an image and reason`); }
    const artifact = verifyFile(root, image.path, `${label}.path`, image.sha256, true);
    verifyFile(root, image.semantic_artifact, `${label}.semantic_artifact`); verifyFile(root, image.command_log, `${label}.command_log`);
    if (image.primary !== false && (!image.path || !artifact.sha256)) throw new Error(`${label} primary representative is incomplete`);
    if (image.actual_path) verifyFile(root, image.actual_path, `${label}.actual_path`, image.actual_sha, true);
    if (image.role === "actual") covered.add(`${image.visual_state_id}\0${image.appearance}`);
    if (image.role === "contact_sheet") for (const member of image.contact_sheet_members || []) covered.add(`${member.visual_state_id}\0${member.appearance}`);
    if (["nonzero", "failed"].includes(image.diff_status)) { if (!image.diff_path) throw new Error(`${label} nonzero/failing diff requires diff_path`); verifyFile(root, image.diff_path, `${label}.diff_path`, image.diff_sha, true); }
    if (image.role === "baseline" || image.diff_status === "zero") { if (!image.baseline_path || !image.baseline_sha || !image.baseline_commit) throw new Error(`${label} approved baseline provenance is incomplete`); verifyFile(root, image.baseline_path, `${label}.baseline_path`, image.baseline_sha, true); if (!SHA40.test(image.baseline_commit)) throw new Error(`${label}.baseline_commit is invalid`); }
    if (!image.baseline_path && image.diff_status !== "candidate_only" && image.role !== "failure") throw new Error(`${label} absent baseline must be candidate_only`);
    if (image.diff_status === "candidate_only" && image.inspection !== "NEEDS_JUDGMENT") throw new Error(`${label} candidate_only requires NEEDS_JUDGMENT`);
    if (image.mask_path || image.mask_sha || image.mask_rationale) { if (!image.mask_path || !image.mask_sha || !image.mask_rationale) throw new Error(`${label} mask provenance is incomplete`); verifyFile(root, image.mask_path, `${label}.mask_path`, image.mask_sha, true); if (!image.semantic_artifact) throw new Error(`${label} masked comparison lacks blocking semantics`); }
  }
  for (const key of expected) if (!covered.has(key) && report.status !== "DISPLAY_DEFERRED") throw new Error(`missing actual/contact-sheet visual state ${key.replace("\0", "/")}`);
}
function validatePerformance(report, root) {
  const expectedCases = new Map();
  for (const item of report.expected_performance_cases) { if (!item.case_id || !Number.isInteger(item.repetitions) || item.repetitions < 1 || !Array.isArray(item.required_roles) || !item.required_roles.length || !item.configuration || item.seed === undefined) throw new Error("expected performance case schema is invalid"); if (expectedCases.has(item.case_id)) throw new Error(`duplicate performance case ${item.case_id}`); expectedCases.set(item.case_id, item); }
  const seen = new Set(); const binaries = new Map();
  for (const [index, item] of report.performance_artifacts.entries()) {
    const label = `performance_artifacts[${index}]`; const expected = expectedCases.get(item.case_id); if (!expected) throw new Error(`${label} belongs to unexpected case`);
    if (!PERF_ROLES.has(item.role) || !Number.isInteger(item.iteration) || item.iteration < 1 || item.iteration > expected.repetitions) throw new Error(`${label} role/iteration is invalid`);
    if (!expected.required_roles.includes(item.role)) throw new Error(`${label} has extra role ${item.role}`);
    const key = `${item.case_id}\0${item.iteration}\0${item.role}`; if (seen.has(key)) throw new Error(`${label} duplicates case/iteration/role`); seen.add(key);
    verifyFile(root, item.path, `${label}.path`, item.sha256); if (!SHA256.test(item.binary_sha256 || "") || item.configuration !== expected.configuration || String(item.seed) !== String(expected.seed)) throw new Error(`${label} binary/configuration/seed mismatch`);
    const prior = binaries.get(item.case_id); if (prior && prior !== item.binary_sha256) throw new Error(`${label} binary mismatch within case`); binaries.set(item.case_id, item.binary_sha256);
    if (["soak_summary"].includes(item.role)) { const summaryPath = verifyFile(root, item.derived_summary || item.path, `${label}.derived_summary`).path; const summary = readJSON(summaryPath, `${label} summary`); if (!Array.isArray(summary.raw_inputs) || !Number.isInteger(summary.sample_count)) throw new Error(`${label} summary must name raw_inputs and sample_count`); for (const raw of summary.raw_inputs) verifyFile(root, raw, `${label}.raw_input`); if (summary.sample_count !== summary.raw_inputs.length) throw new Error(`${label} summary sample count disagrees with raw inputs`); }
  }
  for (const expected of expectedCases.values()) for (let iteration = 1; iteration <= expected.repetitions; iteration += 1) for (const role of expected.required_roles) if (!seen.has(`${expected.case_id}\0${iteration}\0${role}`)) throw new Error(`missing performance artifact ${expected.case_id}/${iteration}/${role}`);
}
function validate(options) {
  requireOptions(options, ["root"]); const root = rootInfo(options.root); const loaded = loadManifest(root); const errors = [];
  for (const entry of loaded.manifest.reports) { try { const file = verifyFile(root, entry.path, "ingested report", entry.sha256).path; const report = readJSON(file, "ingested report"); if (report.workstream !== entry.workstream || report.role !== entry.role || report.candidate_sha !== entry.candidate_sha) throw new Error("ingested report identity changed"); validateReportShape(report, root, true); } catch (error) { errors.push(error.message); } }
  for (const entry of loaded.manifest.capture_manifests) { try { verifyFile(root, entry.path, "capture manifest", entry.sha256); readJSON(entry.path, "capture manifest"); } catch (error) { errors.push(error.message); } }
  for (const entry of loaded.manifest.canonical_artifacts) { try { verifyFile(root, entry.path, "canonical artifact", entry.sha256); } catch (error) { errors.push(error.message); } }
  if (loaded.manifest.canonical_artifacts.filter(item => item.canonical).length > 1) errors.push("more than one artifact is marked canonical");
  if (errors.length) throw new Error(errors.join("\n")); loaded.manifest.validated_at = new Date().toISOString(); atomicJSON(loaded.file, loaded.manifest, "manifest"); console.log(`validated ${loaded.manifest.reports.length} report(s), ${loaded.manifest.capture_manifests.length} capture manifest(s), ${loaded.manifest.canonical_artifacts.length} canonical artifact(s)`);
}
function summary(options) {
  requireOptions(options, ["root", "output"]); const root = rootInfo(options.root); validate({ root: root.root }); const loaded = loadManifest(root); const output = contained(root, options.output, "--output", false);
  const reports = loaded.manifest.reports.map(item => readJSON(item.path)); const counts = {}; for (const report of reports) counts[report.status] = (counts[report.status] || 0) + 1;
  atomicWrite(output, `# Release evidence summary\n\nRun: ${loaded.manifest.run_id}\n\nBase: ${loaded.manifest.base_sha}\n\nReports: ${reports.length}\n\n${Object.entries(counts).sort().map(([key, count]) => `- ${key}: ${count}`).join("\n")}\n`, "summary");
}
function exec(command, args, allowFailure = false) { const result = spawnSync(command, args, { encoding: "utf8" }); const output = `${result.stdout || ""}${result.stderr || ""}`.trim(); if (result.error || (!allowFailure && result.status !== 0)) throw new Error(`${command} ${args.join(" ")} failed: ${result.error?.message || output}`); return { command: [command, ...args], exit_code: result.status ?? 1, output }; }
function systemTool(name, fallback) { return process.env.RELEASE_EVIDENCE_SYSTEM_TOOLS ? path.join(process.env.RELEASE_EVIDENCE_SYSTEM_TOOLS, name) : fallback; }
function plistValue(plist, key) { return exec("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]).output; }
function treeInventory(bundle) {
  const inventory = [];
  function walk(directory, relative = "") { for (const name of fs.readdirSync(directory).sort()) { const full = path.join(directory, name), rel = path.posix.join(relative, name), stat = fs.lstatSync(full); const mode = stat.mode & 0o7777; if (stat.isSymbolicLink()) inventory.push({ path: rel, type: "symlink", mode, target: fs.readlinkSync(full) }); else if (stat.isDirectory()) { inventory.push({ path: rel, type: "directory", mode }); walk(full, rel); } else if (stat.isFile()) inventory.push({ path: rel, type: "file", mode, size: stat.size, sha256: sha256File(full) }); else throw new Error(`unsupported bundle entry: ${full}`); } }
  walk(bundle); return { entries: inventory, sha256: sha256Text(`${JSON.stringify(inventory)}\n`) };
}
function parseNotary(log, kind) {
  const section = log.split(new RegExp(`==> notarize ${kind}`, "i"))[1] || ""; const beforeNext = section.split(/==> /)[0]; const id = beforeNext.match(/(?:id|submission id):\s*([0-9a-f-]{20,})/i)?.[1] || null; const status = beforeNext.match(/status:\s*(\w+)/i)?.[1] || null; return { submission_id: id, status };
}
function signing(bundle) {
  const codesign = systemTool("codesign", "/usr/bin/codesign"); const details = exec(codesign, ["-d", "--verbose=4", bundle], true); const requirement = exec(codesign, ["-d", "-r-", bundle], true); const verify = exec(codesign, ["--verify", "--deep", "--strict", "--verbose=2", bundle], true); return { team_id: details.output.match(/TeamIdentifier=(.+)/)?.[1] || null, identity: details.output.match(/Authority=(.+)/)?.[1] || null, designated_requirement: requirement.output.match(/designated => (.+)/)?.[1] || null, details, verification: verify };
}
function bundleIdentity(app) {
  const plist = path.join(app, "Contents", "Info.plist"); if (!fs.existsSync(plist)) throw new Error(`missing Info.plist: ${plist}`); const executableName = plistValue(plist, "CFBundleExecutable"); const executable = path.join(app, "Contents", "MacOS", executableName); const identifier = plistValue(plist, "CFBundleIdentifier"), version = plistValue(plist, "CFBundleShortVersionString"), build = plistValue(plist, "CFBundleVersion");
  return { path: app, bundle_id: identifier, channel: identifier === "dev.arrayapp.macos" ? "prod" : "dev", version, build, executable: { path: executable, sha256: sha256File(executable) }, tree: treeInventory(app), signing: signing(app) };
}
function shaSumsPath(dmg) { return path.join(path.dirname(dmg), "SHA256SUMS"); }
function verifySums(dmg, expectedHash) { const sums = shaSumsPath(dmg); if (!fs.existsSync(sums)) throw new Error(`missing SHA256SUMS: ${sums}`); const line = fs.readFileSync(sums, "utf8"); const expected = `${expectedHash}  ${path.basename(dmg)}\n`; if (line !== expected || sha256File(dmg) !== expectedHash) throw new Error("SHA256SUMS does not match the manifest and DMG bytes"); return { path: sums, sha256: sha256File(sums) }; }
function artifactCreate(options) {
  requireOptions(options, ["root", "candidate-sha", "release-argv", "release-log", "app", "dmg", "output"]); if (!SHA40.test(options["candidate-sha"])) throw new Error("--candidate-sha is invalid"); const root = rootInfo(options.root); const loaded = loadManifest(root); if (options["candidate-sha"] !== loaded.manifest.base_sha && loaded.manifest.i3_sha && options["candidate-sha"] !== loaded.manifest.i3_sha) throw new Error("candidate SHA does not match I3");
  const output = contained(root, options.output, "--output", false), argv = verifyFile(root, options["release-argv"], "release argv"), log = verifyFile(root, options["release-log"], "release log"), app = contained(root, options.app, "app"), dmg = verifyFile(root, options.dmg, "DMG"); const identity = bundleIdentity(app); if (identity.version !== "0.8.0" || identity.build !== "56" || identity.bundle_id !== "dev.arrayapp.macos") throw new Error("canonical bundle must be dev.arrayapp.macos 0.8.0/56");
  const gitHead = exec("/usr/bin/git", ["-C", process.cwd(), "rev-parse", "HEAD"]).output; const gitStatus = exec("/usr/bin/git", ["-C", process.cwd(), "status", "--porcelain"]).output; if (gitHead !== options["candidate-sha"] || gitStatus) throw new Error("candidate checkout SHA/status does not match clean canonical source");
  const logText = fs.readFileSync(log.path, "utf8"), appNotary = parseNotary(logText, "app"), dmgNotary = parseNotary(logText, "DMG"); if (appNotary.status !== "Accepted" || dmgNotary.status !== "Accepted" || !appNotary.submission_id || !dmgNotary.submission_id) throw new Error("release log lacks fresh accepted app and DMG notary submissions");
  const sums = shaSumsPath(dmg.path); atomicWrite(sums, `${dmg.sha256}  ${path.basename(dmg.path)}\n`, "checksum");
  const xcrun = systemTool("xcrun", "/usr/bin/xcrun"), spctl = systemTool("spctl", "/usr/sbin/spctl");
  const artifact = { schema_version: 1, canonical: true, created_at: new Date().toISOString(), candidate_sha: options["candidate-sha"], clean_status: true, release_script: { path: path.resolve(__dirname, "release-app.sh"), sha256: sha256File(path.resolve(__dirname, "release-app.sh")) }, release_argv: argv, release_log: log, app: identity, app_notary: appNotary, app_staple: exec(xcrun, ["stapler", "validate", app], true), app_gatekeeper: exec(spctl, ["-a", "-vv", app], true), dmg: { ...dmg, signing: signing(dmg.path) }, dmg_notary: dmgNotary, dmg_staple: exec(xcrun, ["stapler", "validate", dmg.path], true), dmg_gatekeeper: exec(spctl, ["-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg.path], true), sha256sums: { path: sums, sha256: sha256File(sums) } };
  for (const [label, result] of [["app signature", artifact.app.signing.verification], ["DMG signature", artifact.dmg.signing.verification], ["app staple", artifact.app_staple], ["DMG staple", artifact.dmg_staple], ["app Gatekeeper", artifact.app_gatekeeper], ["DMG Gatekeeper", artifact.dmg_gatekeeper]]) if (result.exit_code !== 0) throw new Error(`${label} verification failed`);
  atomicJSON(output, artifact, "artifact"); const entry = { path: output, sha256: sha256File(output), candidate_sha: artifact.candidate_sha, canonical: true }; if (loaded.manifest.canonical_artifacts.some(item => item.canonical && item.path !== output)) throw new Error("a canonical artifact already exists"); loaded.manifest.canonical_artifacts = loaded.manifest.canonical_artifacts.filter(item => item.path !== output); loaded.manifest.canonical_artifacts.push(entry); atomicJSON(loaded.file, loaded.manifest, "manifest"); console.log(output);
}
function compare(label, expected, actual) { if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error(`${label} mismatch`); }
function artifactVerify(options) {
  requireOptions(options, ["manifest", "candidate-sha", "dmg", "mounted-app", "output"]); const manifestPath = absolute(options.manifest, "--manifest"), artifact = readJSON(manifestPath, "canonical artifact"); if (!artifact.canonical || artifact.candidate_sha !== options["candidate-sha"] || !SHA40.test(options["candidate-sha"])) throw new Error("candidate/canonical identity mismatch"); if (artifact.app.version !== "0.8.0" || artifact.app.build !== "56") throw new Error("canonical artifact is not 0.8.0/56");
  const dmg = absolute(options.dmg, "--dmg"); compare("DMG SHA-256", artifact.dmg.sha256, sha256File(dmg)); verifySums(dmg, artifact.dmg.sha256); const mounted = bundleIdentity(absolute(options["mounted-app"], "--mounted-app")); compare("mounted bundle ID", artifact.app.bundle_id, mounted.bundle_id); compare("mounted version", artifact.app.version, mounted.version); compare("mounted build", artifact.app.build, mounted.build); compare("mounted executable", artifact.app.executable.sha256, mounted.executable.sha256); compare("mounted bundle tree", artifact.app.tree.sha256, mounted.tree.sha256); compare("mounted designated requirement", artifact.app.signing.designated_requirement, mounted.signing.designated_requirement); compare("mounted Team ID", artifact.app.signing.team_id, mounted.signing.team_id);
  if (artifact.app_notary.status !== "Accepted" || artifact.dmg_notary.status !== "Accepted" || !artifact.app_notary.submission_id || !artifact.dmg_notary.submission_id) throw new Error("stale/incomplete notary identity"); const xcrun = systemTool("xcrun", "/usr/bin/xcrun"), spctl = systemTool("spctl", "/usr/sbin/spctl"); for (const [label, result] of [["mounted signature", mounted.signing.verification], ["mounted staple", exec(xcrun, ["stapler", "validate", mounted.path], true)], ["DMG staple", exec(xcrun, ["stapler", "validate", dmg], true)], ["mounted Gatekeeper", exec(spctl, ["-a", "-vv", mounted.path], true)], ["DMG Gatekeeper", exec(spctl, ["-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg], true)]]) if (result.exit_code !== 0) throw new Error(`${label} verification failed`); const output = absolute(options.output, "--output"); atomicJSON(output, { status: "PASS", verified_at: new Date().toISOString(), canonical_manifest: manifestPath, candidate_sha: artifact.candidate_sha, dmg_sha256: artifact.dmg.sha256, mounted_app: mounted }, "artifact-verify"); console.log(output);
}

function main() {
  if (process.argv.length < 3) die("expected command", 2); const command = process.argv[2]; let options;
  try { options = argumentsFor(process.argv.slice(3)); ({ init, ingest, validate, summary, "artifact-create": artifactCreate, "artifact-verify": artifactVerify }[command] || (() => { throw new Error(`unknown command: ${command}`); }))(options); }
  catch (error) { die(error.message, 1); }
}
main();
