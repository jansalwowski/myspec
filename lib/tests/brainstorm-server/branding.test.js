/**
 * Tests for the visual companion's branding.
 * Adapted from obra/superpowers tests/brainstorm-server (bb92a777): upstream
 * renders a versioned Prime Radiant logo fetched from a remote asset, with
 * telemetry opt-outs. myspec strips all of that (upstream-sources.yml), so the
 * BRANDING slot is a static "myspec Visual Buddy" link with no remote asset,
 * and these tests assert exactly that plus the layout rules upstream kept.
 */

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const {
  SERVER_PATH, freePort, httpGet, serverEnv, killAndWait, waitForStarted, harness, sleep
} = require('./ws-client.cjs');

const TOKEN = 'testtoken-branding-0123456789abcdef';
const BRAND_LINK = '<a href="https://github.com/jansalwowski/myspec"><span class="brand-copy">myspec Visual Buddy</span></a>';

async function withServer(fn, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bs-branding-'));
  const port = await freePort();
  const server = spawn('node', [SERVER_PATH], {
    env: serverEnv({ BRAINSTORM_PORT: port, BRAINSTORM_DIR: dir, BRAINSTORM_TOKEN: TOKEN, ...env })
  });
  try {
    await waitForStarted(server);
    const fetchHtml = async () =>
      (await httpGet(port, '/', { cookie: `brainstorm-key-${port}=${TOKEN}` })).body;
    await fn({ dir, fetchHtml });
  } finally {
    await killAndWait(server);
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function writeFragment(dir) {
  fs.writeFileSync(path.join(dir, 'content', 'screen.html'), '<h2>Pick a layout</h2>');
}

function assertMyspecBranding(html) {
  assert(html.includes(`<div class="brand">${BRAND_LINK}</div>`), 'should render the static myspec brand link');
  assert(!/superpowers|prime ?radiant/i.test(html), 'no upstream branding may remain');
  assert(!html.includes('brand-logo'), 'no logo element (upstream remote logo is stripped)');
  assert(!/<img\b/i.test(html), 'no images: nothing may load from a remote host');
  assert(
    /\.brand a\s*\{[^}]*line-height:\s*1/i.test(html),
    'brand link should use a compact line height'
  );
  assert(
    /\.brand a\s*\{[^}]*max-width:\s*100%/i.test(html),
    'brand link should be constrained so it cannot overlap the status column'
  );
  assert(
    /\.brand\s*\{[^}]*line-height:\s*1/i.test(html),
    'brand wrapper should not inherit the page line height'
  );
  assert(
    /\.brand\s*\{[^}]*overflow:\s*hidden/i.test(html),
    'brand wrapper should clip before it reaches the status column'
  );
  assert(
    /\.brand-copy\s*\{[^}]*min-width:\s*0/i.test(html),
    'brand text should be allowed to shrink inside the brand row'
  );
}

function assertFramedScreenUsesBrandHeader(html) {
  assert.strictEqual((html.match(/class="brand"/g) || []).length, 1, 'framed screens should render the brand only in the header');
  assert(!html.includes('<div class="indicator-bar">'), 'framed screens should not render footer chrome');
  assert(
    /<div class="header">\s*<div class="brand">[\s\S]*<\/div>\s*<div class="status">Connecting…<\/div>/.test(html),
    'header should contain branding and connection status'
  );
  assert(!html.includes('id="indicator-text"'), 'header should not render the selection indicator text');
  assert(!html.includes('Click an option above'), 'header should not render the selection instruction');
}

function assertHeaderAvoidsNarrowOverlap(html) {
  assert(
    /grid-template-columns:\s*minmax\(0,\s*1fr\)\s*auto/i.test(html),
    'header should allocate shrinkable space to branding before the status column'
  );
  assert(
    /\.header \.status\s*\{[^}]*grid-column:\s*2/i.test(html),
    'status should live in the final fixed-width grid column'
  );
  assert(
    /\.header \.brand\s*\{[^}]*width:\s*100%/i.test(html),
    'header brand should fill its grid track so overflow clipping prevents overlap'
  );
}

async function main() {
  const { test, report } = harness();
  console.log('\n--- Visual Companion Branding ---');

  await test('framed screens render the static myspec brand in the header', async () => {
    await withServer(async ({ dir, fetchHtml }) => {
      writeFragment(dir);
      await sleep(300);
      const html = await fetchHtml();
      assert(html.includes('Pick a layout'), 'the fragment should be served framed');
      assertMyspecBranding(html);
      assertFramedScreenUsesBrandHeader(html);
      assertHeaderAvoidsNarrowOverlap(html);
    });
  });

  await test('waiting screen renders the static myspec brand', async () => {
    await withServer(async ({ fetchHtml }) => {
      const html = await fetchHtml();
      assert(html.includes('Waiting for the agent'), 'waiting page should still render');
      assertMyspecBranding(html);
    });
  });

  await test('upstream telemetry opt-out env vars change nothing', async () => {
    const optOut = {
      SUPERPOWERS_DISABLE_TELEMETRY: 'true',
      DISABLE_TELEMETRY: 'true',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1'
    };
    await withServer(async ({ dir, fetchHtml }) => {
      writeFragment(dir);
      await sleep(300);
      assertMyspecBranding(await fetchHtml());
    }, optOut);
  });

  report();
}

main().catch(err => { console.error('Test failed:', err); process.exitCode = 1; });
