# Blueprint: Visual questions

## Purpose
Turn Visual Buddy, the browser tab beside the conversation, on or off for this project. When on (`visualQuestions: "auto"`), the agent puts visual questions (layouts, UI states, colors, spacing, typography, designs a diagram shows better than words, anything that would need ASCII art) to the user through `/myspec:visualize-options` instead of AskUserQuestion, offers "Show in Visual Buddy" on questions that are only partly visual, and shows diagrams, graphs and visual results there instead of linking files. The behaviour lives in one always-loaded rule, installed only while the setting is on, so a project that keeps it off pays nothing for it.

## Recon (before asking)

- Read `.myspec.json` `visualQuestions` (absent means `off`) and whether `.claude/rules/visual-questions.md` exists.
- Check that `node` is on `PATH`: the Visual Buddy server needs it.

## Discovery Questions (ask one at a time)

1. Ask with AskUserQuestion, recommending the current state when one is set and `Off` when none is:

   "Use Visual Buddy, a browser tab beside the conversation? When the agent asks about layouts, UI states, colors, spacing, typography or designs a diagram explains better, it shows each option side by side there and you pick there instead of reading ASCII previews. Diagrams, graphs and images it produces go there too, instead of file paths.

   Heads-up: this uses more tokens. The agent writes an HTML preview for every option of every visual question, and a screen for every diagram or result it shows, several times what a text answer costs. Text questions are unaffected, and you can switch it off any time with `/myspec:setup visual-questions`."

   Options: `On (auto)` · `Off`.

   No `node` on `PATH` → say Visual Buddy cannot run here, recommend `Off`, and still let the user choose.

## Output Format

The rule is the manifest's conditional entry `rules/visual-questions.md` (`when: {"visualQuestions": "auto"}`), so `update` keeps it in step with the setting from then on. Check `.myspec.json` `frameworkFiles["rules/visual-questions.md"].pinned` first.

- **On:** set `"visualQuestions": "auto"` in `.myspec.json`, then install the rule as `update` would: copy the plugin's `framework-files/rules/visual-questions.md` to `.claude/rules/visual-questions.md` (create `.claude/rules/` if missing). A pinned file is left as it is.
- **Off:** set `"visualQuestions": "off"` in `.myspec.json`, then delete `.claude/rules/visual-questions.md` if present, unless it is pinned (leave it and say so). Record `off` rather than deleting the key: `update` asks only while the key is absent.

## Output Location

`.claude/rules/visual-questions.md` (present only when on) + `.myspec.json` `visualQuestions`.

## Post-generation

The rule loads at session start. Tell the user it applies from the next session, or after `/clear`. Do not stage or commit anything; the user commits `.claude/rules/` and `.myspec.json` with their next change.
