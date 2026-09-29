// metrics: per-session and per-skill-run field metrics from one finished
// Claude Code session, appended to a local JSONL file. Nothing is sent
// anywhere. Called as `scan.mjs --emit[=<path>]` (by the SessionEnd hook
// hooks/record-session-metrics.sh, or by hand); summarised by stats.mjs.
//
// Records hold names, counts and timestamps only: no prompt, no message, no
// tool input, no file path. The skill name is the one the harness recorded,
// and `feature` is kept only when it names an existing directory under
// ${aiDir}/features/.
//
// Opt-outs, any one of which turns recording off:
//   "feedback": { "metrics": false } in .myspec.json
//   MYSPEC_DISABLE_METRICS=1
//   DO_NOT_TRACK=1 (the cross-tool convention; any value but empty or 0)
//
// Idempotent: every record carries `id` (the session plus the entry that
// opened its window) and `end`. A record whose id and end are already in the
// file is not written again, so re-running on the same session adds nothing;
// a resumed session that grew adds a newer record for the same id, and
// stats.mjs keeps the latest one per id.
//
// Writes are all-or-nothing: every new line goes out in one append call, and
// nothing is written until every record is built.

import { readFileSync, existsSync, statSync, mkdirSync, appendFileSync, openSync, readSync, closeSync } from 'node:fs'
import { join, dirname, basename, resolve } from 'node:path'
import { homedir } from 'node:os'
import { execFileSync } from 'node:child_process'
import { env, stdout, stderr } from 'node:process'
import { readJsonl, readSubagents, extractEvents, blockName, activeMs, projectRoot, findTranscript } from './scan.mjs'

export const SCHEMA = 1

// A transcript larger than this is skipped rather than parsed: the hook runs
// this in the background under a time cap, and a cap-killed run records
// nothing anyway.
export const MAX_TRANSCRIPT_BYTES = 256 * 1024 * 1024

const DISPATCH_TOOLS = new Set(['Agent', 'Task'])

// ───────────────────────── opt-out and location ─────────────────────────

function readConfig(root) {
  const p = join(root, '.myspec.json')
  if (!existsSync(p)) { return null }
  try { return JSON.parse(readFileSync(p, 'utf8')) ?? {} } catch { return {} }
}

// Returns the reason recording is off, or null.
export function metricsDisabled(root, e = env) {
  if (e.MYSPEC_DISABLE_METRICS === '1') { return 'MYSPEC_DISABLE_METRICS=1' }
  const dnt = String(e.DO_NOT_TRACK ?? '').trim()
  if (dnt !== '' && dnt !== '0' && dnt.toLowerCase() !== 'false') { return 'DO_NOT_TRACK' }
  if (readConfig(root)?.feedback?.metrics === false) { return '"feedback.metrics": false in .myspec.json' }
  return null
}

// .claude/state/ belongs to the primary checkout (AGENTS.md: the isolation
// hook pins it there), so a session that ran in a linked worktree records
// into the main checkout's file. Same resolution as mark-code-changed.sh:
// the parent of the common git dir when it is named `.git`, else the
// toplevel (submodules, bare repos), else the directory itself.
export function mainRoot(dir) {
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    if (basename(common) === '.git') { return dirname(common) }
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return resolve(dir)
  }
}

export function defaultRunsPath(root) {
  return join(root, '.claude', 'state', 'metrics', 'runs.jsonl')
}

// ───────────────────────── transcript helpers ─────────────────────────

function ts(entry) {
  const t = Date.parse(entry?.timestamp ?? '')
  return Number.isNaN(t) ? null : t
}

function blocks(entry) {
  const c = entry?.message?.content
  return Array.isArray(c) ? c : []
}

function userText(entry) {
  const c = entry?.message?.content
  if (typeof c === 'string') { return c }
  if (!Array.isArray(c) || c.some((b) => b?.type === 'tool_result')) { return '' }
  return c.filter((b) => b?.type === 'text').map((b) => b.text ?? '').join('\n')
}

// `<command-name>/myspec:feature-plan</command-name>` as the user typed it.
function slashName(entry) {
  if (entry?.type !== 'user' || entry.isMeta) { return null }
  const m = userText(entry).match(/<command-name>\/?([^<\s]+)<\/command-name>/)
  return m ? m[1] : null
}

