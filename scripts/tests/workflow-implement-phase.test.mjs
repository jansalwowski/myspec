// Runs workflows/implement-phase.js against a stub Workflow runtime (#247).
// The real runtime is Claude Code's Workflow tool, which no test can start;
// the stub supplies the same globals (args, agent, parallel, phase, log) and
// answers each agent() call from a scripted queue keyed by its label prefix.
//
// Usage: node scripts/tests/workflow-implement-phase.test.mjs [path-to-script]

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const scriptPath = process.argv[2] || resolve(here, '../../workflows/implement-phase.js')
const source = readFileSync(scriptPath, 'utf8')

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
// The runtime evaluates `export const meta` as a declaration; a function body
// cannot hold an export, so the stub drops the keyword.
const body = source.replace(/^export\s+const\s+meta\b/m, 'const meta')
const compiled = new AsyncFunction('args', 'agent', 'parallel', 'pipeline', 'phase', 'log', 'budget', 'workflow', body)

let pass = 0
let fail = 0
function check(name, cond, detail) {
  if (cond) { pass++; console.log('ok   ' + name) } else { fail++; console.log('FAIL ' + name + (detail ? ' -- ' + detail : '')) }
}

// script: { 'implement 1': [resp, ...], 'verify 1': [...], ... } -- each call
// with a label starting with the key shifts the next response. A response may
// be a function of the call (prompt, opts).
async function run(args, script) {
  const calls = []
  const logs = []
  const queues = Object.fromEntries(Object.entries(script).map(([k, v]) => [k, v.slice()]))
  const agent = async (prompt, opts = {}) => {
    calls.push({ prompt, ...opts })
    if (/Date\.now|Math\.random/.test(prompt)) throw new Error('nondeterminism leaked into a prompt')
    const key = Object.keys(queues).filter((k) => (opts.label || '').startsWith(k)).sort((x, y) => y.length - x.length)[0]
    if (!key || queues[key].length === 0) throw new Error('unscripted agent call: ' + opts.label)
    const r = queues[key].shift()
    return typeof r === 'function' ? r(prompt, opts) : r
  }
  const parallel = async (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)))
  const pipeline = async () => { throw new Error('pipeline not expected') }
  const out = await compiled(args, agent, parallel, pipeline, () => {}, (m) => logs.push(m), { total: null, spent: () => 0, remaining: () => Infinity }, async () => null)
  const left = Object.entries(queues).filter(([, v]) => v.length).map(([k]) => k)
  return { out, calls, logs, left }
}

const MODELS = { cheap: 'model-cheap', mid: 'model-mid', premium: 'model-premium' }
const SHA = 'a'.repeat(40)
function task(id, extra = {}) {
  return {
    id, name: 'task ' + id, tier: 'mid', workdir: '/repo', implementerPrompt: 'You are implementing Task ' + id,
    files: ['src/t' + id + '.py', 'tests/test_t' + id + '.py'], verifyCommand: 'pytest tests/test_t' + id + '.py',
    scopedChecks: ['ruff check src/t' + id + '.py'], specContract: '- spec.md REQ-00' + id + ': "rule ' + id + '"', ...extra,
  }
}
function payload(tasks, extra = {}) {
  return {
    feature: 'invoice-due-dates', phase: 1, mode: 'sequential', phaseBase: SHA, stateDir: '/repo/.claude/state/implement/invoice-due-dates',
    planPath: '.ai/features/invoice-due-dates/implementation-plan.md', models: MODELS, standards: ['.claude/rules/conventions.md'],
    reviewDiff: '/plugin/lib/review-diff.sh', tasks, ...extra,
  }
}
const done = (extra = {}) => ({ status: 'DONE', summary: 'did it', checksRun: [{ command: 'pytest tests/test_t1.py', result: '3 passed' }], ...extra })
function verified(id, extra = {}) {
  return {
    baseValid: true, head: 'b'.repeat(39) + id, commits: ['c'.repeat(39) + id], changedFiles: ['src/t' + id + '.py', 'tests/test_t' + id + '.py'],
    dirty: [], diffPath: '/repo/.claude/state/implement/x/phase-1-task-' + id + '-r0.diff',
    checks: [{ command: 'pytest tests/test_t' + id + '.py', ran: true, exitCode: 0, outputTail: '3 passed' }, { command: 'ruff check src/t' + id + '.py', ran: true, exitCode: 0 }],
    ...extra,
  }
}
const clean = { findings: [] }
const statusOf = (r, id) => r.out.tasks.find((t) => t.id === String(id))?.status

