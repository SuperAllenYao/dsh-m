/**
 * p1-lite-list.mjs — P1.5-A lite `session/list` (plugin side).
 *
 * Covers the opt-in projection trim end to end, without a DSH host or real
 * device (handler-level exercise like test/m2-transport.mjs):
 *
 *   1. row shape: a synthetic session/list row with the real projection key set
 *      keeps every field the App list/detail derive path reads;
 *   2. a ~1 MB synthetic-but-real-shaped fixture (~80 busy sessions with the
 *      real projection key set) trims to <15% and keeps the envelope;
 *   3. legacy path (`POST /api/session/list`): no opt-in => response bytes are
 *      byte-for-byte the upstream bytes; header opt-in => trimmed; body-hint
 *      opt-in => trimmed AND the upstream request is byte-identical to the
 *      legacy request (hint stripped);
 *   4. unrelated endpoints / error bodies are never rewritten;
 *   5. gzip still works on the trimmed body; config `features.listLite:false`
 *      is a full kill switch;
 *   6. P1 `forwardP1Unary` honors the same signals (frame `headers` or body
 *      hint) and returns trimmed bytes;
 *   7. instrumentation: counters + audit `unary.list-lite` records.
 *
 * Runs standalone:
 *   node test/p1-lite-list.mjs [--out-dir <dir>]
 */

import { createServer as createHttpServer } from 'node:http';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { gunzipSync } from 'node:zlib';

import { AuditLog } from '../lib/audit.js';
import {
  detectListLiteRequest,
  LITE_ITEM_FIELDS,
  LITE_PROJECTION_FIELDS,
  LIST_LITE_HEADER,
  trimSessionListResponse,
} from '../lib/list-lite.js';
import { LinkServer } from '../lib/link-server.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const checks = [];
const startedAt = Date.now();

function record(name, ok, detail) {
  checks.push({ name, ok: ok === true, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' — ' + JSON.stringify(detail)));
  if (!ok) throw new Error('check failed: ' + name);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// ------------------------------------------------------------------ fixtures

/** A 3-row `session/list` value with the real projection key set.
 *  Self-contained (no externally captured fixture), so a clean clone runs this
 *  suite without the development `spikes/` tree. */
function fixtureSessionListValue() {
  const value = { items: [busySessionRow(0), busySessionRow(1), busySessionRow(2)] };
  assert(Array.isArray(value.items) && value.items.length === 3, 'synthetic sessionList fixture malformed');
  return value;
}

function serverResponse(value) {
  return { type: 'server-response', rpcId: 'rpc-lite-fixture', result: { ok: true, value } };
}

/** Real projection key set + realistic heavy payloads (turnOutline dominates). */
function busySessionRow(index) {
  const base = 1_792_510_000_000 + index * 60_000;
  const turns = Array.from({ length: 24 }, (_, turn) => ({
    turn: turn + 1,
    seq: (turn + 1) * 4,
    prompt: '第 ' + (turn + 1) + ' 轮：请分析远程列表 1MB 响应里哪些 projection 是列表必需字段，并给出裁剪白名单与验收口径。'.repeat(2),
    response: '结论：列表只保留 title / sessionListMetadata / userQuestions.active / contextPressure；turnOutline、todos、subagentCatalog 等详情状态走 session/follow。'.repeat(3),
  }));
  return {
    sessionId: 'session-' + String(index).padStart(4, '0') + '-6cd1-4a12-a78e-20a17c9e39c5',
    updatedAt: base,
    agentAvailable: index % 2 === 0,
    formatStatus: 'current',
    running: index % 7 === 0,
    blank: index % 11 === 0,
    cwd: '/Users/dev/workspace/repo-' + (index % 3),
    projections: {
      kind: 'sequenced',
      asOfSeq: 100 + index,
      values: {
        title: '会话 ' + index + '：远程连接性能重构 P1.5 数据面',
        goal: { id: 'goal-' + index, revision: 2, objective: '把 session/list 从 ~1MB 降到列表必需字段', phase: 'active', maxGoalRounds: 8 },
        tokenUsage: { uncachedInputTokens: 12000 + index, outputTokens: 3400, cacheReadTokens: 99000, cacheWriteTokens: 512 },
        contextPressure: { contextWindow: 1_000_000, usedTokens: 12000 + index, pressureTokens: 15000, projectedTokens: 18000 },
        contextBreakdown: { systemTokens: 1406, toolsTokens: 6902, messageTokens: 840 },
        inbox: { 'next-turn': [], 'next-step': [] },
        sessionStats: { turns: 24, steps: 31, llmMs: 81_000, toolMs: 42_000, ttftMs: 900, ttftSteps: 2, decodeMs: 70_000, decodeTokens: 31_000 },
        turnOutline: turns,
        agentPreset: 'standard',
        userQuestions: {
          active: index % 5 === 0 ? [{ callId: 'call-' + index, state: 'open', questions: [{ id: 'q1', text: '是否继续？' }] }] : [],
          settled: [{ callId: 'settled-' + index, state: 'answered' }],
        },
        permissions: { currentValue: 'workspace-write' },
        workingDirectory: '/Users/dev/workspace/repo-' + (index % 3),
        subagentCatalog: [{ childId: 'child-' + index + '-1', label: '探索子代理 ' + index, mode: 'continuable', childCreatedAt: base - 5000 }],
        subagentTiming: { settledMs: 1234 },
        subagent: null,
        todos: [{ content: '盘点列表字段', status: 'completed' }, { content: '裁剪 projection', status: 'in_progress' }],
        plan: { active: true, pending: false },
        modelSelection: { lastUsed: { provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high' }, next: { provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high' } },
        sessionListMetadata: { blank: index % 11 === 0, lastPromptAt: base - 1000 },
        imageLimits: { maxImageBytes: 20_971_520, maxImagesPerMessage: 20, maxMessageImageBytes: 209_715_200, maxImagePixels: 64_000_000, maxImageDimension: 8192, mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'] },
      },
    },
  };
}

/** ~1 MB: 80 busy sessions with the real 20-key projection block. */
function bigSessionListValue(count = 80) {
  return { items: Array.from({ length: count }, (_, index) => busySessionRow(index)) };
}

function clientRequestText(method, args, rpcId = 'rpc-lite-1') {
  return JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } });
}

