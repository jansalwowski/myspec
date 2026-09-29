#!/usr/bin/env node
// Compare two eval result sets case by case: did the plugin regress?
//
// Usage:
//   node scripts/evals/compare.mjs <old> <new> [--json] [--k N] [--seed N]
//        [--resamples N] [--pass-k-margin X] [--case <glob>]
//        [--old-label L] [--new-label L]
//
// <old> and <new> are each a run.sh results directory or a baseline file
// (quality/baselines/v<X.Y.Z>.json); see results.mjs. Per model present in
// both, over the cases present in both (paired cases):
//
//   per-case mean score, old and new, and the paired difference new - old
//   mean paired delta with a paired-bootstrap 95% CI: resample the paired
//     differences with replacement, --resamples times (default 10000), with a
//     seeded mulberry32 RNG (default seed 42), so the output is deterministic;
//     CI = [sorted[floor(0.025 B)], sorted[ceil(0.975 B) - 1]]
//   sign test: exact two-sided binomial p over non-tied differences
//   pass@k = 1 - C(n-c,k)/C(n,k) and pass^k = C(c,k)/C(n,k) per case, averaged
//     over paired cases; n runs, c passing runs (every scored grader passed),
//     k = --k or the fewest runs any paired case has
//   flaky cases: mixed pass/fail across runs
//   cases in only one set: listed, excluded from every paired statistic
//
// Verdict per model:
//   regressed  CI upper bound < 0, or pass^k dropped by more than
//              --pass-k-margin (default 0.10: with 15 cases one case losing
//              pass^k is 0.067 and tolerated, two are 0.133 and are not)
//   improved   CI lower bound > 0 and not regressed
//   no-change  otherwise
// Overall verdict: regressed if any model regressed, else improved if any
// improved, else no-change.
//
// Exit status: 0 improved or no-change · 1 regressed · 2 bad input
// (unreadable set, no model or no case in common, --k above the run count).

import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { filterCases, loadSet } from './results.mjs';

export const DEFAULTS = { seed: 42, resamples: 10000, passKMargin: 0.1 };

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function choose(n, k) {
  if (k < 0 || k > n) return 0;
  let r = 1;
  for (let i = 1; i <= k; i++) r = (r * (n - k + i)) / i;
  return Math.round(r);
}

export const passAtK = (n, c, k) => (n - c < k ? 1 : 1 - choose(n - c, k) / choose(n, k));
export const passHatK = (n, c, k) => choose(c, k) / choose(n, k);

const mean = (xs) => xs.reduce((s, x) => s + x, 0) / xs.length;
const EPS = 1e-9;

export function bootstrapCI(diffs, { seed, resamples }) {
  const n = diffs.length;
  const rng = mulberry32(seed);
  const means = new Array(resamples);
  for (let b = 0; b < resamples; b++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += diffs[Math.floor(rng() * n)];
    means[b] = s / n;
  }
  means.sort((x, y) => x - y);
  return [means[Math.floor(0.025 * resamples)], means[Math.ceil(0.975 * resamples) - 1]];
}

export function signTest(diffs) {
  const pos = diffs.filter((d) => d > EPS).length;
  const neg = diffs.filter((d) => d < -EPS).length;
  const m = pos + neg;
  let p = 1;
  if (m > 0) {
    let tail = 0;
    for (let i = 0; i <= Math.min(pos, neg); i++) tail += choose(m, i);
    p = Math.min(1, (2 * tail) / 2 ** m);
  }
  return { pos, neg, ties: diffs.length - m, p };
}

const r4 = (x) => Math.round(x * 1e4) / 1e4;
const countPassed = (c) => c.passed.filter(Boolean).length;
const isFlaky = (c) => c.passed.some(Boolean) && !c.passed.every(Boolean);

// Summary of one model's cases in one set (used for each side and the trend line).
export function summarize(cases, k) {
  const names = Object.keys(cases).sort();
  const runs = names.flatMap((n) => cases[n].passed);
  return {
    cases: names.length,
    k,
    mean_score: r4(mean(names.map((n) => mean(cases[n].scores)))),
    pass_rate: r4(runs.filter(Boolean).length / runs.length),
    pass_at_k: r4(mean(names.map((n) => passAtK(cases[n].passed.length, countPassed(cases[n]), k)))),
    pass_hat_k: r4(mean(names.map((n) => passHatK(cases[n].passed.length, countPassed(cases[n]), k)))),
    flaky: names.filter((n) => isFlaky(cases[n])),
  };
}

