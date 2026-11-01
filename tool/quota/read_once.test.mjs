// Synthetic inputs only: temp directories with made-up sign-in files and a
// stubbed fetch. No real auth file, provider call or listener is used.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

globalThis.__OCMN_READER_NO_RUN = true;
const reader = await import('./read_once.mjs');
const collector = await import('./collector.mjs');
const here = dirname(fileURLToPath(import.meta.url));
const SOURCE_PATH = join(here, 'read_once.mjs');

const NOW = 1_800_000_000_000;
const ACCESS = `${Buffer.from('{"alg":"none"}').toString('base64url')}.${Buffer.from(
  JSON.stringify({ exp: Math.floor(NOW / 1000) + 3600 })).toString('base64url')}.sig`;
const ACCOUNT = 'synthetic-account-A';
const GLM_KEY = 'synthetic-glm-key-AAAA';
const MM_KEY = 'synthetic-minimax-key-BBBB';
const SECRETS = [ACCESS, ACCOUNT, GLM_KEY, MM_KEY, 'synthetic@example.com'];

const oauthEntry = (extra = {}) => ({ type: 'oauth', access: ACCESS, refresh: 'synthetic-refresh',
  expires: NOW + 3_600_000, accountId: ACCOUNT, ...extra });
const authDoc = (extra = {}) => ({ openai: oauthEntry(), 'zai-coding-plan': { type: 'api', key: GLM_KEY },
  'minimax-coding-plan': { type: 'api', key: MM_KEY }, ...extra });
const codexCli = () => ({ auth_mode: 'chatgpt', tokens: { access_token: ACCESS, account_id: ACCOUNT,
  id_token: 'x', refresh_token: 'synthetic-refresh' }, last_refresh: 'x' });

const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json' } });
const fixtureMiniMax = JSON.parse(await readFile(join(here, 'fixtures', 'minimax-general.json')));
const rawWindow = (used) => ({ used_percent: used, limit_window_seconds: 18_000,
  reset_after_seconds: 1800, reset_at: 1_800_001_800 });
const wham = () => ({ plan_type: 'plus', account_id: ACCOUNT, rate_limit: { allowed: true,
  limit_reached: false, primary_window: rawWindow(25), secondary_window: { ...rawWindow(60),
    limit_window_seconds: 604_800, reset_at: 1_800_086_400 } } });
const glm = () => ({ success: true, code: 200, data: { limits: [
  { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 10, nextResetTime: NOW + 3_600_000 },
  { type: 'TOKENS_LIMIT', unit: 6, number: 1, percentage: 20, nextResetTime: NOW + 86_400_000 }] } });

function stubFetch(overrides = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    const handler = overrides[new URL(url).hostname];
    if (handler) return handler(url, options);
    if (url.includes('chatgpt.com')) return json(wham());
    if (url.includes('z.ai')) return json(glm());
    return json(fixtureMiniMax);
  };
  return { fetchImpl, calls };
}

async function home(files) {
  const dir = await mkdtemp(join(tmpdir(), 'ocmn-reader-'));
  for (const [rel, doc] of Object.entries(files)) {
    await mkdir(dirname(join(dir, rel)), { recursive: true });
    await writeFile(join(dir, rel), JSON.stringify(doc));
  }
  return dir;
}
const read = (dir, extra = {}) => reader.readUsage({ env: {}, home: dir, platform: 'linux',
  clock: () => NOW, nodeVersion: '22.1.0', ...stubFetch(), ...extra });
const cleanup = (dir) => rm(dir, { recursive: true, force: true });

test('output is one marker line with every provider and the auth types', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const result = await read(dir);
    const line = reader.encodeLine(result);
    assert.match(line, /^OCMN_USAGE_V1 [A-Za-z0-9+/]+=*$/);
    assert.ok(!line.includes('\n'));
    const decoded = JSON.parse(Buffer.from(line.split(' ')[1], 'base64').toString('utf8'));
    assert.equal(decoded.v, 1);
    assert.deepEqual(decoded.auth, { codex: 'oauth', glm: 'api', minimax: 'api' });
    assert.deepEqual(Object.keys(decoded.providers).sort(), ['codex', 'glm', 'minimax']);
    const codex = decoded.providers.codex;
    assert.equal(codex.status, 'ok');
    assert.equal(codex.account.status, 'matched');
    assert.equal(codex.account.plan, 'plus');
    assert.match(codex.account.ref, /^[a-f0-9]{64}$/);
    assert.equal(codex.windows.length, 2);
    assert.equal(decoded.providers.glm.windows.length, 2);
    assert.equal(decoded.providers.minimax.account.status, 'sourceBound');
  } finally { await cleanup(dir); }
});

