import assert from 'node:assert/strict';
import test from 'node:test';
import { CACHE_MS, GLM_QUOTA_URL, GLM_QUOTA_PATH, createCollector,
  createGlmKeySource, createRequestHandler, mapGlmUsage } from './collector.mjs';

const READ_TOKEN = 'SYNTHETIC_READ_TOKEN_abcdefghijklmnopqrstuvwxyz0123456789';
const NOW = 1800000000000;
const fixture = () => ({ success: true, code: 200, data: { limits: [
  { type: 'TOKENS_LIMIT', percentage: 37.5, currentValue: 999999, usage: 1 },
  { type: 'TIME_LIMIT', percentage: 100 },
] } });
const response = (value) => new Response(JSON.stringify(value), {
  headers: { 'Content-Type': 'application/json' },
});
const collector = (options = {}) => createCollector({ provider: 'glm', readToken: READ_TOKEN,
  clock: () => NOW, authSource: async () => ({ status: 'ok', accessToken: 'synthetic-zai-key' }),
  fetchImpl: async () => response(fixture()), ...options });

test('GLM reports explicit percentages without invented counts, durations or resets', () => {
  const result = mapGlmUsage(fixture(), 'a'.repeat(64), NOW);
  assert.equal(result.source, 'glm.codingPlan');
  assert.equal(result.account.status, 'sourceBound');
  assert.equal(result.ordinaryUsageAllowed, null);
  assert.deepEqual(result.windows, [
    { id: 'tokens', status: 'reported', usedPercent: 37.5 },
    { id: 'mcp', status: 'reported', usedPercent: 100 },
  ]);
});

test('GLM live shape: five-hour and weekly token windows with resets', () => {
  // Shape seen from the live API on 2026-10-13 (values synthetic).
  const live = { code: 200, success: true, data: { level: 'max', limits: [
    { type: 'TIME_LIMIT', unit: 5, number: 1, usage: 4000, remaining: 4000, percentage: 0,
      nextResetTime: NOW + 380 * 3600_000, usageDetails: [{ modelCode: 'search-prime', usage: 0 }] },
    { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 1, nextResetTime: NOW + 3600_000 },
    { type: 'TOKENS_LIMIT', unit: 6, number: 1, percentage: 12, nextResetTime: NOW + 23 * 3600_000 },
  ] } };
  const result = mapGlmUsage(live, 'a'.repeat(64), NOW);
  assert.equal(result.status, 'ok');
  assert.deepEqual(result.windows, [
    { id: 'mcp', status: 'reported', usedPercent: 0, resetsAtMs: NOW + 380 * 3600_000 },
    { id: 'tokens.5h', status: 'reported', usedPercent: 1, durationSeconds: 18_000,
      resetsAtMs: NOW + 3600_000 },
    { id: 'tokens.1w', status: 'reported', usedPercent: 12, durationSeconds: 604_800,
      resetsAtMs: NOW + 23 * 3600_000 },
  ]);
  const odd = structuredClone(live); odd.data.limits[1].unit = 9;
  assert.deepEqual(mapGlmUsage(odd, 'a'.repeat(64), NOW).windows[1],
    { id: 'tokens.5u9', status: 'reported', usedPercent: 1, resetsAtMs: NOW + 3600_000 });
  const twin = structuredClone(live); twin.data.limits[2].unit = 3; twin.data.limits[2].number = 5;
  assert.throws(() => mapGlmUsage(twin, 'a'.repeat(64), NOW));
  const badReset = structuredClone(live); badReset.data.limits[1].nextResetTime = 'soon';
  assert.throws(() => mapGlmUsage(badReset, 'a'.repeat(64), NOW));
});

test('GLM unknown, duplicate and malformed windows fail visibly', async () => {
  for (const percent of [-1, 101, '50', {}, NaN]) {
    const body = fixture(); body.data.limits[0].percentage = percent;
    // NaN becomes null in JSON, which is explicitly missing rather than zero.
    const result = await collector({ fetchImpl: async () => response(body) }).readSnapshot();
    if (Number.isNaN(percent)) assert.equal(result.windows[0].status, 'missing');
    else assert.equal(result.status, 'invalidResponse');
  }
  const unknown = fixture(); unknown.data.limits[0].type = 'CREDIT_LIMIT';
  assert.equal(mapGlmUsage(unknown, 'a'.repeat(64), NOW).status, 'unsupported');
  const duplicate = fixture(); duplicate.data.limits.push(duplicate.data.limits[0]);
  assert.equal((await collector({ fetchImpl: async () => response(duplicate) }).readSnapshot()).status, 'invalidResponse');
  const missing = fixture(); delete missing.data.limits[0].percentage;
  assert.deepEqual(mapGlmUsage(missing, 'a'.repeat(64), NOW).windows[0], { id: 'tokens', status: 'missing' });
  const error = { success: false, code: 401, msg: 'private synthetic error' };
  const result = mapGlmUsage(error, 'a'.repeat(64), NOW);
  assert.equal(result.status, 'unavailable');
  assert.deepEqual(result.windows, []);
  assert.equal(JSON.stringify(result).includes('private'), false);
});

test('GLM raw API key uses only fixed global host, cache and key rotation', async () => {
  let key = 'synthetic-key-A', reads = 0, now = NOW;
  const instance = collector({ clock: () => now,
    authSource: async () => ({ status: 'ok', accessToken: key }),
    fetchImpl: async (url, options) => {
      reads++;
      assert.equal(url, GLM_QUOTA_URL);
      assert.equal(options.headers.Authorization, key);
      assert.equal(options.redirect, 'error');
      assert.equal(options.headers['ChatGPT-Account-Id'], undefined);
      return response(fixture());
    },
  });
  const first = await instance.readSnapshot();
  await instance.readSnapshot(); assert.equal(reads, 1);
  key = 'synthetic-key-B';
  const second = await instance.readSnapshot();
  assert.notEqual(first.account.ref, second.account.ref); assert.equal(reads, 2);
  now += CACHE_MS; await instance.readSnapshot(); assert.equal(reads, 3);
});

test('GLM key loader is explicit and route requires collector authorization', async () => {
  let reads = 0;
  assert.equal((await createGlmKeySource({ readFile: async () => { reads++; } })()).status, 'unconfigured');
  assert.equal(reads, 0);
  const source = createGlmKeySource({ filePath: '/synthetic/key',
    readFile: async () => new TextEncoder().encode('synthetic-zai-key\n') });
  assert.equal((await source()).accessToken, 'synthetic-zai-key');
  const handler = createRequestHandler({ readToken: READ_TOKEN, glmCollector: collector() });
  for (const [auth, path, expected] of [
    ['', GLM_QUOTA_PATH, 401], [`Bearer ${READ_TOKEN}`, `${GLM_QUOTA_PATH}?x=1`, 404],
    [`Bearer ${READ_TOKEN}`, GLM_QUOTA_PATH, 200],
  ]) {
    let status;
    await handler({ socket: { remoteAddress: '127.0.0.1' }, method: 'GET', url: path,
      headers: { authorization: auth }, rawHeaders: [] },
    { writeHead(value) { status = value; }, end() {} });
    assert.equal(status, expected);
  }
});
