#!/usr/bin/env node
// Release eval baselines (quality/baselines/v<X.Y.Z>.json) and the trend log
// (quality/trend.jsonl). Called by scripts/evals/release-check.sh.
//
//   write <results-dir> --out <file> --version X.Y.Z --evals-dir <evals/>
//         [--tag T] [--commit SHA] [--source release|rerun]
//         [--model-id alias=<id>|alias=!<why unresolved>]...
//         [--workspaces <workspaces.mjs output>]
//         [--merge-into <file> [--replace-models a,b]]
//       Normalise a run.sh results dir into a baseline file. Its evals block
//       holds, per case that ran: the content hash of its directory (cases),
//       the same hash without case.yaml's generated project-instructions
//       block (inputs), its stability tier (tiers) and, with --workspaces,
//       the hash of the workspace its fixture builds against the plugin that
//       ran (workspaces); plus the hash of evals/_fixtures/. A model whose id
//       could not be resolved is stored with model_id_unresolved: <why>,
//       never a null id. --merge-into keeps that baseline's other models and,
//       for models not in --replace-models, its other cases (a rerun of only
//       the changed cases).
//
//   check <baseline-file> <head-baseline> --evals-dir <evals/> [--models a,b]
//         [--case <glob>] [--cc-match exact|minor] [--workspaces <file>]
//       Can the stored baseline stand in for re-running the previous tag?
//       Prints one line per decision:
//         RERUN <model> <reason>       re-run the whole suite for that model
//         RERUN-CASE <case> <reason>   re-run that case for the reused models
//         REUSE <model> <note>
//         WORKSPACES <reason>          evals/_fixtures/ changed: run again with
//                                      --workspaces, the previous tag's
//                                      workspace hashes with HEAD's evals/
//       Whole-suite rerun: no baseline file, no case hashes in it, the Claude
//       Code version differs (any change; --cc-match minor ignores patch
//       releases), or evals/_fixtures/ changed and the baseline has no
//       workspace hashes. Per model: no results in the baseline, a model id
//       unresolved now or then, or a different resolved id. Per case: its
//       inputs hash differs (its directory hash, for a baseline without
//       inputs hashes), the baseline lacks it, or, after a _fixtures/ change,
//       its workspace hash differs. A case whose only change is its
//       regenerated project-instructions block keeps its stored results
//       (RELEASING.md, "Eval comparison"). Exit 0 on any decision, 2 on bad
//       input.
//
//   trend --head <head-baseline> --out <trend.jsonl> [--compare <compare.json>]
//         [--gate true|false]
//       Append one line (replacing an earlier line for the same version):
//       version, date, per model {pass_rate, pass^k, k, mean_score, cost_usd,
//       duration_s, flaky[]} and the paired delta vs the previous release
//       from compare.mjs --json.
//
//   append --from <file of lines> --out <trend.jsonl>
//       Append each line of --from (same-version lines replaced).
//
//   skip --version X.Y.Z --reason <text> --out <trend.jsonl>
//       Append {"version", "date", "skipped": "<reason>"}.

import fs from 'node:fs';
import path from 'node:path';
import { summarize } from './compare.mjs';
import { caseTiers, evalsHashes, formatBaseline, globToRegExp, loadBaseline, loadResultsDir } from './results.mjs';

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

const list = (s) => (s ? s.split(',').filter(Boolean) : []);
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const pickKeys = (obj, keys) => Object.fromEntries(keys.filter((k) => obj && k in obj).map((k) => [k, obj[k]]));