// A slash command is a skill run when the harness injected a skill body
// after it ("Base directory for this skill: …"), or when it is namespaced
// (plugin skills, `myspec:…`). /clear, /model and the like are neither.
function isSkillSlash(entries, i, name) {
  if (name.includes(':')) { return true }
  for (let j = i + 1; j < Math.min(entries.length, i + 4); j++) {
    const e = entries[j]
    if (e?.type === 'user' && e.isMeta && /^\s*Base directory for this skill:/.test(userText(e))) { return true }
  }
  return false
}

// A turn the user took: a typed prompt or slash command, or a prompt queued
// while the model was working. Tool results and harness injections
// ("<system-reminder>…", "[tag] …", isMeta) are not turns.
function isHumanTurn(entry) {
  if (entry?.type === 'attachment') { return entry.attachment?.type === 'queued_command' }
  if (entry?.type !== 'user' || entry.isMeta) { return false }
  const text = userText(entry)
  if (!text.trim()) { return false }
  return !/^\s*[<[]/.test(text) || /<command-name>/.test(text)
}

function skillArgs(block) {
  const a = block?.input?.args
  return typeof a === 'string' ? a : ''
}

function slashArgs(entry) {
  const m = userText(entry).match(/<command-args>([\s\S]*?)<\/command-args>/)
  return m ? m[1] : ''
}

// The feature a skill ran on, only when its first argument names an existing
// feature directory: a slug from the manifest contract, never free text.
export function featureOf(args, root, aiDir) {
  if (!root || !args) { return null }
  let token = String(args).trim().split(/\s+/)[0] ?? ''
  token = token.replace(/^\.?\/?/, '').replace(new RegExp(`^${aiDir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/features/`), '').replace(/\/+$/, '')
  if (!/^[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)?$/.test(token)) { return null }
  try {
    return statSync(join(root, aiDir, 'features', token)).isDirectory() ? token : null
  } catch {
    return null
  }
}

// Final-line verdicts from myspec's dispatch prompts, on a line of their own
// (same anchoring as scan.mjs), reduced to the verdict word.
export function statusOf(finalText) {
  const text = String(finalText ?? '')
  const probes = text.match(/^\s*(PROBES_(?:PASSED|FAILED|BLOCKED))\s*$/m)
  if (probes) { return probes[1] }
  const st = [...text.matchAll(/^\s*\*\*Status:\*\*\s*([A-Z][A-Z_]{1,29})\s*$/gm)]
  return st.length ? st[st.length - 1][1] : null
}

function emptyTokens() {
  return { in: 0, out: 0, cache_read: 0, cache_write: 0 }
}

function addTokens(into, from) {
  for (const k of Object.keys(into)) { into[k] += from[k] ?? 0 }
  return into
}

// Usage from assistant entries, counted once per message id: one API message
// is written as several transcript entries (one per content block), each
// carrying the same usage.
function tokensOf(entries, seen = new Set()) {
  const t = emptyTokens()
  for (const e of entries) {
    if (e?.type !== 'assistant') { continue }
    const u = e.message?.usage
    if (!u || typeof u !== 'object') { continue }
    const id = e.message?.id ?? e.requestId ?? e.uuid
    if (id) {
      if (seen.has(id)) { continue }
      seen.add(id)
    }
    t.in += Number(u.input_tokens) || 0
    t.out += Number(u.output_tokens) || 0
    t.cache_read += Number(u.cache_read_input_tokens) || 0
    t.cache_write += Number(u.cache_creation_input_tokens) || 0
  }
  return t
}

// MCP tools are counted per server: `mcp__<server>__<tool>` → `mcp__<server>`.
function toolKey(name) {
  const m = String(name).match(/^(mcp__[^_]+(?:_[^_]+)*?)__/)
  return m ? m[1] : String(name)
}

function toolCounts(entries) {
  const seen = new Set()
  const out = {}
  for (const e of entries) {
    if (e?.type !== 'assistant') { continue }
    for (const b of blocks(e)) {
      if (b?.type !== 'tool_use' || seen.has(b.id)) { continue }
      seen.add(b.id)
      const k = toolKey(b.name)
      out[k] = (out[k] ?? 0) + 1
    }
  }
  return out
}

// Hook blocks by name, counting distinct turns (parallel denials in one
// assistant message count once, as in the friction report).
function hookBlocks(events) {
  const turns = new Map()
  for (const ev of events) {
    if (ev.kind !== 'hook-block') { continue }
    const name = blockName(ev)
    if (!turns.has(name)) { turns.set(name, new Set()) }
    turns.get(name).add(ev.turn ?? `${ev.at}`)
  }
  return Object.fromEntries([...turns].map(([k, v]) => [k, v.size]).sort())
}

function mergeCounts(into, from) {
  for (const [k, v] of Object.entries(from)) { into[k] = (into[k] ?? 0) + v }
  return into
}

function sortedObject(o) {
  return Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b)))
}

