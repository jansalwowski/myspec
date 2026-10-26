#!/usr/bin/env node
// Fold comparison: does a skill's subagent dispatch earn its handoff?
//
// Usage:
//   node scripts/evals/fold-compare.mjs <results-dir>... [--evals-dir evals] [--json]
//   node scripts/evals/fold-compare.mjs --lint [--evals-dir evals]
//
// A fold pair is two cases tagged fold-pair:<name>, one fold-arm:subagent
// (Agent granted, so the skill dispatches) and one fold-arm:inline (Agent not
// granted, so the skill runs its documented inline fallback). They share the
// prompt body, the fixture and the outcome graders: grader files with the same
// name and content in both. A grader only one arm has (the dispatch grader) is
// not an outcome and is left out.
//
// Per model and pair, over the runs in the results dirs (a run that ended in an
// error other than the max_turns cap is left out, as results.mjs does):
//   outcome rate  runs in which every shared grader passed / runs
//   per shared grader, its pass rate in each arm
//   mean cost and duration per run
//
// Verdict per pair (evals/README.md, "Fold pairs"):
//   missing-arm     an arm has no runs
//   keep-subagent   the inline arm's outcome rate is lower
//   fold-candidate  the inline arm scores no worse: the dispatch buys nothing
//                   these graders can see
// Either verdict on fewer than 3 runs in an arm is marked tentative.
//
// --lint checks the pairs in --evals-dir: each fold-pair tag on exactly two
// cases, one per arm, identical prompt bodies, at least one shared grader.
// Exit: 0 report printed or lint clean, 1 lint problems, 2 bad input.

import fs from 'node:fs';
import path from 'node:path';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { BENIGN_ERROR_RE, findAggregates, promptTags } from './results.mjs';

const MIN_RUNS = 3;

const body = (file) => fs.readFileSync(file, 'utf8').replace(/^---\n[\s\S]*?\n---\n/, '').trim();

function graderFiles(dir) {
  const g = path.join(dir, 'graders');
  if (!fs.existsSync(g)) return {};
  return Object.fromEntries(fs.readdirSync(g).filter((f) => f.endsWith('.md'))
    .map((f) => [f.replace(/\.md$/, ''), fs.readFileSync(path.join(g, f), 'utf8')]));
}

// { pairs: { <name>: { subagent, inline, shared: [grader names] } }, problems: [..] }
export function foldPairs(evalsDir) {
  const byPair = {};
  const problems = [];
  for (const e of fs.readdirSync(evalsDir, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name.startsWith('_')) continue;
    const tags = promptTags(path.join(evalsDir, e.name, 'prompt.md'));
    const pairTags = tags.filter((t) => t.startsWith('fold-pair:'));
    const armTags = tags.filter((t) => t.startsWith('fold-arm:'));
    if (pairTags.length === 0 && armTags.length === 0) continue;
    if (pairTags.length !== 1 || armTags.length !== 1) {
      problems.push(`${e.name}: needs exactly one fold-pair:<name> and one fold-arm:<subagent|inline> tag`);
      continue;
    }
    const arm = armTags[0].slice('fold-arm:'.length);
    if (arm !== 'subagent' && arm !== 'inline') {
      problems.push(`${e.name}: fold-arm must be subagent or inline, not ${arm}`);
      continue;
    }
    ((byPair[pairTags[0].slice('fold-pair:'.length)] ??= {})[arm] ??= []).push(e.name);
  }
  const pairs = {};
  for (const [name, arms] of Object.entries(byPair).sort(([a], [b]) => a.localeCompare(b))) {
    if (arms.subagent?.length !== 1 || arms.inline?.length !== 1) {
      problems.push(`fold-pair:${name}: needs one subagent and one inline case, has subagent=[${arms.subagent ?? []}] inline=[${arms.inline ?? []}]`);
      continue;
    }
    const [sub, inl] = [arms.subagent[0], arms.inline[0]];
    if (body(path.join(evalsDir, sub, 'prompt.md')) !== body(path.join(evalsDir, inl, 'prompt.md'))) {
      problems.push(`fold-pair:${name}: ${sub} and ${inl} have different prompts`);
    }
    const gs = graderFiles(path.join(evalsDir, sub));
    const gi = graderFiles(path.join(evalsDir, inl));
    const shared = Object.keys(gs).filter((g) => gi[g] === gs[g]).sort();
    if (shared.length === 0) problems.push(`fold-pair:${name}: ${sub} and ${inl} share no grader`);
    pairs[name] = { subagent: sub, inline: inl, shared };
  }
  return { pairs, problems };
}

