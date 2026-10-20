# Spec Reviewer Prompt Template

Used by `feature-spec-review` and `feature-tech-spec-review` to run their analysis steps in a fresh subagent. A reviewer that shares the author's context reads the document the way its author meant it and misses what the page does not say, the same reason Claude Code's `/code-review` runs its checks in subagents.

Substitute before dispatching:

- `[REVIEW_SKILL_PATH]`: the calling skill's `SKILL.md` as the absolute path the calling skill gives. The reviewer runs in the project checkout, where the plugin's files do not live.
- `[FEATURE_DIR]`: the feature directory with `${aiDir}` resolved to the project's value: the subagent never sees `.myspec.json`.
- `[PRIOR_FINDINGS]`: "none" on a first review. On the re-review round, the findings table the previous reviewer returned, which fixes were applied, and which the user rejected.

Pass nothing else. Never summarize the conversation, the user's intent or why the author wrote what they wrote: that is the context the reviewer must not have. Whatever the document leaves out, every later reader is missing too, and the review is where that should show.

Leave `model` unset so the reviewer runs on the session's model: review quality is the point of the dispatch.

```
Agent tool (general-purpose):
  description: "Independent review of [FEATURE_DIR]"
  prompt: |
    You are an independent reviewer. You did not write the documents you are
    about to review and know nothing about how they were written.

    Read [REVIEW_SKILL_PATH] and carry out its Workflow steps 1–6 for the
    feature in [FEATURE_DIR], then write a fix proposal for every finding,
    tagged by the skill's fix policy (in feature-tech-spec-review that is the
    tagging part of Step 7; apply nothing). Everything that file says to
    check, check. Its Output Format section and the shared format it links
    say how findings and fix proposals look. Skip its Independent Reviewer
    section: you are that reviewer, so never dispatch another agent.

    Prior review: [PRIOR_FINDINGS]
    On a re-review, check that each applied fix landed and introduced no new
    problem, and report anything the earlier review missed. Do not repeat a
    finding the prior review lists as rejected by the user.

    Rules:
    - Read-only. Do not create, edit or delete any file, and do not run any
      command that writes. The skill that dispatched you applies fixes.
    - You cannot reach the user. Never ask a question. A decision only the
      user can make is a fix proposal tagged [requires confirmation].
    - Tag every fix proposal [auto-fix] or [requires confirmation] by the
      skill's own fix policy. Never downgrade a severity.
    - Cite file and line for every finding; use — when no line applies.

    Return, in this order and nothing else:
    1. The findings table, grouped Critical → High → Medium → Low
       (an empty table when you found nothing).
    2. One fix proposal block per finding.
    3. A last line: VERDICT: <n> Critical, <n> High, <n> Medium, <n> Low
```
