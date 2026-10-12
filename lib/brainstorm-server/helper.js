(function() {
  const MIN_RECONNECT_MS = 500;
  const MAX_RECONNECT_MS = 30000;
  const TOMBSTONE_AFTER_MS = 15000; // show the "paused" overlay after this long disconnected

  // Pure: next backoff delay (doubles, capped). Exported for unit tests.
  function nextReconnectDelay(current, max) {
    return Math.min(current * 2, max);
  }

  // Pure: AskUserQuestion's result from what a decision screen holds. Each entry
  // is { question, multiSelect, picked: [labels in screen order], note }.
  // A note with no pick is the answer (AskUserQuestion's "Other"); every note is
  // also an annotation. Questions with neither come back in `missing`.
  function buildAnswer(questions) {
    const answers = {};
    const annotations = {};
    const missing = [];
    for (const q of questions) {
      const note = (q.note || '').trim();
      const picked = q.multiSelect ? q.picked : q.picked.slice(-1);
      if (picked.length) answers[q.question] = picked.join(', ');
      else if (note) answers[q.question] = note;
      else missing.push(q.question);
      if (note) annotations[q.question] = { notes: note };
    }
    return { answers, annotations, missing };
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { nextReconnectDelay, buildAnswer, MIN_RECONNECT_MS, MAX_RECONNECT_MS, TOMBSTONE_AFTER_MS };
  }

  // Everything below is browser-only; bail out when loaded in Node (tests).
  if (typeof window === 'undefined') return;

  let ws = null;
  let eventQueue = [];
  let reconnectDelay = MIN_RECONNECT_MS;
  let reconnectTimer = null;
  let disconnectedSince = null;
  let everConnected = false;
  let tombstoneShown = false;

  function sessionKey() {
    try {
      return window.sessionStorage && window.sessionStorage.getItem('brainstorm-session-key');
    } catch {
      // Storage can throw (privacy mode, sandboxed frame); connect without a key.
    }
    return null;
  }

  function websocketUrl() {
    const key = sessionKey();
    return 'ws://' + window.location.host + (key ? '/?key=' + encodeURIComponent(key) : '');
  }

  function reloadAfterRecovery() {
    const key = sessionKey();
    if (key) {
      window.location.replace('/?key=' + encodeURIComponent(key));
    } else {
      window.location.reload();
    }
  }

  // Reflect connection state in the frame's status pill (absent on full-doc screens).
  function setStatus(state) {
    const el = document.querySelector('.status');
    if (!el) return;
    const map = {
      connecting:   ['Connecting…',   'var(--text-tertiary)'],
      connected:    ['Connected',     'var(--success)'],
      reconnecting: ['Reconnecting…', 'var(--warning)'],
      disconnected: ['Disconnected',  'var(--error)']
    };
    const [text, color] = map[state] || map.disconnected;
    el.textContent = text;
    el.style.setProperty('--status-color', color);
  }

  // Self-styled so it works on framed and full-document screens alike.
  function showTombstone() {
    if (tombstoneShown) return;
    tombstoneShown = true;
    const el = document.createElement('div');
    el.id = 'bs-tombstone';
    el.style.cssText = 'position:fixed;inset:0;z-index:99999;display:flex;' +
      'align-items:center;justify-content:center;padding:2rem;text-align:center;' +
      'background:rgba(20,20,22,0.92);color:#f5f5f7;font-family:system-ui,sans-serif';
    el.innerHTML = '<div style="max-width:480px">' +
      '<h2 style="margin:0 0 .5rem;font-weight:600">Companion paused</h2>' +
      '<p style="margin:0;opacity:.85">This brainstorm companion has stopped. ' +
      'Ask your coding agent to bring it back — this page reconnects automatically.</p></div>';
    if (document.body) document.body.appendChild(el);
  }

  function connect() {
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    setStatus(everConnected ? 'reconnecting' : 'connecting');
    ws = new WebSocket(websocketUrl());

    ws.onopen = () => {
      const recovered = tombstoneShown;
      everConnected = true;
      disconnectedSince = null;
      reconnectDelay = MIN_RECONNECT_MS;
      tombstoneShown = false;
      setStatus('connected');
      eventQueue.forEach(e => ws.send(JSON.stringify(e)));
      eventQueue = [];
      // Recovered from a tombstoned outage (e.g. the server restarted on the same
      // port) — reload through the keyed bootstrap when possible so the cookie is
      // refreshed before the visible URL returns to bare /.
      if (recovered) reloadAfterRecovery();
    };

    ws.onmessage = (msg) => {
      let data;
      try { data = JSON.parse(msg.data); } catch { return; }
      if (data.type === 'reload') window.location.reload();
      if (data.type === 'submit-rejected' && data.screen === window.brainstormScreen) {
        submitStatus('This screen was replaced before your answer arrived, so it was not used. Answer in the terminal.', 'error');
      }
    };

    ws.onclose = () => {
      ws = null;
      if (disconnectedSince === null) disconnectedSince = Date.now();
      if (Date.now() - disconnectedSince >= TOMBSTONE_AFTER_MS) {
        setStatus('disconnected');
        showTombstone();
      } else {
        setStatus('reconnecting');
      }
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = nextReconnectDelay(reconnectDelay, MAX_RECONNECT_MS);
    };

    // Let onclose own reconnection so we don't schedule it twice.
    ws.onerror = () => {
      try { ws.close(); } catch {
        // Already closing; onclose still fires and owns the reconnect.
      }
    };
  }

  function sendEvent(event) {
    event.timestamp = Date.now();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(event));
    } else {
      eventQueue.push(event);
    }
  }

  // Capture clicks on choice elements
  document.addEventListener('click', (e) => {
    const target = e.target.closest('[data-choice]');
    if (!target) return;
    // Decision screens need no inline onclick: selection is wired here.
    if (target.closest('[data-question]') && !target.hasAttribute('onclick')) {
      if (submitted) return; // the answer is sent; the screen must keep showing it
      window.toggleSelect(target);
    }

    sendEvent({
      type: 'click',
      text: target.textContent.trim(),
      choice: target.dataset.choice,
      id: target.id || null
    });

  });

  // Frame UI: selection tracking
  window.selectedChoice = null;

  // The group a choice belongs to: its .options/.cards wrapper, or on a decision
  // screen the whole [data-question] (so any data-choice markup is one group).
  function choiceGroup(el) {
    return el.closest('.options') || el.closest('.cards') || el.closest('[data-question]');
  }

  window.toggleSelect = function(el) {
    const container = choiceGroup(el);
    const multi = container && container.dataset.multiselect !== undefined;
    if (container && !multi) {
      const scope = el.closest('[data-question]') ? '[data-choice]' : '.option, .card';
      container.querySelectorAll(scope).forEach(o => o.classList.remove('selected'));
    }
    if (multi) {
      el.classList.toggle('selected');
    } else {
      el.classList.add('selected');
    }
    (container || document).querySelectorAll('[data-choice]').forEach(c => {
      c.setAttribute('aria-checked', String(c.classList.contains('selected')));
    });
    window.selectedChoice = el.dataset.choice;
  };

  // Keyboard and screen readers: choices are focusable radios/checkboxes;
  // Space or Enter selects (via the element's own click handler).
  function enhanceChoices() {
    document.querySelectorAll('[data-choice]').forEach(el => {
      const container = choiceGroup(el);
      const multi = container && container.dataset.multiselect !== undefined;
      if (!el.hasAttribute('tabindex')) el.tabIndex = 0;
      el.setAttribute('role', multi ? 'checkbox' : 'radio');
      el.setAttribute('aria-checked', String(el.classList.contains('selected')));
      el.addEventListener('keydown', (e) => {
        if (e.target !== el || (e.key !== ' ' && e.key !== 'Enter')) return;
        e.preventDefault();
        el.click();
      });
    });
    document.querySelectorAll('.options, .cards').forEach(c => {
      c.setAttribute('role', c.dataset.multiselect !== undefined ? 'group' : 'radiogroup');
    });
  }

  // Phone / full width toggle above every .preview.
  function enhancePreviews() {
    document.querySelectorAll('.preview').forEach(preview => {
      const bar = document.createElement('div');
      bar.className = 'preview-toggle';
      bar.setAttribute('role', 'group');
      bar.setAttribute('aria-label', 'Preview width');
      [['Phone 412', true], ['Full width', false]].forEach(([label, phone]) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = label;
        b.setAttribute('aria-pressed', String(preview.classList.contains('phone') === phone));
        b.addEventListener('click', (e) => {
          e.stopPropagation(); // not a click on the choice around it
          preview.classList.toggle('phone', phone);
          bar.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
        });
        bar.appendChild(b);
      });
      preview.parentNode.insertBefore(bar, preview);
    });
  }

  function submitStatus(text, kind) {
    let el = document.querySelector('.submit-status');
    if (!el) {
      el = document.createElement('p');
      el.className = 'submit-status';
      el.setAttribute('role', 'status');
      const anchor = document.querySelector('[data-submit]');
      if (anchor) anchor.insertAdjacentElement('afterend', el);
      else document.body.appendChild(el);
    }
    el.textContent = text;
    el.className = 'submit-status' + (kind ? ' ' + kind : '');
  }

  // Decision screens: each [data-question] holds one .options or .cards group and
  // an optional textarea[data-note]; a [data-submit] button sends the answer.
  let submitted = false;

  function submitAnswers() {
    if (submitted) return;
    const sections = Array.from(document.querySelectorAll('[data-question]'));
    const questions = sections.map(s => {
      const group = s.querySelector('.options, .cards') || s;
      const note = s.querySelector('textarea[data-note]');
      return {
        question: s.dataset.question,
        multiSelect: group.dataset.multiselect !== undefined,
        picked: Array.from(s.querySelectorAll('[data-choice].selected')).map(c => c.dataset.choice),
        note: note ? note.value : ''
      };
    });
    const result = buildAnswer(questions);
    if (result.missing.length) {
      const i = questions.findIndex(q => q.question === result.missing[0]);
      submitStatus('Answer "' + result.missing[0] + '": pick an option or write a note.', 'error');
      const first = sections[i].querySelector('[data-choice]');
      if (first) first.focus();
      return;
    }
    sendEvent({ type: 'submit', screen: window.brainstormScreen || null, answers: result.answers, annotations: result.annotations });
    submitted = true;
    document.querySelectorAll('[data-submit], [data-note]').forEach(x => { x.disabled = true; });
    document.querySelectorAll('[data-question] [data-choice]').forEach(c => {
      c.setAttribute('aria-disabled', 'true');
      c.tabIndex = -1;
    });
    if (ws && ws.readyState === WebSocket.OPEN) {
      submitStatus('Submitted. Return to the terminal; you can close this tab.', 'ok');
    } else {
      submitStatus('Saved; it will send when the connection comes back.', 'error');
    }
  }

  document.addEventListener('click', (e) => {
    if (e.target.closest('[data-submit]')) submitAnswers();
  });

  // Expose API for explicit use
  window.brainstorm = {
    send: sendEvent,
    choice: (value, metadata = {}) => sendEvent({ type: 'choice', value, ...metadata }),
    submit: submitAnswers
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { enhanceChoices(); enhancePreviews(); });
  } else {
    enhanceChoices();
    enhancePreviews();
  }

  connect();
})();