function iso(t) {
  return t === null ? null : new Date(t).toISOString()
}

function span(entries) {
  const times = entries.map(ts).filter((t) => t !== null)
  return times.length ? [Math.min(...times), Math.max(...times)] : [null, null]
}

// tool_use id → subagent id, from the tool result the harness wrote for an
// Agent/Task call or a forked Skill (`toolUseResult.agentId`).
function agentLinks(entries) {
  const links = new Map()
  for (const e of entries) {
    const agentId = e?.toolUseResult?.agentId
    if (e?.type !== 'user' || typeof agentId !== 'string') { continue }
    for (const b of blocks(e)) {
      if (b?.type === 'tool_result' && b.tool_use_id) { links.set(b.tool_use_id, agentId) }
    }
  }
  return links
}

// ───────────────────────── skill windows ─────────────────────────

// A skill window opens at a skill start and runs to the next start at its
// level, or to the end of the transcript.
//  - `user-slash`: the user typed /skill. Top-level; closes every open window.
//  - `model`: the model called the Skill tool with no top-level window open,
//    or after the user took a turn inside the open one. Top-level.
//  - `nested`: the model called the Skill tool inside an open top-level
//    window before the user took another turn (session-complete calling
//    memory-create). Closes only the previous nested window; the parent keeps
//    running, so a parent's counts include its nested skills.
//  - `subagent`: a Skill call inside a subagent transcript.
// The window therefore also holds any conversation until the next skill
// starts; `turns` shows how much.
export function skillWindows(entries, { inSubagent = false } = {}) {
  const windows = []
  let top = null
  let nested = null
  let promptSinceTop = false
  const seen = new Set()
  const close = (w, i) => { if (w && w.endIdx === null) { w.endIdx = i } }

  for (let i = 0; i < entries.length; i++) {
    const e = entries[i]
    const slash = slashName(e)
    if (slash && isSkillSlash(entries, i, slash)) {
      close(nested, i); close(top, i); nested = null
      top = { skill: slash, trigger: inSubagent ? 'subagent' : 'user-slash', startIdx: i, endIdx: null, args: slashArgs(e), anchor: e.uuid ?? `i${i}` }
      windows.push(top)
      promptSinceTop = false
      continue
    }
    if (isHumanTurn(e)) { promptSinceTop = true; continue }
    if (e?.type !== 'assistant') { continue }
    for (const b of blocks(e)) {
      if (b?.type !== 'tool_use' || b.name !== 'Skill' || seen.has(b.id)) { continue }
      seen.add(b.id)
      const skill = typeof b.input?.skill === 'string' ? b.input.skill.replace(/^\//, '') : '?'
      const w = { skill, startIdx: i, endIdx: null, args: skillArgs(b), anchor: b.id ?? e.uuid ?? `i${i}`, toolUseId: b.id }
      if (inSubagent) {
        close(top, i)
        top = { ...w, trigger: 'subagent' }
        windows.push(top)
      } else if (top && top.endIdx === null && !promptSinceTop) {
        close(nested, i)
        nested = { ...w, trigger: 'nested' }
        windows.push(nested)
      } else {
        close(nested, i); close(top, i); nested = null
        top = { ...w, trigger: 'model' }
        windows.push(top)
        promptSinceTop = false
      }
    }
  }
  for (const w of windows) { close(w, entries.length) }
  return windows
}

// ───────────────────────── records ─────────────────────────

function subagentFacts(s) {
  return {
    tokens: tokensOf(s.entries),
    status: statusOf(s.finalText),
    fixRounds: Math.max(0, s.prompts - 1),
    events: extractEvents(s.entries, `subagent:${s.id}`),
  }
}

function countStatuses(list) {
  const out = {}
  for (const f of list) { if (f.status) { out[f.status] = (out[f.status] ?? 0) + 1 } }
  return sortedObject(out)
}

function lastString(entries, pick) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const v = pick(entries[i])
    if (typeof v === 'string' && v) { return v }
  }
  return null
}

