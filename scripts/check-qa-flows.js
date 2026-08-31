#!/usr/bin/env node

const fs = require("fs");
const { execFileSync, spawnSync } = require("child_process");
const os = require("os");
const path = require("path");

const root = path.resolve(__dirname, "..");
const requiredExecutables = [
  "qa/setup.sh",
  "qa/file-finding.sh",
  "qa/flows/cmdk-spam.sh",
  "qa/flows/drag-past-edge.sh",
  "qa/flows/window-resize-stress.sh",
  "qa/flows/quit-during-load.sh"
  ,"qa/flows/release-preflight.sh"
  ,"qa/tests/wave0-gui-adversarial.sh"
];

const markerChecks = new Map([
  ["qa/setup.sh", ["brew install cliclick", "osascript", "screencapture", "Accessibility"]],
  ["qa/README.md", ["qa-runs/<flow>-<timestamp>", "manifest.json", "qa/flows/lib.sh", "qa/reviewer-prompt.md", "qa/file-finding.sh", "assert_flow"]],
  ["qa/reviewer-prompt.md", ["manifest.json", "docs/05-canvas-and-ux.md", "qa/expectations/<flow>.md", "qa/file-finding.sh", "verified-working"]],
  ["qa/file-finding.sh", ["--severity", "--summary", "--expected", "--observed", "--screenshot", "--flow", "--step", "fingerprint", "[qa-finding]"]],
  ["qa/expectations/cmdk-spam.md", ["cmdk-spam", "initial", "cmdk-spam-final", "verified-working"]],
  ["qa/expectations/drag-past-edge.md", ["drag-past-edge", "before-drag", "after-drag-past-edge", "verified-working"]],
  ["qa/expectations/window-resize-stress.md", ["window-resize-stress", "before-resize", "window-width-320", "window-width-1920", "verified-working"]],
  ["qa/expectations/quit-during-load.md", ["quit-during-load", "before-quit", "diagnosticreports-clean", "verified-working"]],
  ["qa/expectations/release-preflight.md", ["release-preflight", "CGWindowID", "WKWebView", "DISPLAY_DEFERRED", "verified-working"]],
  ["qa/flows/lib.sh", ["begin_flow", "capture_step", "assert_flow", "QA_ASSERTIONS", "write_manifest", "launch_continuum"]],
  ["qa/flows/release-preflight.sh", ["release-preflight", "DISPLAY_DEFERRED", "wait_for_named_readiness", "capture_app_window", "assert_window_owned_by_pid", "CONTINUUM_QA_RUN_DIR", "caffeinate"]],
  ["qa/flows/cmdk-spam.sh", ["CONTINUUM_QA_FLOW=palette-open-close", "cliclick", "capture_step", "assert_flow"]],
  ["qa/flows/drag-past-edge.sh", ["CONTINUUM_QA_FLOW=canvas-drag-resize", "cliclick", "drag", "assert_flow"]],
  ["qa/flows/window-resize-stress.sh", ["set bounds", "320", "1920", "capture_step", "assert_flow"]],
  ["qa/flows/quit-during-load.sh", ["CONTINUUM_QA_FLOW=cmd-3-browser", "DiagnosticReports", "quit", "assert_flow"]],
  ["Sources/ContinuumRevived/App/ContinuumApp.swift", ["palette.onClose", "QAPerf.residentMemoryBytes()", "palette-leak-cycle"]],
  ["Sources/ContinuumRevived/App/ContinuumApp.swift", ["CONTINUUM_QA_HOLD_OPEN", "== \"1\"", "ARRAY_QA_RULER_V1", "fixture=ARRAY_QA_RULER_V1"]],
  ["Sources/ContinuumRevived/App/LaunchProfilePalette.swift", ["let search = NSSearchField()", "func close()", "searchField?.delegate = nil", "tableView?.dataSource = nil", "paletteView?.removeFromSuperview()"]]
]);

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function readRelative(relativePath) {
  const absolutePath = path.join(root, relativePath);
  if (!fs.existsSync(absolutePath)) {
    fail(`Missing ${relativePath}`);
    return "";
  }
  return fs.readFileSync(absolutePath, "utf8");
}

for (const relativePath of requiredExecutables) {
  const absolutePath = path.join(root, relativePath);
  if (!fs.existsSync(absolutePath)) {
    fail(`Missing executable ${relativePath}`);
    continue;
  }
  const mode = fs.statSync(absolutePath).mode;
  if ((mode & 0o111) === 0) {
    fail(`${relativePath} is not executable`);
  }
}

for (const [relativePath, markers] of markerChecks.entries()) {
  const content = readRelative(relativePath);
  for (const marker of markers) {
    if (!content.includes(marker)) {
      fail(`${relativePath} is missing marker: ${marker}`);
    }
  }
}

const appSource = readRelative("Sources/ContinuumRevived/App/ContinuumApp.swift");
if (appSource.includes("palette-leak-warmup")) {
  fail("Sources/ContinuumRevived/App/ContinuumApp.swift must not warm the palette before leak sampling");
}