function write(pos, o) {
  if (pos.length !== 1) throw new Error('write <results-dir> --out <file> --version X.Y.Z --evals-dir <dir>');
  need(o, 'out', 'version', 'evalsDir');
  const set = loadResultsDir(pos[0]);
  for (const m of Object.values(set.models)) m.model_id_unresolved = 'no --model-id given';
  for (const pair of o.modelId) {
    const i = pair.indexOf('=');
    const alias = pair.slice(0, i);
    const id = pair.slice(i + 1);
    const m = set.models[alias];
    if (!m) continue;
    if (id && !id.startsWith('!')) {
      m.model_id = id;
      delete m.model_id_unresolved;
    } else m.model_id_unresolved = id.slice(1) || 'unknown';
  }
  const hashes = evalsHashes(o.evalsDir);
  const ran = [...new Set(Object.values(set.models).flatMap((m) => Object.keys(m.cases)))].filter((c) => c in hashes.cases);
  const evals = {
    fixtures: hashes.fixtures,
    cases: pickKeys(hashes.cases, ran),
    inputs: pickKeys(hashes.inputs, ran),
    tiers: pickKeys(caseTiers(o.evalsDir), ran),
  };
  // Every case's workspace hash, not only the ones that ran: a merge below
  // keeps stored results for the others, and they were built the same way.
  if (o.workspaces) evals.workspaces = readJson(o.workspaces);

  let models = set.models;
  if (o.mergeInto && fs.existsSync(o.mergeInto)) {
    const stored = loadBaseline(o.mergeInto);
    const replace = new Set(list(o.replaceModels));
    models = { ...stored.models };
    for (const [alias, m] of Object.entries(set.models)) {
      const old = stored.models[alias];
      if (replace.has(alias) || !old) {
        models[alias] = m;
        continue;
      }
      const cases = { ...old.cases, ...m.cases };
      models[alias] = {
        ...m,
        cost_usd: Math.round(Object.values(cases).reduce((s, c) => s + c.cost_usd, 0) * 1e4) / 1e4,
        duration_s: (old.duration_s ?? 0) + m.duration_s,
        cases,
      };
    }
    for (const key of ['cases', 'inputs', 'tiers']) evals[key] = { ...(stored.evals?.[key] ?? {}), ...evals[key] };
    if (!evals.workspaces && stored.evals?.workspaces) evals.workspaces = stored.evals.workspaces;
  }
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
    evals,
    models,
  };
  fs.mkdirSync(path.dirname(o.out), { recursive: true });
  fs.writeFileSync(o.out, formatBaseline(doc));
}

