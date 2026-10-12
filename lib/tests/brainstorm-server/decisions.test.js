/**
 * Decision screens (visualize-options) and the upstream fixes adopted with them:
 * - helper.js buildAnswer: AskUserQuestion's result shape from a screen's picks
 * - server.cjs: a `submit` message writes state/answer.json; a new screen clears it
 * - server.cjs: wrapInFrame inserts fragments verbatim ($&, $', $` stay literal)
 * - server.cjs: BRAINSTORM_OPEN_CMD runs without a shell (shellArgv + execFile)
 * - start-server.sh: a value-taking option given no value fails fast
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const {
  SERVER_DIR, SERVER_PATH, connectWs, freePort, httpGet, serverEnv,
  killAndWait, waitForStarted, harness, sleep
} = require('./ws-client.cjs');

const { buildAnswer } = require(path.join(SERVER_DIR, 'helper.js'));
const { shellArgv } = require(SERVER_PATH);
const FIXTURE = path.join(__dirname, '../fixtures/brainstorm-server/decision.html');
const TOKEN = 'testtoken-decisions-0123456789abcdef';
const { test, report } = harness();

async function waitFor(check, timeoutMs = 2000) {
  for (let waited = 0; waited < timeoutMs; waited += 50) {
    if (check()) return true;
    await sleep(50);
  }
  return check();
}

async function withServer(fn, extraEnv = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bs-decisions-'));
  const port = await freePort();
  const server = spawn('node', [SERVER_PATH], {
    env: serverEnv({ BRAINSTORM_PORT: port, BRAINSTORM_DIR: dir, BRAINSTORM_TOKEN: TOKEN, ...extraEnv })
  });
  try {
    await waitForStarted(server);
    await fn({ dir, port, content: path.join(dir, 'content'), state: path.join(dir, 'state') });
  } finally {
    await killAndWait(server);
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function main() {
  console.log('\n--- buildAnswer ---');

  await test('single select, multiSelect joined in screen order, notes trimmed into annotations', () => {
    const r = buildAnswer([
      { question: 'Layout?', multiSelect: false, picked: ['Card grid'], note: '  amounts right-aligned ' },
      { question: 'States?', multiSelect: true, picked: ['Empty', 'Filtered to zero'], note: '' }
    ]);
    assert.deepStrictEqual(r, {
      answers: { 'Layout?': 'Card grid', 'States?': 'Empty, Filtered to zero' },
      annotations: { 'Layout?': { notes: 'amounts right-aligned' } },
      missing: []
    });
  });

  await test('a note with no pick is the answer (AskUserQuestion "Other")', () => {
    const r = buildAnswer([{ question: 'Layout?', multiSelect: false, picked: [], note: 'a table' }]);
    assert.strictEqual(r.answers['Layout?'], 'a table');
    assert.deepStrictEqual(r.annotations['Layout?'], { notes: 'a table' });
  });

  await test('a question with neither pick nor note is missing', () => {
    const r = buildAnswer([
      { question: 'Layout?', multiSelect: false, picked: ['A'], note: '' },
      { question: 'States?', multiSelect: true, picked: [], note: '   ' }
    ]);
    assert.deepStrictEqual(r.missing, ['States?']);
    assert.strictEqual(r.answers['States?'], undefined);
  });

  await test('a single-select question never answers with two labels', () => {
    const r = buildAnswer([{ question: 'Layout?', multiSelect: false, picked: ['A', 'B'], note: '' }]);
    assert.strictEqual(r.answers['Layout?'], 'B');
  });

  console.log('\n--- submit -> answer.json ---');

  await test('a submit message writes answer.json in AskUserQuestion shape', () => withServer(async ({ port, content, state }) => {
    fs.copyFileSync(FIXTURE, path.join(content, 'decision.html'));
    await sleep(300);
    const page = await httpGet(port, '/', { cookie: `brainstorm-key-${port}=${TOKEN}` });
    assert(page.body.includes('data-question="Which layout should the invoices page use?"'), 'decision screen is served');
    assert(page.body.includes('buildAnswer'), 'helper with submit support is injected');

    const { outcome, client } = await connectWs(port, { key: TOKEN });
    assert.strictEqual(outcome, 'opened');
    const answers = { 'Which layout should the invoices page use?': 'Card grid', 'Which states need their own mockup?': 'Empty' };
    const annotations = { 'Which states need their own mockup?': { notes: 'skip loading' } };
    client.send(JSON.stringify({ type: 'submit', answers, annotations, timestamp: 42 }));
    const file = path.join(state, 'answer.json');
    assert(await waitFor(() => fs.existsSync(file)), 'answer.json appears');
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { answers, annotations, timestamp: 42 });
    client.close();
  }));

  await test('a submit without an answers object writes nothing', () => withServer(async ({ port, state }) => {
    const { client } = await connectWs(port, { key: TOKEN });
    client.send(JSON.stringify({ type: 'submit', answers: ['Card grid'] }));
    client.send(JSON.stringify({ type: 'submit' }));
    await sleep(300);
    assert(!fs.existsSync(path.join(state, 'answer.json')), 'no answer.json for a malformed submit');
    client.close();
  }));

  await test('an unauthorized WebSocket cannot submit', () => withServer(async ({ port, state }) => {
    const { outcome } = await connectWs(port, { key: 'wrong-key' });
    assert.notStrictEqual(outcome, 'opened');
    await sleep(200);
    assert(!fs.existsSync(path.join(state, 'answer.json')));
  }));

  await test('pushing a new screen deletes the previous answer.json', () => withServer(async ({ port, content, state }) => {
    fs.writeFileSync(path.join(content, 'first.html'), '<h2>First</h2>');
    await sleep(300);
    const { client } = await connectWs(port, { key: TOKEN });
    client.send(JSON.stringify({ type: 'submit', answers: { q: 'a' } }));
    const file = path.join(state, 'answer.json');
    assert(await waitFor(() => fs.existsSync(file)), 'answer.json written');
    fs.writeFileSync(path.join(content, 'second.html'), '<h2>Second</h2>');
    assert(await waitFor(() => !fs.existsSync(file)), 'answer.json removed by the next screen');
    client.close();
  }));

  console.log('\n--- wrapInFrame ---');

  await test('fragments with $& $\' $` and $1 are inserted verbatim (upstream v7.0.0)', () => withServer(async ({ port, content }) => {
    const fragment = '<h2>Prices</h2><pre>' + ["$'", '$`', '$&', '$$', '$1', '$<name>'].join(' | ') + '</pre>';
    fs.writeFileSync(path.join(content, 'tokens.html'), fragment);
    await sleep(300);
    const res = await httpGet(port, '/', { cookie: `brainstorm-key-${port}=${TOKEN}` });
    assert(res.body.includes(fragment), 'fragment inserted verbatim');
    assert.strictEqual(res.body.split('<div class="header">').length - 1, 1, 'frame chrome not duplicated');
    assert(!res.body.includes('<!-- CONTENT -->'), 'placeholder not restored');
  }));

  console.log('\n--- BRAINSTORM_OPEN_CMD ---');

  await test('shellArgv splits quoted segments and refuses unbalanced quotes', () => {
    assert.deepStrictEqual(shellArgv('flatpak run org.mozilla.firefox'), ['flatpak', 'run', 'org.mozilla.firefox']);
    assert.deepStrictEqual(shellArgv(`node "/a b/c.js" 'x y'`), ['node', '/a b/c.js', 'x y']);
    assert.strictEqual(shellArgv('node "/a b'), null);
    assert.strictEqual(shellArgv('   '), null);
  });

  await test('the launcher runs without a shell and gets the keyed URL as one argument', async () => {
    const capDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bs-argv-'));
    const marker = path.join(capDir, 'argv.log');
    const script = path.join(capDir, 'capture argv.cjs');
    fs.writeFileSync(script, "require('fs').appendFileSync(" + JSON.stringify(marker) +
      ", JSON.stringify(process.argv.slice(2)) + '\\n');\n");
    try {
      await withServer(async ({ content }) => {
        fs.writeFileSync(path.join(content, 'first.html'), '<h2>First</h2>');
        assert(await waitFor(() => fs.existsSync(marker), 3000), 'launcher ran');
      }, { BRAINSTORM_OPEN: '1', BRAINSTORM_OPEN_CMD: `node "${script}" "$(touch ${marker}.pwned)"` });
      const argv = JSON.parse(fs.readFileSync(marker, 'utf8').trim().split('\n')[0]);
      assert.strictEqual(argv.length, 2, 'quoted arg + URL: ' + JSON.stringify(argv));
      assert.strictEqual(argv[0], `$(touch ${marker}.pwned)`, 'command substitution stays literal');
      assert(/^http:\/\/localhost:\d+\/\?key=/.test(argv[1]), 'URL with its key is one argument');
      assert(!fs.existsSync(marker + '.pwned'), 'no shell ran the injected command');
    } finally {
      fs.rmSync(capDir, { recursive: true, force: true });
    }
  });

  console.log('\n--- start-server.sh ---');

  await test('value-taking options with no value fail fast with a JSON error (upstream PR #2444)', () => {
    for (const option of ['--project-dir', '--host', '--url-host', '--idle-timeout-minutes']) {
      const r = spawnSync('bash', [path.join(SERVER_DIR, 'start-server.sh'), option], { encoding: 'utf8', timeout: 10000 });
      assert.notStrictEqual(r.error && r.error.code, 'ETIMEDOUT', option + ' hung');
      assert.notStrictEqual(r.status, 0, option + ' exited 0');
      assert(new RegExp('"error".*' + option).test(r.stdout), option + ': ' + r.stdout);
    }
  });

  report();
}

main();