const gitignore = readRelative(".gitignore");
if (!/(^|\n)qa-runs\/(\n|$)/.test(gitignore)) {
  fail(".gitignore must ignore qa-runs/");
}

function runFindingWrapperChecks() {
  const sourceDb = path.join(root, ".conductor", "conductor.db");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "continuum-qa-finding-"));
  const tempDb = path.join(tempDir, "conductor.db");
  if (fs.existsSync(sourceDb)) {
    fs.copyFileSync(sourceDb, tempDb);
  } else {
    execFileSync("sqlite3", [
      tempDb,
      `
      create table projects (
        id text primary key,
        name text not null unique,
        project_type text not null,
        workspace_path text,
        depends_on text,
        ready_threshold integer not null default 30,
        created_at integer default (unixepoch())
      );
      create table tasks (
        id text primary key,
        project_id text references projects(id),
        category text not null,
        phase integer not null,
        description text not null,
        steps text,
        depends_on text,
        status text not null default 'pending',
        priority integer not null default 0,
        attempt_count integer not null default 0,
        last_error text,
        updated_at integer default (unixepoch()),
        session_id text,
        commit_hash text,
        archive_reason text,
        current_phase text
      );
      insert into projects (id, name, project_type) values ('test-project', 'continuum-revived', 'swift');
      `
    ], { cwd: root });
  }

  const commonArgs = [
    "--db", tempDb,
    "--severity", "major",
    "--summary", "Temporary planted visual issue",
    "--expected", "Palette remains readable.",
    "--observed", "Palette text overlaps in the planted check.",
    "--screenshot", "qa-runs/example/full-page.png",
    "--flow", "cmdk-spam",
    "--step", "cmdk-spam-final"
  ];

  function expectFailure(args, expectedStderr, label) {
    const result = spawnSync(path.join(root, "qa", "file-finding.sh"), args, {
      cwd: root,
      encoding: "utf8"
    });
    if (result.status === 0 || !result.stderr.includes(expectedStderr)) {
      fail(`qa/file-finding.sh should reject ${label}`);
    }
  }

  try {
    const first = execFileSync(path.join(root, "qa", "file-finding.sh"), commonArgs, {
      cwd: root,
      encoding: "utf8"
    });
    if (!first.includes("filed qa finding:") || !first.includes("fingerprint:")) {
      fail("qa/file-finding.sh did not file the planted finding with a fingerprint");
    }

    const second = execFileSync(path.join(root, "qa", "file-finding.sh"), commonArgs, {
      cwd: root,
      encoding: "utf8"
    });
    if (!second.includes("skipped duplicate qa finding:") || !second.includes("fingerprint:")) {
      fail("qa/file-finding.sh did not skip the duplicate planted finding");
    }

    const count = execFileSync("sqlite3", [
      tempDb,
      "select count(*) from tasks where description like '%Temporary planted visual issue%';"
    ], {
      cwd: root,
      encoding: "utf8"
    }).trim();
    if (count !== "1") {
      fail(`qa/file-finding.sh should insert one planted finding, saw ${count}`);
    }

    expectFailure([
      "--db", tempDb,
      "--severity", "invalid",
      "--summary", "Invalid severity planted issue",
      "--expected", "Rejected severity.",
      "--observed", "Rejected severity.",
      "--screenshot", "qa-runs/example/full-page.png",
      "--flow", "cmdk-spam",
      "--step", "cmdk-spam-final"
    ], "Invalid severity: invalid", "invalid severity values");

    expectFailure([
      "--db", tempDb,
      "--severity", "major",
      "--expected", "Missing summary rejected.",
      "--observed", "Missing summary rejected.",
      "--screenshot", "qa-runs/example/full-page.png",
      "--flow", "cmdk-spam",
      "--step", "cmdk-spam-final"
    ], "Missing required value: summary", "missing required values");

    expectFailure([
      "--db", tempDb,
      "--severity", "--summary"
    ], "Missing value for --severity", "missing option values");

    expectFailure([
      "--db", path.join(tempDir, "missing.db"),
      "--severity", "major",
      "--summary", "Missing database planted issue",
      "--expected", "Existing database.",
      "--observed", "Missing database.",
      "--screenshot", "qa-runs/example/full-page.png",
      "--flow", "cmdk-spam",
      "--step", "cmdk-spam-final"
    ], "Conductor database not found:", "missing databases");

    expectFailure([
      "--db", tempDb,
      "--severity", "major",
      "--summary", "Missing project planted issue",
      "--expected", "Existing project.",
      "--observed", "Missing project.",
      "--screenshot", "qa-runs/example/full-page.png",
      "--flow", "cmdk-spam",
      "--step", "cmdk-spam-final",
      "--project", "missing-project"
    ], "Project not found: missing-project", "missing projects");

    expectFailure(["--unknown"], "Unknown argument: --unknown", "unknown arguments");
  } catch (error) {
    fail(`qa/file-finding.sh verification failed: ${error.message}`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

runFindingWrapperChecks();

if (!process.exitCode) {
  console.log("QA external flow checks passed");
}
