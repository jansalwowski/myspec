#!/usr/bin/env node
// friction-scan: read one finished Claude Code session's transcripts and report
// repeated friction, attributed to myspec, the project, the project's myspec
// setup, or unknown. Read-only. Zero npm dependencies. No model calls.
//
// Usage:
//   node scan.mjs --session=<id> [--projects-dir=<path>] [--json]
//   node scan.mjs --transcript=<path/to/session.jsonl> [--json]
//   node scan.mjs --session=<id> | --transcript=<path> --emit[=<runs.jsonl>] [--json]
//
// --emit records field metrics instead of printing the report: one JSON line
// per skill run and one per session, appended to
// <main checkout>/.claude/state/metrics/runs.jsonl (see metrics.mjs). It
// always exits 0; a skipped or failed run prints one line on stderr.
//
// Defaults:
//   --projects-dir   $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects
//
// Exit codes: 0 scanned (text mode prints nothing when nothing crosses a
// threshold) or disabled; 1 usage error; 2 transcript not found; 3 transcript
// format not recognized.
//
// Disabled by `"feedback": { "frictionReport": false }` in .myspec.json or
// MYSPEC_DISABLE_FRICTION_REPORT=1.
//
// The transcript is an internal Claude Code format, not a documented API.
// Events are read by JSON structure, never by grepping raw text: transcripts
// quote themselves, so a text match counts a report that mentions a hook
// error as the error.

import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { join, resolve, dirname, basename } from 'node:path'
import { homedir } from 'node:os'
import { argv, cwd, env, exit, stdout, stderr } from 'node:process'
import { execFileSync } from 'node:child_process'
import { getSetting } from '../myspec-config.mjs'

// ───────────────────────── rules (data) ─────────────────────────
// A hook block is reported only when the same signature repeats. One
// isolation prompt per session is the hook working, not friction.

export const REPEAT_THRESHOLD = 3

// Block-message fragments emitted by myspec's own hooks. Each fragment must
// stay a literal substring of the hook source; lib/tests/friction-scan.test.sh
// fails when a hook's message changes without this table.
export const HOOK_SIGNATURES = [
  { id: 'isolation-undecided', match: 'no work-isolation decision recorded', hook: 'require-isolation-decision.sh', owner: 'myspec' },
  { id: 'isolation-mismatch', match: 'this session chose WORKTREE isolation', hook: 'require-isolation-decision.sh', owner: 'myspec' },
  { id: 'branch-guard', match: 'Branch-mutating git commands are not allowed', hook: 'guard-worktree-context.sh', owner: 'myspec' },
  { id: 'reuse-audit', match: 'is missing a valid "## Reuse audit" section', hook: 'require-reuse-audit.sh', owner: 'myspec' },
  { id: 'memory-conformance', match: 'Memory conformance check failed', hook: 'verify-before-stop.sh', owner: 'myspec' },
  { id: 'worktree-provisioning', match: 'Symlinked dependency directory in', hook: 'verify-before-stop.sh', owner: 'myspec' },
  { id: 'setup-conformance', match: 'Setup conformance check failed', hook: 'verify-before-stop.sh', owner: 'setup' },
  // The model's own writes, not a framework defect, until shown otherwise.
  { id: 'absolute-paths', match: 'contains absolute homedir paths', hook: 'no-absolute-paths.sh', owner: 'unknown' },
  { id: 'frontmatter', match: 'Frontmatter issue in ', hook: 'validate-frontmatter.sh', owner: 'unknown' },
  { id: 'project-verification', match: 'Verification did not pass', hook: 'verify-before-stop.sh', owner: 'project' },
]

// Refusals from Claude Code itself, so they are not counted as tool errors
// of unknown origin.
export const HARNESS_SIGNATURES = [
  { id: 'harness-worktree-guard', match: 'is isolated in the worktree' },
]

// Current hook scripts plus retired names an older install may still
// register (guard-git-branch.sh became guard-worktree-context.sh in 7bf8bf8).
export const MYSPEC_HOOKS = [
  'guard-git-branch.sh',
  'guard-worktree-context.sh',
  'mark-code-changed.sh',
  'no-absolute-paths.sh',
  'record-session-metrics.sh',
  'require-isolation-decision.sh',
  'require-reuse-audit.sh',
  'validate-frontmatter.sh',
  'verify-before-stop.sh',
]

