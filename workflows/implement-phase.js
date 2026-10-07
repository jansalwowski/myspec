export const meta = {
  name: 'implement-phase',
  description: 'myspec feature-implement workflow mode: the per-task loop for one plan phase (implement, independent verify, standards and spec-contract checks, up to two fix rounds)',
  whenToUse: 'Started only by /myspec:feature-implement in workflow mode, with the phase payload in args (skills/feature-implement/workflow-args.md). If invoked with no args, do not call Workflow: tell the user to run /myspec:feature-implement, which builds the payload.',
  phases: [
    { title: 'Implement', detail: 'one implementer per task, at the tier the controller chose' },
    { title: 'Verify', detail: 'an independent agent runs the task Verify command and scoped checks and collects the diff' },
    { title: 'Check', detail: 'standards and spec-contract check on the cheap tier; every failure re-judged on the mid tier' },
    { title: 'Fix', detail: 'at most two fix rounds, the second one tier up' },
  ],
}

// The controller keeps every gate: PHASE_BASE, checkbox flips, task
// worktrees, the barrier, the phase review and its fix loop, the Execution
// Log, probes and rulings. This script flips no checkbox and asks nobody
// anything; it returns one structured result per task.

const MAX_FIX_ROUNDS = 2
const TIERS = ['cheap', 'mid', 'premium']
const STATUSES = ['DONE', 'DONE_WITH_CONCERNS', 'OPEN_FINDINGS', 'BLOCKED', 'NEEDS_CONTEXT']

