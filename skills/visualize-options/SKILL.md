---
name: visualize-options
description: "Use when the user should pick layouts, UI states, variants or diagrammed designs by seeing them side by side in a browser, or a diagram, graph or visual result (image, render, screenshot) belongs in Visual Buddy, not a link. Do NOT use for text choices (AskUserQuestion), building mockups (feature-mockup), or open visual exploration (brainstorm)."
tags: [decision, mockup, ux, askuserquestion]
---

# Visualize Options

A visual AskUserQuestion. Same questions and options, same result shape; the user picks on one screen of Visual Buddy, the browser tab beside the conversation, where each option shows a live preview, side by side, with a phone-width toggle. Callers swap one call for the other and change nothing else.

It also has a show mode, for a diagram, a graph or a visual result that needs no answer (step 2b).

## When to use

| Use it | Use AskUserQuestion |
|---|---|
| Options differ in layout, density, IA, or which UI states exist | Options are words: approaches, scopes, names, trade-offs |
| Designs differ in structure a diagram shows: architecture, data flow, states, sequence | The difference fits in one sentence |
| A 40-column ASCII preview would misstate the option | An ASCII preview (the `preview` field) shows it well enough |
| Seeing it at phone width matters | One question with no visual payload |

A question *about* UI is not automatically visual: "what kind of wizard?" is words; "which of these wizard layouts?" is visual. Options without a preview are fine on the same screen.

## Inputs

What AskUserQuestion takes: 1–4 questions, each with its text, a header, 2–4 options (label, description, recommended first), and `multiSelect`. Add per option, when it helps:

- **a preview**: HTML for the option, built from Visual Buddy's classes (`mock-nav`, `mock-sidebar`, `mock-content`, `mock-button`, `mock-input`, `placeholder`) plus inline styles, with realistic sample data. Self-contained: no scripts, no network URLs, so it works offline. Use the project's tokens and components only as far as plain HTML can mirror them.
- **metrics**: short facts you measured or computed ("~1,500 DOM elements at 200 rows"). Never estimates of time.

## Workflow

`<plugin lib>` is `${CLAUDE_PLUGIN_ROOT}/lib`, resolved here; the Bash tool does not export the variable, so use this path.

### 1. Start or reuse Visual Buddy

If a Visual Buddy session is already running (its `state_dir` has `server-info` and no `server-stopped`), push to it. Otherwise:

```bash
bash <plugin lib>/brainstorm-server/start-server.sh --open
```

It prints `{"type":"server-started","url":…,"screen_dir":…,"state_dir":…}`. Keep all three; below, `<screen_dir>` and `<state_dir>` are those paths, written out in each command (nothing carries a shell variable between Bash calls). Without `--project-dir` the session lives in a temp directory and is deleted on stop, which is what a one-off decision wants. Remote bind (container, SSH): add `--host 0.0.0.0 --url-host <name the browser uses>`.

### 2. Write the decision screen