// { <model>: { <case>: [ { graders: {name: passed}, cost, duration } ] } }
function loadRuns(dirs) {
  const out = {};
  for (const dir of dirs) {
    for (const file of findAggregates(dir)) {
      const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
      const model = doc.suite?.modelOverride ?? path.basename(path.dirname(file));
      for (const c of doc.cases ?? []) {
        const runs = (c.arms?.with ?? []).filter((r) => !r.error || BENIGN_ERROR_RE.test(String(r.error)));
        const list = ((out[model] ??= {})[c.name] ??= []);
        for (const r of runs) {
          list.push({
            graders: Object.fromEntries((r.graders ?? []).map((g) => [g.name, g.passed === true])),
            cost: (r.costUsd ?? 0) + (r.judgeCostUsd ?? 0),
            duration: r.durationSeconds ?? 0,
          });
        }
      }
    }
  }
  return out;
}

const mean = (xs) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : null);
const r3 = (x) => (x == null ? null : Math.round(x * 1000) / 1000);

function armStats(runs, shared) {
  return {
    runs: runs.length,
    outcome: r3(mean(runs.map((r) => (shared.every((g) => r.graders[g]) ? 1 : 0)))),
    graders: Object.fromEntries(shared.map((g) => [g, r3(mean(runs.map((r) => (r.graders[g] ? 1 : 0))))])),
    cost_usd: r3(mean(runs.map((r) => r.cost))),
    duration_s: r3(mean(runs.map((r) => r.duration))),
  };
}

export function foldCompare(pairs, runsByModel) {
  const out = [];
  for (const [model, cases] of Object.entries(runsByModel).sort(([a], [b]) => a.localeCompare(b))) {
    for (const [name, p] of Object.entries(pairs)) {
      if (!cases[p.subagent] && !cases[p.inline]) continue;
      const subagent = armStats(cases[p.subagent] ?? [], p.shared);
      const inline = armStats(cases[p.inline] ?? [], p.shared);
      let verdict;
      if (subagent.runs === 0 || inline.runs === 0) verdict = 'missing-arm';
      else verdict = inline.outcome < subagent.outcome ? 'keep-subagent' : 'fold-candidate';
      const tentative = verdict !== 'missing-arm' && Math.min(subagent.runs, inline.runs) < MIN_RUNS;
      const flipped = p.shared.filter((g) => subagent.graders[g] !== inline.graders[g] && subagent.runs && inline.runs);
      out.push({ model, pair: name, subagent_case: p.subagent, inline_case: p.inline, verdict, tentative, flipped, subagent, inline });
    }
  }
  return out;
}

function formatText(rows) {
  if (rows.length === 0) return 'no fold-pair case in these results';
  const lines = [];
  for (const r of rows) {
    lines.push(`${r.model}  fold-pair:${r.pair}  ${r.verdict}${r.tentative ? ` (tentative: under ${MIN_RUNS} runs in an arm)` : ''}`);
    for (const arm of ['subagent', 'inline']) {
      const s = r[arm];
      lines.push(`  ${arm.padEnd(8)}  ${r[`${arm}_case`].padEnd(32)}  runs ${s.runs}  outcome ${s.outcome ?? '-'}  cost $${s.cost_usd ?? '-'}  time ${s.duration_s ?? '-'}s`);
    }
    for (const g of r.flipped) lines.push(`  flipped  ${g}: subagent ${r.subagent.graders[g]}, inline ${r.inline.graders[g]}`);
  }
  return lines.join('\n');
}

function main() {
  const argv = process.argv.slice(2);
  let evalsDir = 'evals';
  let json = false;
  let lint = false;
  const dirs = [];
  try {
    for (let i = 0; i < argv.length; i++) {
      const a = argv[i];
      if (a === '--evals-dir') evalsDir = argv[++i];
      else if (a === '--json') json = true;
      else if (a === '--lint') lint = true;
      else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
      else dirs.push(a);
    }
    if (!evalsDir || !fs.existsSync(evalsDir)) throw new Error(`no evals dir ${evalsDir}`);
    const { pairs, problems } = foldPairs(evalsDir);
    if (lint) {
      if (problems.length) {
        process.stdout.write(problems.join('\n') + '\n');
        process.exit(1);
      }
      process.exit(0);
    }
    if (dirs.length === 0) throw new Error('usage: fold-compare.mjs <results-dir>... [--evals-dir evals] [--json] | --lint [--evals-dir evals]');
    for (const p of problems) console.error(`fold-compare: ${p}`);
    const rows = foldCompare(pairs, loadRuns(dirs));
    process.stdout.write((json ? JSON.stringify(rows, null, 2) : formatText(rows)) + '\n');
  } catch (err) {
    console.error(`fold-compare: ${err.message}`);
    process.exit(2);
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