// ------------------------------------------------------------ HTTP fixtures

function fakeRequest({ method = 'POST', url = '/', bodyText, headers = {} } = {}) {
  const request = Readable.from(bodyText === undefined ? [] : [Buffer.from(bodyText, 'utf8')]);
  request.method = method;
  request.url = url;
  request.headers = headers;
  request.socket = { remoteAddress: '127.0.0.1' };
  return request;
}

function fakeResponse() {
  return {
    statusCode: 0,
    headers: {},
    body: Buffer.alloc(0),
    headersSent: false,
    writeHead(status, headers) {
      this.statusCode = status;
      this.headers = {};
      for (const [name, value] of Object.entries(headers ?? {})) this.headers[name.toLowerCase()] = value;
      this.headersSent = true;
    },
    end(chunk) {
      if (chunk !== undefined && chunk !== null) {
        this.body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
      }
    },
  };
}

function makeServer({ upstreamOrigin, config = {}, home }) {
  const ctx = {
    state: { active: true },
    get: (name) => (name === 'dshHomePath' ? home : undefined),
    webServer: { getOrigin: () => upstreamOrigin },
    connection: { authenticatedUrl: (url) => url },
  };
  const server = new LinkServer(ctx, {
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
    ...config,
  });
  server.audit = new AuditLog({ dir: join(home, 'audit') });
  server.authorizeApi = () => ({ device: { deviceId: 'dev-lite-list' } });
  server.ensurePeer = () => ({ cookie: { name: 'upstream', value: 'test-cookie' }, connect: async () => {} });
  return server;
}

async function callUnary(server, { path = '/api/session/list', headers = {}, bodyText } = {}) {
  const response = fakeResponse();
  await server.handleRequest(
    fakeRequest({
      method: 'POST',
      url: path,
      bodyText,
      headers: { 'content-type': 'application/json', ...headers },
    }),
    response
  );
  return response;
}

function responseJSON(response) {
  return JSON.parse(response.body.toString('utf8'));
}