test('nothing secret, no path and no email is in the output', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    for (const fetchImpl of [stubFetch().fetchImpl,
      async () => json({ error: 'synthetic@example.com key ' + GLM_KEY }, 500),
      async () => { throw new Error(`failed for ${ACCESS} at ${dir}`); }]) {
      const text = reader.encodeLine(await read(dir, { fetchImpl }));
      const body = Buffer.from(text.split(' ')[1], 'base64').toString('utf8');
      for (const secret of [...SECRETS, dir, tmpdir(), 'synthetic-refresh']) {
        assert.ok(!text.includes(secret) && !body.includes(secret), `leaked ${secret.slice(0, 8)}`);
      }
    }
  } finally { await cleanup(dir); }
});

test('the request carries the credentials only to the fixed provider endpoints', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const stub = stubFetch();
    await read(dir, stub);
    assert.deepEqual(stub.calls.map((c) => c.url).sort(), [
      'https://api.z.ai/api/monitor/usage/quota/limit',
      'https://chatgpt.com/backend-api/wham/usage',
      'https://www.minimax.io/v1/token_plan/remains']);
    for (const call of stub.calls) {
      assert.equal(call.options.method, 'GET');
      assert.equal(call.options.redirect, 'error');
    }
  } finally { await cleanup(dir); }
});

test('every sign-in location is found, in order', async () => {
  const cases = [
    ['XDG_DATA_HOME', { XDG_DATA_HOME: 'XDG' }, 'XDG/opencode/auth.json', 'linux'],
    ['default share dir', {}, '.local/share/opencode/auth.json', 'linux'],
    ['macOS support dir', {}, 'Library/Application Support/opencode/auth.json', 'darwin'],
    ['OpenCode 2 data dir', { XDG_DATA_HOME: 'oc2/data' }, 'oc2/data/opencode/auth.json', 'linux'],
    ['Windows local app data', { LOCALAPPDATA: 'LOCAL' }, 'LOCAL/opencode/auth.json', 'win32'],
  ];
  for (const [name, envRel, rel, platform] of cases) {
    const dir = await home({ [rel]: authDoc() });
    try {
      const env = Object.fromEntries(Object.entries(envRel).map(([k, v]) => [k, join(dir, v)]));
      const result = await read(dir, { env, platform });
      assert.equal(result.auth.codex, 'oauth', name);
      assert.equal(result.providers.codex.status, 'ok', name);
      assert.equal(result.auth.glm, 'api', name);
    } finally { await cleanup(dir); }
  }
  const first = reader.authPaths({ XDG_DATA_HOME: '/x' }, '/h', 'darwin');
  assert.deepEqual(first, ['/x/opencode/auth.json', '/h/.local/share/opencode/auth.json',
    '/h/Library/Application Support/opencode/auth.json']);
});

test('the Codex CLI file is the fallback for Codex only', async () => {
  const dir = await home({ '.codex/auth.json': codexCli() });
  try {
    const result = await read(dir);
    assert.equal(result.auth.codex, 'oauth');
    assert.equal(result.providers.codex.status, 'ok');
    assert.equal(result.auth.glm, null);
    assert.equal(result.auth.minimax, null);
    assert.ok(!('glm' in result.providers) && !('minimax' in result.providers));
  } finally { await cleanup(dir); }
  const dir2 = await home({ 'cx/auth.json': codexCli(), '.codex/auth.json': {} });
  try {
    const result = await read(dir2, { env: { CODEX_HOME: join(dir2, 'cx') } });
    assert.equal(result.auth.codex, 'oauth');
  } finally { await cleanup(dir2); }
});

test('OpenCode wins over the Codex CLI file when both sign in', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc(),
    '.codex/auth.json': { ...codexCli(), tokens: { access_token: ACCESS, account_id: 'other-account' } } });
  try {
    const stub = stubFetch();
    await read(dir, stub);
    const codexCall = stub.calls.find((c) => c.url.includes('chatgpt.com'));
    assert.equal(codexCall.options.headers['ChatGPT-Account-Id'], ACCOUNT);
  } finally { await cleanup(dir); }
});

