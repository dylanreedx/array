#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const REQUIRED_HEADINGS = ["TL;DR", "What is broken", "Why", "Fix", "Proof", "Gotchas"];
const CITATION_RE = /(?:[\w./-]+:\d+|memory\/[\w./-]+|test\/qa-round-5\/atlas\/[\w./-]+\.png|test\/[\w./-]+)/;

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function sections(markdown) {
  const matches = [...markdown.matchAll(/^## (.+)$/gm)];
  const result = new Map();
  for (let index = 0; index < matches.length; index += 1) {
    const heading = matches[index][1].trim();
    const start = matches[index].index + matches[index][0].length;
    const end = index + 1 < matches.length ? matches[index + 1].index : markdown.length;
    result.set(heading, markdown.slice(start, end).trim());
  }
  return { matches, result };
}

function claimLines(section) {
  return section
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .filter((line) => /[.!?]$/.test(line))
    .filter((line) => !/^- [A-Za-z][A-Za-z ]*:/.test(line));
}

function verify(ticketId) {
  const recordPath = path.join("test", "qa-round-5", "records", `${ticketId}.md`);
  if (!fs.existsSync(recordPath)) {
    fail(`Missing record: ${recordPath}`);
    return;
  }

  const markdown = fs.readFileSync(recordPath, "utf8");
  const { matches, result } = sections(markdown);
  const headings = matches.map((match) => match[1].trim());
  if (headings.length !== REQUIRED_HEADINGS.length || !REQUIRED_HEADINGS.every((heading, index) => headings[index] === heading)) {
    fail(`Record headings must be exactly: ${REQUIRED_HEADINGS.join(" | ")}`);
  }

  for (const heading of REQUIRED_HEADINGS) {
    if (!result.get(heading)) {
      fail(`Missing section body: ${heading}`);
    }
  }

  const tldr = result.get("TL;DR") || "";
  if (!/^Verdict: (pass|concerns|still-broken)$/m.test(tldr)) {
    fail("TL;DR must include Verdict: pass | concerns | still-broken");
  }
  if (!/(RED|GREEN|J=|review\.md|review\.json)/.test(tldr)) {
    fail("TL;DR must cite a gate: RED, GREEN, J=, review.md, or review.json");
  }

  for (const heading of ["What is broken", "Why", "Fix", "Gotchas"]) {
    for (const line of claimLines(result.get(heading) || "")) {
      if (!CITATION_RE.test(line)) {
        fail(`Claim line in "${heading}" lacks citation: ${line}`);
      }
    }
  }

  const proof = result.get("Proof") || "";
  if (!/RED/.test(proof)) fail("Proof must cite RED gate.");
  if (!/GREEN/.test(proof)) fail("Proof must cite GREEN gate.");
  if (!/(review\.md|review\.json|J=)/.test(proof)) fail("Proof must cite review.md, review.json, J=, or visual review N/A note.");
  const fixtures = new Set(proof.match(/test\/qa-round-5\/fixtures\/fixture-[\w-]+/g) || []);
  if (fixtures.size < 2) fail("Proof must cite at least two distinct fixture-* paths.");
  if (!/test\/qa-round-5\/atlas\/[\w./-]+\.png/.test(proof)) fail("Proof must cite at least one atlas PNG path.");
  if (!/Visual sanity.*full-page\.png.*(?:bands\/\d+\.png|compare\/\d+\.png|annotated\.png|contact-sheet\.png)/s.test(proof)) {
    fail("Proof must include a Visual sanity line with full-page.png plus a band, compare, annotated, or contact-sheet PNG.");
  }
  if (!/font|readable text/i.test(proof) || !/clipping/i.test(proof) || !/overlap/i.test(proof)) {
    fail("Proof must name font/readable text, clipping, and overlap.");
  }
}

const [command, ticketId] = process.argv.slice(2);
if (command !== "--verify" || !ticketId) {
  console.error("Usage: node scripts/qa-atlas.js --verify <ticket-id>");
  process.exit(2);
}

verify(ticketId);
