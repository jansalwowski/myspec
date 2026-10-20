# Quickstart

This page installs myspec, sets it up in one repository, and takes one small feature from a spec to merged code. It takes about 15 minutes of your time, plus however long the agent spends writing code.

## Before you start

| You need | Version | Why |
|----------|---------|-----|
| Claude Code | 2.1.288 or later | The plugin's agents and hooks depend on it |
| git | 2.31 or later | The hooks resolve worktree paths with it |
| jq | 1.6 or later | The hooks read settings with it |

myspec works with any language or framework. It runs your project's own lint and test commands and never assumes a particular stack.

## 1. Install the plugin

Inside Claude Code, add the marketplace (once per machine) and install the plugin:

```
/plugin marketplace add jansalwowski/myspec
/plugin install myspec@myspec-marketplace
```

!!! tip "Setting up a team repo"
    Commit the marketplace and plugin to the project's `.claude/settings.json` so teammates get myspec automatically. See [Auto-setup for team repos](https://github.com/jansalwowski/myspec#auto-setup-for-team-repos).

## 2. Initialize your project

Open Claude Code in your repository and run:

```
/myspec:init
```

The wizard asks for:

1. **Project name** and **tech stack**.
2. **The AI documentation directory** (`.ai` or `ai`). This guide calls it `${aiDir}`. Specs, plans and memories live there, in git, next to your code.
3. **Verification commands**: your lint, type-check and test commands, for example `npm test`, `pytest`, `go test ./...` or `vendor/bin/phpunit`. Before the agent finishes a turn in which it wrote code, the **stop gate** runs them, and the turn cannot end while one of them fails.

It writes `.myspec.json`, scaffolds `${aiDir}/`, installs the framework rules in `.claude/rules/` and offers optional setup blueprints. Pick **Backbone** if you take one: it maps your repository's apps and packages so every later step finds code faster.

Commit the result.

## 3. Write a spec

Pick something small. This guide uses a "favorite reports" feature, in which users star a report and it pins to the top of their list.

```
/myspec:feature-spec favorite-reports
```

The agent asks a handful of scoping questions, such as whether favorites persist across devices, whether there is a limit, and what is out of scope. Answer them. It drafts two files and adds the feature to the manifest:

```
${aiDir}/features/
  index.yaml                  # manifest: favorite-reports, status: draft
  favorite-reports/
    spec.md                   # what and why: user stories, acceptance criteria, out of scope
    dependencies.md           # other features and services this one relies on
```

!!! note "Where a spec stops"
    `spec.md` says *what* the feature does and *why*. It contains no code, file paths or schema. Those go in the tech spec.

## 4. Review and approve it

```
/myspec:feature-spec-review favorite-reports
```

A fresh subagent that sees only the files reviews the spec for gaps, contradictions and untestable criteria. Fix what it finds, or accept the risk. When no Critical or High findings remain, you confirm and the spec's status flips from `draft` to `approved`.

## 5. Design the implementation

```
/myspec:feature-tech-spec favorite-reports
/myspec:feature-tech-spec-review favorite-reports
```

The agent reads your codebase and writes `tech-spec.md`, which covers architecture, data model changes, the files it will touch and the decisions it made. Review and approve it the same way.

## 6. Plan

```
/myspec:feature-plan favorite-reports
```

This writes `implementation-plan.md`: tasks with checkboxes, grouped into milestones, and marked where tasks can run in parallel. You approve the plan before any code is written.

## 7. Implement

```
/myspec:feature-implement favorite-reports
```

Before the first edit to your code, myspec asks one question: **develop** in this checkout, or work in a separate **worktree** and open a PR at the end. You choose, and the hooks enforce the choice.

The agent then sends each task to its own subagent and reviews every phase against the spec and plan. It stops at each milestone checkpoint for you. The stop gate runs your verification commands throughout.

## 8. Finish

```
/myspec:feature-complete favorite-reports
```

This checks that every plan task is done or explicitly deferred. It then archives the plan into the feature's `plans/`, marks the feature `complete` in the manifest and offers to merge the branch or open the PR.

## You're done. What's next?

- **Fewer prompts.** Say "autopilot" or pass `--autopilot`. The review and plan gates then take the recommended option and print each choice. Autopilot still stops on Critical findings, failing checks, and push, merge or deploy.
- **Change a shipped feature** with `/myspec:feature-update` rather than a new spec.
- **Already have code with no spec?** `/myspec:feature-discover` writes the docs from the code.
- **See the whole map** in [The feature lifecycle](lifecycle.md).
