# Visual Buddy Guide

Visual Buddy is a browser tab beside the conversation for mockups, diagrams, graphs, side-by-side options and generated results. The server lives at `<plugin lib>/brainstorm-server/` (the directory keeps its pre-rename name until v4).

## When to Use

Decide per-question, not per-session. The test: **would the user understand this better by seeing it than reading it?**

**Use the browser** when the content itself is visual:

- **UI mockups** — wireframes, layouts, navigation structures, component designs
- **Architecture diagrams** — system components, data flow, relationship maps
- **Side-by-side visual comparisons** — comparing two layouts, two color schemes, two design directions
- **Design polish** — when the question is about look and feel, spacing, visual hierarchy
- **Spatial relationships** — state machines, flowcharts, sequences, entity relationships rendered as diagrams
- **Graphs** — measurements, distributions, trends, before/after numbers, where the shape matters more than the values
- **Visual results** — an image, render, chart, screenshot or comparison sheet you just produced (see "Showing results")

**Use the terminal** when the content is text or tabular:

- **Requirements and scope questions** — "what does X mean?", "which features are in scope?"
- **Conceptual A/B/C choices** — picking between approaches described in words
- **Tradeoff lists** — pros/cons, comparison tables
- **Technical decisions** — API design, data modeling, architectural approach selection
- **Clarifying questions** — anything where the answer is words, not a visual preference

A question *about* a UI topic is not automatically a visual question. "What kind of wizard do you want?" is conceptual — use the terminal. "Which of these wizard layouts feels right?" is visual — use the browser.

## How It Works

The server watches a directory for HTML files and serves the newest one to the browser. You write HTML content, the user sees it in their browser and can click to select options. Selections are recorded to an `events` file in the session's `state/` directory, which you read on your next turn.

**Prerequisite:** the server runs on Node.js (`node` must be on `PATH`). It uses only built-in modules — no `npm install` needed.

**Content fragments vs full documents:** If your HTML file starts with `<!DOCTYPE` or `<html`, the server serves it as-is (just injects the helper script). Otherwise, the server automatically wraps your content in the frame template — adding the header, CSS theme, connection status, and all interactive infrastructure. **Write content fragments by default.** Only write full documents when you need complete control over the page.

## Starting a Session

`<plugin lib>` below is the resolved path the brainstorm skill gave you. This file is not substituted, and the Bash tool does not export the plugin-root variable.

```bash
# Start AFTER the user approves Visual Buddy. --open auto-opens their browser on
# the first screen; --project-dir persists mockups and enables same-port restart.
bash <plugin lib>/brainstorm-server/start-server.sh --project-dir /path/to/project --open

# Returns: {"type":"server-started","port":52341,
#           "url":"http://localhost:52341/?key=ab12…",
#           "screen_dir":"/path/to/project/.myspec/brainstorm/12345-1706000000/content",
#           "state_dir":"/path/to/project/.myspec/brainstorm/12345-1706000000/state"}
```

Save both `screen_dir` (where you write HTML) and `state_dir` (where you read the `events` file) from the response. With `--open`, the browser opens itself when you push the first screen — you don't need to ask the user to open it, but still share the URL as a fallback (headless/remote setups won't auto-open).

**The URL contains a session key (`?key=…`).** The server rejects any request without it, so always give the user the **complete** URL from the `url` field — never strip the query string, and never hand out a bare `http://host:port`. The key gates HTTP and WebSocket access so a stray browser tab or another machine on the network can't read the screens or inject events. After the first load the browser remembers the key via a cookie, so reloads and `/files/*` assets work without repeating it.

**Finding connection info:** The server writes its startup JSON to `$STATE_DIR/server-info`. If you launched the server in the background and didn't capture stdout, read that file to get the URL and port. When using `--project-dir`, check `<project>/.myspec/brainstorm/` for the session directory.

**Note:** Pass the project root as `--project-dir` so screens persist in `.myspec/brainstorm/` and survive server restarts. Without it, files go to `/tmp` and get cleaned up. The start script writes a `.gitignore` of `*` into `.myspec/brainstorm/`, so the screens never show up as untracked files.

