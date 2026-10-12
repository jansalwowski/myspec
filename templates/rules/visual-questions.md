# Visual questions

This project set `.myspec.json` `visualQuestions` to `auto` (`/myspec:setup visual-questions`; switching it off removes this file).

Before you call AskUserQuestion, decide whether the question is visual. It is visual when the options are layouts, screens, UI states, colors, spacing, typography, density, motion or other look-and-feel or UX choices, or when an option would need ASCII art or a `preview` to explain it.

| The question is | Do |
|---|---|
| Clearly visual | Ask it through `/myspec:visualize-options`, with the same questions, options and recommended order |
| Partly visual: words can decide it, but seeing the options could help | Keep AskUserQuestion and add a last option, `Show in visual companion`, when the question has 3 options or fewer. If the user picks it, ask the same question again through `/myspec:visualize-options` |
| Not visual (scope, naming, approach, trade-offs) | AskUserQuestion as usual |

When the user cannot open a local URL (a remote session, no browser), use AskUserQuestion for every question.