// Final-message verdicts from myspec's dispatch prompts. NEEDS_CONTEXT means
// "information not provided" (implementer-prompt.md), which usually traces to
// the project's spec or plan, so it defaults to project.
// Anchored to a line of its own, so a report that mentions an earlier
// verdict ("the executor returned PROBES_FAILED, now fixed") does not count.
const SUBAGENT_STATUS = [
  { id: 'subagent-blocked', re: /^\s*\*\*Status:\*\*\s*BLOCKED\s*$/m, owner: 'unknown' },
  { id: 'subagent-needs-context', re: /^\s*\*\*Status:\*\*\s*NEEDS_CONTEXT\s*$/m, owner: 'project' },
  { id: 'probes-blocked', re: /^\s*PROBES_BLOCKED\s*$/m, owner: 'unknown' },
  { id: 'probes-failed', re: /^\s*PROBES_FAILED\s*$/m, owner: 'project' },
]

const OWNER_ORDER = ['myspec', 'setup', 'harness', 'unknown', 'project']

// ───────────────────────── transcript reading ─────────────────────────

export function readJsonl(path) {
  const entries = []
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.trim()) { continue }
    try { entries.push(JSON.parse(line)) } catch { /* torn trailing line */ }
  }
  return entries
}

function recognized(entries) {
  return entries.some((e) => typeof e?.type === 'string' && (e.type === 'user' || e.type === 'assistant') && e.message)
}

function contentBlocks(entry) {
  const c = entry?.message?.content
  return Array.isArray(c) ? c : []
}

function textOf(value) {
  if (typeof value === 'string') { return value }
  if (Array.isArray(value)) { return value.map((v) => (typeof v === 'string' ? v : v?.text ?? '')).join('\n') }
  return ''
}

// Bash failures open with a bare "Exit code N" line; the line after it is
// the one that tells repeats apart.
function firstLine(text, max = 140) {
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean)
  const line = /^Exit code \d+$/.test(lines[0] ?? '') && lines[1] ? `${lines[0]}: ${lines[1]}` : lines[0] ?? ''
  return line.replace(/<\/?tool_use_error>/g, '').slice(0, max)
}

function lastLine(text) {
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean)
  return lines[lines.length - 1] ?? ''
}