**Windows behavior:** the script auto-detects a Windows-like shell (MSYS2/Git Bash/Cygwin) and switches to foreground mode, which blocks the tool call. Run it with `run_in_background: true` on the Bash tool call so the server survives across turns, then read `$STATE_DIR/server-info` on the next turn to get the URL.

**If background processes are reaped in your environment:** run in foreground from a persistent terminal session:

```bash
bash <plugin lib>/brainstorm-server/start-server.sh --project-dir /path/to/project --foreground
```

In `--foreground` mode, the command stays attached and serves until interrupted.

If the URL is unreachable from your browser (common in remote/containerized setups), bind a non-loopback host:

```bash
bash <plugin lib>/brainstorm-server/start-server.sh \
  --project-dir /path/to/project \
  --host 0.0.0.0 \
  --url-host localhost
```

Use `--url-host` to control what hostname is printed in the returned URL JSON.

**Custom browser launcher:** set `VISUAL_BUDDY_OPEN_CMD` (pre-rename name `BRAINSTORM_OPEN_CMD`, still read until v4) to the command that opens a URL (`firefox`, `flatpak run org.mozilla.firefox`, `node "/path/capture.js"`) when `--open`'s platform launcher does not apply. The server appends the URL as the last argument and runs the command without a shell: quotes group arguments (`""` is an empty one), a backslash escapes the next character, and nothing else is interpreted. A shell builtin is not a command on its own: on Windows use `cmd /c start ""`. A value that cannot be parsed, or a launch that fails, is logged to the server's stderr.

## The Loop

1. **Check server is alive**, then **write HTML** to a new file in `screen_dir`:
   - **Required: confirm the server is alive before referring to the URL or pushing a screen.** Check that `$STATE_DIR/server-info` exists and `$STATE_DIR/server-stopped` does not. If it has shut down, restart it with `start-server.sh` using the **same `--project-dir`** — it reuses the same port, so the user's open tab reconnects on its own (it shows a "paused" overlay while the server is down) and you don't need to send a new URL. The server auto-exits after 4 hours idle (configurable with `--idle-timeout-minutes`).
   - Use semantic filenames: `platform.html`, `visual-style.html`, `layout.html`
   - **Never reuse filenames** — each screen gets a fresh file
   - Use your file-creation tool — **never use cat/heredoc** (dumps noise into terminal)
   - Server automatically serves the newest file

2. **Tell user what to expect and end your turn:**
   - Remind them of the URL (every step, not just first)
   - Give a brief text summary of what's on screen (e.g., "Showing 3 layout options for the homepage")
   - Ask them to respond in the terminal: "Take a look and let me know what you think. Click to select an option if you'd like."

3. **On your next turn** — after the user responds in the terminal:
   - Read `$STATE_DIR/events` if it exists — this contains the user's browser interactions (clicks, selections) as JSON lines
   - Merge with the user's terminal text to get the full picture
   - The terminal message is the primary feedback; `events` provides structured interaction data

4. **Iterate or advance** — if feedback changes current screen, write a new file (e.g., `layout-v2.html`). Only move to the next question when the current step is validated.

5. **Unload when returning to terminal** — when the next step doesn't need the browser (e.g., a clarifying question, a tradeoff discussion), push a waiting screen to clear the stale content:

   ```html
   <!-- filename: waiting.html (or waiting-2.html, etc.) -->
   <div style="display:flex;align-items:center;justify-content:center;min-height:60vh">
     <p class="subtitle">Continuing in terminal...</p>
   </div>
   ```

   This prevents the user from staring at a resolved choice while the conversation has moved on. When the next visual question comes up, push a new content file as usual.

6. Repeat until done.

## Writing Content Fragments

Write just the content that goes inside the page. The server wraps it in the frame template automatically (header, theme CSS, selection indicator, and all interactive infrastructure).

**Minimal example:**