const IMPL_SCHEMA = {
  type: 'object',
  required: ['status', 'summary'],
  properties: {
    status: { type: 'string', enum: ['DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT'] },
    summary: { type: 'string', description: 'what you implemented, or attempted if blocked' },
    testsWritten: { type: 'array', items: { type: 'string' }, description: 'each test and the behavior it pins down' },
    checksRun: {
      type: 'array',
      items: { type: 'object', required: ['command', 'result'], properties: { command: { type: 'string' }, result: { type: 'string' } } },
      description: 'each exact command you ran and its observed result; empty when you ran none',
    },
    filesChanged: { type: 'array', items: { type: 'string' } },
    concerns: { type: 'array', items: { type: 'string' }, description: 'doubts, or what you need (BLOCKED / NEEDS_CONTEXT)' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['baseValid', 'head', 'commits', 'changedFiles', 'dirty', 'checks'],
  properties: {
    baseValid: { type: 'boolean', description: 'false when the base is not a commit (the diff helper exited 2)' },
    head: { type: 'string', description: 'git rev-parse HEAD in the work directory' },
    commits: { type: 'array', items: { type: 'string' }, description: 'git log --format=%H base..HEAD' },
    changedFiles: { type: 'array', items: { type: 'string' }, description: 'git diff --name-only base..HEAD, repo-relative' },
    dirty: { type: 'array', items: { type: 'string' }, description: 'git status --porcelain --untracked-files=all lines' },
    diffPath: { type: 'string', description: 'absolute path of the diff package you wrote' },
    checks: {
      type: 'array',
      items: {
        type: 'object',
        required: ['command', 'ran'],
        properties: {
          command: { type: 'string' },
          ran: { type: 'boolean', description: 'false when the command could not run (denied, tool missing)' },
          exitCode: { type: ['integer', 'null'] },
          outputTail: { type: 'string', description: 'last lines of its output, or why it did not run' },
        },
      },
    },
  },
}

const CHECK_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'rule', 'claim', 'severity'],
        properties: {
          file: { type: 'string' },
          line: { type: ['integer', 'null'] },
          rule: { type: 'string', description: 'the spec-contract quote or standards rule it breaks, verbatim, with its source' },
          claim: { type: 'string', description: 'what the diff does that breaks it' },
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['upheld', 'reason'],
  properties: {
    upheld: { type: 'boolean' },
    reason: { type: 'string', description: 'one or two sentences citing the code you read' },
  },
}

// ---- argument validation (plain code) -------------------------------------

let a = args
if (typeof a === 'string') {
  try { a = JSON.parse(a) } catch { a = null }
}
if (a == null || typeof a !== 'object' || Object.keys(a).length === 0) {
  log('implement-phase was started without a phase payload -- nothing was dispatched')
  return {
    started: false,
    reason: 'no-args',
    next: 'This workflow is started by /myspec:feature-implement in workflow mode, which builds the phase payload. Tell the user to run /myspec:feature-implement; do not re-invoke this workflow by hand.',
  }
}

function invalid(reason) {
  log('implement-phase: ' + reason + ' -- nothing was dispatched')
  return {
    started: false,
    reason: 'bad-args',
    detail: reason,
    next: 'Fix the payload as skills/feature-implement/workflow-args.md describes and start the workflow again, or run this phase in controller mode.',
  }
}

const models = a.models || {}
for (const t of TIERS) {
  if (typeof models[t] !== 'string' || !models[t].trim()) return invalid('models.' + t + ' is missing: name a concrete model for every tier')
}
if (a.mode !== 'sequential' && a.mode !== 'parallel') return invalid('mode must be "sequential" or "parallel"')
if (typeof a.phaseBase !== 'string' || !/^[0-9a-f]{7,64}$/.test(a.phaseBase)) return invalid('phaseBase must be the recorded PHASE_BASE sha')
if (typeof a.stateDir !== 'string' || !a.stateDir.startsWith('/')) return invalid('stateDir must be an absolute path')
if (!Array.isArray(a.tasks) || a.tasks.length === 0) return invalid('tasks must be a non-empty array')
for (const t of a.tasks) {
  if (t == null || typeof t !== 'object') return invalid('every task must be an object')
  if (t.id == null || String(t.id).trim() === '') return invalid('a task has no id')
  if (!TIERS.includes(t.tier)) return invalid('task ' + t.id + ': tier must be cheap, mid or premium')
  if (typeof t.workdir !== 'string' || !t.workdir.startsWith('/')) return invalid('task ' + t.id + ': workdir must be an absolute path')
  if (typeof t.implementerPrompt !== 'string' || !t.implementerPrompt.trim()) return invalid('task ' + t.id + ': implementerPrompt is empty')
  if (!Array.isArray(t.files)) return invalid('task ' + t.id + ': files must list the task Files paths')
}

const planPath = typeof a.planPath === 'string' ? a.planPath : ''
const standards = Array.isArray(a.standards) ? a.standards.filter((s) => typeof s === 'string' && s.trim()) : []
const reviewDiff = typeof a.reviewDiff === 'string' && a.reviewDiff.trim() ? a.reviewDiff.trim() : null

// ---- helpers (plain code) -------------------------------------------------

function tierUp(tier) {
  const i = TIERS.indexOf(tier)
  return TIERS[Math.min(i + 1, TIERS.length - 1)]
}

function norm(p) {
  return String(p == null ? '' : p).trim().replace(/^\.\//, '').replace(/\/+$/, '')
}

function allowed(file, task) {
  const f = norm(file)
  if (planPath && f === norm(planPath)) return true
  return task.files.some((p) => {
    const n = norm(p)
    return n !== '' && (f === n || f.startsWith(n + '/'))
  })
}

// The porcelain path is everything after the two status columns and a space;
// a rename shows as "old -> new".
function porcelainPath(line) {
  const rest = String(line).slice(3)
  const arrow = rest.indexOf(' -> ')
  return norm(arrow >= 0 ? rest.slice(arrow + 4) : rest)
}

// Touch-only, missing-commit and dirty-tree checks: facts, never re-judged.
function plainFindings(task, v) {
  const out = []
  if (!v.baseValid) {
    out.push({ kind: 'base', file: '', claim: 'the task base is not a commit; no diff could be built' })
    return out
  }
  if (v.commits.length === 0) {
    out.push({ kind: 'commit', file: '', claim: 'no commit since the task base: the work is uncommitted or missing' })
  }
  for (const f of v.changedFiles) {
    if (!allowed(f, task)) out.push({ kind: 'scope', file: norm(f), claim: 'changed a file outside the task Files list' })
  }
  for (const line of v.dirty) {
    const p = porcelainPath(line)
    if (p && !(planPath && p === norm(planPath))) out.push({ kind: 'dirty', file: p, claim: 'left uncommitted: ' + String(line).trim() })
  }
  return out
}

function checkFindings(v) {
  return v.checks
    .filter((c) => c.ran && c.exitCode !== 0)
    .map((c) => ({ kind: 'check', file: '', claim: '`' + c.command + '` exited ' + c.exitCode + (c.outputTail ? ':\n' + c.outputTail : '') }))
}

function notChecked(v) {
  return v.checks.filter((c) => !c.ran).map((c) => c.command + (c.outputTail ? ' -- ' + c.outputTail : ''))
}

// A check the implementer reports having run that the verify agent did not
// run itself is a claim without evidence.
function notEvidenced(impl, v) {
  const ran = new Set(v.checks.filter((c) => c.ran).map((c) => c.command.trim()))
  return (impl.checksRun || []).filter((c) => !ran.has(String(c.command).trim())).map((c) => c.command + ' -> ' + c.result)
}

function findingLine(f) {
  const where = f.file ? f.file + (f.line ? ':' + f.line : '') + ' ' : ''
  return '- [' + f.kind + '] ' + where + f.claim + (f.rule ? '\n  rule: ' + f.rule : '')
}

const IMPL_TAIL = '\n\nReturn your report as the structured result: status, summary, testsWritten, checksRun (exact commands and observed results), filesChanged, concerns. Commit your work as the task says before you return.'

function verifyPrompt(task, base, round) {
  const diffPath = a.stateDir + '/phase-' + a.phase + '-task-' + task.id + '-r' + round + '.diff'
  const cmds = [task.verifyCommand].concat(task.scopedChecks || []).filter((c) => typeof c === 'string' && c.trim() && c.trim() !== 'none')
  const diffStep = reviewDiff
    ? '`' + reviewDiff + ' ' + base + ' ' + diffPath + '` -- exit 2 means the base is not a commit: set baseValid false.'
    : '`git diff -U10 ' + base + '..HEAD > ' + diffPath + '` -- if `git rev-parse --verify ' + base + '^{commit}` fails, set baseValid false.'
  return [
    'You verify Task ' + task.id + (task.name ? ' (' + task.name + ')' : '') + '. You did not write it; its implementer\'s report is not evidence.',
    'Work in ' + task.workdir + ' (cd there first). Never edit a file, commit, stage, or change the index, HEAD or a branch.',
    '',
    'Collect, in that directory:',
    '1. head: `git rev-parse HEAD`',
    '2. commits: `git log --format=%H ' + base + '..HEAD`',
    '3. changedFiles: `git diff --name-only ' + base + '..HEAD`',
    '4. dirty: `git status --porcelain --untracked-files=all`, one entry per line',
    '5. diffPath: run ' + diffStep,
    '6. checks: run each command below as written, one at a time, and record its exit code and the last 40 lines of output. A command you cannot run (denied, missing tool) gets ran false and the reason as outputTail. Never change a command to make it pass.',
    cmds.length ? cmds.map((c) => '   - `' + c + '`').join('\n') : '   (none)',
  ].join('\n')
}

function checkPrompt(task, v) {
  return [
    'Check the diff of Task ' + task.id + ' at ' + v.diffPath + ' (work directory ' + task.workdir + '). Read it once; read code outside it only to confirm a specific finding. Do not edit anything.',
    '',
    'Report a finding only where the diff breaks one of these, citing it verbatim:',
    '(a) the task Spec contract:',
    task.specContract ? task.specContract : '(none given)',
    '(b) the project standards in: ' + (standards.length ? standards.join(', ') : '(none given: skip b)'),
    '',
    'Severity: critical = broken behavior, data loss, security; important = a missed contract line or a stated standard broken in a way you would block a merge over; minor = everything else. Do not report preferences no cited rule states. No finding is a valid answer.',
  ].join('\n')
}

function rejudgePrompt(task, v, f) {
  return [
    'A cheaper checker claims Task ' + task.id + ' breaks a rule. Decide whether the claim is real. Read the diff at ' + v.diffPath + ' and the code it cites in ' + task.workdir + '. Do not edit anything.',
    '',
    'Claim: ' + (f.file ? f.file + (f.line ? ':' + f.line : '') + ' -- ' : '') + f.claim,
    'Rule cited: ' + f.rule,
    '',
    'Uphold it only when the code does what the claim says and the cited rule, read literally, forbids it. When either is not so, or you cannot tell, upheld is false.',
  ].join('\n')
}

function fixPrompt(task, open, history, round) {
  const framing = round === 1
    ? 'The checks below failed after you implemented this task. Fix each one.'
    : 'A prior implementer attempted this fix ' + (round - 1) + ' time(s); you own it now. Read the current code yourself.'
  return [
    task.implementerPrompt,
    '',
    '## Open Findings',
    '',
    framing,
    open.map(findingLine).join('\n'),
    '',
    '## Earlier Rounds',
    '',
    history.length ? history.join('\n') : 'none',
    '',
    'A finding about a rule is fixed everywhere the rule is stated or applied, not only at the cited line. Never weaken a test or a check to make it pass. Commit the fix as the task says.',
  ].join('\n') + IMPL_TAIL
}

// ---- the per-task loop ----------------------------------------------------

async function runTask(task, base) {
  const id = String(task.id)
  const result = {
    id,
    status: 'DONE',
    rounds: 0,
    head: null,
    commits: [],
    changedFiles: [],
    findings: [],
    notChecked: [],
    deferredMinors: [],
    notEvidenced: [],
    concerns: [],
    summary: '',
  }

  const impl = await agent(task.implementerPrompt + IMPL_TAIL, {
    label: 'implement ' + id, phase: 'Implement', model: models[task.tier], schema: IMPL_SCHEMA,
  })
  if (!impl) {
    result.status = 'BLOCKED'
    result.concerns = ['the implementer returned no report']
    return result
  }
  result.summary = impl.summary
  result.concerns = impl.concerns || []
  if (impl.status === 'BLOCKED' || impl.status === 'NEEDS_CONTEXT') {
    result.status = impl.status
    return result
  }

  let lastImpl = impl
  const history = []
  for (let round = 0; ; round++) {
    const v = await agent(verifyPrompt(task, base, round), {
      label: 'verify ' + id + (round ? ' r' + round : ''), phase: 'Verify', model: models.cheap, schema: VERIFY_SCHEMA,
    })
    if (!v) {
      result.status = 'DONE_WITH_CONCERNS'
      result.notChecked.push('the verify agent returned nothing: no check ran on this task')
      return result
    }
    result.head = v.head
    result.commits = v.commits
    result.changedFiles = v.changedFiles
    result.notChecked = notChecked(v)
    result.notEvidenced = notEvidenced(lastImpl, v)

    const open = plainFindings(task, v).concat(checkFindings(v))
    if (v.baseValid && v.diffPath) {
      const checked = await agent(checkPrompt(task, v), {
        label: 'check ' + id + (round ? ' r' + round : ''), phase: 'Check', model: models.cheap, schema: CHECK_SCHEMA,
      })
      const claims = checked ? checked.findings : []
      if (!checked) result.notChecked.push('the standards and spec-contract check returned nothing')
      result.deferredMinors = claims.filter((f) => f.severity === 'minor')
        .map((f) => (f.file ? f.file + (f.line ? ':' + f.line : '') + ' ' : '') + f.claim)
      const serious = claims.filter((f) => f.severity !== 'minor')
      const verdicts = await parallel(serious.map((f) => () => agent(rejudgePrompt(task, v, f), {
        label: 'rejudge ' + id, phase: 'Check', model: models.mid, schema: VERDICT_SCHEMA,
      })))
      serious.forEach((f, i) => {
        const verdict = verdicts[i]
        // A judge that returned nothing upholds nothing, but the claim is
        // kept visible for the phase reviewer.
        if (verdict && verdict.upheld) open.push({ kind: 'contract', file: f.file, line: f.line, rule: f.rule, claim: f.claim })
        else if (!verdict) result.notChecked.push('re-judge returned nothing for: ' + f.claim)
      })
    }

    result.findings = open
    if (open.length === 0) {
      result.status = lastImpl.status === 'DONE_WITH_CONCERNS' || result.concerns.length ? 'DONE_WITH_CONCERNS' : 'DONE'
      return result
    }
    if (round >= MAX_FIX_ROUNDS) {
      result.status = 'OPEN_FINDINGS'
      log('Task ' + id + ': ' + open.length + ' finding(s) still open after ' + MAX_FIX_ROUNDS + ' fix rounds -- handed to the phase review')
      return result
    }

    const next = round + 1
    const tier = next === MAX_FIX_ROUNDS ? tierUp(task.tier) : task.tier
    const fix = await agent(fixPrompt(task, open, history, next), {
      label: 'fix ' + id + ' r' + next, phase: 'Fix', model: models[tier], schema: IMPL_SCHEMA,
    })
    result.rounds = next
    if (!fix) {
      result.status = 'OPEN_FINDINGS'
      result.concerns.push('fix round ' + next + ' returned no report')
      return result
    }
    if (fix.status === 'BLOCKED' || fix.status === 'NEEDS_CONTEXT') {
      result.status = fix.status
      result.concerns = result.concerns.concat(fix.concerns || [])
      return result
    }
    result.concerns = result.concerns.concat(fix.concerns || [])
    history.push('Round ' + next + ' (' + tier + '): ' + open.length + ' finding(s) sent; implementer reported: ' + fix.summary)
    lastImpl = fix
  }
}

// ---- run the phase ----------------------------------------------------------

const results = []
const notRun = []

if (a.mode === 'parallel') {
  // Each parallel task works in its own controller-made worktree, forked
  // from PHASE_BASE, so each diffs from PHASE_BASE.
  const out = await parallel(a.tasks.map((t) => () => runTask(t, a.phaseBase)))
  out.forEach((r, i) => {
    results.push(r || { id: String(a.tasks[i].id), status: 'BLOCKED', rounds: 0, findings: [], notChecked: [], deferredMinors: [], notEvidenced: [], concerns: ['the task loop failed'] })
  })
} else {
  // Sequential tasks share one checkout: each diffs from the head the
  // previous task's verify saw.
  let base = a.phaseBase
  for (let i = 0; i < a.tasks.length; i++) {
    const r = await runTask(a.tasks[i], base)
    results.push(r)
    if (r.status === 'BLOCKED' || r.status === 'NEEDS_CONTEXT') {
      for (const rest of a.tasks.slice(i + 1)) notRun.push(String(rest.id))
      if (notRun.length) log('Task ' + r.id + ' is ' + r.status + ' -- tasks ' + notRun.join(', ') + ' were not started')
      break
    }
    if (r.head) base = r.head
  }
}

for (const r of results) {
  if (!STATUSES.includes(r.status)) r.status = 'BLOCKED'
}

return { started: true, phase: a.phase, mode: a.mode, tasks: results, notRun }
