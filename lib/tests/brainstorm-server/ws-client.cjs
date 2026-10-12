// Test-only helpers for the brainstorm-server suites: a minimal WebSocket
// client (Node 20 ships no WebSocket client, and this repo takes no npm
// dependencies) plus small HTTP, port and process utilities.
//
// The client speaks just enough RFC 6455 for the server under test: the
// upgrade handshake, masked client frames (the server's decodeFrame rejects
// unmasked ones), and unmasked server frames.

const crypto = require('crypto');
const EventEmitter = require('events');
const http = require('http');
const net = require('net');
const path = require('path');

// BRAINSTORM_TEST_SERVER_DIR points the suites at another copy of the server
// (used to prove a suite fails against a broken copy).
const SERVER_DIR = process.env.BRAINSTORM_TEST_SERVER_DIR || path.join(__dirname, '../../brainstorm-server');
const SERVER_PATH = path.join(SERVER_DIR, 'server.cjs');
const { computeAcceptKey, encodeFrame, OPCODES } = require(SERVER_PATH);

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// A masked client frame: encodeFrame's header with the mask bit set, a mask
// key after the length, and the payload XORed with it.
function maskedFrame(opcode, payload) {
  const plain = encodeFrame(opcode, payload);
  const headerLen = plain.length - payload.length;
  const header = Buffer.from(plain.subarray(0, headerLen));
  header[1] |= 0x80;
  const mask = crypto.randomBytes(4);
  const data = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) data[i] = payload[i] ^ mask[i % 4];
  return Buffer.concat([header, mask, data]);
}

// Parse one unmasked server frame; null when the buffer holds less than one.
function parseServerFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  let len = buf[1] & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    len = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  if (buf.length < offset + len) return null;
  return { opcode, payload: buf.subarray(offset, offset + len), bytesConsumed: offset + len };
}

class WsClient extends EventEmitter {
  constructor(socket) {
    super();
    this.socket = socket;
    this.closed = false;
    this.messages = [];
    this.buffer = Buffer.alloc(0);
    socket.on('data', chunk => this.onData(chunk));
    socket.on('close', () => { this.closed = true; this.emit('close'); });
    socket.on('error', () => {});
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    let frame;
    while ((frame = parseServerFrame(this.buffer))) {
      this.buffer = this.buffer.subarray(frame.bytesConsumed);
      if (frame.opcode === OPCODES.TEXT) {
        const text = frame.payload.toString();
        this.messages.push(text);
        this.emit('message', text);
      } else if (frame.opcode === OPCODES.CLOSE) {
        this.socket.end();
      }
    }
  }

  send(text) {
    if (!this.closed) this.socket.write(maskedFrame(OPCODES.TEXT, Buffer.from(text)));
  }

  close() {
    if (this.closed) return;
    try { this.socket.write(maskedFrame(OPCODES.CLOSE, Buffer.alloc(0))); } catch { /* already gone */ }
    this.socket.end();
    this.socket.destroy();
  }
}

// Try to open a WebSocket. Resolves { outcome: 'opened' | 'rejected', client };
// client is a WsClient when opened and a closed stub otherwise.
function connectWs(port, { key, cookie, origin, host = 'localhost:' + port, timeoutMs = 1500 } = {}) {
  return new Promise(resolve => {
    const socket = net.connect(port, '127.0.0.1');
    const wsKey = crypto.randomBytes(16).toString('base64');
    let settled = false;
    let head = Buffer.alloc(0);
    const stub = { send() {}, close() {}, on() {}, messages: [] };
    const done = (outcome, client) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (outcome !== 'opened') socket.destroy();
      resolve({ outcome, client: client || stub });
    };
    const timer = setTimeout(() => done('rejected'), timeoutMs);

    const lines = [
      'GET /' + (key !== undefined ? '?key=' + key : '') + ' HTTP/1.1',
      'Host: ' + host,
      'Upgrade: websocket',
      'Connection: Upgrade',
      'Sec-WebSocket-Key: ' + wsKey,
      'Sec-WebSocket-Version: 13'
    ];
    if (cookie) lines.push('Cookie: ' + cookie);
    if (origin) lines.push('Origin: ' + origin);
    socket.on('connect', () => socket.write(lines.join('\r\n') + '\r\n\r\n'));
    socket.on('error', () => done('rejected'));
    socket.on('close', () => done('rejected'));

    const onHead = chunk => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf('\r\n\r\n');
      if (end < 0) return;
      socket.removeListener('data', onHead);
      const text = head.subarray(0, end).toString();
      const rest = head.subarray(end + 4);
      const accept = /\r\nSec-WebSocket-Accept: *(\S+)/i.exec(text);
      if (!/^HTTP\/1\.1 101 /.test(text) || !accept || accept[1] !== computeAcceptKey(wsKey)) {
        done('rejected');
        return;
      }
      const client = new WsClient(socket);
      if (rest.length) client.onData(rest);
      done('opened', client);
    };
    socket.on('data', onHead);
  });
}