// Collapse the variable parts of an error so repeats group together. The
// last line is part of the key because many errors share an opening line
// ("Traceback (most recent call last):") and differ only at the end.
function normalizeError(text) {
  return `${firstLine(text)} … ${lastLine(text).slice(0, 140)}`
    .replace(/\/[^\s'"`:]+/g, '<path>')
    .replace(/\b\d+(\.\d+)?\b/g, '<n>')
}

function hookScript(command) {
  const first = String(command ?? '').trim().split(/\s+/)[0] ?? ''
  return basename(first.replace(/["']/g, ''))
}

function signatureFor(message) {
  return HOOK_SIGNATURES.find((s) => message.includes(s.match)) ?? null
}

// A hook-block event as a short name for the metrics records: the signature
// id when the message is known, else the script that blocked, else the hook
// event. Never the message itself, which can quote project content.
export function blockName(ev) {
  const sig = signatureFor(ev.message ?? '')
  if (sig) { return sig.id }
  const script = hookScript(ev.command)
  return script || String(ev.hookName ?? '?').split(':')[0]
}

function rawFirstLine(text) {
  return text.replace(/^\s*<tool_use_error>/, '').split('\n').find((l) => l.trim())?.trim() ?? ''
}

// A tool result is a hook's refusal only when it opens with the reason. A
// failing test run or a grep that prints the same words further down is
// the tool's own output.
function leadingSignature(table, text) {
  const line = rawFirstLine(text)
  return table.find((s) => line.startsWith(s.match) || (/^BLOCKED: /.test(line) && line.includes(s.match)) || (table === HARNESS_SIGNATURES && line.includes(s.match))) ?? null
}

// Exit 127 means the shell could not find a command. It is the registered
// script itself only when stderr names it ("/bin/sh: <script>: No such file
// or directory"); "<script>: line 12: jq: command not found" is a command
// the script calls.
function scriptMissing(hook, stderrText) {
  if (!hook) { return false }
  const esc = hook.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`${esc}:\\s*(No such file or directory|(command )?not found)`).test(stderrText)
}

function ts(entry) {
  const t = Date.parse(entry?.timestamp ?? '')
  return Number.isNaN(t) ? null : t
}

// ───────────────────────── extraction ─────────────────────────

// Returns raw events from one transcript (main or subagent).
export function extractEvents(entries, source) {
  const events = []
  const toolNames = new Map()
  // Parallel tool calls in one assistant message share its message id. A
  // hook that denies all of them fired once, as far as friction goes.
  const toolTurns = new Map()

  for (const e of entries) {
    if (e.type === 'assistant') {
      for (const b of contentBlocks(e)) {
        if (b.type !== 'tool_use') { continue }
        toolNames.set(b.id, b.name)
        toolTurns.set(b.id, e.message?.id ?? e.uuid ?? b.id)
      }
    }
  }
  let seq = 0
  const turnOf = (toolUseId) => `${source}:${toolTurns.get(toolUseId) ?? toolUseId ?? `entry-${seq++}`}`

  for (const e of entries) {
    const at = e.timestamp ?? null

    // PostToolUse and Stop blocks: attachment carrying the hook's reason and,
    // in current versions, the command that blocked.
    if (e.type === 'attachment' && e.attachment?.type === 'hook_blocking_error') {
      const a = e.attachment
      let be = a.blockingError
      if (typeof be === 'string') { try { be = JSON.parse(be) } catch { be = { blockingError: be } } }
      const message = textOf(be?.blockingError ?? '')
      events.push({ kind: 'hook-block', hookName: a.hookName ?? a.hookEvent ?? '?', command: be?.command ?? a.command ?? '', message, at, source, turn: turnOf(a.toolUseID) })
      continue
    }

    // A hook that could not run. Exit 127 is "command not found".
    if (e.type === 'attachment' && e.attachment?.type === 'hook_non_blocking_error') {
      const a = e.attachment
      events.push({ kind: 'hook-error', hookName: a.hookName ?? '?', command: a.command ?? '', exitCode: a.exitCode ?? null, message: textOf(a.stderr ?? a.content), at, source, turn: turnOf(a.toolUseID) })
      continue
    }

    if (e.type === 'user') {
      for (const b of contentBlocks(e)) {
        if (b.type !== 'tool_result' || b.is_error !== true) { continue }
        const text = textOf(b.content)
        const turn = turnOf(b.tool_use_id)
        // PreToolUse blocks surface as the tool's error result.
        const pre = text.replace(/^\s*<tool_use_error>/, '').match(/^(PreToolUse:[^\s]+) hook error: ([\s\S]*)$/)
        if (pre) {
          events.push({ kind: 'hook-block', hookName: pre[1], command: '', message: pre[2], at, source, turn })
        } else if (leadingSignature(HOOK_SIGNATURES, text)) {
          // A PreToolUse deny can surface as the bare reason.
          events.push({ kind: 'hook-block', hookName: 'PreToolUse', command: '', message: text, at, source, turn })
        } else {
          events.push({ kind: 'tool-error', tool: toolNames.get(b.tool_use_id) ?? '?', message: text, at, source, turn })
        }
      }
    }
  }
  return events
}

export function lastAssistantText(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i]
    if (e.type !== 'assistant') { continue }
    const text = contentBlocks(e).filter((b) => b.type === 'text').map((b) => b.text).join('\n')
    if (text.trim()) { return text }
  }
  return ''
}

// A subagent continued by the controller (a fix round) receives another
// plain user prompt in its transcript. Tool results do not count, and neither
// do harness injections: text opening with "<system-reminder>" or a "[tag]",
// the summary auto-compaction writes (isCompactSummary, isVisibleInTranscriptOnly),
// and isMeta entries such as a forked skill's injected body. A controller's
// SendMessage arrives as isMeta too, but with origin.kind "coordinator".
export function promptCount(entries) {
  let n = 0
  for (const e of entries) {
    if (e.type !== 'user' || e.isCompactSummary || e.isVisibleInTranscriptOnly) { continue }
    if (e.isMeta && e.origin?.kind !== 'coordinator') { continue }
    const c = e.message?.content
    const text = typeof c === 'string'
      ? c
      : Array.isArray(c) && !c.some((b) => b.type === 'tool_result') ? textOf(c.filter((b) => b.type === 'text')) : ''
    if (text.trim() && !/^\s*[<[]/.test(text)) { n++ }
  }
  return n
}

// Wall-clock between first and last entry overstates resumed sessions, so
// count only gaps up to IDLE_GAP_MS as active time.
const IDLE_GAP_MS = 5 * 60 * 1000
export function activeMs(entries) {
  const times = entries.map(ts).filter((t) => t !== null).sort((a, b) => a - b)
  let total = 0
  for (let i = 1; i < times.length; i++) {
    const gap = times[i] - times[i - 1]
    if (gap <= IDLE_GAP_MS) { total += gap }
  }
  return total
}

export function readSubagents(dir) {
  if (!existsSync(dir)) { return [] }
  const out = []
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith('.jsonl')) { continue }
    const id = name.replace(/^agent-/, '').replace(/\.jsonl$/, '')
    const entries = readJsonl(join(dir, name))
    let meta = {}
    const metaPath = join(dir, name.replace(/\.jsonl$/, '.meta.json'))
    if (existsSync(metaPath)) {
      try { meta = JSON.parse(readFileSync(metaPath, 'utf8')) } catch { /* optional */ }
    }
    out.push({
      id,
      description: meta.description ?? '',
      agentType: meta.agentType ?? '',
      entries,
      durationMs: activeMs(entries),
      prompts: promptCount(entries),
      finalText: lastAssistantText(entries),
    })
  }
  return out
}

// ───────────────────────── attribution ─────────────────────────

export function analyze(mainEntries, subagents) {
  const events = [...extractEvents(mainEntries, 'main')]
  for (const s of subagents) { events.push(...extractEvents(s.entries, `subagent:${s.id}`)) }

  const findings = new Map()
  const group = (key, make) => {
    if (!findings.has(key)) { findings.set(key, { turns: new Set(), firstAt: null, sources: new Set(), ...make() }) }
    return findings.get(key)
  }
  // Count distinct turns, not events: see toolTurns in extractEvents.
  let untracked = 0
  const bump = (f, ev) => {
    f.turns.add(ev.turn ?? `untracked-${untracked++}`)
    f.sources.add(ev.source)
    if (ev.at && (!f.firstAt || ev.at < f.firstAt)) { f.firstAt = ev.at }
  }

  for (const ev of events) {
    if (ev.kind === 'hook-block') {
      const script = hookScript(ev.command)
      const sig = signatureFor(ev.message)
      let f
      if (sig) {
        f = group(`block:${sig.id}`, () => ({ pattern: `hook block: ${sig.id}`, owner: sig.owner, ref: `hooks/${sig.hook}`, detail: firstLine(ev.message), threshold: REPEAT_THRESHOLD }))
      } else if (MYSPEC_HOOKS.includes(script)) {
        // A myspec hook block this table does not know yet: count it, but do
        // not guess whose fault it is.
        f = group(`block:${script}:${normalizeError(ev.message)}`, () => ({ pattern: `hook block: ${script}`, owner: 'unknown', ref: `hooks/${script}`, detail: firstLine(ev.message), threshold: REPEAT_THRESHOLD }))
      } else {
        f = group(`block:other:${script || ev.hookName}:${normalizeError(ev.message)}`, () => ({ pattern: `hook block: ${script || ev.hookName}`, owner: script ? 'project' : 'unknown', ref: ev.command || '-', detail: firstLine(ev.message), threshold: REPEAT_THRESHOLD }))
      }
      bump(f, ev)
    } else if (ev.kind === 'hook-error') {
      const hook = hookScript(ev.command)
      const mine = MYSPEC_HOOKS.includes(hook)
      const missing = ev.exitCode === 127 && scriptMissing(hook, ev.message)
      // A myspec hook that exits 127 without its own script missing lacks a
      // command it calls (jq, node): the machine's setup, not the framework.
      const lacksCommand = ev.exitCode === 127 && !missing
      const f = group(`hook-error:${hook || ev.hookName}:${ev.exitCode}:${missing}`, () => ({
        pattern: missing ? `hook not found: ${hook || ev.hookName}` : `hook failed (exit ${ev.exitCode}): ${hook || ev.hookName}`,
        // A registered myspec hook that is missing means this project's
        // install drifted; anything else is the project's own hook.
        owner: mine ? (missing || lacksCommand ? 'setup' : 'myspec') : 'project',
        ref: mine ? `hooks/${hook}` : ev.command || '-',
        detail: missing
          ? (mine ? 'registered in settings but the script is missing: run /myspec:update' : 'registered in settings but the script is missing')
          : lacksCommand
            ? `a command the hook calls is missing: ${firstLine(ev.message) || 'no stderr'}`
            : firstLine(ev.message),
        threshold: 1,
      }))
      bump(f, ev)
    } else if (ev.kind === 'tool-error') {
      const harness = leadingSignature(HARNESS_SIGNATURES, ev.message)
      if (harness) {
        bump(group(`harness:${harness.id}`, () => ({ pattern: `harness refusal: ${harness.id}`, owner: 'harness', ref: '-', detail: firstLine(ev.message), threshold: REPEAT_THRESHOLD })), ev)
        continue
      }
      const f = group(`tool:${ev.tool}:${normalizeError(ev.message)}`, () => ({ pattern: `repeated ${ev.tool} error`, owner: 'unknown', ref: '-', detail: firstLine(ev.message), threshold: REPEAT_THRESHOLD }))
      bump(f, ev)
    }
  }

  for (const s of subagents) {
    const ev = { source: `subagent:${s.id}`, at: s.entries.find((e) => e.timestamp)?.timestamp ?? null }
    for (const st of SUBAGENT_STATUS) {
      if (!st.re.test(s.finalText)) { continue }
      const f = group(`status:${st.id}`, () => ({ pattern: st.id, owner: st.owner, ref: '-', detail: s.description || s.id, threshold: 1 }))
      bump(f, ev)
    }
    const rounds = s.prompts - 1
    if (rounds >= REPEAT_THRESHOLD) {
      const f = group(`rounds:${s.id}`, () => ({ pattern: `subagent continued ${rounds} times`, owner: 'unknown', ref: '-', detail: s.description || s.id, threshold: 1 }))
      bump(f, ev)
    }
  }

  const reported = [...findings.values()]
    .map(({ turns, threshold, sources, ...rest }) => ({ count: turns.size, threshold, ...rest, sources: [...sources].sort() }))
    .filter((f) => f.count >= f.threshold)
    .map((f) => { const rest = { ...f }; delete rest.threshold; return rest })
    .sort((a, b) => OWNER_ORDER.indexOf(a.owner) - OWNER_ORDER.indexOf(b.owner) || b.count - a.count)

  const summary = {
    activeMs: activeMs(mainEntries),
    subagents: subagents.length,
    slowestSubagents: [...subagents]
      .sort((a, b) => b.durationMs - a.durationMs)
      .slice(0, 3)
      .map((s) => ({ id: s.id, description: s.description, durationMs: s.durationMs })),
  }
  return { summary, findings: reported }
}

// ───────────────────────── output ─────────────────────────

function fmtDuration(ms) {
  const m = Math.round(ms / 60000)
  return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m` : `${m}m`
}

// The report is meant to be pasteable, so home-directory paths are shortened.
// Only at a path boundary: with HOME=/Users/jan, /Users/janet stays whole.
const HOME = homedir()
const HOME_RE = HOME && HOME !== '/' ? new RegExp(`${HOME.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?=/|$|[^\\w.-])`, 'g') : null
function cell(s) {
  let out = String(s)
  if (HOME_RE) { out = out.replace(HOME_RE, '~') }
  return out.replace(/\|/g, '\\|').replace(/\n/g, ' ')
}

export function renderText(sessionId, result) {
  const { summary, findings } = result
  if (!findings.length) { return '' }
  const lines = []
  lines.push(`friction-scan: session ${sessionId.slice(0, 8)}, ${fmtDuration(summary.activeMs)} active, ${summary.subagents} subagents`)
  lines.push('')
  lines.push('| Pattern | Owner | Count | Ref | Detail |')
  lines.push('|---|---|---|---|---|')
  for (const f of findings) {
    lines.push(`| ${cell(f.pattern)} | ${f.owner} | ${f.count} | ${cell(f.ref)} | ${cell(f.detail)} |`)
  }
  if (summary.slowestSubagents.length) {
    lines.push('')
    lines.push(`Slowest subagents: ${summary.slowestSubagents.map((s) => `${s.description || s.id} (${fmtDuration(s.durationMs)})`).join('; ')}`)
  }
  const mine = findings.filter((f) => f.owner === 'myspec').length
  const setup = findings.filter((f) => f.owner === 'setup').length
  lines.push('')
  if (mine) { lines.push(`${mine} row(s) look framework-side (owner myspec).`) }
  if (setup) { lines.push(`${setup} row(s) point at this project's myspec install (owner setup): run /myspec:doctor or /myspec:update.`) }
  if (findings.some((f) => f.owner === 'harness')) { lines.push('Rows with owner harness come from Claude Code itself, not myspec or the project.') }
  if (!mine && !setup) { lines.push('No row looks framework-side.') }
  return lines.join('\n') + '\n'
}

// ───────────────────────── cli ─────────────────────────

// .myspec.json lives at the checkout root; session-complete may run from a
// subdirectory. Same lookup as repoRoot() in lib/memory-files.mjs, with git's
// stderr silenced so a run outside git stays quiet and falls back to cwd.
export function projectRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: cwd(), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return resolve(cwd())
  }
}