function check(pos, o) {
  if (pos.length !== 2) throw new Error('check <baseline-file> <head-baseline> --evals-dir <dir> [--models a,b]');
  need(o, 'evalsDir');
  const head = loadBaseline(pos[1]);
  const models = o.models ? list(o.models) : Object.keys(head.models);
  const all = (reason) => models.map((m) => `RERUN ${m} ${reason}`);
  if (!fs.existsSync(pos[0])) return all(`no stored baseline (${path.basename(pos[0])})`);
  const base = loadBaseline(pos[0]);
  const now = evalsHashes(o.evalsDir);
  if (!base.evals?.cases) return all('baseline has no case hashes');
  if (!base.claude_code || !head.claude_code) {
    return all(`Claude Code version unknown (baseline ${base.claude_code ?? '?'}, now ${head.claude_code ?? '?'})`);
  }
  const ccMatch = o.ccMatch ?? 'exact';
  if (ccMatch === 'minor' ? majorMinor(base.claude_code) !== majorMinor(head.claude_code) : base.claude_code !== head.claude_code) {
    return all(`Claude Code ${base.claude_code} -> ${head.claude_code}${ccMatch === 'minor' ? ' (major.minor changed)' : ''}`);
  }
  // A _fixtures/ change matters only where it changed the workspace a case
  // starts from. Without workspace hashes on both sides, re-run everything.
  let workspaces = null;
  if (base.evals.fixtures !== now.fixtures) {
    if (!base.evals.workspaces) return all('evals/_fixtures/ changed since the baseline, which has no workspace hashes');
    if (!o.workspaces) return ['WORKSPACES evals/_fixtures/ changed since the baseline; compare each case\'s workspace'];
    workspaces = readJson(o.workspaces);
  }
  // Compare inputs hashes when the baseline has them (the generated
  // project-instructions block left out), else whole-directory hashes.
  const [stored, current, what] = base.evals.inputs ? [base.evals.inputs, now.inputs, ' (project instructions aside)'] : [base.evals.cases, now.cases, ''];

  const lines = [];
  let reused = 0;
  for (const m of models) {
    const bm = base.models[m];
    const hm = head.models[m];
    if (!bm) lines.push(`RERUN ${m} baseline has no ${m} results`);
    else if (!hm?.model_id) lines.push(`RERUN ${m} model id not resolved now (${hm?.model_id_unresolved ?? 'unknown'})`);
    else if (!bm.model_id) lines.push(`RERUN ${m} baseline model id was not resolved (${bm.model_id_unresolved ?? 'not recorded'})`);
    else if (bm.model_id !== hm.model_id) lines.push(`RERUN ${m} resolved model ${bm.model_id} -> ${hm.model_id}`);
    else {
      reused++;
      const notes = [`Claude Code ${head.claude_code}`, `model ${hm.model_id}`];
      if ((base.runs ?? 0) < (head.runs ?? 0)) notes.push(`baseline has ${base.runs} run(s) per case, now ${head.runs}`);
      lines.push(`REUSE ${m} ${notes.join('; ')}`);
    }
  }
  if (reused) {
    const re = o.case ? globToRegExp(o.case) : null;
    for (const [c, h] of Object.entries(current).sort()) {
      if (re && !re.test(c)) continue;
      if (!(c in stored)) lines.push(`RERUN-CASE ${c} not in the baseline`);
      else if (stored[c] !== h) lines.push(`RERUN-CASE ${c} evals/${c}/ changed since the baseline${what}`);
      else if (workspaces && (workspaces[c] !== base.evals.workspaces[c] || /^!/.test(workspaces[c] ?? '!'))) {
        // A workspace that failed to build ("!<why>") never counts as unchanged.
        const why = /^!./.test(workspaces[c] ?? '') ? `: ${workspaces[c].slice(1)}` : '';
        lines.push(`RERUN-CASE ${c} its fixture workspace changed since the baseline${why}`);
      }
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
  const tiers = head.evals?.tiers ?? {};
  for (const [alias, m] of Object.entries(head.models)) {
    // pass^k over the gating cases only: capability cases run once.
    const gating = Object.keys(m.cases).filter((c) => tiers[c] !== 'capability');
    const kc = gating.length ? gating : Object.keys(m.cases);
    const k = Math.min(...kc.map((c) => m.cases[c].passed.length));
    const s = summarize(m.cases, k);
    const g = summarize(Object.fromEntries(kc.map((c) => [c, m.cases[c]])), k);
    const c = cmp?.models?.[alias];
    models[alias] = {
      ...(m.model_id ? { model_id: m.model_id } : { model_id_unresolved: m.model_id_unresolved ?? 'not recorded' }),
      cases: s.cases,
      pass_rate: s.pass_rate,
      'pass^k': g.pass_hat_k,
      k,
      capability_cases: Object.keys(m.cases).length - gating.length,
      mean_score: s.mean_score,
      cost_usd: Math.round(m.cost_usd * 100) / 100,
      duration_s: m.duration_s,
      flaky: s.flaky,
      paired_delta_vs_prev: c
        ? { mean: c.mean_delta, ci: c.ci, sign_p: c.sign.p, n: c.n_paired, regressed_cases: c.regressed_cases, verdict: c.verdict }
        : null,
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

function append(o) {
  need(o, 'from', 'out');
  const lines = fs.readFileSync(o.from, 'utf8').split('\n').filter((l) => l.trim());
  if (!lines.length) throw new Error(`${o.from} is empty`);
  for (const l of lines) appendLine(o.out, JSON.parse(l));
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
  else if (cmd === 'append') append(o);
  else if (cmd === 'skip') skip(o);
  else throw new Error('usage: baseline.mjs write|check|trend|append|skip ...');
} catch (err) {
  console.error(`baseline: ${err.message}`);
  process.exit(2);
}
