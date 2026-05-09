#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const requiredExecutables = [
  "qa/setup.sh",
  "qa/flows/cmdk-spam.sh",
  "qa/flows/drag-past-edge.sh",
  "qa/flows/window-resize-stress.sh",
  "qa/flows/quit-during-load.sh"
];

const markerChecks = new Map([
  ["qa/setup.sh", ["brew install cliclick", "osascript", "screencapture", "Accessibility"]],
  ["qa/README.md", ["qa-runs/<flow>-<timestamp>", "manifest.json", "qa/flows/lib.sh"]],
  ["qa/flows/lib.sh", ["begin_flow", "capture_step", "write_manifest", "launch_continuum"]],
  ["qa/flows/cmdk-spam.sh", ["CONTINUUM_QA_FLOW=palette-open-close", "cliclick", "capture_step"]],
  ["qa/flows/drag-past-edge.sh", ["CONTINUUM_QA_FLOW=canvas-drag-resize", "cliclick", "drag"]],
  ["qa/flows/window-resize-stress.sh", ["set bounds", "320", "1920", "capture_step"]],
  ["qa/flows/quit-during-load.sh", ["CONTINUUM_QA_FLOW=cmd-3-browser", "DiagnosticReports", "quit"]]
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

const gitignore = readRelative(".gitignore");
if (!/(^|\n)qa-runs\/(\n|$)/.test(gitignore)) {
  fail(".gitignore must ignore qa-runs/");
}

if (!process.exitCode) {
  console.log("QA external flow checks passed");
}
