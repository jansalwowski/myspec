# Visual questions

This project set `.myspec.json` `visualQuestions` to `auto` (`/myspec:setup visual-questions`; switching it off removes this file). Visual Buddy is the browser tab `/myspec:visualize-options` puts screens on.

## Options

Before you call AskUserQuestion, or lay out options in a reply (approaches, designs, alternatives a skill proposes), decide whether they are visual. They are visual when they are layouts, screens, UI states, colors, spacing, typography, density, motion or other look-and-feel or UX choices; when they differ in a structure a diagram shows better than words (architecture, data flow, a state machine, a sequence, entity relationships); or when an option would need ASCII art or a `preview` to explain it.

| The options are | Do |
|---|---|
| Clearly visual | Ask through `/myspec:visualize-options`, with the same questions, options and recommended order. A preview may be a diagram |
| Partly visual: words can decide it, but seeing the options could help | Keep AskUserQuestion and add a last option, `Show in Visual Buddy`, when the question has 3 options or fewer; if the user picks it, ask the same question again through `/myspec:visualize-options`. Options in prose: end with one line offering to show them side by side in Visual Buddy |
| Not visual (scope, naming, trade-offs in words) | AskUserQuestion or prose as usual |

## Results

Show, don't link. When you produce something visual (an image, a render, a chart, a screenshot, a before/after) or an explanation a diagram or graph carries better than prose (a data flow, a state machine, measurements whose shape matters), and Visual Buddy is running, show it there through `/myspec:visualize-options` (show mode). When it is not running, offer it in one line and keep the path or prose as the fallback; do not open it unasked.

When the user cannot open a local URL (a remote session, no browser), stay in the terminal for all of this.
