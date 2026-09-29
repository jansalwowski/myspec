#!/usr/bin/env node
// Prove every deterministic grader in evals/ can both pass and fail, with no
// model calls.
//
// Usage: node scripts/evals/check-graders.mjs [evals-dir]
//
// - regex graders: evals/<case>/grader-samples.json must hold, per grader,
//   at least one `pass` sample the pattern accepts and one `fail` sample it
//   rejects (for a file target, the sample is the file's content).
// - tool_used Skill graders: checked against synthetic Skill calls — the
//   right-skill grader must reject no call and a prefix-sharing skill; a
//   sibling (max: 0) grader must reject a call to its own skill. For the
//   names Claude Code also ships as built-in skills, the grader must reject
//   the bare built-in call.
// - every case has at least one deterministic grader.
//
// Exit 0 when every check holds, 1 otherwise.

import fs from 'node:fs';
import path from 'node:path';

const E = path.resolve(process.argv[2] ?? path.join(path.dirname(new URL(import.meta.url).pathname), '../../evals'));
const BUILTIN = new Set(['code-review', 'doctor', 'init']);
const DETERMINISTIC = new Set(['regex', 'tool_used', 'tool_order', 'file_exists']);

function frontmatter(file) {
  const m = fs.readFileSync(file, 'utf8').match(/^---\n([\s\S]*?)\n---/);
  const o = {};
  if (!m) return o;
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^(\w+):\s*(.*)$/);
    if (!kv) continue;
    const v = kv[2];
    o[kv[1]] = /^'.*'$/.test(v) || /^".*"$/.test(v) ? v.slice(1, -1).replace(/''/g, "'") : v;
  }
  return o;
}

const regexPasses = (g, text) => {
  const hit = new RegExp(g.pattern, g.flags || '').test(text);
  return g.match === 'not_contains' ? !hit : hit;
};
const toolPasses = (g, calls) => {
  const re = g.input_match ? new RegExp(g.input_match) : null;
  const n = calls.filter((c) => c.tool === g.tool && (!re || re.test(JSON.stringify(c.input)))).length;
  const min = g.min === undefined ? 1 : Number(g.min);
  const max = g.max === undefined ? Infinity : Number(g.max);
  return n >= min && n <= max;
};

const problems = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) problems.push(msg); };

for (const name of fs.readdirSync(E).sort()) {
  const dir = path.join(E, name);
  if (!fs.statSync(dir).isDirectory()) continue;
  if (!fs.existsSync(path.join(dir, 'prompt.md')) && !fs.existsSync(path.join(dir, 'case.yaml'))) continue;
  const gdir = path.join(dir, 'graders');
  const graders = fs.existsSync(gdir)
    ? fs.readdirSync(gdir).filter((f) => f.endsWith('.md')).map((f) => ({ name: f.slice(0, -3), ...frontmatter(path.join(gdir, f)) }))
    : [];
  expect(graders.some((g) => DETERMINISTIC.has(g.type)), `${name}: no deterministic grader (belt-and-braces rule)`);

  const samplesFile = path.join(dir, 'grader-samples.json');
  const samples = fs.existsSync(samplesFile) ? JSON.parse(fs.readFileSync(samplesFile, 'utf8')) : {};
  for (const g of graders) {
    const id = `${name}/${g.name}`;
    if (g.type === 'regex') {
      const s = samples[g.name];
      if (!s || !(s.pass ?? []).length || !(s.fail ?? []).length) {
        expect(false, `${id}: grader-samples.json needs at least one "pass" and one "fail" sample`);
        continue;
      }
      for (const t of s.pass) expect(regexPasses(g, t), `${id}: rejects its pass sample: ${JSON.stringify(t.slice(0, 80))}`);
      for (const t of s.fail) expect(!regexPasses(g, t), `${id}: accepts its fail sample: ${JSON.stringify(t.slice(0, 80))}`);
    } else if (g.type === 'tool_used' && g.tool === 'Skill' && g.input_match) {
      const skill = (g.input_match.match(/([A-Za-z0-9_-]+)"?$/) ?? [])[1];
      if (!skill) { expect(false, `${id}: cannot read the skill name from input_match`); continue; }
      const call = (s) => ({ tool: 'Skill', input: { skill: s, args: '' } });
      const own = [call(`myspec:${skill}`)];
      if (g.max === '0') {
        expect(toolPasses(g, [call('myspec:memory-create')]), `${id}: sibling grader fails when its skill is not called`);
        expect(!toolPasses(g, own), `${id}: sibling grader passes although myspec:${skill} was called`);
      } else {
        expect(toolPasses(g, own), `${id}: does not accept a call to myspec:${skill}`);
        expect(!toolPasses(g, []), `${id}: passes with no Skill call`);
        expect(!toolPasses(g, [call(`myspec:${skill}-other`)]), `${id}: accepts a skill that only shares the prefix`);
        if (BUILTIN.has(skill)) expect(!toolPasses(g, [call(skill)]), `${id}: accepts the built-in ${skill} skill`);
      }
    }
  }
  for (const k of Object.keys(samples)) {
    expect(graders.some((g) => g.name === k), `${name}: grader-samples.json names unknown grader ${k}`);
  }
}

if (problems.length) {
  console.log(problems.join('\n'));
  console.log(`\n${problems.length} of ${checks} grader checks failed`);
  process.exit(1);
}
console.log(`${checks} grader checks passed`);
