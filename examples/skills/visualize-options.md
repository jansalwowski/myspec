# `/myspec:visualize-options` — examples

A visual AskUserQuestion: the same questions and options, put on one screen of the brainstorm visual companion with each option's preview side by side and a phone-width toggle. Submit writes the pick to `state_dir/answer.json` in AskUserQuestion's result shape, so the agent continues without a terminal round-trip.

> **Related**: Called by [feature-mockup.md](feature-mockup.md) for its variant pick and by [brainstorm.md](brainstorm.md) for layout decisions. Text choices stay in AskUserQuestion.

**Contents**

- [Layout and states decision on one screen](#layout-and-states-decision-on-one-screen)
- [feature-mockup variant pick](#feature-mockup-variant-pick)
- [Answer given in the terminal instead](#answer-given-in-the-terminal-instead)

---

## Layout and states decision on one screen

### Setup

A Flask invoicing app with myspec initialized. Planning the invoices page, the agent has two questions: list or card layout, and which UI states deserve their own mockup. The layout question is visual; an ASCII preview would misstate density, the very thing being decided.

### Invocation

```
/myspec:visualize-options invoices page: list vs cards, and which states to mock
```

### Skill flow

1. **Companion** — none running, so `bash <plugin lib>/brainstorm-server/start-server.sh --open`; the agent keeps `url`, `screen_dir` and `state_dir`.
2. **Screen** — writes `screen_dir/invoices-layout.html`, a fragment with two `data-question` sections. Layout uses `.cards`, the recommended "Dense list" first with a badge, each card holding a `.preview` (three realistic invoice rows built from `mock-nav` and inline styles) and metrics chips (`~1,500 DOM elements at 200 invoices`, `14 per screen`). States uses `.options data-multiselect` with three text rows and no previews. A Submit button closes the screen. The full fragment is the test fixture `lib/tests/fixtures/brainstorm-server/decision.html`.
3. **Hand-off** — the push opens the browser. The agent sends the full URL with its `?key=…`, says "2 questions: layout, states", starts the background wait on `answer.json`, and ends its turn.
4. **User** — toggles both previews to Phone 412, picks Card grid, ticks Empty and Filtered to zero with the keyboard, writes "skip the loading state" in the States note, presses Submit. The page says "Submitted. Return to the terminal".
5. **Result** — the wait exits and prints `answer.json`:

   ```json
   {
     "answers": {
       "Which layout should the invoices page use?": "Card grid",
       "Which states need their own mockup?": "Empty, Filtered to zero"
     },
     "annotations": { "Which states need their own mockup?": { "notes": "skip the loading state" } },
     "timestamp": 1791819100000
   }
   ```

6. **Clean up** — nothing else uses the companion, so `stop-server.sh` on the session dir; the temp session is deleted.

---

## feature-mockup variant pick

### Setup

`/myspec:feature-mockup billing-portal` built `InvoiceListA.vue` (table) and `InvoiceListB.vue` (grouped by month) for a `(variants?)` surface, both green.

### Skill flow

1. feature-mockup reaches its variant pick and runs this skill instead of AskUserQuestion: one question, two cards, each preview an HTML rendering of that variant's layout with the mockup's sample data.
2. The user picks "Grouped by month" with the note "month headers sticky".
3. feature-mockup continues with `{"answers": {"Which invoice list variant wins?": "Grouped by month"}, "annotations": {…: {"notes": "month headers sticky"}}}`: deletes `InvoiceListA.vue`, renames B, and applies the note in its iterate loop.

---

## Answer given in the terminal instead

### Setup

As in the first example, but the user's browser shows the screen and they reply in the terminal: "cards, and only the empty state".

### Skill flow

1. No `answer.json` arrives; the user's reply is the answer. The agent maps it as AskUserQuestion's "Other" would: Layout → "Card grid", States → "Empty".
2. It stops the background wait and the companion, and continues. It does not ask the user to go back and press Submit.
