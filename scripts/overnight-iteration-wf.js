export const meta = {
  name: 'overnight-iteration',
  description: 'Execute ONE Continuum ticket with a self-repair loop: implement with Sonnet, prove with swift build + the matrix, dual-review the diff (Claude review model + GPT-5.5 via Codex), and if either reviewer rejects, feed the concerns back for a fix pass and re-review — up to 3 rounds — before either committing (only when build+matrix green AND both reviewers clear) or skipping honestly. No push. No co-authoring footer.',
  phases: [
    { title: 'Implement', detail: 'edit Sources/, make swift build + matrix green' },
    { title: 'Dual review', detail: 'Claude review model + Codex gpt-5.5 review of the diff' },
    { title: 'Commit', detail: 'commit iff green and both reviewers clear' },
  ],
}

// Inputs arrive via the Workflow `args`. Be robust to args being passed as a
// JSON string (a known foot-gun) rather than an object.
let A = args || {}
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
const TICKET = A.ticketPath
const NAME = A.ticketName || TICKET || 'ticket'
const EFFORT = ['low','medium','high'].includes(A.effort) ? A.effort : 'medium'
const MAX_ROUNDS = 3
const CLAUDE_REVIEW_MODEL = (typeof process !== 'undefined' && process.env && process.env.CLAUDE_REVIEW_MODEL) ? process.env.CLAUDE_REVIEW_MODEL : 'opus'

const IMPL_RESULT = { type:'object', additionalProperties:false, required:['built','matrixGreen','changedFiles','summary'], properties:{
  built:{type:'boolean'}, matrixGreen:{type:'boolean'},
  changedFiles:{type:'array', items:{type:'string'}}, summary:{type:'string'}, notes:{type:'string'}
}}
const VERDICT = { type:'object', additionalProperties:false, required:['clear','concerns'], properties:{
  clear:{type:'boolean'}, concerns:{type:'array', items:{type:'string'}}, notes:{type:'string'}
}}
const COMMIT_RESULT = { type:'object', additionalProperties:false, required:['committed','reason'], properties:{
  committed:{type:'boolean'}, commitHash:{type:'string'}, reason:{type:'string'}
}}

const IMPL_PROMPT = [
  'Implement ONE Continuum ticket end to end. Native macOS/Swift app at /Users/dylan/Documents/personal/continuum-overnight (this worktree — work HERE, not any other checkout).',
  'READ THE TICKET FIRST and follow it exactly — its approach, seams, breadcrumbs, and "Done when" are authoritative; do not redesign or descope: ' + TICKET + '.',
  'Also skim docs/38-locked-decisions.md so you do not reopen a settled decision.',
  'If docs/38-tickets/_PROGRESS.md contains a prior skip-note for THIS ticket (a "Reset for the hardened retry" section or an earlier row), READ it first and proactively address every issue it lists — a previous attempt already found those bugs; do not rediscover them the hard way.',
  'DO THE WORK: edit files under Sources/ (and tests) per the ticket. Implement the FULL ticket — if it says migrate call sites, migrate ALL of them (a compatibility shim that leaves old call sites working is a FAILURE of a compile-enforced migration, not a convenience). Write the ticket\'s Logic/Backend/UX tests where automatable; a test that only compares IDs or uses a local fold helper instead of the real production merge/apply path does not count. VERIFICATION CONVENTION (mandatory): this project has NO XCTest and `run-matrix.sh` never runs `swift test` — all checks are Swift EXECUTABLE targets (`*Checks`, e.g. ContinuumRevivedCoreChecks) that print measured values and exit non-zero on failure. Add your checks to the relevant `*Checks` executable (or a new one) AND wire it into `scripts/run-matrix.sh` so the matrix actually runs them. Do NOT write XCTestCase / `import XCTest` / a `Tests/` target — nothing runs it, so it does not gate and will be rejected. Then PROVE it: (1) `swift build` until clean; (2) `./scripts/run-matrix.sh` and read the result honestly. The harness sets CONTINUUM_SKIP_SURFACE_CHECKS=1, so the matrix will print "SKIPPED (headless): ...surface checks" and still end with "Matrix passed" — that is EXPECTED and correct (those checks render a terminal surface unavailable in this sandbox; a supervised GUI pass covers them). Treat "Matrix passed" as green; do NOT try to force the skipped checks to run or weaken anything.',
  'GIT RULE: do NOT commit (a later stage owns the commit). The ONE exception: after creating any NEW source/test file, run `git add -N <file>` (intent-to-add only — this makes it appear in `git diff` for the reviewers and prevents it being mistaken for a droppable untracked file; it does NOT commit). Do not otherwise touch git. Do NOT edit files outside what the ticket requires. NO fake-green: if you cannot reach a clean build + green matrix with an honest, complete implementation, report built/matrixGreen=false with the real reason — never weaken a test or add a shim to pass.',
  'Return {built, matrixGreen, changedFiles, summary, notes}.'
].join('\n')

