#!/usr/bin/env node
// Summarise every aggregate-result.json under a results dir written by run.sh.
//
// Usage: node scripts/evals/summary.mjs <results-dir> <threshold>
//
// Prints one row per case per model:
//   CASE  MODEL  SCORE  FIRED  WRONG  ERRORS  COST  TIME  NOTES
// FIRED  = runs in which every "right skill" Skill grader passed (tool_used Skill, no max: 0)
// WRONG  = runs in which any sibling grader (tool_used Skill with max: 0) failed
// COST   = agent runs plus judge calls (aggregate-result.json's top-level
//          costUsd leaves the judge out). Scores come from the with-plugin arm.
//
// SCORE  = mean over the with-arm runs that ended cleanly. A run that ended
//          in an error (API unreachable, timeout, usage limit, ...) is left out
//          of SCORE, FIRED and WRONG: its graders read an empty or truncated
//          transcript, where every max: 0 grader passes by default. Hitting
//          max_turns is not such an error: trigger cases cap turns on purpose
//          and are graded on what the capped run did.
//
// Exit status: 0 all cases at or above threshold, 1 some case below it,
// 2 no readable result, a partial run, or any run that ended in an error
// (its score says nothing about the plugin).

import fs from 'node:fs';
import path from 'node:path';

const [dir, thresholdArg] = process.argv.slice(2);
const threshold = Number(thresholdArg ?? '0.8');
if (!dir || Number.isNaN(threshold)) {
  console.error('usage: summary.mjs <results-dir> <threshold>');
  process.exit(2);
}

function findResults(d) {
  const out = [];
  if (!fs.existsSync(d)) return out;
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) out.push(...findResults(p));
    else if (e.name === 'aggregate-result.json') out.push(p);
  }
  return out.sort();
}

const BENIGN_ERROR_RE = /maximum number of turns/i;
const files = findResults(dir);
if (files.length === 0) {
  console.error(`summary: no aggregate-result.json under ${dir}`);
  process.exit(2);
}

const rows = [];
let below = 0;
let infra = 0;
let totalCost = 0;
for (const f of files) {
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch (err) {
    console.error(`summary: unreadable ${f}: ${err.message}`);
    infra++;
    continue;
  }
  if (doc.partial) {
    console.error(`summary: ${f} is partial (${doc.partialReason ?? 'unknown reason'})`);
    infra++;
  }
  const model = doc.suite?.modelOverride ?? '-';
  for (const c of doc.cases ?? []) {
    const skillGraders = (c.graders ?? []).filter((g) => g.type === 'tool_used' && g.config?.tool === 'Skill');
    const sibling = new Set(skillGraders.filter((g) => g.config?.max === 0).map((g) => g.name));
    const right = new Set(skillGraders.filter((g) => g.config?.max !== 0).map((g) => g.name));
    const allRuns = c.arms?.with ?? [];
    const runs = allRuns.filter((r) => !r.error || BENIGN_ERROR_RE.test(String(r.error)));
    const errored = allRuns.length - runs.length;
    for (const r of Object.values(c.arms ?? {}).flat()) totalCost += (r.costUsd ?? 0) + (r.judgeCostUsd ?? 0);
    let fired = 0;
    let wrong = 0;
    let cost = 0;
    let secs = 0;
    const notes = new Set();
    for (const r of allRuns) {
      cost += (r.costUsd ?? 0) + (r.judgeCostUsd ?? 0);
      secs += r.durationSeconds ?? 0;
      if (r.error) notes.add(`error: ${String(r.error).slice(0, 60)}`);
    }
    if (errored) infra++;
    for (const r of runs) {
      const byName = Object.fromEntries((r.graders ?? []).map((g) => [g.name, g]));
      if (right.size && [...right].every((n) => byName[n]?.passed)) fired++;
      if ([...sibling].some((n) => byName[n] && !byName[n].passed)) wrong++;
      for (const g of r.graders ?? []) {
        if (!g.passed && g.scored !== false && !right.has(g.name) && !sibling.has(g.name)) notes.add(g.name);
      }
    }
    const score = runs.length ? runs.reduce((a, r) => a + (r.score ?? 0), 0) / runs.length : null;
    if (score !== null && score < threshold) below++;
    rows.push({
      case: c.name,
      model,
      score: score === null ? 'error' : score.toFixed(2),
      fired: right.size ? `${fired}/${runs.length}` : '-',
      wrong: sibling.size ? `${wrong}/${runs.length}` : '-',
      errors: errored ? `${errored}/${allRuns.length}` : '-',
      cost: `$${cost.toFixed(2)}`,
      time: `${secs}s`,
      notes: [...notes].join(', '),
    });
  }
}

const cols = ['case', 'model', 'score', 'fired', 'wrong', 'errors', 'cost', 'time', 'notes'];
const width = Object.fromEntries(cols.map((k) => [k, Math.max(k.length, ...rows.map((r) => String(r[k]).length))]));
const line = (r) => cols.map((k) => String(r[k]).padEnd(width[k])).join('  ').trimEnd();
console.log(line(Object.fromEntries(cols.map((k) => [k, k.toUpperCase()]))));
for (const r of rows) console.log(line(r));
console.log(`\n${rows.length} case result(s) · ${below} below threshold ${threshold} · total $${totalCost.toFixed(2)}`);
if (infra) console.log('Runs that ended in an error, or partial results: infrastructure, not a verdict on the plugin.');

process.exit(infra ? 2 : below ? 1 : 0);