// Resolves with the next message of the given type, or null after timeoutMs.
function nextMessage(client, type, timeoutMs = 1000) {
  return new Promise(resolve => {
    const onMessage = text => {
      let msg;
      try { msg = JSON.parse(text); } catch { return; }
      if (msg.type !== type) return;
      clearTimeout(timer);
      client.removeListener('message', onMessage);
      resolve(msg);
    };
    const timer = setTimeout(() => { client.removeListener('message', onMessage); resolve(null); }, timeoutMs);
    client.on('message', onMessage);
  });
}

// A port that was free a moment ago. The server takes BRAINSTORM_PORT as given
// and reports it back, so port 0 would leave the reported URL at :0.
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function httpGet(port, pathname, { cookie, host = '127.0.0.1' } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  return new Promise((resolve, reject) => {
    http.get({ host, port, path: pathname, headers }, res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', reject);
  });
}

// The environment every spawned server gets: the caller's, minus anything that
// would make a test server open a real browser.
function serverEnv(extra = {}) {
  const env = { ...process.env };
  delete env.BRAINSTORM_OPEN;
  delete env.BRAINSTORM_OPEN_CMD;
  for (const [k, v] of Object.entries(extra)) env[k] = String(v);
  return env;
}

function waitForExit(child, timeoutMs = 2000) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise(resolve => {
    const timer = setTimeout(() => resolve(false), timeoutMs);
    child.once('exit', () => { clearTimeout(timer); resolve(true); });
  });
}

async function killAndWait(child, timeoutMs = 2000) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return true;
  const exited = waitForExit(child, timeoutMs);
  child.kill();
  if (await exited) return true;
  child.kill('SIGKILL');
  return waitForExit(child, 500);
}

// Resolves with stdout once it contains server-started; rejects on timeout or exit.
function waitForStarted(child, timeoutMs = 5000) {
  let stdout = '';
  let stderr = '';
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start. stderr: ' + stderr)), timeoutMs);
    child.stdout.on('data', d => {
      stdout += d.toString();
      if (stdout.includes('server-started')) { clearTimeout(timer); resolve(stdout); }
    });
    child.stderr.on('data', d => { stderr += d.toString(); });
    child.on('exit', code => { clearTimeout(timer); reject(new Error('server exited (' + code + ') before starting. stderr: ' + stderr)); });
  });
}

function serverStarted(out) {
  const line = out.trim().split('\n').find(l => l.includes('server-started'));
  if (!line) throw new Error('no server-started line in: ' + out);
  return JSON.parse(line);
}

// A tiny PASS/FAIL harness matching upstream's output.
function harness() {
  const counts = { passed: 0, failed: 0, skipped: 0 };
  async function test(name, fn) {
    try {
      await fn();
      console.log('  PASS: ' + name);
      counts.passed++;
    } catch (e) {
      if (e && e.skip) {
        console.log('  SKIP: ' + name);
        console.log('    ' + e.message);
        counts.skipped++;
        return;
      }
      console.log('  FAIL: ' + name);
      console.log('    ' + (e && e.message));
      counts.failed++;
    }
  }
  function report() {
    const skipped = counts.skipped ? ', ' + counts.skipped + ' skipped' : '';
    console.log('\n--- Results: ' + counts.passed + ' passed, ' + counts.failed + ' failed' + skipped + ' ---');
    if (counts.failed > 0) process.exitCode = 1;
  }
  return { test, report, counts };
}

module.exports = {
  SERVER_DIR,
  SERVER_PATH,
  connectWs,
  nextMessage,
  maskedFrame,
  freePort,
  httpGet,
  serverEnv,
  waitForExit,
  killAndWait,
  waitForStarted,
  serverStarted,
  harness,
  sleep
};
