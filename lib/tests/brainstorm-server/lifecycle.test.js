/**
 * Tests for the brainstorm server's lifecycle (idle timeout + shutdown).
 *
 * - The idle timeout is configurable (default 4h) and reported in server-info.
 * - Idle shutdown must close any open WebSocket so the process actually exits,
 *   not hang on a lingering connection.
 * - start-server.sh exposes the timeout via --idle-timeout-minutes.
 *
 * Ported from obra/superpowers tests/brainstorm-server (bb92a777), using the
 * dependency-free test client in ws-client.cjs instead of the `ws` package,
 * free ports instead of fixed ones, and .myspec/brainstorm session dirs. Every
 * spawned server is killed in a finally, even when an assertion fails first.
 */

const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const {
  SERVER_DIR, SERVER_PATH, connectWs, freePort, httpGet, serverEnv, waitForExit, killAndWait,
  serverStarted, harness, sleep
} = require('./ws-client.cjs');

const START = path.join(SERVER_DIR, 'start-server.sh');
const STOP = path.join(SERVER_DIR, 'stop-server.sh');
const tmpDir = prefix => fs.mkdtempSync(path.join(os.tmpdir(), prefix));

// Spawn a server and collect its output; `ready` resolves once it reports
// server-started (or after ~3 s, so a test can assert on a server that refused).
function startServer(env) {
  const child = spawn('node', [SERVER_PATH], { env: serverEnv(env) });
  child.out = '';
  child.err = '';
  child.stdout.on('data', d => { child.out += d.toString(); });
  child.stderr.on('data', d => { child.err += d.toString(); });
  child.ready = (async () => {
    for (let i = 0; i < 60 && !child.out.includes('server-started') && child.exitCode === null; i++) await sleep(50);
  })();
  return child;
}

async function started(child) {
  await child.ready;
  return serverStarted(child.out);
}

const keyOf = info => new URL(info.url).searchParams.get('key');

function newestSessionDir(projectDir) {
  const root = path.join(projectDir, '.myspec', 'brainstorm');
  const dirs = fs.readdirSync(root, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => path.join(root, d.name))
    .sort();
  assert(dirs.length, `expected at least one session dir under ${root}`);
  return dirs[dirs.length - 1];
}