```html
<h2>Which layout works better?</h2>
<p class="subtitle">Consider readability and visual hierarchy</p>

<div class="options">
  <div class="option" data-choice="a" onclick="toggleSelect(this)">
    <div class="letter">A</div>
    <div class="content">
      <h3>Single Column</h3>
      <p>Clean, focused reading experience</p>
    </div>
  </div>
  <div class="option" data-choice="b" onclick="toggleSelect(this)">
    <div class="letter">B</div>
    <div class="content">
      <h3>Two Column</h3>
      <p>Sidebar navigation with main content</p>
    </div>
  </div>
</div>
```

That's it. No `<html>`, no CSS, no `<script>` tags needed. The server provides all of that.

## CSS Classes Available

The frame template provides these CSS classes for your content:

### Options (A/B/C choices)

```html
<div class="options">
  <div class="option" data-choice="a" onclick="toggleSelect(this)">
    <div class="letter">A</div>
    <div class="content">
      <h3>Title</h3>
      <p>Description</p>
    </div>
  </div>
</div>
```

**Multi-select:** Add `data-multiselect` to the container to let users select multiple options. Each click toggles the item's selected styling.

```html
<div class="options" data-multiselect>
  <!-- same option markup — users can select/deselect multiple -->
</div>
```

### Cards (visual designs)

```html
<div class="cards">
  <div class="card" data-choice="design1" onclick="toggleSelect(this)">
    <div class="card-image"><!-- mockup content --></div>
    <div class="card-body">
      <h3>Name</h3>
      <p>Description</p>
    </div>
  </div>
</div>
```

### Mockup container

```html
<div class="mockup">
  <div class="mockup-header">Preview: Dashboard Layout</div>
  <div class="mockup-body"><!-- your mockup HTML --></div>
</div>
```

### Split view (side-by-side)

```html
<div class="split">
  <div class="mockup"><!-- left --></div>
  <div class="mockup"><!-- right --></div>
</div>
```

### Pros/Cons

```html
<div class="pros-cons">
  <div class="pros"><h4>Pros</h4><ul><li>Benefit</li></ul></div>
  <div class="cons"><h4>Cons</h4><ul><li>Drawback</li></ul></div>
</div>
```

### Mock elements (wireframe building blocks)

```html
<div class="mock-nav">Logo | Home | About | Contact</div>
<div style="display: flex;">
  <div class="mock-sidebar">Navigation</div>
  <div class="mock-content">Main content area</div>
</div>
<button class="mock-button">Action Button</button>
<input class="mock-input" placeholder="Input field">
<div class="placeholder">Placeholder area</div>
```

### Typography and sections

- `h2` — page title
- `h3` — section heading
- `.subtitle` — secondary text below title
- `.section` — content block with bottom margin
- `.label` — small uppercase label text

## Diagrams and graphs

Draw them as inline SVG inside a content fragment: no scripts, no network, so a screen works offline and renders the same on every reload. Keep one idea per diagram, label every box and arrow, draw with `currentColor` (strokes, text and markers) so it reads in the dark theme too, give each SVG's marker its own id (`arrow-a`, `arrow-b`): ids are page-wide, and put two candidate designs in a `.split` so the user compares structure side by side.

```html
<h2>Where does the retry live?</h2>
<div class="split">
  <div class="mockup"><div class="mockup-header">A: retry in the client</div><div class="mockup-body">
    <svg viewBox="0 0 320 90" width="100%" role="img" aria-label="Client retries calls to the API, which writes to the queue">
      <defs><marker id="arrow-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
      <rect x="5" y="25" width="80" height="40" rx="6" fill="none" stroke="currentColor"/><text fill="currentColor" x="45" y="50" text-anchor="middle">Client ⟳</text>
      <rect x="120" y="25" width="80" height="40" rx="6" fill="none" stroke="currentColor"/><text fill="currentColor" x="160" y="50" text-anchor="middle">API</text>
      <rect x="235" y="25" width="80" height="40" rx="6" fill="none" stroke="currentColor"/><text fill="currentColor" x="275" y="50" text-anchor="middle">Queue</text>
      <line x1="85" y1="45" x2="118" y2="45" stroke="currentColor" marker-end="url(#arrow-a)"/><line x1="200" y1="45" x2="233" y2="45" stroke="currentColor" marker-end="url(#arrow-a)"/>
    </svg></div></div>
  <div class="mockup"><div class="mockup-header">B: retry in the worker</div><div class="mockup-body"><!-- same shape; its own marker id, arrow-b --></div></div>
</div>
```

