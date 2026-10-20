# Visual Buddy

Visual Buddy is a browser tab that sits beside your Claude Code conversation. When something is easier to see than to read, the agent puts it on a screen there: two layouts side by side, an architecture diagram, a graph of measurements, the images an experiment just rendered. You look, click or press Submit, and keep talking in the terminal. The terminal stays the conversation; Visual Buddy is where the pictures go.

It runs locally (a small Node server the plugin ships, no dependencies, nothing leaves your machine) and only ever opens after you say yes.

## What it shows

| Use | You see | Comes from |
|---|---|---|
| Picking between options | Each option rendered side by side, a phone-width toggle, a note box, Submit | `/myspec:visualize-options`, the visual-questions setting, `feature-mockup`'s variant pick |
| Comparing designs | Two or three candidate architectures, data flows or state machines drawn next to each other | Options a skill proposes, with the visual-questions setting on |
| Explaining a structure | A diagram of a flow, sequence, state machine or entity relationships | `/myspec:brainstorm`, `visualize-options` show mode |
| Graphs | Bars or points drawn from real measurements, axes with units, the source named | `visualize-options` show mode, brainstorm |
| Results | The images, renders, charts or screenshots the agent just produced, a before/after in a split | Brainstorm and any spike: *show, don't link* |
| Exploring | Mockups and wireframes you react to while ideas are still forming | `/myspec:brainstorm` |

The rule of thumb the agent follows: would you understand this better by seeing it than reading it? Requirements, scope, naming and trade-offs in words stay in the terminal. A question *about* UI is not automatically visual: "what kind of wizard?" is words; "which of these wizard layouts?" is a picture.

## Turning it on

There are two ways in.

- **Brainstorm offers it on its own.** In `/myspec:brainstorm` the agent offers Visual Buddy the first time seeing would beat reading: options that look different, a structure easier to see than read, numbers whose shape matters, or a visual result it just produced. The offer is a message of its own; say no and it stays text-only.
- **The project setting puts it everywhere.** `/myspec:setup visual-questions` sets `.myspec.json` `visualQuestions` to `"auto"` and installs `.claude/rules/visual-questions.md`. From the next session, in every skill:
  - clearly visual questions are asked through `/myspec:visualize-options`;
  - partly visual ones get a last option, `Show in Visual Buddy`, and options laid out in a reply (approaches, designs a skill proposes) end with one line offering to show them side by side;
  - diagrams, graphs and visual results go on a screen when Visual Buddy is running, and are offered when it is not.

  `update` asks this once per project. Switch it off the same way; `"off"` removes the rule.

Both need `node` on `PATH`. Visual Buddy costs tokens: every option preview and every diagram is HTML the agent writes, several times what a text answer costs.

## A session, step by step

1. The agent starts the server and gives you a URL with `?key=…`. Open the **full** URL: the key is what lets your browser in, and the server refuses requests without it. With `--open` your browser opens by itself on the first screen.
2. Each screen is a new HTML file; the tab always shows the newest one and reloads by itself.
3. Clicks are recorded for the agent to read on its next turn. A decision screen has a Submit button: the answer goes straight back to the agent, in the same shape AskUserQuestion returns, so you do not have to retype it.
4. When the conversation moves back to words, the agent pushes a "Continuing in terminal..." screen so you are not looking at a choice already made.
5. The server stops after 4 hours idle, or when the agent stops it. A tab left open shows "Visual Buddy paused" and reconnects if the agent restarts it.

## Where the files live

By default a session lives in a temporary directory and is deleted when it stops. Brainstorm may start it with `--project-dir`, which keeps the screens in `.myspec/brainstorm/<session>/` in your project so they survive restarts and stay for later reference. Add `.myspec/` to `.gitignore`. The work-isolation hook treats `.myspec/` as scratch, so writing screens there needs no develop/worktree decision.

## Remote machines, containers, other browsers

- **Remote or containerised session:** the server binds to loopback by default. Start it with `--host 0.0.0.0 --url-host <the name your browser uses>` so the URL it prints is one you can open. The key still guards every request.
- **No browser at all** (headless, CI, a remote session you cannot reach): the agent stays in the terminal and asks with AskUserQuestion instead.
- **A specific browser:** set `VISUAL_BUDDY_OPEN_CMD` to the command that opens a URL (`firefox`, `flatpak run org.mozilla.firefox`, on Windows `cmd /c start ""`). The URL is appended as the last argument and the command runs without a shell.

## Names you may still see

Visual Buddy was called the brainstorm visual companion before 3.4. A few internal names keep the old spelling until v4 ([#364](https://github.com/jansalwowski/myspec/issues/364)), so nothing that depends on them breaks: the server directory `lib/brainstorm-server/`, the session directory `.myspec/brainstorm/`, and the `BRAINSTORM_*` environment variables the start script sets. `BRAINSTORM_OPEN_CMD` still works as the old name of `VISUAL_BUDDY_OPEN_CMD`.

## Where to read more

- `skills/brainstorm/visual-buddy.md`: the agent's guide, with the screen classes, diagram and results examples, and the session loop.
- `skills/visualize-options/SKILL.md`: decision screens and show mode.
- [examples/skills/visualize-options.md](../examples/skills/visualize-options.md) and the show-don't-link scenario in [examples/skills/brainstorm.md](../examples/skills/brainstorm.md).
