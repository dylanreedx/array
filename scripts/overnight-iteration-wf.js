export const meta = {
  name: 'overnight-iteration',
  description: 'Execute ONE Continuum implementation ticket: implement with Sonnet at the ticket-appropriate effort, prove it with swift build + the matrix, then dual-review the diff (Opus + GPT-5.5 via the Codex CLI) and commit only if the build is green, the matrix is green, and both reviewers clear. No push. No co-authoring footer.',
  phases: [
    { title: 'Implement', detail: 'edit Sources/, make swift build + matrix green' },
    { title: 'Dual review', detail: 'Opus review + Codex gpt-5.5 cross-review of the diff' },
    { title: 'Commit', detail: 'commit iff green and both reviewers clear' },
  ],
}

// args: { ticketPath, ticketName, effort ('low'|'medium'|'high'), branch }
const A = args || {}
const TICKET = A.ticketPath
const NAME = A.ticketName || (TICKET || 'ticket')
const EFFORT = (A.effort === 'low' || A.effort === 'medium' || A.effort === 'high') ? A.effort : 'low'

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
  'Implement ONE Continuum ticket end to end. This is a native macOS/Swift app at /Users/dylan/Documents/personal/continuum-overnight (a git worktree on branch overnight/agent-orchestration — work here, not in any other checkout).',
  'READ THE TICKET FIRST and follow it exactly (its approach, seams, breadcrumbs, and "Done when" are authoritative — do not redesign): ' + TICKET + '.',
  'Also skim /Users/dylan/Documents/personal/continuum-overnight/docs/38-locked-decisions.md so you do not reopen a settled decision.',
  'DO THE WORK: edit files under Sources/ (and tests) per the ticket. Write the ticket\'s Logic/Backend/UX tests where they are automatable. Then PROVE it:',
  '  1. Run `swift build` and fix until it compiles cleanly.',
  '  2. Run `./scripts/run-matrix.sh` and read the result honestly.',
  'HARD RULES: do NOT `git commit`, do NOT `git push`, do NOT touch git at all — a later stage owns the commit. Do NOT edit files outside what the ticket requires. NO fake-green: if you cannot get a clean build and a green matrix with an honest implementation, stop and report built/matrixGreen=false with the real reason — do not weaken tests or stub the check to pass.',
  'Return {built, matrixGreen, changedFiles, summary, notes}: built=did `swift build` succeed; matrixGreen=did the matrix pass; summary=what you changed and why (for the reviewers); notes=anything shaky.'
].join('\n')

const OPUS_PROMPT = [
  'Adversarially review the UNCOMMITTED diff that implements a Continuum ticket. Be strict — this ships unattended.',
  'The ticket (the contract the diff must satisfy): ' + TICKET + '. Read it, then read the working-tree diff via `git diff` and `git status` (nothing is committed yet).',
  'Judge: does the diff actually deliver the ticket\'s "Done when"? Correct, idiomatic to the surrounding code, no scope creep, no dead code, no weakened/faked tests, no reopened settled decision, no secret or transcript body crossing a sync boundary (I5). Verify the tests genuinely exercise the behavior (not tautologies).',
  'Return {clear, concerns[], notes}: clear=true only if you would merge this as-is. List every real problem as a concern.'
].join('\n')

const CODEX_PROMPT = [
  'Get an INDEPENDENT second-model review of the current uncommitted diff by driving the Codex CLI (GPT-5.5), then relay its verdict.',
  'Run exactly this (read-only, non-interactive) from the repo root and capture stdout:',
  '  codex exec --json -m gpt-5.5 --sandbox read-only --skip-git-repo-check "Review the current uncommitted git diff (run: git --no-pager diff; git --no-pager diff --staged; git status) against the ticket at ' + TICKET + '. Report as strict JSON {clear:boolean, concerns:string[]} whether the change correctly and completely implements the ticket with no bugs, no scope creep, no weakened or faked tests, and no reopened decision. clear=true only if you would merge as-is."',
  'If the codex invocation errors, hangs, or cannot authenticate, treat that as NOT clear (clear=false) with a concern explaining the failure — never fabricate a pass.',
  'Parse Codex\'s JSON verdict from its output and return {clear, concerns[], notes}. Put Codex\'s raw concerns into concerns[]; note in notes if you had to infer the verdict.'
].join('\n')

const COMMIT_PROMPT = (impl, opus, codex) => [
  'Decide whether to commit the current uncommitted work for a Continuum ticket, and act.',
  'Inputs — implementation: ' + JSON.stringify(impl) + '; Opus review: ' + JSON.stringify(opus) + '; Codex(gpt-5.5) review: ' + JSON.stringify(codex) + '.',
  'COMMIT ONLY IF all of these hold: built===true AND matrixGreen===true AND Opus clear===true AND Codex clear===true. Otherwise DO NOT commit.',
  'If committing: `git add -A` then `git commit` with a plain Conventional-Commits message `type(scope): summary` describing the ticket outcome. ABSOLUTELY NO co-authoring / "Generated with" / AI footer of any kind. Do NOT push. Then return {committed:true, commitHash:<short hash>, reason:"all gates green"}.',
  'If NOT committing: leave the working tree exactly as-is (do not revert — the harness will inspect). Return {committed:false, reason:"<which gate failed, concretely>"}.'
].join('\n')

log('iteration for ' + NAME + ' (effort=' + EFFORT + ')')

phase('Implement')
const impl = await agent(IMPL_PROMPT, { label:'implement:' + NAME, phase:'Implement', model:'sonnet', effort: EFFORT, schema: IMPL_RESULT })

// Only spend review budget if the implementation actually built + passed the matrix.
let opus = { clear:false, concerns:['implementation did not reach a green build+matrix; review skipped'] }
let codex = { clear:false, concerns:['implementation did not reach a green build+matrix; review skipped'] }
if (impl && impl.built && impl.matrixGreen) {
  phase('Dual review')
  const reviews = await parallel([
    () => agent(OPUS_PROMPT, { label:'review-opus:' + NAME, phase:'Dual review', effort:'high', schema: VERDICT }),
    () => agent(CODEX_PROMPT, { label:'review-codex-gpt5.5:' + NAME, phase:'Dual review', schema: VERDICT }),
  ])
  opus = reviews[0] || opus
  codex = reviews[1] || codex
} else {
  log('build/matrix not green — skipping review, will not commit')
}

phase('Commit')
const commit = await agent(COMMIT_PROMPT(impl, opus, codex), { label:'commit:' + NAME, phase:'Commit', schema: COMMIT_RESULT })

return {
  ticket: NAME,
  built: !!(impl && impl.built),
  matrixGreen: !!(impl && impl.matrixGreen),
  opusClear: !!(opus && opus.clear),
  codexClear: !!(codex && codex.clear),
  committed: !!(commit && commit.committed),
  commitHash: (commit && commit.commitHash) || null,
  reason: (commit && commit.reason) || 'unknown',
  opusConcerns: (opus && opus.concerns) || [],
  codexConcerns: (codex && codex.concerns) || [],
  implNotes: (impl && impl.notes) || '',
}