One new file in `<screen_dir>` (`{id}.html`, never reused; `{id}.html` is the screen's name below), written with the file-creation tool. A content fragment, no `<html>`: the server wraps it in the frame. Markup contract, read by Visual Buddy's helper script:

```html
<h2>{title}</h2>
<section class="question" data-question="{question text, verbatim}">
  <h3>{question text}</h3>
  <div class="cards">            <!-- add data-multiselect for multiSelect; .options for text-only rows -->
    <div class="card" data-choice="{label, verbatim}">
      <div class="card-body"><h3>{label} <span class="badge">Recommended</span></h3><p>{description}</p>
        <div class="metrics"><span>{metric}</span></div></div>
      <div class="preview">{preview HTML}</div>
    </div>
  </div>
  <label class="note">Note (optional)<textarea data-note></textarea></label>
</section>
<div class="submit-bar"><button type="button" class="submit" data-submit>Submit</button></div>
```

- `data-question` and `data-choice` become the keys and values of the result: copy question text and labels verbatim. A label keeps its `(Recommended)` suffix if AskUserQuestion would have had it; show the badge instead of the suffix in the visible title.
- Recommended option first. No `onclick`: inside `data-question`, the helper wires selection, keyboard (Tab, then Space or Enter) and the Phone 412 / Full width toggle above each `.preview`.
- Text-only questions use `.options` with `.option` rows (`<div class="letter">A</div><div class="content">…</div>`).

Pushing the file opens the browser (first screen) or reloads the open tab. Tell the user the **full** `url`, `?key=` included (the server refuses requests without it), and in one line what is on screen.

### 2b. Show mode: a diagram, graph or result, no question

For something to look at rather than pick: a diagram of a design, a graph of measurements, or a visual result (an image, a render, a screenshot, a before/after). Start or reuse as in step 1, then write one new screen with no `data-question` and no Submit:

- **A diagram or graph**: inline SVG in the fragment, labelled boxes and arrows, axes with units; two designs side by side in `<div class="split">`. A graph uses only numbers you measured, with their source under it.
- **A file you produced**: copy it into `<screen_dir>` under a new name and reference it as `/files/<name>` (`<img src="/files/blur-v2.png" alt="…" style="max-width:100%">`). Only `.html` files become screens, so the copy does not replace the one showing.

Worked examples of both: "Diagrams and graphs" and "Showing results" in `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/visual-buddy.md`. Tell the user the full `url` and, in one line, what is on screen; keep the file path for the record. There is nothing to wait for: skip steps 3 and 4.

### 3. Wait for Submit

Submit writes `<state_dir>/answer.json`, naming the screen it answers; the server refuses a Submit from any other screen (a stale tab, a send queued across a reconnect). Wait with Bash `run_in_background: true`, so the harness wakes you, then end your turn:

```bash
until grep -qs '"screen": "{id}.html"' <state_dir>/answer.json || [ -f <state_dir>/server-stopped ] || [ ! -d <state_dir> ]; do sleep 1; done; cat <state_dir>/answer.json <state_dir>/server-stopped 2>/dev/null
```

The `screen` match keeps an earlier decision's answer from being read as this one's. The loop also ends when the session directory is gone (`stop-server.sh` deletes temp sessions, a killed server writes nothing).

If the user answers in the terminal instead, that reply is the answer: treat it as AskUserQuestion's "Other" for the questions it covers.

### 4. Use the result

`answer.json` holds AskUserQuestion's result shape; the caller consumes it unchanged:

```json
{ "screen": "invoices-layout.html",
  "answers": { "Which layout?": "Dense list (Recommended)", "Which states?": "Empty, Overdue banner" },
  "annotations": { "Which states?": { "notes": "skip loading" } }, "timestamp": 1791819100000 }
```

A multiSelect answer joins labels with `", "` in screen order. A question with no pick but a note is answered by the note. Every note is also an annotation. If the loop ended any other way (`server-stopped`: idle timeout or owner exited; or the session directory is gone), there is no answer: ask in the terminal.

### 5. Clean up

Push a waiting screen if Visual Buddy stays in use (brainstorm's convention), or stop it: `bash <plugin lib>/brainstorm-server/stop-server.sh <session dir>` (the parent of `<screen_dir>`). A new screen deletes the previous `answer.json`, so one session can put several decisions in turn.

## The `visualQuestions` setting

`/myspec:setup visual-questions` turns this on for a whole project (`.myspec.json` `visualQuestions: "auto"`, with a token heads-up). It installs `.claude/rules/visual-questions.md`, which routes every clearly visual question here has the agent add a `Show in Visual Buddy` option to partly visual ones, and sends visual results here in show mode instead of as file paths. When the user picks that option, run this skill with the same question; leave the extra option out of the screen.

## Calling it from another skill

Where a skill would call AskUserQuestion and an option has a visual payload (feature-mockup's variant pick, a brainstorm layout decision, any question whose options are screens), build the screen from the same questions, options and order, run steps 1–4, and continue with the result as if AskUserQuestion had returned it. Keep the AskUserQuestion call when an ASCII preview carries the option.

## Verification checklist

- [ ] The question is visual; text choices stayed in AskUserQuestion (show mode: the content is a diagram, graph or visual result)
- [ ] 1–4 questions, 2–4 options each, recommended first, question text and labels verbatim in `data-question` / `data-choice`
- [ ] Previews are self-contained: no `<script>`, no http(s) URLs
- [ ] The user got the full URL with `?key=`
- [ ] The wait loop matched this screen's name and also ends when the session directory is gone
- [ ] The result came from `answer.json` (or the user's terminal reply), never retyped from memory
- [ ] Visual Buddy stopped, or left on a waiting screen when the caller keeps using it

## When NOT to use

- Text, scope, naming or trade-off questions: AskUserQuestion.
- Building or iterating on spec mockups: feature-mockup (it calls this skill for its variant pick).
- Exploring visual directions with no decision yet: brainstorm's Visual Buddy directly.
- Headless runs with no user to answer.
