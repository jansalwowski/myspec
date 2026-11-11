# Visual questions

This project set `.myspec.json` `visualQuestions` to `auto` (`/myspec:setup visual-questions`; switching it off removes this file). Visual Buddy is the browser tab `/myspec:visualize-options` puts screens on.

## Options

Before every choice you put to the user, whether through AskUserQuestion, as a question in your reply ("Which do you want: A or B?") or as options you lay out in a reply (approaches, designs, alternatives a skill proposes), sort the options with the table below: a clearly visual choice is asked through `/myspec:visualize-options`, not as text. They are visual when they are layouts, screens, UI states, colors, spacing, typography, density, motion or other look-and-feel or UX choices; when they differ in a structure a diagram shows better than words (architecture, data flow, a state machine, a sequence, entity relationships); or when an option would need ASCII art or a `preview` to explain it.

| The options are | Do |
|---|---|
| Clearly visual | Ask through `/myspec:visualize-options`, which starts Visual Buddy itself, so it need not be running already, with the same questions, options and recommended order. A preview may be a diagram |
| Partly visual: words can decide it, but seeing the options could help | Keep AskUserQuestion and add a last option, `Show in Visual Buddy`, when the question has 3 options or fewer; if the user picks it, ask the same question again through `/myspec:visualize-options`. A question or options in your reply: end with one line offering to show them side by side in Visual Buddy |
| Not visual (scope, naming, trade-offs in words) | AskUserQuestion or a question in your reply, as usual |

## Results

Show, don't link or describe. When something visual is on the table (an image, a render, a chart, a screenshot, a before/after), one you produced, or one the user brought or pointed you at as a file or image URL (a pasted image cannot be shown) when the conversation turns on how it looks (comparing renders, judging a result) and not when it is only context for another task (a screenshot of a bug to fix), or when you produce an explanation a diagram or graph carries better than prose (a data flow, a state machine, measurements whose shape matters), and Visual Buddy is running, show it there through `/myspec:visualize-options` (show mode). It is running when you started it in this conversation and its `state_dir` has `server-info` and no `server-stopped`; a session you did not start is not yours to push to. When it is not running, offer it in one line and keep the path or prose as the fallback; do not open it unasked.

Inside `/myspec:brainstorm`, its own offer (a message of its own) replaces these one-line offers.

When the user cannot open a local URL (a remote session, no browser), stay in the terminal for all of this, clearly visual choices included.