function assertWhitelistOnly(items, label) {
  const allowedItem = new Set([...LITE_ITEM_FIELDS, 'projections']);
  const allowedProjections = new Set([...LITE_PROJECTION_FIELDS]);
  for (const item of items) {
    for (const key of Object.keys(item)) {
      assert(allowedItem.has(key), label + ': unexpected row field ' + key);
    }
    assert(item.projections !== undefined, label + ': projections block missing (App derives title/time from it)');
    for (const key of Object.keys(item.projections.values ?? {})) {
      assert(allowedProjections.has(key), label + ': unexpected projection ' + key);
    }
    assert(item.projections.values !== undefined, label + ': projections.values missing');
    const questions = item.projections.values.userQuestions;
    if (questions !== undefined) {
      assert(Object.keys(questions).every((key) => key === 'active'), label + ': userQuestions.settled must be dropped');
    }
    const metadata = item.projections.values.sessionListMetadata;
    if (metadata !== undefined) {
      assert(Object.keys(metadata).every((key) => key === 'lastPromptAt' || key === 'blank'), label + ': sessionListMetadata extra sub-fields');
    }
  }
}

function assertItemDerivedFieldsPreserved(originalItems, liteItems, label) {
  assert(originalItems.length === liteItems.length, label + ': item count changed');
  for (let index = 0; index < originalItems.length; index += 1) {
    const full = originalItems[index];
    const lite = liteItems[index];
    for (const field of LITE_ITEM_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(full, field)) continue;
      assert(JSON.stringify(lite[field]) === JSON.stringify(full[field]), label + ': row field changed: ' + field);
    }
    const fullValues = full.projections?.values ?? {};
    const liteValues = lite.projections?.values ?? {};
    for (const key of LITE_PROJECTION_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(fullValues, key)) continue;
      assert(Object.prototype.hasOwnProperty.call(liteValues, key), label + ': projection dropped: ' + key);
      if (key === 'userQuestions') {
        assert(JSON.stringify(liteValues[key].active) === JSON.stringify(fullValues[key].active), label + ': userQuestions.active changed');
      } else if (key === 'sessionListMetadata') {
        if (Object.prototype.hasOwnProperty.call(fullValues[key], 'lastPromptAt')) {
          assert(liteValues[key].lastPromptAt === fullValues[key].lastPromptAt, label + ': lastPromptAt changed');
        }
      } else {
        assert(JSON.stringify(liteValues[key]) === JSON.stringify(fullValues[key]), label + ': projection changed: ' + key);
      }
    }
    assert(lite.sessionId === full.sessionId && lite.projections.kind === full.projections.kind && lite.projections.asOfSeq === full.projections.asOfSeq, label + ': row identity/watermark changed');
  }
}

function countAuditEvents(home, event) {
  try {
    const text = readFileSync(join(home, 'audit', 'audit.log'), 'utf8');
    return text
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line))
      .filter((entry) => entry.event === event);
  } catch {
    return [];
  }
}

// --------------------------------------------------------------------- run