function mainModel(entries) {
  const n = new Map()
  const seen = new Set()
  for (const e of entries) {
    const m = e?.type === 'assistant' ? e.message?.model : null
    const id = e?.message?.id
    if (typeof m !== 'string' || m.startsWith('<') || (id && seen.has(id))) { continue }
    if (id) { seen.add(id) }
    n.set(m, (n.get(m) ?? 0) + 1)
  }
  return [...n].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null
}

// Builds every record for one session. `context` carries what the transcript
// cannot: the project root (for `feature`), aiDir, the framework version and
// the SessionEnd reason.
export function buildRecords(sessionId, mainEntries, subagents, context = {}) {
  const { root = null, aiDir = '.ai', myspec = null, reason = null } = context
  const cc = lastString(mainEntries, (e) => e?.version)
  const facts = new Map(subagents.map((s) => [s.id, subagentFacts(s)]))
  const links = agentLinks(mainEntries)
  const records = []

  // Subagents dispatched by description, for transcripts without agentId links.
  const byDescription = new Map(subagents.filter((s) => s.description).map((s) => [s.description, s.id]))

  const base = (kind, id, entries) => {
    const [start, end] = span(entries)
    return { schema: SCHEMA, kind, id, session: sessionId, myspec, cc, start: iso(start), end: iso(end), active_ms: activeMs(entries) }
  }

  const windowRecord = (w, entries, owner, extraLinks) => {
    const slice = entries.slice(w.startIdx, w.endIdx)
    const linked = new Set()
    let dispatched = 0
    for (const e of slice) {
      if (e?.type !== 'assistant') { continue }
      for (const b of blocks(e)) {
        if (b?.type !== 'tool_use') { continue }
        // Agent/Task calls, plus Skill calls the harness ran as a forked subagent.
        if (DISPATCH_TOOLS.has(b.name) || extraLinks.has(b.id)) { dispatched++ }
        const agent = extraLinks.get(b.id) ?? (DISPATCH_TOOLS.has(b.name) ? byDescription.get(b.input?.description) : undefined)
        if (agent && facts.has(agent)) { linked.add(agent) }
      }
    }
    const subFacts = [...linked].map((id) => facts.get(id))
    const tokens = tokensOf(slice)
    const events = extractEvents(slice, owner)
    for (const f of subFacts) { addTokens(tokens, f.tokens); events.push(...f.events) }
    return {
      ...base('skill', `${sessionId}:${owner === 'main' ? '' : `${owner}:`}${w.anchor}`, slice),
      skill: w.skill,
      trigger: w.trigger,
      feature: featureOf(w.args, root, aiDir),
      turns: slice.slice(1).filter(isHumanTurn).length,
      tools: sortedObject(toolCounts(slice)),
      subagents: dispatched,
      tokens,
      hook_blocks: hookBlocks(events),
      fix_rounds: subFacts.reduce((n, f) => n + f.fixRounds, 0),
      subagent_status: countStatuses(subFacts),
    }
  }

  const mainWindows = skillWindows(mainEntries)
  for (const w of mainWindows) { records.push(windowRecord(w, mainEntries, 'main', links)) }
  for (const s of subagents) {
    for (const w of skillWindows(s.entries, { inSubagent: true })) {
      records.push(windowRecord(w, s.entries, `agent-${s.id}`, agentLinks(s.entries)))
    }
  }

  const allFacts = [...facts.values()]
  const sessionTokens = tokensOf(mainEntries)
  const sessionEvents = extractEvents(mainEntries, 'main')
  const sessionTools = toolCounts(mainEntries)
  for (const f of allFacts) { addTokens(sessionTokens, f.tokens); sessionEvents.push(...f.events) }
  const [start, end] = span([...mainEntries, ...subagents.flatMap((s) => s.entries)])
  records.push({
    ...base('session', `${sessionId}:session`, mainEntries),
    start: iso(start),
    end: iso(end),
    reason,
    model: mainModel(mainEntries),
    turns: mainEntries.filter(isHumanTurn).length,
    skills: records.length,
    tools: sortedObject(sessionTools),
    subagents: subagents.length,
    tokens: sessionTokens,
    hook_blocks: hookBlocks(sessionEvents),
    fix_rounds: allFacts.reduce((n, f) => n + f.fixRounds, 0),
    subagent_status: countStatuses(allFacts),
  })
  // A window with no timestamps has no `end` to key on; it cannot be
  // deduplicated, so it is not recorded.
  return records.filter((r) => r.end !== null)
}