const FIX_PROMPT = (concerns, round) => [
  'You are fix round ' + round + ' for a Continuum ticket. A previous pass implemented it but reviewers REJECTED it. The implementation is in the working tree (uncommitted). Fix EVERY concern below in place; do not start over, do not revert good work.',
  'The ticket (authoritative contract): ' + TICKET + '. Re-read it. Also read the current uncommitted diff (`git --no-pager diff`, `git status`) to see what exists.',
  'CONCERNS TO RESOLVE (from Claude reviewer and/or GPT-5.5 — every one must be genuinely addressed, not papered over):',
  ...(concerns || []).map((c, i) => '  ' + (i + 1) + '. ' + c),
  'After fixing: `swift build` until clean, then `./scripts/run-matrix.sh`. Do NOT commit; `git add -N` any brand-new file so it shows in the diff, but otherwise do not touch git. NO fake-green — if a concern reveals the approach is wrong, fix it properly; if you genuinely cannot resolve one honestly, say so in notes rather than masking it.',
  'Return {built, matrixGreen, changedFiles, summary, notes} — summary should say how each concern was addressed.'
].join('\n')

const CLAUDE_REVIEW_PROMPT = [
  'Adversarially review the UNCOMMITTED diff implementing a Continuum ticket. Be strict — this ships unattended.',
  'Ticket (the contract the diff must satisfy): ' + TICKET + '. Read it, then read the working-tree diff (`git --no-pager diff`, `git status`; nothing is committed).',
  'Judge against the ticket\'s "Done when": does the diff actually and COMPLETELY deliver it? Watch specifically for: incomplete migrations (compat shims / unmigrated call sites that defeat a compile-enforced change), tests that are tautological or bypass the real production path, missing required test tiers, reopened settled decisions, real correctness bugs, scope creep, and any secret/transcript body crossing a sync boundary (I5). REJECT verification that does not actually gate: this repo has NO XCTest and the matrix does not run `swift test`, so any XCTestCase / `import XCTest` / new `Tests/` target is dead weight that never runs — checks MUST be in a `*Checks` executable target wired into `scripts/run-matrix.sh`. Also reject any diff that edits `scripts/run-matrix.sh` to weaken/skip a check (a fake-green attempt).',
  'Return {clear, concerns[], notes}: clear=true only if you would merge as-is. Every real problem is a concern, stated concretely enough to fix.'
].join('\n')

const CODEX_PROMPT = [
  'Get an INDEPENDENT second-model review of the current uncommitted diff via the Codex CLI (GPT-5.5), then relay its verdict.',
  'Run this from the repo root and capture stdout:',
  '  codex exec --json -m gpt-5.5 --sandbox read-only --skip-git-repo-check "Review the current uncommitted git diff (run: git --no-pager diff; git status) against the ticket at ' + TICKET + '. Check for incomplete migrations, correctness bugs, tautological/bypassing tests, missing required tests, scope creep, verification written as XCTest (this repo has no test targets and the matrix does not run swift test, so XCTest never gates — checks must be in a *Checks executable wired into run-matrix.sh), and any edit to scripts/run-matrix.sh that weakens a check. Return strict JSON {clear:boolean, concerns:string[]}; clear=true only if you would merge as-is."',
  'If codex errors, hangs, or cannot authenticate, treat that as NOT clear with a concern explaining the failure — never fabricate a pass.',
  'Return {clear, concerns[], notes} parsed from Codex\'s verdict; put its raw concerns in concerns[].'
].join('\n')