test('an expired OpenCode sign-in does not hide a live Codex CLI one', async () => {
  // OpenCode renews its own sign-in only when Codex is next used there.
  const dir = await home({ '.local/share/opencode/auth.json': authDoc({
    openai: oauthEntry({ expires: NOW - 1000 }) }),
    '.codex/auth.json': { ...codexCli(), tokens: { access_token: ACCESS, account_id: 'other-account' } } });
  try {
    const stub = stubFetch();
    const result = await read(dir, stub);
    assert.equal(result.providers.codex.status, 'ok');
    const codexCall = stub.calls.find((c) => c.url.includes('chatgpt.com'));
    assert.equal(codexCall.options.headers['ChatGPT-Account-Id'], 'other-account');
  } finally { await cleanup(dir); }
});

test('the `codex` entry and an API key tell oauth and api apart', async () => {
  const viaCodex = await home({ '.local/share/opencode/auth.json': { codex: oauthEntry() } });
  const apiOnly = await home({ '.local/share/opencode/auth.json': {
    openai: { type: 'api', key: 'sk-synthetic-openai-key' },
    minimax: { type: 'api', key: 'sk-api-synthetic-paygo-key' } } });
  const nothing = await home({ '.local/share/opencode/auth.json': {} });
  try {
    assert.equal((await read(viaCodex)).auth.codex, 'oauth');
    const api = await read(apiOnly);
    assert.equal(api.auth.codex, 'api');
    assert.ok(!('codex' in api.providers));
    assert.equal(api.auth.minimax, 'api');
    assert.equal(api.providers.minimax.status, 'unsupported');
    assert.deepEqual((await read(nothing)).auth, { codex: null, glm: null, minimax: null });
    assert.deepEqual((await read(nothing)).providers, {});
  } finally { await Promise.all([viaCodex, apiOnly, nothing].map(cleanup)); }
});

test('an expired Codex sign-in is authRequired and makes no Codex request', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc({
    openai: oauthEntry({ expires: NOW - 1000 }) }) });
  try {
    const stub = stubFetch();
    const result = await read(dir, stub);
    assert.equal(result.providers.codex.status, 'authRequired');
    assert.equal(result.auth.codex, 'oauth');
    assert.ok(!stub.calls.some((c) => c.url.includes('chatgpt.com')));
  } finally { await cleanup(dir); }
});

test('provider failures become fixed status codes', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const cases = [
      [() => json({}, 401), 'authRequired'],
      [() => json({}, 429), 'rateLimited'],
      [() => json({}, 404), 'unsupported'],
      [() => json({}, 500), 'unavailable'],
      [() => new Response('<html>', { headers: { 'Content-Type': 'text/html' } }), 'invalidResponse'],
      [() => json({ nonsense: true }), 'invalidResponse'],
      [() => { throw new TypeError('network down ' + ACCESS); }, 'unavailable'],
    ];
    for (const [handler, status] of cases) {
      const result = await read(dir, { fetchImpl: async () => handler() });
      for (const name of ['codex', 'glm', 'minimax']) {
        assert.equal(result.providers[name].status, status, `${name} ${status}`);
        assert.deepEqual(result.providers[name].windows, []);
      }
    }
  } finally { await cleanup(dir); }
});

test('a provider that never answers times out without hanging the others', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const hang = (_url, { signal }) => new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(new Error('aborted')));
    });
    const stub = stubFetch({ 'chatgpt.com': hang });
    const result = await read(dir, { fetchImpl: stub.fetchImpl, timeoutMs: 50 });
    assert.equal(result.providers.codex.status, 'unavailable');
    assert.equal(result.providers.glm.status, 'ok');
  } finally { await cleanup(dir); }
});

test('a missing Node feature gives the fixed code and no request', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const stub = stubFetch();
    const old = await read(dir, { nodeVersion: '18.19.0', fetchImpl: stub.fetchImpl });
    assert.deepEqual(old, { v: 1, error: 'nodeTooOld', providers: {},
      auth: { codex: null, glm: null, minimax: null } });
    const noFetch = await read(dir, { fetchImpl: null });
    assert.equal(noFetch.error, 'nodeTooOld');
    assert.equal(stub.calls.length, 0);
  } finally { await cleanup(dir); }
});

test('an unreadable, huge or malformed sign-in file is treated as no sign-in', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'ocmn-reader-'));
  try {
    await mkdir(join(dir, '.local/share/opencode'), { recursive: true });
    await writeFile(join(dir, '.local/share/opencode/auth.json'), '{not json');
    assert.deepEqual((await read(dir)).auth, { codex: null, glm: null, minimax: null });
    await writeFile(join(dir, '.local/share/opencode/auth.json'),
      JSON.stringify({ openai: oauthEntry(), pad: 'x'.repeat(70_000) }));
    assert.equal((await read(dir)).auth.codex, null);
  } finally { await cleanup(dir); }
});

