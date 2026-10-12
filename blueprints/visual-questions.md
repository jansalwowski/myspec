# Blueprint: Visual questions

## Purpose
Turn browser-based questions on or off for this project. When on (`visualQuestions: "auto"`), the agent puts visual questions (layouts, UI states, colors, spacing, typography, anything that would need ASCII art) to the user through `/myspec:visualize-options` instead of AskUserQuestion, and offers "Show in visual companion" on questions that are only partly visual. The behaviour lives in one always-loaded rule, installed only while the setting is on, so a project that keeps it off pays nothing for it.

## Recon (before asking)

- Read `.myspec.json` `visualQuestions` (absent means `off`) and whether `.claude/rules/visual-questions.md` exists.
- Check that `node` is on `PATH`: the visual companion server needs it.

## Discovery Questions (ask one at a time)

1. Ask with AskUserQuestion, recommending the current state when one is set and `Off` when none is:

   "Show visual questions in the browser? When the agent asks about layouts, UI states, colors, spacing or typography, it opens the brainstorm visual companion with each option rendered side by side, and you pick there instead of reading ASCII previews.

   Heads-up: this uses more tokens. The agent writes an HTML preview for every option of every visual question, several times what a text question costs. Text questions are unaffected, and you can switch it off any time with `/myspec:setup visual-questions`."

   Options: `On (auto)` · `Off`.

   No `node` on `PATH` → say the companion cannot run here, recommend `Off`, and still let the user choose.

## Output Format

- **On:** copy the plugin's `templates/rules/visual-questions.md` byte for byte to `.claude/rules/visual-questions.md` (create `.claude/rules/` if missing), and set `"visualQuestions": "auto"` in `.myspec.json`.
- **Off:** delete `.claude/rules/visual-questions.md` if present, and set `"visualQuestions": "off"` in `.myspec.json`. Record `off` rather than deleting the key: `update` asks only while the key is absent.

## Output Location

`.claude/rules/visual-questions.md` (present only when on) + `.myspec.json` `visualQuestions`.

## Post-generation

The rule loads at session start. Tell the user it applies from the next session, or after `/clear`. Do not stage or commit anything; the user commits `.claude/rules/` and `.myspec.json` with their next change.
