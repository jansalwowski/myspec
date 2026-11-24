---
name: research
description: Use when a question needs a sourced answer from several sources: picking a library or approach, why a framework or tool behaves a certain way, a migration path, AI tooling setup. Keywords: research, investigate, compare options. Do NOT use for one doc lookup, a reproducible failure in this repo (root-cause-debugging), or ideation (brainstorm).
---

# Research

Research quality varies mostly because the brief varies, and because nobody checks the claims. This skill fixes the brief and adds the two steps with measured effect: a verifier that never saw the draft, and a check of each key claim against the page it cites. Evidence behind each rule is in `references/evidence.md`; read it only if the user asks why.

Steps: 0 size → 1 brief → 2 plan → 3 search (parallel) → 4 verify → 5 report.

Keep a notes file at `<scratchpad>/research-<slug>.md` (use the session scratchpad directory if one is listed, otherwise `/tmp`). Write the brief, the plan, each agent's returned claims and the verdicts there as you go. It keeps the sources if the conversation is compacted, and the user can open it.

## 0. Size the task

Pick the domain (code, ai-setup, general) and the effort. Without a cap, research agents over-spawn: Anthropic saw 50 subagents for simple questions.

| Question type | Subagents | Tool calls each |
|---|---|---|
| One fact or one behavior | 0 (do it inline) | 3-10 |
| Comparison, how-to, why does X happen | 2-4 | 10-15 |
| Broad or open-ended survey | 4-6 | up to 20 |

For the one-fact case, skip steps 2-4 as agents but still cite sources and still run a check when one is cheap (step 4, code).

## 1. Brief

Fill these from the conversation and the repo. Ask the user (one AskUserQuestion, at most 3 questions) only about fields you cannot infer and that would change the plan.

- **Question**: one sentence.
- **Decision**: what the user will do with the answer. A question without a decision drifts into a survey.
- **Context**: today's date (claims are judged against it).
  - code: read the lockfile or manifest (`composer.lock`, `package-lock.json`, `go.mod`, `poetry.lock`...) for the exact versions of the packages involved, plus the runtime version. Answers for the wrong version are the most common failure in code research.
  - ai-setup: `claude --version`, and the files in play (CLAUDE.md, skill, agent or hook files).
- **Out of scope**.
- **Done when**: what a sufficient answer contains. It is the stop condition.
- **Hypothesis**: if the user already suspects an answer, write it down here. It must not reach the search or verify agents as a claim. Models drift toward a stated view; a single authority note flipped up to 40% of correct verdicts in one study. Turn it into a neutral question instead ("is X the cause? find evidence for and against").

Show the brief in at most 6 lines and continue. Don't wait for approval unless something in it is a guess that changes the plan.

## 2. Plan

Split the question into 2-4 sub-questions (more only for a broad survey) that do not overlap. Make at least one of them look for the opposite: known problems, failure reports, reasons not to.

Each subagent brief needs 4 things, or agents duplicate work and miss gaps: an objective, the sources to use in order, boundaries (what other agents cover), and an output format. Use the template at the end of this file.

## 3. Search, in parallel

Launch all search agents in one message with `run_in_background: true`. Agents prefer SEO content farms unless told otherwise, so give each one the source order for its domain:

**code**
1. The local repo: actual code, config, lockfile, the installed package source (`vendor/`, `node_modules/`).
2. Official docs for the pinned version, its changelog, release notes, migration guide.
3. The library's source on GitHub at that version's tag.
4. GitHub issues and PRs. Record state (open/closed/merged) and date.
5. Stack Overflow, blogs, model memory: dated hints only. Most obsolete SO answers were already obsolete when posted. Model memory is biased toward deprecated APIs.

**ai-setup**
1. code.claude.com docs and the Claude Code changelog. Note the version a feature appeared in.
2. platform.claude.com docs, the Anthropic engineering blog.
3. Official repos (anthropics/*).
4. Papers.
5. Blogs, awesome-lists, social posts: hypotheses until 1-3 confirm them. This field changes monthly; date every claim.

**general**: primary sources (paper, standard, official site, original data) before reputable secondary sources, before aggregators.

## 4. Verify

When the searches return, pick the load-bearing claims: the ones that would change the answer if they were wrong. Usually 5-15. Check them in the cheapest way that is real:

- **Runnable claims (code)**: if a claim about behavior can be checked locally in a few minutes (an API exists in the installed version, a function behaves a certain way, a config option does X), run a minimal reproduction or read the installed source. Work in the scratchpad, never in the user's repo. A run beats any number of pages.
- **Sourced claims**: spawn 1-2 fresh verifier agents (template below). Give them only the claims, written as neutral statements, and the cited URLs. Do not give them the draft answer, your conclusion, the user's hypothesis, or which claims you believe. A verifier that sees the draft agrees with it; Chain-of-Verification gained 3x more when the checking ran without the draft in view. Links are valid over 94% of the time while only 39-77% of cited facts hold, so the verifier must read the page, not just open it.
- **Prompting and skill claims (ai-setup)**: claims that some prompt, skill or setup "works better" stay hypotheses even when sourced. Say so, and propose a test instead: run the same prompt in fresh sessions with the skill on and off (`skillOverrides: "off"`), or `claude plugin eval` for plugins.

Drop claims that fail. Downgrade partial ones to what the source actually says.

## 5. Report

Write it yourself, in one pass. Parallel-written sections contradict each other.

Follow the user's length preferences from CLAUDE.md; default to short. Use this shape:

1. **Answer**: the recommendation or explanation, in 1-3 sentences, tied to the decision from the brief.
2. **Evidence**: the claims that carry the answer. Each one gets a source link and a confidence label:
   - high: checked against a primary source by the verifier, or reproduced by running it
   - medium: one primary source, not independently checked
   - low: secondary source, single report, or inference
3. **Dropped or unverified**: what failed verification, in one line each. This shows the user what the answer does not rest on.
4. **Open questions**: only those that would change the decision.

End with the path to the notes file. Don't paste the full source list into the reply.

## Search agent brief template

```
Goal: <one sentence>. This serves the decision: <decision>.
Your sub-question: <sub-question>
Context: today is <date>. Versions: <pinned versions>. Other agents cover <...>; skip those.
Sources, most trusted first: <domain list from step 3>.
Read primary sources. Don't answer from memory or from search snippets. Every claim needs a URL.
Look for evidence against as well as for.
Web tools may be deferred: load them with ToolSearch "select:WebSearch,WebFetch", or use the web-fetch agent.
Return at most 500 words: each claim with URL, date, and strength
(measured / documented / expert opinion / anecdote). End with "Could not verify: ...".
```

## Verifier brief template

```
Check each claim against its cited source. Fetch the source itself, not search snippets.
Judge each claim on its own. Some may be wrong, outdated or exaggerated.
<numbered claims, neutral wording, each with its URL>
For each: SUPPORTED / PARTIAL (say what differs) / NOT SUPPORTED / SOURCE NOT FOUND,
with a short quote or the exact number from the source. At most 400 words.
```
