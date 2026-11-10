# Mockup questions (update Step 3.5)

`/myspec:setup mockup` generates `{aiDir}/conventions/mockup-design.md` once, from the answers to its questions, and the project owns it. A release that adds a question, or changes what one asks or writes, lists it in the blueprint's *Question changes* table, so the project has never been asked it in that form. The check compares each row's version with the file's `myspec_version` and never reads the rest of the file.

| Exit | Do |
|---|---|
| 0 | Nothing to ask: report `up to date` under `Mockups`. |
| 3 | Ask with AskUserQuestion, naming each `ask:` line's question number and what it writes. **Answer them (Recommended)**: run the `setup` skill's `mockup` blueprint for those question numbers alone; its *Question changes* section asks them, writes each answer where its row says, and stamps the file. **Not now**: leave the file; the next `/myspec:update` offers them again. **Don't ask again**: run the check with `--stamp`, which writes only the `myspec_version` line (the plugin's version), so these rows are never offered again. |
| 4 | The file is gone: report "`mockup-design.md` missing, run `/myspec:setup mockup`" under `Mockups`. |
| 2 or any other | Report `check failed: <its stderr>` under `Mockups` and go on; never report the file as up to date. The same holds when `--stamp` exits 2 after either choice: the file has no frontmatter block on line 1, so say it needs one, or its questions are offered on every run. |

Only this step may change `mockup-design.md` or the `.myspec.json` `mockups` block, and only through the blueprint's *Question changes* procedure or `--stamp`.
