# Evidence behind the rules

Collected and verified on 2026-11-24. Each claim was checked against its source by a separate verifier agent.

| Rule | Evidence | Source |
|---|---|---|
| Cap effort by question type | Without rules, agents spawned 50 subagents for simple queries. Rules used in Anthropic's prompts: 1 agent with 3-10 calls for a fact, 2-4 subagents with 10-15 calls for a comparison. | https://www.anthropic.com/engineering/multi-agent-research-system |
| Multi-agent pays only for breadth | Multi-agent beat single-agent Opus 4 by 90.2% on an internal eval. Token usage alone explained 80% of the variance on BrowseComp. Multi-agent used about 15x the tokens of chat. | same |
| Subagent brief has 4 parts | "Each subagent needs an objective, an output format, guidance on the tools and sources to use, and clear task boundaries." | same |
| Give a source order | Early agents "consistently chose SEO-optimized content farms over authoritative but less highly-ranked sources". | same |
| Separate citation check | Anthropic uses a dedicated CitationAgent. | same |
| Verifier must not see the draft | Chain-of-Verification, Llama 65B biographies: FActScore 55.9 baseline, 60.8 joint (draft in view), 71.4 factor+revise. | https://arxiv.org/abs/2309.11495 |
| Keep the hypothesis away from the verifier | One false authority note overturned up to 40% of correct verdicts of tool-using judges. For Claude judges, 67-75% of harmful flips were "verify, conclude correctly, then defer". | https://arxiv.org/abs/2611.05662 |
| Check the page, not the link | Frontier models keep links valid over 94% of the time, but only 39-77% of cited facts are accurate. Accuracy fell about 42% (average of 2 models) from 2 to 150 tool calls. | https://arxiv.org/abs/2605.06635 |
| Deep research products are unreliable on support | Unsupported statements: GPT-5 DR 12.5%, Gemini DR 53.6%, Perplexity DR 97.5%. | https://arxiv.org/abs/2509.04499 |
| Per-claim checking works | SAFE agreed with humans on 72% of ~16k facts, won 76% of 100 sampled disagreements, at over 20x lower cost. | https://arxiv.org/abs/2403.18802 |
| Look for counterexamples | Prompting to consider counterexamples raised 2-4-6 rule discovery from 42% to 56% on average across 11 LLMs. | https://arxiv.org/abs/2604.02485 |
| Pin versions (code) | Deprecated API usage 25-38% of plausible completions, 70-90% when the prompt came from real code that used the deprecated API. | https://arxiv.org/abs/2406.09834 |
| Version docs help only partly | Version-conditioned tasks: 48-51% baseline; with retrieval 52.4-59.4% depending on model ("up to 10%"). | https://arxiv.org/abs/2507.12367 |
| SO is dated | 58.4% of obsolete SO answers were obsolete when posted; 20.5% were ever updated. | https://arxiv.org/pdf/1903.12282 |
| Run a check | "Give Claude a check to run"; "'All tests pass' on its own tells you very little". | https://code.claude.com/docs/en/best-practices |
| Test prompting claims | "Create evaluations BEFORE writing extensive documentation." Skills: compare runs with the skill on and off via `skillOverrides: "off"`. | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices, https://code.claude.com/docs/en/skills |
| Write the report in one pass | Parallel-written report sections did not fit together. | https://www.langchain.com/blog/open-deep-research |