async function run() {
  mkdirSync(OUT_DIR, { recursive: true });
  const home = mkdtempSync(join(tmpdir(), 'dshm-p15-lite-'));
  const cleanup = [() => rmSync(home, { recursive: true, force: true })];

  // Upstream "DSH host": answers every POST with the current fixture body and
  // records the exact request text so byte-identity can be asserted.
  let upstreamStatus = 200;
  let upstreamBodyText = '';
  const upstreamRequests = [];
  const upstream = createHttpServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      upstreamRequests.push({ url: request.url, text });
      response.writeHead(upstreamStatus, { 'content-type': 'application/json', 'content-length': String(Buffer.byteLength(upstreamBodyText)) });
      response.end(upstreamBodyText);
    });
  });
  await new Promise((done) => upstream.listen(0, '127.0.0.1', done));
  cleanup.push(() => new Promise((done) => upstream.close(done)));
  const upstreamOrigin = 'http://127.0.0.1:' + upstream.address().port;

  try {
    // ================================================================ 1. pure trims
    const fixtureValue = fixtureSessionListValue();
    const fixtureFullText = JSON.stringify(serverResponse(fixtureValue));
    const fixtureTrimmed = trimSessionListResponse(Buffer.from(fixtureFullText, 'utf8'));
    assert(fixtureTrimmed !== undefined, 'fixture sample must be trimmable');
    const fixtureLiteValue = JSON.parse(fixtureTrimmed.bytes.toString('utf8'));
    assert(fixtureLiteValue.type === 'server-response' && fixtureLiteValue.rpcId === 'rpc-lite-fixture' && fixtureLiteValue.result.ok === true, 'fixture envelope must be preserved');
    assertWhitelistOnly(fixtureLiteValue.result.value.items, 'row-shape-fixture');
    assertItemDerivedFieldsPreserved(fixtureValue.items, fixtureLiteValue.result.value.items, 'row-shape-fixture');
    record('row-shape-fixture-whitelist-preserved', true, { items: fixtureValue.items.length, fullBytes: fixtureTrimmed.stats.fullBytes, liteBytes: fixtureTrimmed.stats.liteBytes });

    const bigValue = bigSessionListValue();
    const bigFullText = JSON.stringify(serverResponse(bigValue));
    assert(Buffer.byteLength(bigFullText) > 1024 * 1024, 'synthetic fixture must exceed 1 MiB, got ' + Buffer.byteLength(bigFullText));
    const bigTrimmed = trimSessionListResponse(Buffer.from(bigFullText, 'utf8'));
    assert(bigTrimmed !== undefined, 'big fixture must be trimmable');
    const ratio = bigTrimmed.stats.liteBytes / bigTrimmed.stats.fullBytes;
    assert(ratio < 0.15, 'lite response must be <15% of the full bytes, got ' + (ratio * 100).toFixed(2) + '%');
    const bigLiteValue = JSON.parse(bigTrimmed.bytes.toString('utf8'));
    assertWhitelistOnly(bigLiteValue.result.value.items, 'big-fixture');
    assertItemDerivedFieldsPreserved(bigValue.items, bigLiteValue.result.value.items, 'big-fixture');
    assert(bigLiteValue.result.value.items.length === bigValue.items.length, 'big fixture item count must be preserved');
    record('big-fixture-lite-under-15pct', true, {
      items: bigValue.items.length,
      fullBytes: bigTrimmed.stats.fullBytes,
      liteBytes: bigTrimmed.stats.liteBytes,
      ratioPct: Math.round(ratio * 10000) / 100,
      savedRatio: bigTrimmed.stats.savedRatio,
    });

    // Unknown/malformed payloads are never rewritten by the trimmer itself.
    assert(trimSessionListResponse(Buffer.from('not json', 'utf8')) === undefined, 'non-JSON must return undefined');
    assert(trimSessionListResponse(Buffer.from(JSON.stringify({ type: 'server-response', result: { ok: false, error: { code: 'x' } } }), 'utf8')) === undefined, 'error envelope must return undefined');

    // ============================================================ 2. legacy HTTP
    const { server } = { server: makeServer({ upstreamOrigin, home }) };
    const legacyBody = clientRequestText('session/list', { _request: {} });
    const hintBody = clientRequestText('session/list', { _request: { listMode: 'lite' } });
    const fullResponseText = bigFullText;

    upstreamBodyText = fullResponseText;
    upstreamRequests.length = 0;
    let countersBefore = { ...server.counters };
    let response = await callUnary(server, { bodyText: legacyBody });
    assert(response.statusCode === 200, 'legacy response status');
    assert(response.body.toString('utf8') === fullResponseText, 'no opt-in => response bytes must be byte-for-byte upstream');
    assert(response.headers[LIST_LITE_HEADER] === undefined, 'no opt-in => no lite marker header');
    assert(upstreamRequests[0].text === legacyBody, 'no opt-in => upstream request must be byte-for-byte');
    assert(server.counters.listLiteResponses === countersBefore.listLiteResponses && server.counters.listLiteFullBytes === 0, 'no opt-in => lite counters untouched');
    record('legacy-client-byte-identical', true, { bytes: response.body.length });

    // header opt-in
    countersBefore = { ...server.counters };
    upstreamRequests.length = 0;
    response = await callUnary(server, { bodyText: legacyBody, headers: { [LIST_LITE_HEADER]: '1' } });
    assert(response.statusCode === 200, 'header opt-in status');
    assert(response.headers[LIST_LITE_HEADER] === '1', 'header opt-in => lite marker header');
    const headerLiteValue = responseJSON(response);
    assertWhitelistOnly(headerLiteValue.result.value.items, 'legacy-header');
    assertItemDerivedFieldsPreserved(bigValue.items, headerLiteValue.result.value.items, 'legacy-header');
    assert(response.body.length / Buffer.byteLength(fullResponseText) < 0.15, 'header opt-in => lite body <15%');
    assert(upstreamRequests[0].text === legacyBody, 'header opt-in must not change the upstream request');
    assert(server.counters.listLiteResponses === countersBefore.listLiteResponses + 1, 'header opt-in => counter');
    assert(server.counters.listLiteFullBytes === countersBefore.listLiteFullBytes + Buffer.byteLength(fullResponseText), 'header opt-in => full byte counter');
    assert(server.counters.listLiteBytes === countersBefore.listLiteBytes + response.body.length, 'header opt-in => lite byte counter');
    record('legacy-header-opt-in-trims', true, { fullBytes: Buffer.byteLength(fullResponseText), liteBytes: response.body.length });

    // body-hint opt-in: trimmed response AND a byte-identical legacy upstream request
    upstreamRequests.length = 0;
    response = await callUnary(server, { bodyText: hintBody });
    assert(response.statusCode === 200, 'body-hint status');
    assert(response.headers[LIST_LITE_HEADER] === '1', 'body-hint => lite marker header');
    assertItemDerivedFieldsPreserved(bigValue.items, responseJSON(response).result.value.items, 'legacy-body-hint');
    assert(upstreamRequests[0].text === legacyBody, 'body hint must be stripped so the upstream request is byte-identical, got ' + upstreamRequests[0].text.slice(0, 120));
    record('legacy-body-hint-stripped-upstream', true, { upstreamBytes: Buffer.byteLength(upstreamRequests[0].text) });

    // Hint on a different endpoint must be ignored entirely.
    upstreamRequests.length = 0;
    response = await callUnary(server, {
      path: '/api/session/follow',
      bodyText: clientRequestText('session/follow', { _request: { listMode: 'lite' } }),
    });
    assert(response.body.toString('utf8') === fullResponseText, 'other endpoints must never be trimmed');
    assert(upstreamRequests[0].text === clientRequestText('session/follow', { _request: { listMode: 'lite' } }), 'other endpoints must not have their body rewritten');
    record('other-endpoints-untouched', true, { path: '/api/session/follow' });

    // Error body with the opt-in: never rewritten (App needs the real error).
    upstreamStatus = 500;
    const errorBodyText = JSON.stringify({ type: 'server-response', rpcId: 'rpc-err', result: { ok: false, error: { code: 'session/list-failed', message: 'boom' } } });
    upstreamBodyText = errorBodyText;
    response = await callUnary(server, { bodyText: legacyBody, headers: { [LIST_LITE_HEADER]: '1' } });
    upstreamStatus = 200;
    upstreamBodyText = fullResponseText;
    assert(response.statusCode === 500, 'error status passthrough');
    assert(response.body.toString('utf8') === errorBodyText, 'error body must never be trimmed');
    assert(response.headers[LIST_LITE_HEADER] === undefined, 'error response must not carry the lite marker');
    record('error-body-untouched', true, { status: 500 });

    // gzip still applies to the trimmed body.
    response = await callUnary(server, { bodyText: legacyBody, headers: { [LIST_LITE_HEADER]: '1', 'accept-encoding': 'gzip' } });
    assert(response.headers['content-encoding'] === 'gzip', 'lite + gzip => content-encoding gzip');
    const inflated = gunzipSync(response.body).toString('utf8');
    assertWhitelistOnly(JSON.parse(inflated).result.value.items, 'legacy-gzip');
    assert(Buffer.byteLength(inflated) / Buffer.byteLength(fullResponseText) < 0.15, 'gzip body must inflate to the lite JSON');
    record('lite-gzip-still-works', true, { gzipBytes: response.body.length, liteBytes: Buffer.byteLength(inflated) });

    // kill switch
    const disabled = makeServer({ upstreamOrigin, home, config: { features: { listLite: false } } });
    assert(disabled.config.features.listLite === false, 'features.listLite=false must stick');
    response = await callUnary(disabled, { bodyText: legacyBody, headers: { [LIST_LITE_HEADER]: '1' } });
    assert(response.body.toString('utf8') === fullResponseText, 'kill switch => byte-identical full response');
    assert(response.headers[LIST_LITE_HEADER] === undefined, 'kill switch => no lite marker');
    assert(disabled.counters.listLiteResponses === 0, 'kill switch => no lite counters');
    record('config-kill-switch', true, { listLite: disabled.config.features.listLite });

    // ============================================================ 3. P1 forwarder
    const p1Plan = detectListLiteRequest({ endpoint: 'session/list', headers: { 'X-DSHM-LIST-LITE': 'true' }, bodyText: legacyBody });
    assert(p1Plan.lite === true && p1Plan.source === 'header', 'P1 header signal must be detected case-insensitively');
    const p1Stripped = detectListLiteRequest({ endpoint: 'session/list', bodyText: hintBody });
    assert(p1Stripped.lite === true && p1Stripped.bodyText === legacyBody, 'P1 body hint must normalize to the legacy body exactly');
    record('detect-signals', true, { headerSource: p1Plan.source, bodyStripped: p1Stripped.bodyText === legacyBody });

    upstreamRequests.length = 0;
    upstreamBodyText = fullResponseText;
    let p1Result = await server.forwardP1Unary({ deviceId: 'dev-lite-list' }, { endpoint: 'session/list', bodyText: legacyBody });
    assert(p1Result.bytes.toString('utf8') === fullResponseText, 'P1 no opt-in => upstream bytes untouched');
    assert(p1Result.listLite === undefined, 'P1 no opt-in => no lite stats');
    assert(upstreamRequests[0].text === legacyBody, 'P1 no opt-in => upstream request untouched');
    record('p1-no-opt-in-untouched', true, { bytes: p1Result.bytes.length });

    upstreamRequests.length = 0;
    p1Result = await server.forwardP1Unary({ deviceId: 'dev-lite-list' }, { endpoint: 'session/list', bodyText: legacyBody, headers: { [LIST_LITE_HEADER]: '1' } });
    assert(p1Result.listLite !== undefined, 'P1 header opt-in => lite stats');
    assert(p1Result.bytes.length / Buffer.byteLength(fullResponseText) < 0.15, 'P1 header opt-in => <15% bytes');
    assertWhitelistOnly(JSON.parse(p1Result.bytes.toString('utf8')).result.value.items, 'p1-header');
    assert(upstreamRequests[0].text === legacyBody, 'P1 header opt-in must not change the upstream request');
    record('p1-header-opt-in-trims', true, { fullBytes: Buffer.byteLength(fullResponseText), liteBytes: p1Result.bytes.length });

    upstreamRequests.length = 0;
    p1Result = await server.forwardP1Unary({ deviceId: 'dev-lite-list' }, { endpoint: 'session/list', bodyText: hintBody });
    assert(p1Result.listLite !== undefined, 'P1 body-hint => lite stats');
    assert(upstreamRequests[0].text === legacyBody, 'P1 body hint must be stripped upstream');
    record('p1-body-hint-trims', true, { liteBytes: p1Result.bytes.length });

    // ============================================================ 4. audit/counters
    const liteAudit = countAuditEvents(home, 'unary.list-lite');
    assert(liteAudit.length >= 4, 'expected >=4 unary.list-lite audit records, got ' + liteAudit.length);
    const legacyAudit = liteAudit.filter((entry) => entry.transport === 'legacy');
    const p1Audit = liteAudit.filter((entry) => entry.transport === 'p1');
    assert(legacyAudit.length >= 2 && p1Audit.length >= 2, 'audit must tag both transports');
    for (const entry of liteAudit) {
      assert(entry.fullBytes > entry.liteBytes && entry.liteBytes > 0, 'audit byte fields must show the saving');
      assert(typeof entry.savedRatio === 'number' && entry.savedRatio > 0.8, 'audit savedRatio must be >0.8');
      assert(entry.deviceId === 'dev-lite-list' && entry.endpoint === '/api/session/list' || entry.endpoint === 'session/list', 'audit endpoint');
    }
    record('instrumentation-counters-audit', true, {
      auditRecords: liteAudit.length,
      legacy: legacyAudit.length,
      p1: p1Audit.length,
      savedRatio: legacyAudit[0].savedRatio,
    });

    const report = {
      startedAt: new Date(startedAt).toISOString(),
      durationMs: Date.now() - startedAt,
      fixture: { items: bigValue.items.length, fullBytes: Buffer.byteLength(fullResponseText), liteBytes: bigTrimmed.stats.liteBytes },
      checks,
      pass: checks.length,
      fail: 0,
    };
    writeFileSync(join(OUT_DIR, 'p1-lite-list-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
    console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
  } finally {
    for (const fn of cleanup.reverse()) await fn();
  }
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
});