export function compareModel(oldM, newM, opts) {
  const oldNames = Object.keys(oldM.cases);
  const newNames = Object.keys(newM.cases);
  const paired = oldNames.filter((n) => n in newM.cases).sort();
  const onlyOld = oldNames.filter((n) => !(n in newM.cases)).sort();
  const onlyNew = newNames.filter((n) => !(n in oldM.cases)).sort();
  if (paired.length === 0) throw new Error('no cases in common');
  const minRuns = Math.min(...paired.flatMap((n) => [oldM.cases[n].passed.length, newM.cases[n].passed.length]));
  const k = opts.k ?? minRuns;
  if (!(k >= 1) || k > minRuns) throw new Error(`k=${k} but some paired case has only ${minRuns} run(s)`);

  const cases = paired.map((name) => {
    const o = oldM.cases[name];
    const n = newM.cases[name];
    const oldMean = mean(o.scores);
    const newMean = mean(n.scores);
    return { name, old_mean: oldMean, new_mean: newMean, diff: newMean - oldMean, old_passed: o.passed, new_passed: n.passed };
  });
  const diffs = cases.map((c) => c.diff);
  const ci = bootstrapCI(diffs, opts);
  const pick = (m) => Object.fromEntries(paired.map((n) => [n, m.cases[n]]));
  const oldS = summarize(pick(oldM), k);
  const newS = summarize(pick(newM), k);

  const reasons = [];
  let verdict = 'no-change';
  if (ci[1] < -EPS) reasons.push(`paired-delta 95% CI [${fmt(ci[0])}, ${fmt(ci[1])}] lies entirely below 0`);
  const drop = oldS.pass_hat_k - newS.pass_hat_k;
  if (drop > opts.passKMargin + EPS) {
    reasons.push(`pass^${k} dropped ${oldS.pass_hat_k.toFixed(2)} -> ${newS.pass_hat_k.toFixed(2)}, more than the ${opts.passKMargin} margin`);
  }
  if (reasons.length) verdict = 'regressed';
  else if (ci[0] > EPS) {
    verdict = 'improved';
    reasons.push(`paired-delta 95% CI [${fmt(ci[0])}, ${fmt(ci[1])}] lies entirely above 0`);
  }

  return {
    verdict,
    reasons,
    k,
    n_paired: paired.length,
    mean_delta: r4(mean(diffs)),
    ci: [r4(ci[0]), r4(ci[1])],
    sign: (({ pos, neg, ties, p }) => ({ pos, neg, ties, p: r4(p) }))(signTest(diffs)),
    old: oldS,
    new: newS,
    only_old: onlyOld,
    only_new: onlyNew,
    cases: cases.map((c) => ({ ...c, old_mean: r4(c.old_mean), new_mean: r4(c.new_mean), diff: r4(c.diff) })),
  };
}

export function compare(oldSet, newSet, options = {}) {
  const opts = { ...DEFAULTS, ...options };
  const oldModels = Object.keys(oldSet.models);
  const newModels = Object.keys(newSet.models);
  const common = oldModels.filter((m) => newModels.includes(m));
  if (common.length === 0) throw new Error(`no model in common (old: ${oldModels.join(',') || '-'}; new: ${newModels.join(',') || '-'})`);
  const models = {};
  for (const m of common) {
    try {
      models[m] = compareModel(oldSet.models[m], newSet.models[m], opts);
    } catch (err) {
      throw new Error(`${m}: ${err.message}`);
    }
  }
  const verdicts = Object.values(models).map((r) => r.verdict);
  const verdict = verdicts.includes('regressed') ? 'regressed' : verdicts.includes('improved') ? 'improved' : 'no-change';
  return {
    verdict,
    seed: opts.seed,
    resamples: opts.resamples,
    pass_k_margin: opts.passKMargin,
    old: { label: opts.oldLabel ?? null, claude_code: oldSet.claude_code ?? null },
    new: { label: opts.newLabel ?? null, claude_code: newSet.claude_code ?? null },
    only_old_models: oldModels.filter((m) => !newModels.includes(m)),
    only_new_models: newModels.filter((m) => !oldModels.includes(m)),
    models,
  };
}