For a graph, draw bars or points in SVG from the real numbers you measured, label the axes with units, and state the source under it (`.subtitle`). Never draw a graph from estimates.

## Showing results

When you produce something visual (an image, a render, a chart, a screenshot, a before/after), show it instead of linking it:

1. Copy the file into `screen_dir` under a new name (`cp out/blur-v2.png <screen_dir>/blur-v2.png`). Only `.html` files become screens, so the copy does not replace what is on screen.
2. Push a screen that references it by `/files/<name>`: `<img src="/files/blur-v2.png" alt="…" style="max-width:100%">`. For a comparison, put the images in a `.split`, each with a one-line caption saying what differs.
3. Tell the user what is on screen in one line, and keep the file path for the record.

If Visual Buddy is not running and was never offered, offer it now, as its own message (brainstorm's offer text). If the user declined earlier, offer once more for this result; a second no stands for the session.

## Decision screens

When a screen asks the user to decide (pick a layout, tick the states to build) rather than react, give it a Submit button: the answer arrives as `$STATE_DIR/answer.json` in AskUserQuestion's result shape, with no terminal round-trip. `skills/visualize-options/SKILL.md` has the markup contract (`data-question`, `data-choice` with no `onclick`, `textarea[data-note]`, `button[data-submit]`, `.preview` for a phone-width toggle). The answer names the screen it came from (`"screen": "<file>.html"`), and the server refuses a Submit from a screen that is no longer the newest, so wait for your screen's name, not just for the file. Pushing a new screen deletes the previous `answer.json`.

## Browser Events Format

When the user clicks options in the browser, their interactions are recorded to `$STATE_DIR/events` (one JSON object per line). The file is cleared automatically when you push a new screen.

```jsonl
{"type":"click","choice":"a","text":"Option A - Simple Layout","timestamp":1706000101}
{"type":"click","choice":"c","text":"Option C - Complex Grid","timestamp":1706000108}
{"type":"click","choice":"b","text":"Option B - Hybrid","timestamp":1706000115}
```

The full event stream shows the user's exploration path — they may click multiple options before settling. The last `choice` event is typically the final selection, but the pattern of clicks can reveal hesitation or preferences worth asking about.

If the `events` file doesn't exist, the user didn't interact with the browser — use only their terminal text.

## Design Tips

- **Scale fidelity to the question** — wireframes for layout, polish for polish questions
- **Explain the question on each page** — "Which layout feels more professional?" not just "Pick one"
- **Iterate before advancing** — if feedback changes current screen, write a new version
- **2-4 options max** per screen
- **Use real content when it matters** — for a photography portfolio, use actual images (Unsplash). Placeholder content obscures design issues.
- **Keep mockups simple** — focus on layout and structure, not pixel-perfect design

## File Naming

- Use semantic names: `platform.html`, `visual-style.html`, `layout.html`
- Never reuse filenames — each screen must be a new file
- For iterations: append version suffix like `layout-v2.html`, `layout-v3.html`
- Server serves newest file by modification time

## Cleaning Up

```bash
# Pass the SESSION directory — the parent of screen_dir/state_dir, not either of them.
bash <plugin lib>/brainstorm-server/stop-server.sh $SESSION_DIR
```

If the session used `--project-dir`, mockup files persist in `.myspec/brainstorm/` for later reference. Only `/tmp` sessions get deleted on stop.

## Reference

- Server engine (Node, no dependencies): `<plugin lib>/brainstorm-server/server.cjs`
- Frame template (CSS reference): `<plugin lib>/brainstorm-server/frame-template.html`
- Helper script (client-side): `<plugin lib>/brainstorm-server/helper.js`