test('the reader never writes: the home directory is byte-identical afterwards', async () => {
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  const path = join(dir, '.local/share/opencode/auth.json');
  try {
    const before = await readFile(path, 'utf8');
    const mtime = (await stat(path)).mtimeMs;
    await read(dir);
    assert.equal(await readFile(path, 'utf8'), before);
    assert.equal((await stat(path)).mtimeMs, mtime);
  } finally { await cleanup(dir); }
});

test('mappers give the same result as the collector for the same payloads', () => {
  const ref = 'a'.repeat(64);
  const auth = { accessToken: ACCESS, accountId: ACCOUNT, userId: null };
  assert.deepEqual(reader.mapWham(wham(), auth, ref, NOW), collector.mapWham(wham(), auth, ref, NOW));
  const other = { ...wham(), account_id: 'someone-else' };
  assert.deepEqual(reader.mapWham(other, auth, ref, NOW), collector.mapWham(other, auth, ref, NOW));
  assert.deepEqual(reader.mapGlmUsage(glm(), ref, NOW), collector.mapGlmUsage(glm(), ref, NOW));
  assert.deepEqual(reader.mapMiniMaxUsage(fixtureMiniMax, ref, NOW),
    collector.mapMiniMaxUsage(fixtureMiniMax, ref, NOW));
  for (const bad of [{}, { limits: 1 }, null]) {
    assert.throws(() => reader.mapGlmUsage(bad, ref, NOW));
    assert.throws(() => collector.mapGlmUsage(bad, ref, NOW));
  }
});

test('the account hash is stable, one-way and the same across computers', async () => {
  const a = await home({ '.local/share/opencode/auth.json': authDoc() });
  const b = await home({ '.local/share/opencode/auth.json': authDoc() });
  try {
    const [ra, rb] = [await read(a), await read(b)];
    assert.equal(ra.providers.codex.account.ref, rb.providers.codex.account.ref);
    assert.equal(ra.providers.codex.account.ref,
      createHmac('sha256', 'ocmn-usage-ref-v1').update(ACCOUNT).digest('hex'));
    assert.notEqual(ra.providers.glm.account.ref, ra.providers.minimax.account.ref);
  } finally { await Promise.all([a, b].map(cleanup)); }
});

test('the source fits one -e argument and runs as that command, printing one line', async () => {
  const source = await readFile(SOURCE_PATH, 'utf8');
  assert.ok(source.length < 60_000, `source is ${source.length} bytes`);
  assert.ok(source.length < 30_000, 'stays under the Windows command-line cap');
  const dir = await home({ '.local/share/opencode/auth.json': authDoc() });
  const preload = join(dir, 'stub.mjs');
  await writeFile(preload, `
    const body = (v) => new Response(JSON.stringify(v), { headers: { 'Content-Type': 'application/json' } });
    globalThis.fetch = async (url) => String(url).includes('chatgpt.com') ? body(${JSON.stringify(wham())})
      : String(url).includes('z.ai') ? body(${JSON.stringify(glm())}) : body(${JSON.stringify(fixtureMiniMax)});
  `);
  try {
    const run = spawnSync(process.execPath, ['--import', preload, '--input-type=module', '-e', source], {
      env: { PATH: process.env.PATH, HOME: dir }, encoding: 'utf8', timeout: 20_000 });
    assert.equal(run.status, 0);
    assert.equal(run.stderr, '');
    const lines = run.stdout.split('\n').filter(Boolean);
    assert.equal(lines.length, 1);
    const decoded = JSON.parse(Buffer.from(lines[0].split(' ')[1], 'base64').toString('utf8'));
    assert.equal(decoded.providers.codex.status, 'ok');
    assert.deepEqual(decoded.auth, { codex: 'oauth', glm: 'api', minimax: 'api' });
    for (const secret of [...SECRETS, dir]) assert.ok(!run.stdout.includes(secret));
  } finally { await cleanup(dir); }
});

test('with no sign-in files at all the command still prints its line and exits 0', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'ocmn-reader-'));
  try {
    const run = spawnSync(process.execPath, ['--input-type=module', '-e',
      await readFile(SOURCE_PATH, 'utf8')], {
      env: { PATH: process.env.PATH, HOME: dir }, encoding: 'utf8', timeout: 20_000 });
    assert.equal(run.status, 0);
    const decoded = JSON.parse(Buffer.from(run.stdout.trim().split(' ')[1], 'base64').toString('utf8'));
    assert.deepEqual(decoded, { v: 1, providers: {}, auth: { codex: null, glm: null, minimax: null } });
  } finally { await cleanup(dir); }
});