// 1. Happy path.
{
  const r = await run(payload([task(1)]), { 'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [clean] })
  check('happy path: started', r.out.started === true)
  check('happy path: DONE', statusOf(r, 1) === 'DONE', JSON.stringify(r.out.tasks))
  check('happy path: no fix round', r.calls.every((c) => !c.label.startsWith('fix')))
  check('happy path: implementer on the task tier', r.calls[0].model === 'model-mid')
  check('happy path: verify and check on the cheap tier', r.calls.filter((c) => /^(verify|check)/.test(c.label)).every((c) => c.model === 'model-cheap'))
  check('happy path: verify uses the diff helper and the task base', /\/plugin\/lib\/review-diff\.sh a{40} /.test(r.calls[1].prompt))
  check('happy path: every scripted answer used', r.left.length === 0, r.left.join(','))
}

// 2. A failing Verify command costs a fix round, then passes.
{
  const failing = verified(1, { checks: [{ command: 'pytest tests/test_t1.py', ran: true, exitCode: 1, outputTail: '1 failed' }] })
  const r = await run(payload([task(1)]), {
    'implement 1': [done()], 'verify 1': [failing, verified(1)], 'check 1': [clean, clean], 'fix 1': [done({ summary: 'fixed' })],
  })
  check('verify failure: DONE after a fix', statusOf(r, 1) === 'DONE', JSON.stringify(r.out.tasks))
  const fix = r.calls.find((c) => c.label === 'fix 1 r1')
  check('verify failure: one fix round on the task tier', fix && fix.model === 'model-mid')
  check('verify failure: fix carries the failing command', fix && fix.prompt.includes('`pytest tests/test_t1.py` exited 1'))
  check('verify failure: rounds counted', r.out.tasks[0].rounds === 1)
}

// 3. A cheap-tier finding the mid-tier judge rejects never costs a fix.
{
  const claim = { findings: [{ file: 'src/t1.py', line: 4, rule: 'REQ-001 "rule 1"', claim: 'ignores rule', severity: 'important' }] }
  const r = await run(payload([task(1)]), {
    'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [claim], 'rejudge 1': [{ upheld: false, reason: 'the code applies it at line 6' }],
  })
  check('rejected claim: DONE', statusOf(r, 1) === 'DONE', JSON.stringify(r.out.tasks))
  check('rejected claim: re-judged on the mid tier', r.calls.some((c) => c.label === 'rejudge 1' && c.model === 'model-mid'))
  check('rejected claim: no fix round', r.calls.every((c) => !c.label.startsWith('fix')))
}

// 4. An upheld finding survives two fix rounds: OPEN_FINDINGS, second round
//    one tier up, never a third.
{
  const claim = { findings: [{ file: 'src/t1.py', line: 4, rule: 'REQ-001 "rule 1"', claim: 'ignores rule', severity: 'critical' }] }
  const upheld = { upheld: true, reason: 'line 4 skips it' }
  const r = await run(payload([task(1)]), {
    'implement 1': [done()], 'verify 1': [verified(1), verified(1), verified(1)], 'check 1': [claim, claim, claim],
    'rejudge 1': [upheld, upheld, upheld], 'fix 1': [done(), done()],
  })
  check('two rounds: OPEN_FINDINGS', statusOf(r, 1) === 'OPEN_FINDINGS', JSON.stringify(r.out.tasks))
  const fixes = r.calls.filter((c) => c.label.startsWith('fix'))
  check('two rounds: exactly two fix rounds', fixes.length === 2, String(fixes.length))
  check('two rounds: round 1 on the task tier', fixes[0] && fixes[0].model === 'model-mid')
  check('two rounds: round 2 one tier up', fixes[1] && fixes[1].model === 'model-premium')
  check('two rounds: round 2 framed as a takeover', fixes[1] && fixes[1].prompt.includes('you own it now'))
  check('two rounds: round 2 carries the round summary', fixes[1] && /Round 1 \(mid\)/.test(fixes[1].prompt))
  check('two rounds: the open finding is returned', r.out.tasks[0].findings.some((f) => f.kind === 'contract'))
}

// 5. A minor finding is deferred, never fixed or re-judged.
{
  const minor = { findings: [{ file: 'src/t1.py', line: 9, rule: 'conventions.md naming', claim: 'short name', severity: 'minor' }] }
  const r = await run(payload([task(1)]), { 'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [minor] })
  check('minor: DONE', statusOf(r, 1) === 'DONE')
  check('minor: deferred', r.out.tasks[0].deferredMinors.length === 1)
  check('minor: not re-judged', r.calls.every((c) => !c.label.startsWith('rejudge')))
}

// 6. Plain-code checks: a file outside Files, no commit, a dirty tree. The
//    plan file's own uncommitted edit is not a finding.
{
  const bad = verified(1, {
    commits: [], changedFiles: ['src/t1.py', 'src/other.py'],
    dirty: [' M .ai/features/invoice-due-dates/implementation-plan.md', '?? src/scratch.py'],
  })
  const r = await run(payload([task(1)]), {
    'implement 1': [done()], 'verify 1': [bad, bad, bad], 'check 1': [clean, clean, clean], 'fix 1': [done(), done()],
  })
  const kinds = r.out.tasks[0].findings.map((f) => f.kind).sort().join(',')
  check('plain checks: scope, commit and dirty found', kinds === 'commit,dirty,scope', kinds)
  check('plain checks: plan file edit is not dirty', !r.out.tasks[0].findings.some((f) => f.file.endsWith('implementation-plan.md')))
  check('plain checks: never re-judged', r.calls.every((c) => !c.label.startsWith('rejudge')))
  check('plain checks: OPEN_FINDINGS after two rounds', statusOf(r, 1) === 'OPEN_FINDINGS')
}

// 7. A base that is not a commit: no check agent, a finding.
{
  const gone = verified(1, { baseValid: false, commits: [], changedFiles: [], diffPath: '' })
  const r = await run(payload([task(1)]), { 'implement 1': [done()], 'verify 1': [gone, gone, gone], 'fix 1': [done(), done()] })
  check('bad base: finding of kind base', r.out.tasks[0].findings.some((f) => f.kind === 'base'))
  check('bad base: check agent skipped', r.calls.every((c) => !c.label.startsWith('check')))
}

// 8. BLOCKED stops a sequential phase; later tasks are reported not run.
{
  const r = await run(payload([task(1), task(2), task(3)]), {
    'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [clean],
    'implement 2': [{ status: 'BLOCKED', summary: 'no db', concerns: ['database URL missing'] }],
  })
  check('blocked: task 2 BLOCKED', statusOf(r, 2) === 'BLOCKED')
  check('blocked: task 2 not verified', r.calls.every((c) => c.label !== 'verify 2'))
  check('blocked: task 3 not run', JSON.stringify(r.out.notRun) === '["3"]', JSON.stringify(r.out.notRun))
  check('blocked: concerns carried', r.out.tasks[1].concerns.includes('database URL missing'))
}

// 9. Sequential bases chain: task 2 diffs from the head task 1's verify saw.
{
  const r = await run(payload([task(1), task(2)]), {
    'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [clean],
    'implement 2': [done()], 'verify 2': [verified(2)], 'check 2': [clean],
  })
  const v2 = r.calls.find((c) => c.label === 'verify 2')
  check('sequential: task 2 base is task 1 head', v2 && v2.prompt.includes('git log --format=%H ' + 'b'.repeat(39) + '1..HEAD'))
}

// 10. Parallel tasks each diff from PHASE_BASE in their own worktree.
{
  const r = await run(payload([task(1, { workdir: '/wt/t1' }), task(2, { workdir: '/wt/t2' })], { mode: 'parallel' }), {
    'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [clean],
    'implement 2': [done()], 'verify 2': [verified(2)], 'check 2': [clean],
  })
  const v = r.calls.filter((c) => c.label.startsWith('verify'))
  check('parallel: both DONE', statusOf(r, 1) === 'DONE' && statusOf(r, 2) === 'DONE')
  check('parallel: each from PHASE_BASE', v.every((c) => c.prompt.includes('git log --format=%H ' + SHA + '..HEAD')))
  check('parallel: each in its worktree', v.some((c) => c.prompt.includes('/wt/t1')) && v.some((c) => c.prompt.includes('/wt/t2')))
}

// 11. Evidence: an implementer check the verify agent never ran is reported;
//     a check that could not run is notChecked.
{
  const v = verified(1, { checks: [{ command: 'pytest tests/test_t1.py', ran: true, exitCode: 0 }, { command: 'ruff check src/t1.py', ran: false, outputTail: 'ruff not installed' }] })
  const r = await run(payload([task(1)]), {
    'implement 1': [done({ checksRun: [{ command: 'mypy src', result: 'clean' }] })], 'verify 1': [v], 'check 1': [clean],
  })
  check('evidence: unreproduced claim listed', r.out.tasks[0].notEvidenced.some((s) => s.startsWith('mypy src')))
  check('evidence: unrunnable check listed', r.out.tasks[0].notChecked.some((s) => s.startsWith('ruff check')))
}

// 12. Bare and malformed invocations dispatch nothing.
{
  const bare = await run(undefined, {})
  check('bare: not started', bare.out.started === false && bare.out.reason === 'no-args')
  check('bare: no agent', bare.calls.length === 0)
  const noModels = await run(payload([task(1)], { models: { cheap: 'x' } }), {})
  check('bad args: missing tier model refused', noModels.out.started === false && noModels.out.reason === 'bad-args')
  const badTier = await run(payload([task(1, { tier: 'huge' })]), {})
  check('bad args: unknown tier refused', badTier.out.started === false)
  const asString = await run(JSON.stringify(payload([task(1)])), { 'implement 1': [done()], 'verify 1': [verified(1)], 'check 1': [clean] })
  check('args as JSON text: read as its value', asString.out.started === true)
}

// 13. Determinism: the script must not call the APIs the runtime forbids.
check('no Date.now / Math.random / argless new Date', !/Date\.now\(|Math\.random\(|new Date\(\)/.test(source))
check('meta is a literal object', /^export const meta = \{/m.test(source))

console.log('\n' + pass + ' passed, ' + fail + ' failed')
process.exit(fail ? 1 : 0)
