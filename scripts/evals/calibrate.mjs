#!/usr/bin/env node
// Monte Carlo calibration of compare.mjs's verdict rule: how often does it
// cry "regressed" when nothing changed (A/A), and how often does it catch
// cases that broke? Seeded, so the numbers are reproducible.
//
// Usage: node scripts/evals/calibrate.mjs [--trials N] [--json]
//
// A simulated case is a list of per-grader pass probabilities; a run's score
// is the fraction of graders passed and the run passes when all of them do.
// 15 cases, 3 runs each (the release suite). Scenarios:
//   sonnet        12 stable cases (graders 0.995), 1 flaky (0.93), 2 that
//                 always fail one grader (the capability cases)
//   sonnet-flaky3 as sonnet, but 3 flaky cases
//   haiku         graders 0.55 .. 0.95 across the 15 cases
//   haiku-low     graders 0.45 .. 0.80
// A/A compares a scenario with a fresh sample of itself. "break N" makes N
// cases fail one grader on every run (a skill that stopped triggering).
// RELEASING.md records the output; scripts/tests/eval-compare.test.sh holds
// the bounds.

import { DEFAULTS, compareModel, mulberry32 } from './compare.mjs';

const args = process.argv.slice(2);
const trials = Number(args[args.indexOf('--trials') + 1] || 1000) || 1000;
const R = mulberry32(12345);

// mode 'fixed': 3 runs per case. 'adaptive': 1 run, and 2 more when it failed
// (run.sh --adaptive-models).
function sample(spec, mode = 'fixed') {
  const cases = {};
  spec.forEach((q, i) => {
    const scores = [];
    const passed = [];
    const run = () => {
      const g = q.map((p) => R() < p);
      scores.push(Math.round((g.filter(Boolean).length / g.length) * 1e4) / 1e4);
      passed.push(g.every(Boolean));
    };
    run();
    if (mode === 'fixed' || !passed[0]) { run(); run(); }
    cases[`c${String(i).padStart(2, '0')}`] = { scores, passed };
  });
  return { cases };
}

const stable = [0.995, 0.995, 0.995];
const capability = [0.995, 0.995, 0];
const flaky = [0.93, 0.93, 0.93];
const sonnet = [...Array(12).fill(stable), flaky, capability, capability];
const sonnetFlaky3 = [...Array(10).fill(stable), ...Array(3).fill(flaky), capability, capability];
const sonnetFlaky5 = [...Array(8).fill(stable), ...Array(5).fill([0.9, 0.9, 0.9]), capability, capability];
const ramp = (lo, hi) => Array.from({ length: 15 }, (_, i) => lo + ((hi - lo) * i) / 14).map((p) => [p, p, p]);
const haiku = ramp(0.55, 0.95);
const haikuLow = ramp(0.45, 0.8);
const brk = (spec, idx) => spec.map((q, i) => (idx.includes(i) ? [q[0], q[1], 0] : q));

export const SCENARIOS = [
  ['sonnet A/A', sonnet, sonnet],
  ['sonnet-flaky3 A/A', sonnetFlaky3, sonnetFlaky3],
  ['haiku A/A', haiku, haiku],
  ['haiku-low A/A', haikuLow, haikuLow],
  ['sonnet break 1', sonnet, brk(sonnet, [0])],
  ['sonnet break 2', sonnet, brk(sonnet, [0, 1])],
  ['sonnet break 3', sonnet, brk(sonnet, [0, 1, 2])],
  ['haiku break 2', haiku, brk(haiku, [13, 14])],
  ['haiku break 3', haiku, brk(haiku, [12, 13, 14])],
  // Adaptive runs (the gated model, "adaptiveModels"): both sides adaptive,
  // and "first" for the release that switches, against a 3-run baseline.
  ['adaptive sonnet A/A', sonnet, sonnet, 'adaptive', 'adaptive'],
  ['adaptive sonnet-flaky3 A/A', sonnetFlaky3, sonnetFlaky3, 'adaptive', 'adaptive'],
  ['adaptive sonnet-flaky5 A/A', sonnetFlaky5, sonnetFlaky5, 'adaptive', 'adaptive'],
  ['adaptive sonnet break 1', sonnet, brk(sonnet, [0]), 'adaptive', 'adaptive'],
  ['adaptive sonnet break 2', sonnet, brk(sonnet, [0, 1]), 'adaptive', 'adaptive'],
  ['adaptive sonnet break 3', sonnet, brk(sonnet, [0, 1, 2]), 'adaptive', 'adaptive'],
  ['first adaptive sonnet A/A', sonnet, sonnet, 'fixed', 'adaptive'],
  ['first adaptive break 2', sonnet, brk(sonnet, [0, 1]), 'fixed', 'adaptive'],
];

const out = {};
for (const [name, a, b, ma, mb] of SCENARIOS) {
  let reg = 0;
  for (let t = 0; t < trials; t++) if (compareModel(sample(a, ma), sample(b, mb), DEFAULTS).verdict === 'regressed') reg++;
  out[name] = Math.round((1000 * reg) / trials) / 10;
}
if (args.includes('--json')) console.log(JSON.stringify(out));
else for (const [name, pct] of Object.entries(out)) console.log(`${name.padEnd(28)} regressed ${pct.toFixed(1)}%  (${trials} trials)`);