// feedback.frictionReport through the one settings reader (lib/myspec-config.mjs),
// which also applies the MYSPEC_DISABLE_FRICTION_REPORT session override its
// schema lists. A missing or malformed .myspec.json reads as the default (on).
function disabled(root) {
  return getSetting('feedback.frictionReport', { root, env }).value === false
}

export function findTranscript(projectsDir, sessionId) {
  if (!existsSync(projectsDir)) { return null }
  for (const dir of readdirSync(projectsDir)) {
    const p = join(projectsDir, dir, `${sessionId}.jsonl`)
    if (existsSync(p)) { return p }
  }
  return null
}

async function main() {
  const args = {}
  for (const raw of argv.slice(2)) {
    if (!raw.startsWith('--')) { continue }
    const i = raw.indexOf('=')
    args[i === -1 ? raw.slice(2) : raw.slice(2, i)] = i === -1 ? true : raw.slice(i + 1)
  }

  // Metrics have their own opt-outs and must never fail the caller (a
  // SessionEnd hook), so they take a separate path that always exits 0.
  if (args.emit !== undefined) {
    try {
      const { emitCli } = await import('./metrics.mjs')
      await emitCli(args)
    } catch (err) {
      stderr.write(`friction-scan: metrics not recorded: ${String(err?.message ?? err).split('\n')[0]}\n`)
    }
    exit(0)
  }

  if (disabled(projectRoot())) {
    if (args.json === true) { stdout.write(JSON.stringify({ disabled: true, findings: [] }) + '\n') }
    exit(0)
  }

  let transcript = typeof args.transcript === 'string' ? resolve(args.transcript) : null
  let sessionId = typeof args.session === 'string' ? args.session : null
  if (!transcript && !sessionId) {
    stderr.write('usage: scan.mjs --session=<id> | --transcript=<path> [--projects-dir=<path>] [--json]\n')
    exit(1)
  }
  if (!transcript) {
    const configDir = env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude')
    const projectsDir = typeof args['projects-dir'] === 'string' ? resolve(args['projects-dir']) : join(configDir, 'projects')
    transcript = findTranscript(projectsDir, sessionId)
  }
  if (!transcript || !existsSync(transcript)) {
    stderr.write(`friction-scan: no transcript found for session ${sessionId ?? transcript}\n`)
    exit(2)
  }
  sessionId ??= basename(transcript, '.jsonl')

  const mainEntries = readJsonl(transcript)
  if (!recognized(mainEntries)) {
    stderr.write(`friction-scan: transcript format not recognized: ${transcript}\n`)
    exit(3)
  }
  const subagents = readSubagents(join(dirname(transcript), sessionId, 'subagents'))
  const result = analyze(mainEntries, subagents)

  if (args.json === true) {
    stdout.write(JSON.stringify({ session: sessionId, ...result }, null, 2) + '\n')
  } else {
    stdout.write(renderText(sessionId, result))
  }
}

// Not awaited at top level: metrics.mjs imports this module, and a top-level
// await here would leave it mid-evaluation while main() imports metrics.mjs.
if (import.meta.url === `file://${argv[1]}` || argv[1]?.endsWith('/scan.mjs')) { main() }