async function runTests() {
  const { test, report } = harness();
  console.log('\n--- Lifecycle ---');

  await test('server-info reports the configured idle_timeout_ms', async () => {
    const dir = tmpDir('bs-life-');
    const srv = startServer({ BRAINSTORM_PORT: await freePort(), BRAINSTORM_DIR: dir, BRAINSTORM_IDLE_TIMEOUT_MS: 1234567 });
    try {
      const info = await started(srv);
      assert.strictEqual(info.idle_timeout_ms, 1234567, 'idle_timeout_ms should reflect the env override');
    } finally {
      await killAndWait(srv);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('idle shutdown closes an open WebSocket and the process exits', async () => {
    const dir = tmpDir('bs-life-');
    const port = await freePort();
    const srv = startServer({ BRAINSTORM_PORT: port, BRAINSTORM_DIR: dir, BRAINSTORM_TOKEN: 'lifetoken', BRAINSTORM_IDLE_TIMEOUT_MS: 800, BRAINSTORM_LIFECYCLE_CHECK_MS: 100 });
    let exited = false, code = null;
    srv.on('exit', c => { exited = true; code = c; });
    let ws = null;
    try {
      await started(srv);
      const conn = await connectWs(port, { key: 'lifetoken' });
      ws = conn.client;
      assert.strictEqual(conn.outcome, 'opened', 'WebSocket should open before the idle timeout');

      // 800ms idle (upstream: 200ms, which a cold start under load can spend
      // before the WS connects; the upgrade is not activity), checked every
      // 100ms: exits well within 4s *despite* the open WS, but only if
      // shutdown() closes client sockets.
      for (let i = 0; i < 40 && !exited; i++) await sleep(100);

      assert(exited, 'process must exit after idle shutdown even with an open WebSocket');
      assert.strictEqual(code, 0, 'should exit cleanly (0)');
      assert(fs.existsSync(path.join(dir, 'state', 'server-stopped')), 'should write server-stopped');
    } finally {
      if (ws) ws.close();
      await killAndWait(srv);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('start-server.sh --idle-timeout-minutes sets the timeout', async () => {
    const dir = tmpDir('bs-life-');
    let sessionDir = null;
    try {
      const out = execFileSync('bash', [START, '--project-dir', dir, '--idle-timeout-minutes', '5', '--background'], { encoding: 'utf8' });
      sessionDir = newestSessionDir(dir);
      const info = serverStarted(out);
      assert.strictEqual(info.idle_timeout_ms, 5 * 60 * 1000, '5 minutes -> 300000 ms');
    } finally {
      if (!sessionDir) {
        try { sessionDir = newestSessionDir(dir); } catch { /* the script made none */ }
      }
      if (sessionDir) {
        const pidFile = path.join(sessionDir, 'state', 'server.pid');
        const pid = fs.existsSync(pidFile) ? Number(fs.readFileSync(pidFile, 'utf8').trim()) : null;
        execFileSync('bash', [STOP, sessionDir], { stdio: 'ignore' });
        if (pid) {
          try { process.kill(pid, 'SIGKILL'); } catch { /* already stopped, as expected */ }
        }
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('server-started URL brackets IPv6 URL hosts', async () => {
    const dir = tmpDir('bs-ipv6-url-');
    const port = await freePort();
    const srv = startServer({
      BRAINSTORM_PORT: port,
      BRAINSTORM_HOST: '127.0.0.1',
      BRAINSTORM_URL_HOST: '::1',
      BRAINSTORM_TOKEN: 'ipv6token',
      BRAINSTORM_DIR: dir,
      BRAINSTORM_LIFECYCLE_CHECK_MS: 100000
    });
    try {
      const info = await started(srv);
      assert.strictEqual(info.url, `http://[::1]:${port}/?key=ipv6token`);
    } finally {
      await killAndWait(srv);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('persists the bound port AND key, and restores both on restart', async () => {
    const dir = tmpDir('bs-port-');
    const portFile = path.join(dir, '.last-port');
    const tokenFile = path.join(dir, '.last-token');
    const env = { BRAINSTORM_PORT_FILE: portFile, BRAINSTORM_TOKEN_FILE: tokenFile, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 };
    let a = null, b = null;
    try {
      a = startServer({ ...env, BRAINSTORM_DIR: path.join(dir, 's1') });
      const infoA = await started(a);
      assert(fs.existsSync(portFile) && fs.existsSync(tokenFile), 'should write the port and token files');
      assert(await killAndWait(a), 'first server should exit before restart binds its port');

      b = startServer({ ...env, BRAINSTORM_DIR: path.join(dir, 's2') });
      const infoB = await started(b);

      assert.strictEqual(infoB.port, infoA.port, 'restart should reuse the same port');
      // Same key too — otherwise the open tab's cookie would 403 against the restart.
      assert.strictEqual(keyOf(infoB), keyOf(infoA), 'restart should reuse the same session key');
    } finally {
      await killAndWait(a);
      await killAndWait(b);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('hardens existing persisted token file permissions', async () => {
    const dir = tmpDir('bs-token-mode-');
    const tokenFile = path.join(dir, '.last-token');
    let srv = null;
    try {
      fs.writeFileSync(tokenFile, 'efefefefefefefefefefefefefefefef', { mode: 0o644 });
      fs.chmodSync(tokenFile, 0o644);
      srv = startServer({
        BRAINSTORM_DIR: path.join(dir, 's1'),
        BRAINSTORM_PORT_FILE: path.join(dir, '.last-port'),
        BRAINSTORM_TOKEN_FILE: tokenFile,
        BRAINSTORM_LIFECYCLE_CHECK_MS: 100000
      });
      await srv.ready;
      assert(srv.out.includes('server-started'), 'server should start with persisted token');
      const mode = fs.statSync(tokenFile).mode & 0o777;
      assert.strictEqual(mode, 0o600, `.last-token mode should be 0600, got ${mode.toString(8)}`);
    } finally {
      await killAndWait(srv);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('stored key can authenticate WebSocket after same-port restart', async () => {
    const dir = tmpDir('bs-reconnect-');
    const env = {
      BRAINSTORM_PORT_FILE: path.join(dir, '.last-port'),
      BRAINSTORM_TOKEN_FILE: path.join(dir, '.last-token'),
      BRAINSTORM_LIFECYCLE_CHECK_MS: 100000
    };
    let a = null, b = null, ws = null;
    try {
      a = startServer({ ...env, BRAINSTORM_DIR: path.join(dir, 's1') });
      const infoA = await started(a);
      assert(await killAndWait(a), 'first server should exit before restart binds its port');

      b = startServer({ ...env, BRAINSTORM_DIR: path.join(dir, 's2') });
      const infoB = await started(b);
      const conn = await connectWs(infoB.port, { key: keyOf(infoA), origin: `http://localhost:${infoB.port}` });
      ws = conn.client;

      assert.strictEqual(infoB.port, infoA.port, 'restart should reuse same port');
      assert.strictEqual(conn.outcome, 'opened', 'stored key should authenticate WS after restart');
    } finally {
      if (ws) ws.close();
      await killAndWait(a);
      await killAndWait(b);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('falls back to a random port when the preferred port is taken', async () => {
    const dir = tmpDir('bs-port-');
    const portFile = path.join(dir, '.last-port');
    const portA = await freePort();
    let a = null, b = null;
    try {
      a = startServer({ BRAINSTORM_DIR: path.join(dir, 'a'), BRAINSTORM_PORT: portA, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      await started(a);

      fs.writeFileSync(portFile, String(portA)); // preferred port, but it's taken by A
      b = startServer({ BRAINSTORM_DIR: path.join(dir, 'b'), BRAINSTORM_PORT_FILE: portFile, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      const portB = (await started(b)).port;
      const persisted = fs.readFileSync(portFile, 'utf8').trim();

      assert.notStrictEqual(portB, portA, 'must not bind the already-taken port');
      assert(portB >= 49152, 'should fall back to a random high port');
      // The fallback must NOT clobber the shared port file — A still owns its
      // port and its open tab must keep reconnecting there.
      assert.strictEqual(persisted, String(portA), 'fallback must not overwrite .last-port');
    } finally {
      await killAndWait(a);
      await killAndWait(b);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('fallback with persisted token generates a fresh unpersisted key', async () => {
    const dir = tmpDir('bs-port-');
    const portFile = path.join(dir, '.last-port');
    const tokenFile = path.join(dir, '.last-token');
    const preferredToken = 'abababababababababababababababab';
    const portA = await freePort();
    let a = null, b = null;
    try {
      a = startServer({ BRAINSTORM_DIR: path.join(dir, 'a'), BRAINSTORM_PORT: portA, BRAINSTORM_TOKEN: preferredToken, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      await started(a);

      fs.writeFileSync(portFile, String(portA));
      fs.writeFileSync(tokenFile, preferredToken, { mode: 0o600 });

      b = startServer({ BRAINSTORM_DIR: path.join(dir, 'b'), BRAINSTORM_PORT_FILE: portFile, BRAINSTORM_TOKEN_FILE: tokenFile, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      const infoB = await started(b);
      const fallbackKey = keyOf(infoB);
      const persistedAfter = fs.readFileSync(tokenFile, 'utf8').trim();
      const originalStatus = (await httpGet(portA, '/?key=' + encodeURIComponent(fallbackKey))).status;

      assert.notStrictEqual(infoB.port, portA, 'fallback should use a different port');
      assert.notStrictEqual(fallbackKey, preferredToken, 'fallback must not reuse persisted key');
      assert.strictEqual(persistedAfter, preferredToken, 'fallback must not overwrite .last-token');
      assert.strictEqual(originalStatus, 403, 'fallback key must not authenticate to original server');
    } finally {
      await killAndWait(a);
      await killAndWait(b);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('fallback with explicit BRAINSTORM_TOKEN fails closed', async () => {
    const dir = tmpDir('bs-port-');
    const portFile = path.join(dir, '.last-port');
    const explicitToken = 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
    const portA = await freePort();
    let a = null, b = null;
    try {
      a = startServer({ BRAINSTORM_DIR: path.join(dir, 'a'), BRAINSTORM_PORT: portA, BRAINSTORM_TOKEN: explicitToken, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      await a.ready;
      assert(a.out.includes('server-started'), 'preferred-port server should start');

      fs.writeFileSync(portFile, String(portA));
      b = startServer({ BRAINSTORM_DIR: path.join(dir, 'b'), BRAINSTORM_PORT_FILE: portFile, BRAINSTORM_TOKEN: explicitToken, BRAINSTORM_LIFECYCLE_CHECK_MS: 100000 });
      await b.ready;
      const exited = await waitForExit(b, 1500);

      assert(exited, 'explicit-token fallback process should exit');
      assert.notStrictEqual(b.exitCode, 0, 'explicit-token fallback should fail non-zero');
      assert(!b.out.includes('server-started'), 'explicit-token fallback must not start on a random port');
      assert(/BRAINSTORM_TOKEN/.test(b.err), `stderr should explain explicit token fallback refusal, got: ${b.err}`);
    } finally {
      await killAndWait(a);
      await killAndWait(b);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('unauthenticated requests do not defeat the idle timeout', async () => {
    const dir = tmpDir('bs-life-');
    const port = await freePort();
    const srv = startServer({ BRAINSTORM_PORT: port, BRAINSTORM_DIR: dir, BRAINSTORM_TOKEN: 'authtok', BRAINSTORM_IDLE_TIMEOUT_MS: 400, BRAINSTORM_LIFECYCLE_CHECK_MS: 100 });
    let exited = false;
    srv.on('exit', () => { exited = true; });
    let hammer = null;
    try {
      await started(srv);
      // Flood with UNAUTHENTICATED (keyless → 403) requests. These must NOT count
      // as activity, so the idle timeout still fires and the process exits.
      hammer = setInterval(() => { httpGet(port, '/').catch(() => {}); }, 60);
      for (let i = 0; i < 40 && !exited; i++) await sleep(100);
      assert(exited, 'idle shutdown must still fire despite a flood of unauthenticated requests');
    } finally {
      clearInterval(hammer);
      await killAndWait(srv);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  report();
}

runTests().catch(err => { console.error('Test failed:', err); process.exitCode = 1; });
