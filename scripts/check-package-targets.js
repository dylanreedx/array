#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const sourcesRoot = path.join(root, "Sources");
const packagePath = path.join(root, "Package.swift");

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function read(pathname) {
  if (!fs.existsSync(pathname)) {
    fail(`Missing ${path.relative(root, pathname)}`);
    return "";
  }
  return fs.readFileSync(pathname, "utf8");
}

const packageSource = read(packagePath);
const registeredTargets = new Set();
const executableTargetPattern = /\.executableTarget\s*\(\s*name:\s*"([^"]+)"/g;
for (const match of packageSource.matchAll(executableTargetPattern)) {
  registeredTargets.add(match[1]);
}

const checkDirectories = fs.readdirSync(sourcesRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .filter((name) => name.endsWith("Checks"))
  .sort();

for (const targetName of checkDirectories) {
  const mainPath = path.join(sourcesRoot, targetName, "main.swift");
  if (!fs.existsSync(mainPath)) {
    fail(`Sources/${targetName} is missing main.swift`);
  }
  if (!registeredTargets.has(targetName)) {
    fail(`Sources/${targetName}/main.swift is not registered as an executableTarget`);
  }
}

for (const targetName of registeredTargets) {
  if (!targetName.endsWith("Checks")) {
    continue;
  }
  const mainPath = path.join(sourcesRoot, targetName, "main.swift");
  if (!fs.existsSync(mainPath)) {
    fail(`Package.swift registers ${targetName}, but Sources/${targetName}/main.swift is missing`);
  }
}

if (!process.exitCode) {
  console.log("Package executable check targets passed");
}
