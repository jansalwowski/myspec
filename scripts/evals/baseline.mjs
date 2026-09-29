#!/usr/bin/env node
// Release eval baselines (quality/baselines/v<X.Y.Z>.json) and the trend log
// (quality/trend.jsonl). Called by scripts/evals/release-check.sh.
//
//   write <results-dir> --out <file> --version X.Y.Z [--tag T] [--commit SHA]
//         [--source release|rerun] [--model-id alias=id]... [--merge-into <file>]
//       Normalise a run.sh results dir into a baseline file. --merge-into keeps
//       that baseline's models that this run did not produce (a partial rerun).
//
//   check <baseline-file> <head-baseline> [--models a,b]
//       Can the stored baseline stand in for re-running the previous tag?
//       Prints one line per model: "REUSE <model> <note>" or
//       "RERUN <model> <reason>". Rerun when the file is missing, the Claude
//       Code major.minor differs, the model has no results in it, or the
//       resolved model id differs. An unknown model id on either side is
//       reused with a note. Exit 0 on any decision, 2 on bad input.
//
//   trend --head <head-baseline> --out <trend.jsonl> [--compare <compare.json>]
//         [--gate true|false]
//       Append one line (replacing an earlier line for the same version):
//       version, date, per model {pass_rate, pass^k, k,
//       mean_score, cost_usd, duration_s, flaky[]} and the paired delta vs
//       the previous release from compare.mjs --json.
//
//   skip --version X.Y.Z --reason <text> --out <trend.jsonl>
//       Append {"version", "date", "skipped": "<reason>"}.

import fs from 'node:fs';
import path from 'node:path';
import { summarize } from './compare.mjs';
import { formatBaseline, loadBaseline, loadResultsDir } from './results.mjs';

const today = () => new Date().toISOString().slice(0, 10);
const majorMinor = (v) => (v ? String(v).split('.').slice(0, 2).join('.') : null);

function parse(argv) {
  const pos = [];
  const o = { modelId: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      pos.push(a);
      continue;
    }
    if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
    const v = argv[++i];
    const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    if (key === 'modelId') o.modelId.push(v);
    else o[key] = v;
  }
  return { pos, o };
}

function need(o, ...keys) {
  for (const k of keys) if (o[k] === undefined) throw new Error(`--${k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())} is required`);
}

function write(pos, o) {
  if (pos.length !== 1) throw new Error('write <results-dir> --out <file> --version X.Y.Z');
  need(o, 'out', 'version');
  const set = loadResultsDir(pos[0]);
  for (const pair of o.modelId) {
    const [alias, id] = pair.split('=');
    if (set.models[alias] && id) set.models[alias].model_id = id;
  }
  let models = set.models;
  if (o.mergeInto && fs.existsSync(o.mergeInto)) models = { ...loadBaseline(o.mergeInto).models, ...set.models };
  const doc = {
    schema: set.schema,
    version: o.version,
    tag: o.tag ?? `v${o.version}`,
    commit: o.commit ?? null,
    date: today(),
    source: o.source ?? 'release',
    claude_code: set.claude_code,
    runs: set.runs,
    judge_model: set.judge_model,
    models,
  };
  fs.mkdirSync(path.dirname(o.out), { recursive: true });
  fs.writeFileSync(o.out, formatBaseline(doc));
}

function check(pos, o) {
  if (pos.length !== 2) throw new Error('check <baseline-file> <head-baseline> [--models a,b]');
  const head = loadBaseline(pos[1]);
  const models = o.models ? o.models.split(',').filter(Boolean) : Object.keys(head.models);
  const lines = [];
  if (!fs.existsSync(pos[0])) {
    for (const m of models) lines.push(`RERUN ${m} no stored baseline (${path.basename(pos[0])})`);
    return lines;
  }
  const base = loadBaseline(pos[0]);
  const bv = majorMinor(base.claude_code);
  const hv = majorMinor(head.claude_code);
  for (const m of models) {
    const bm = base.models[m];
    const hid = head.models[m]?.model_id ?? null;
    if (bv && hv && bv !== hv) {
      lines.push(`RERUN ${m} Claude Code ${base.claude_code} -> ${head.claude_code} (major.minor changed)`);
    } else if (!bv || !hv) {
      lines.push(`RERUN ${m} Claude Code version unknown (baseline ${base.claude_code ?? '?'}, now ${head.claude_code ?? '?'})`);
    } else if (!bm) {
      lines.push(`RERUN ${m} baseline has no ${m} results`);
    } else if (bm.model_id && hid && bm.model_id !== hid) {
      lines.push(`RERUN ${m} resolved model ${bm.model_id} -> ${hid}`);
    } else {
      const notes = [`Claude Code ${base.claude_code} ~ ${head.claude_code}`];
      notes.push(bm.model_id && hid ? `model ${hid}` : 'model id unknown, assumed unchanged');
      if ((base.runs ?? 0) < (head.runs ?? 0)) notes.push(`baseline has ${base.runs} run(s) per case, now ${head.runs}`);
      lines.push(`REUSE ${m} ${notes.join('; ')}`);
    }
  }
  return lines;
}

// Append obj as one line, replacing an earlier line for the same version (a
// re-attempted release records once).
function appendLine(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const kept = fs.existsSync(file)
    ? fs.readFileSync(file, 'utf8').split('\n').filter((l) => {
        if (!l.trim()) return false;
        try {
          return JSON.parse(l).version !== obj.version;
        } catch {
          return true;
        }
      })
    : [];
  fs.writeFileSync(file, [...kept, JSON.stringify(obj)].join('\n') + '\n');
}

function trend(o) {
  need(o, 'head', 'out');
  const head = loadBaseline(o.head);
  const cmp = o.compare && fs.existsSync(o.compare) ? JSON.parse(fs.readFileSync(o.compare, 'utf8')) : null;
  const models = {};
  for (const [alias, m] of Object.entries(head.models)) {
    const k = Math.min(...Object.values(m.cases).map((c) => c.passed.length));
    const s = summarize(m.cases, k);
    const c = cmp?.models?.[alias];
    models[alias] = {
      model_id: m.model_id ?? null,
      cases: s.cases,
      pass_rate: s.pass_rate,
      'pass^k': s.pass_hat_k,
      k,
      mean_score: s.mean_score,
      cost_usd: Math.round(m.cost_usd * 100) / 100,
      duration_s: m.duration_s,
      flaky: s.flaky,
      paired_delta_vs_prev: c ? { mean: c.mean_delta, ci: c.ci, sign_p: c.sign.p, n: c.n_paired, verdict: c.verdict } : null,
    };
  }
  appendLine(o.out, {
    version: head.version,
    date: today(),
    claude_code: head.claude_code,
    runs: head.runs,
    vs: cmp?.old?.label ?? null,
    verdict: cmp?.verdict ?? null,
    gate: o.gate === undefined ? null : o.gate === 'true',
    models,
  });
}

function skip(o) {
  need(o, 'version', 'reason', 'out');
  appendLine(o.out, { version: o.version, date: today(), skipped: o.reason });
}

try {
  const [cmd, ...rest] = process.argv.slice(2);
  const { pos, o } = parse(rest);
  if (cmd === 'write') write(pos, o);
  else if (cmd === 'check') console.log(check(pos, o).join('\n'));
  else if (cmd === 'trend') trend(o);
  else if (cmd === 'skip') skip(o);
  else throw new Error('usage: baseline.mjs write|check|trend|skip ...');
} catch (err) {
  console.error(`baseline: ${err.message}`);
  process.exit(2);
}