const COMMIT_PROMPT = [
  'All gates for a Continuum ticket are green (build + matrix + both reviewers clear). Commit the current uncommitted work.',
  '`git add -A` then `git commit` with a plain Conventional-Commits message `type(scope): summary` describing the ticket outcome. ABSOLUTELY NO co-authoring / "Generated with" / AI footer. Do NOT push.',
  'Return {committed:true, commitHash:<short hash>, reason:"all gates green"}. If for some reason git fails, return {committed:false, reason:<why>}.'
].join('\n')

if (!TICKET) {
  log('FATAL: no ticketPath in args (threading failed) — cannot run')
  return { ticket: NAME, committed:false, built:false, matrixGreen:false, claudeReviewClear:false, codexClear:false, rounds:0, reason:'no ticketPath in args', outstandingConcerns:['Workflow args did not thread a ticketPath'] }
}

log('iteration for ' + NAME + ' (effort=' + EFFORT + ', up to ' + MAX_ROUNDS + ' repair rounds)')

let committed = false, hash = null, reason = '', rounds = 0
let claudeReview = { clear:false, concerns:[] }, codex = { clear:false, concerns:[] }
let concerns = []

for (let round = 1; round <= MAX_ROUNDS && !committed; round++) {
  rounds = round
  // Round 1 implements at the ticket's effort; repair rounds escalate to high
  // (subtle review concerns need more reasoning than the first pass).
  phase('Implement')
  const implEffort = round === 1 ? EFFORT : 'high'
  const implPrompt = round === 1 ? IMPL_PROMPT : FIX_PROMPT(concerns, round)
  const label = round === 1 ? ('implement:' + NAME) : ('fix' + round + ':' + NAME)
  const impl = await agent(implPrompt, { label, phase:'Implement', model:'sonnet', effort: implEffort, schema: IMPL_RESULT })

  if (!impl || !impl.built || !impl.matrixGreen) {
    concerns = ['Build or matrix not green — ' + ((impl && impl.summary) || 'implementer returned no result') + ' | ' + ((impl && impl.notes) || '')]
    log('round ' + round + ': build/matrix not green, ' + (round < MAX_ROUNDS ? 'retrying' : 'giving up'))
    continue
  }

  phase('Dual review')
  const reviews = await parallel([
    () => agent(CLAUDE_REVIEW_PROMPT, { label:'review-claude-' + CLAUDE_REVIEW_MODEL + ':' + NAME, phase:'Dual review', model:CLAUDE_REVIEW_MODEL, effort:'high', schema: VERDICT }),
    () => agent(CODEX_PROMPT, { label:'review-codex-gpt5.5:' + NAME, phase:'Dual review', schema: VERDICT }),
  ])
  claudeReview = reviews[0] || { clear:false, concerns:['Claude review agent returned nothing'] }
  codex = reviews[1] || { clear:false, concerns:['Codex review agent returned nothing'] }

  if (claudeReview.clear && codex.clear) {
    phase('Commit')
    const c = await agent(COMMIT_PROMPT, { label:'commit:' + NAME, phase:'Commit', schema: COMMIT_RESULT })
    if (c && c.committed) {
      committed = true; hash = c.commitHash || null; reason = 'all gates green (round ' + round + ')'
    } else {
      concerns = ['Commit stage declined: ' + ((c && c.reason) || 'unknown')]
    }
  } else {
    concerns = [
      ...(claudeReview.clear ? [] : (claudeReview.concerns || []).map(x => 'Claude reviewer: ' + x)),
      ...(codex.clear ? [] : (codex.concerns || []).map(x => 'Codex: ' + x)),
    ]
    log('round ' + round + ': reviewers rejected (' + concerns.length + ' concerns), ' + (round < MAX_ROUNDS ? 'fixing' : 'out of rounds'))
  }
}

if (!committed && !reason) {
  reason = 'not cleared after ' + rounds + ' round(s); outstanding: ' + JSON.stringify(concerns).slice(0, 600)
}

return {
  ticket: NAME, committed, commitHash: hash, rounds, reason,
  claudeReviewClear: !!claudeReview.clear, codexClear: !!codex.clear,
  outstandingConcerns: committed ? [] : concerns,
}