// ───────────────────────── file ─────────────────────────

// The `id@end` keys already recorded for this session. Only lines naming the
// session are parsed, so the cost stays with the file read.
export function recordedKeys(path, sessionId) {
  const keys = new Set()
  if (!existsSync(path)) { return keys }
  const needle = `"session":${JSON.stringify(sessionId)}`
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.includes(needle)) { continue }
    try {
      const r = JSON.parse(line)
      keys.add(`${r.id}@${r.end}`)
    } catch { /* torn line from a killed writer */ }
  }
  return keys
}

function endsWithNewline(path) {
  const size = statSync(path).size
  if (size === 0) { return true }
  const fd = openSync(path, 'r')
  try {
    const buf = Buffer.alloc(1)
    readSync(fd, buf, 0, 1, size - 1)
    return buf[0] === 0x0a
  } finally {
    closeSync(fd)
  }
}

// Appends the records not yet in the file, in one write. A file left without
// a trailing newline (a writer killed mid-line) gets one first, so the torn
// line stays one bad line instead of corrupting the first new one.
export function appendRecords(path, sessionId, records) {
  const have = recordedKeys(path, sessionId)
  const fresh = records.filter((r) => !have.has(`${r.id}@${r.end}`))
  if (!fresh.length) { return { written: 0, skipped: records.length } }
  mkdirSync(dirname(path), { recursive: true })
  const lead = existsSync(path) && !endsWithNewline(path) ? '\n' : ''
  appendFileSync(path, lead + fresh.map((r) => JSON.stringify(r)).join('\n') + '\n')
  return { written: fresh.length, skipped: records.length - fresh.length }
}

// ───────────────────────── cli ─────────────────────────

function note(msg) {
  stderr.write(`friction-scan: metrics not recorded: ${msg}\n`)
}

// args: the parsed scan.mjs flags. Never throws for expected conditions;
// scan.mjs catches the rest.
export function emitCli(args) {
  const here = projectRoot()
  const root = mainRoot(here)
  const off = metricsDisabled(here) ?? (root !== here ? metricsDisabled(root) : null)
  const json = args.json === true
  const done = (result) => { if (json) { stdout.write(JSON.stringify(result) + '\n') } }

  if (off) { return done({ disabled: true, reason: off, written: 0 }) }

  const explicit = typeof args.emit === 'string' && args.emit !== ''
  const config = readConfig(root) ?? readConfig(here)
  // The default location is only written in a myspec project, so a scan run
  // elsewhere does not grow a stray state tree.
  if (!explicit && !config) { note('no .myspec.json at the checkout root'); return done({ written: 0, reason: 'not a myspec project' }) }
  const target = explicit ? resolve(args.emit) : defaultRunsPath(root)

  let transcript = typeof args.transcript === 'string' ? resolve(args.transcript) : null
  let sessionId = typeof args.session === 'string' && args.session ? args.session : null
  if (!transcript && sessionId) {
    const configDir = env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude')
    const projectsDir = typeof args['projects-dir'] === 'string' ? resolve(args['projects-dir']) : join(configDir, 'projects')
    transcript = findTranscript(projectsDir, sessionId)
  }
  if (!transcript || !existsSync(transcript)) { note(`no transcript for ${sessionId ?? args.transcript ?? '(none given)'}`); return done({ written: 0, reason: 'no transcript' }) }
  if (statSync(transcript).size > MAX_TRANSCRIPT_BYTES) { note('transcript over the size limit'); return done({ written: 0, reason: 'too large' }) }
  sessionId ??= basename(transcript, '.jsonl')

  const entries = readJsonl(transcript)
  if (!entries.some((e) => (e?.type === 'user' || e?.type === 'assistant') && e.message)) {
    note('transcript format not recognized'); return done({ written: 0, reason: 'format' })
  }
  const subagents = readSubagents(join(dirname(transcript), sessionId, 'subagents'))
  const aiDir = String(config?.aiDir || '.ai').replace(/\/+$/, '')
  const records = buildRecords(sessionId, entries, subagents, {
    root: config ? root : null,
    aiDir,
    myspec: typeof config?.frameworkVersion === 'string' ? config.frameworkVersion : null,
    reason: typeof args.reason === 'string' && /^[a-z_]{1,32}$/.test(args.reason) ? args.reason : null,
  })
  const result = appendRecords(target, sessionId, records)
  return done({ ...result, path: target })
}