function fmt(x, d = 3) {
  const s = x.toFixed(d);
  return x >= 0 ? `+${s}` : s;
}
const pf = (passed) => passed.map((p) => (p ? 'P' : 'F')).join('');

export function formatText(res) {
  const out = [];
  const side = (s) => `${s.label ?? '?'}${s.claude_code ? ` (Claude Code ${s.claude_code})` : ''}`;
  out.push(`Eval comparison: ${side(res.old)} -> ${side(res.new)}`);
  out.push(`paired bootstrap ${res.resamples} resamples, seed ${res.seed} · pass^k margin ${res.pass_k_margin}`);
  for (const [model, r] of Object.entries(res.models)) {
    out.push('', `== ${model}: ${r.verdict} ==`);
    const rows = [['CASE', 'OLD', 'NEW', 'DIFF', 'OLD RUNS', 'NEW RUNS']];
    for (const c of r.cases) rows.push([c.name, c.old_mean.toFixed(2), c.new_mean.toFixed(2), fmt(c.diff, 2), pf(c.old_passed), pf(c.new_passed)]);
    const w = rows[0].map((_, i) => Math.max(...rows.map((row) => row[i].length)));
    for (const row of rows) out.push(row.map((v, i) => v.padEnd(w[i])).join('  ').trimEnd());
    out.push(
      `paired cases ${r.n_paired} · mean delta ${fmt(r.mean_delta)}  95% CI [${fmt(r.ci[0])}, ${fmt(r.ci[1])}]` +
        ` · sign test +${r.sign.pos}/-${r.sign.neg} (${r.sign.ties} ties) p=${r.sign.p.toFixed(4)}`,
    );
    out.push(
      `pass@${r.k} ${r.old.pass_at_k.toFixed(2)} -> ${r.new.pass_at_k.toFixed(2)} · pass^${r.k} ${r.old.pass_hat_k.toFixed(2)} -> ${r.new.pass_hat_k.toFixed(2)}` +
        ` · mean score ${r.old.mean_score.toFixed(2)} -> ${r.new.mean_score.toFixed(2)}`,
    );
    out.push(`flaky: old [${r.old.flaky.join(', ')}] · new [${r.new.flaky.join(', ')}]`);
    if (r.only_old.length) out.push(`only in old (excluded): ${r.only_old.join(', ')}`);
    if (r.only_new.length) out.push(`only in new (excluded): ${r.only_new.join(', ')}`);
    for (const reason of r.reasons) out.push(`  ${reason}`);
  }
  if (res.only_old_models.length) out.push('', `models only in old (not compared): ${res.only_old_models.join(', ')}`);
  if (res.only_new_models.length) out.push('', `models only in new (not compared): ${res.only_new_models.join(', ')}`);
  out.push('', `Verdict: ${res.verdict}`);
  return out.join('\n');
}

function parseArgs(argv) {
  const pos = [];
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    const num = () => {
      const v = Number(val());
      if (!Number.isFinite(v)) throw new Error(`${a} needs a number`);
      return v;
    };
    if (a === '--json') o.json = true;
    else if (a === '--k') o.k = num();
    else if (a === '--seed') o.seed = num();
    else if (a === '--resamples') o.resamples = num();
    else if (a === '--pass-k-margin') o.passKMargin = num();
    else if (a === '--case') o.caseGlob = val();
    else if (a === '--old-label') o.oldLabel = val();
    else if (a === '--new-label') o.newLabel = val();
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else pos.push(a);
  }
  if (pos.length !== 2) throw new Error('usage: compare.mjs <old> <new> [--json] [--k N] [--seed N] [--resamples N] [--pass-k-margin X] [--case glob]');
  return { pos, o };
}

function main() {
  let res;
  try {
    const { pos, o } = parseArgs(process.argv.slice(2));
    const oldSet = filterCases(loadSet(pos[0]), o.caseGlob);
    const newSet = filterCases(loadSet(pos[1]), o.caseGlob);
    const opts = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
    res = compare(oldSet, newSet, { ...opts, oldLabel: o.oldLabel ?? pos[0], newLabel: o.newLabel ?? pos[1] });
    process.stdout.write((o.json ? JSON.stringify(res, null, 2) : formatText(res)) + '\n');
  } catch (err) {
    console.error(`compare: ${err.message}`);
    process.exit(2);
  }
  process.exit(res.verdict === 'regressed' ? 1 : 0);
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
