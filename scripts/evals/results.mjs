// Load eval results into one normalised shape, shared by compare.mjs and
// baseline.mjs. Zero dependencies (node 20).
//
// A "result set" is either
//   - a results directory written by run.sh: every aggregate-result.json below
//     it, grouped by the model it ran (suite.modelOverride), or
//   - a baseline file (quality/baselines/v<X.Y.Z>.json) written by baseline.mjs.
//
// Normalised set:
//   { schema: 1, version?, tag?, commit?, date?, source?, claude_code, runs,
//     judge_model, models: { <alias>: { model_id, cost_usd, duration_s,
//       cases: { <case>: { scores: [..], passed: [..], cost_usd, duration_s } } } } }
//
// A run passes when every scored grader passed (graders with scored: false are
// plugin-fired indicators under --ablation with-without and do not count).

import fs from 'node:fs';
import path from 'node:path';

export const SCHEMA = 1;

function findAggregates(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...findAggregates(p));
    else if (e.name === 'aggregate-result.json') out.push(p);
  }
  return out.sort();
}

export function runPassed(run) {
  const scored = (run.graders ?? []).filter((g) => g.scored !== false);
  if (scored.length === 0) return Boolean(run.passed ?? (run.score ?? 0) >= 1);
  return scored.every((g) => g.passed === true);
}

const round = (x, d = 4) => (x == null || Number.isNaN(x) ? x : Math.round(x * 10 ** d) / 10 ** d);

// Fold one aggregate-result.json into set (mutates it).
function addAggregate(set, file) {
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`unreadable ${file}: ${err.message}`);
  }
  if (doc.partial) throw new Error(`${file} is partial (${doc.partialReason ?? 'unknown reason'})`);
  const alias = doc.suite?.modelOverride ?? path.basename(path.dirname(file));
  const m = (set.models[alias] ??= { model_id: null, cost_usd: 0, duration_s: 0, cases: {} });
  m.duration_s += doc.durationSeconds ?? 0;
  if (doc.claudeVersion) set.claude_code ??= doc.claudeVersion;
  if (doc.suite?.judgeModel) set.judge_model ??= doc.suite.judgeModel;
  for (const c of doc.cases ?? []) {
    const runs = c.arms?.with ?? [];
    const entry = (m.cases[c.name] ??= { scores: [], passed: [], cost_usd: 0, duration_s: 0 });
    for (const r of runs) {
      entry.scores.push(round(r.score ?? 0));
      entry.passed.push(runPassed(r));
      const cost = (r.costUsd ?? 0) + (r.judgeCostUsd ?? 0);
      entry.cost_usd = round(entry.cost_usd + cost);
      entry.duration_s += r.durationSeconds ?? 0;
    }
    set.runs = Math.max(set.runs ?? 0, runs.length);
  }
  m.cost_usd = round(Object.values(m.cases).reduce((s, c) => s + c.cost_usd, 0));
}

export function loadResultsDir(dir) {
  const files = findAggregates(dir);
  if (files.length === 0) throw new Error(`no aggregate-result.json under ${dir}`);
  const set = { schema: SCHEMA, claude_code: null, runs: 0, judge_model: null, models: {} };
  for (const f of files) addAggregate(set, f);
  return set;
}

export function loadBaseline(file) {
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`unreadable baseline ${file}: ${err.message}`);
  }
  if (doc.schema !== SCHEMA || typeof doc.models !== 'object') {
    throw new Error(`${file} is not a schema ${SCHEMA} baseline`);
  }
  return doc;
}

export function loadSet(p) {
  if (!fs.existsSync(p)) throw new Error(`not found: ${p}`);
  return fs.statSync(p).isDirectory() ? loadResultsDir(p) : loadBaseline(p);
}

// Shell glob (*, ?, [...] and [!...]) to an anchored RegExp, as run.sh's --case matches.
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i];
    const close = ch === '[' ? glob.indexOf(']', i + 2) : -1;
    if (ch === '*') re += '.*';
    else if (ch === '?') re += '.';
    else if (close > 0) {
      const body = glob.slice(i + 1, close).replace(/^!/, '^').replace(/\\/g, '\\\\');
      re += `[${body}]`;
      i = close;
    } else re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

// Keep only cases whose name matches the glob.
export function filterCases(set, glob) {
  if (!glob) return set;
  const re = globToRegExp(glob);
  const out = structuredClone(set);
  for (const m of Object.values(out.models)) {
    for (const name of Object.keys(m.cases)) if (!re.test(name)) delete m.cases[name];
  }
  return out;
}

// Baseline JSON with one line per case, so a diff between releases reads per case.
export function formatBaseline(set) {
  const head = { ...set, models: undefined };
  const lines = ['{'];
  for (const [k, v] of Object.entries(head)) {
    if (v !== undefined) lines.push(`  ${JSON.stringify(k)}: ${JSON.stringify(v)},`);
  }
  lines.push('  "models": {');
  const models = Object.entries(set.models);
  models.forEach(([alias, m], i) => {
    lines.push(`    ${JSON.stringify(alias)}: {`);
    lines.push(`      "model_id": ${JSON.stringify(m.model_id ?? null)},`);
    lines.push(`      "cost_usd": ${JSON.stringify(round(m.cost_usd, 4))},`);
    lines.push(`      "duration_s": ${JSON.stringify(m.duration_s)},`);
    lines.push('      "cases": {');
    const cases = Object.entries(m.cases).sort(([a], [b]) => a.localeCompare(b));
    cases.forEach(([name, c], j) => {
      lines.push(`        ${JSON.stringify(name)}: ${JSON.stringify(c)}${j < cases.length - 1 ? ',' : ''}`);
    });
    lines.push('      }');
    lines.push(`    }${i < models.length - 1 ? ',' : ''}`);
  });
  lines.push('  }');
  lines.push('}');
  return lines.join('\n') + '\n';
}
