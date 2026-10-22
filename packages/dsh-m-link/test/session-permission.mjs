/**
 * session-permission.mjs — M5 plugin tests for `POST /session/permission`.
 *
 * Covers:
 *   1. pure request/catalog/apply logic against a fake host service pair
 *      (validation, session-not-found, preset-unavailable, host-unavailable,
 *      previous capture, set failure, catalog failure);
 *   2. the route handler end-to-end at the HTTP-handler level: device auth is
 *      required before the body is read, success returns the catalog and writes
 *      an audit record, revoked/invalid auth passes through, GET is rejected;
 *   3. the opt-in device list behavior is exercised only through the pure
 *      `revoked` flag contract (client.js is a browser bundle).
 *
 * Runs standalone (no DSH host, no ~/.dsh):
 *   node test/session-permission.mjs
 */

import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';

import { LinkServer } from '../lib/link-server.js';
import {
  applySessionPermission,
  catalogView,
  normalizePermissionRequest,
  readHostServices,
  SESSION_PERMISSION_PATH,
} from '../lib/session-permission.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const checks = [];
const startedAt = Date.now();

function record(name, ok, detail) {
  checks.push({ name, ok, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' — ' + JSON.stringify(detail)));
  if (!ok) throw new Error('check failed: ' + name);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// ---------------------------------------------------------------- fixtures

const CATALOG = {
  options: [
    { value: 'read-only', name: '只读', description: '只能读取工作区' },
    { value: 'workspace-write', name: '工作区可写', description: '可在工作区内写入' },
    { value: 'danger-full-access', name: '完全访问' },
    { bogus: true },
    { value: '', name: 'empty' },
  ],
  defaultOptions: [{ value: 'workspace-write', name: '工作区可写' }],
  defaultPreset: 'workspace-write',
};

function makeHostServices(overrides = {}) {
  const session = { id: 'session-abc', agent: { id: 'agent-abc' } };
  const calls = [];
  const services = {
    sessions: {
      get(id) {
        calls.push(['sessions.get', id]);
        return id === session.id ? session : undefined;
      },
    },
    permissionPresets: {
      catalog() {
        calls.push(['permissionPresets.catalog']);
        return CATALOG;
      },
      current(value) {
        calls.push(['permissionPresets.current', value]);
        return 'workspace-write';
      },
      set(value, preset) {
        calls.push(['permissionPresets.set', value, preset]);
      },
    },
  };
  Object.assign(services, overrides);
  return { services, calls, session };
}

function makeCtx(services) {
  return {
    state: { active: true },
    webServer: { getOrigin: () => 'http://127.0.0.1:9' },
    connection: { authenticatedUrl: (url) => url },
    get(name) {
      if (name === 'dshHomePath') return mkdtempSync(join(tmpdir(), 'dshm-m5-perm-'));
      if (name === 'sessions') return services?.sessions;
      if (name === 'permissionPresets') return services?.permissionPresets;
      return undefined;
    },
  };
}

function fakeRequest({ method = 'POST', url = '/', body, headers = {}, ip = '127.0.0.1' } = {}) {
  const request = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  request.method = method;
  request.url = url;
  request.headers = headers;
  request.socket = { remoteAddress: ip };
  return request;
}

function fakeResponse() {
  return {
    statusCode: 0,
    headers: {},
    body: Buffer.alloc(0),
    writeHead(status, headers) {
      this.statusCode = status;
      this.headers = {};
      for (const [name, value] of Object.entries(headers ?? {})) this.headers[name.toLowerCase()] = value;
    },
    end(chunk) {
      if (chunk !== undefined && chunk !== null) {
        this.body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
      }
    },
  };
}

function makeServer(services, { authorize } = {}) {
  const ctx = makeCtx(services);
  const server = new LinkServer(ctx, {
    port: 3467,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
  });
  const audit = [];
  server.audit = { record: (event, data) => audit.push({ event, data }) };
  server.ensurePeer = () => ({ cookie: { name: 'upstream', value: 'test' }, connect: async () => {} });
  if (authorize !== undefined) server.authorizeApi = authorize;
  return { server, audit };
}

async function callRoute(server, { method = 'POST', body, headers = {} } = {}) {
  const response = fakeResponse();
  await server.handleRequest(
    fakeRequest({
      method,
      url: SESSION_PERMISSION_PATH,
      body,
      headers: { 'content-type': 'application/json', ...headers },
    }),
    response
  );
  const text = response.body.length === 0 ? '' : response.body.toString();
  let json;
  try {
    json = text.length === 0 ? undefined : JSON.parse(text);
  } catch {
    json = undefined;
  }
  return { status: response.statusCode, json, text };
}

// ---------------------------------------------------------------- checks

async function run() {
  // 1. pure helpers -------------------------------------------------------
  record('normalize-accepts-valid-body', JSON.stringify(normalizePermissionRequest({ sessionId: 's1', preset: 'read-only' })) === JSON.stringify({ sessionId: 's1', preset: 'read-only' }));
  for (const [name, body] of [
    ['missing-fields', {}],
    ['non-object', null],
    ['array', []],
    ['empty-strings', { sessionId: ' ', preset: '' }],
    ['wrong-types', { sessionId: 1, preset: 2 }],
  ]) {
    const normalized = normalizePermissionRequest(body);
    record('normalize-rejects-' + name, normalized.error === 'permission/bad-request' && normalized.status === 400);
  }

  const view = catalogView(CATALOG);
  record('catalog-view-keeps-valid-options', view.options.length === 3 && view.options[0].value === 'read-only' && view.options[0].description === '只能读取工作区');
  record('catalog-view-drops-unknown-fields', view.options.every((option) => option.bogus === undefined));
  record('catalog-view-keeps-default', view.defaultPreset === 'workspace-write');
  record('catalog-view-tolerates-garbage', catalogView(undefined).options.length === 0 && catalogView(null).defaultPreset === undefined);

  record('services-missing-is-undefined', readHostServices(makeCtx(undefined)) === undefined);

  // 2. applySessionPermission ---------------------------------------------
  {
    const { services, calls } = makeHostServices();
    const result = applySessionPermission({ ctx: makeCtx(services), sessionId: 'session-abc', preset: 'read-only' });
    record('apply-succeeds', result.ok === true && result.status === 200 && result.preset === 'read-only' && result.previous === 'workspace-write');
    record('apply-returns-catalog', result.catalog?.options?.length === 3 && result.catalog.defaultPreset === 'workspace-write');
    record('apply-calls-set-once', calls.filter((call) => call[0] === 'permissionPresets.set').length === 1 && calls.at(-1)[2] === 'read-only');
  }
  {
    const { services } = makeHostServices();
    const result = applySessionPermission({ ctx: makeCtx(services), sessionId: 'session-missing', preset: 'read-only' });
    record('apply-unknown-session-404', result.ok === false && result.status === 404 && result.error === 'permission/session-not-found');
  }
  {
    const { services, calls } = makeHostServices();
    const result = applySessionPermission({ ctx: makeCtx(services), sessionId: 'session-abc', preset: 'github-access' });
    record('apply-unknown-preset-409', result.ok === false && result.status === 409 && result.error === 'permission/preset-unavailable' && result.catalog.options.length === 3);
    record('apply-unknown-preset-does-not-write', calls.every((call) => call[0] !== 'permissionPresets.set'));
  }
  {
    const result = applySessionPermission({ ctx: makeCtx(undefined), sessionId: 'session-abc', preset: 'read-only' });
    record('apply-host-unavailable-503', result.ok === false && result.status === 503 && result.error === 'permission/host-unavailable');
  }
  {
    const { services } = makeHostServices({
      permissionPresets: {
        catalog: () => CATALOG,
        current: () => 'read-only',
        set: () => {
          throw new Error('host exploded');
        },
      },
    });
    const result = applySessionPermission({ ctx: makeCtx(services), sessionId: 'session-abc', preset: 'workspace-write' });
    record('apply-set-failure-500', result.ok === false && result.status === 500 && result.error === 'permission/failed');
  }
  {
    const { services } = makeHostServices({
      permissionPresets: {
        catalog: () => {
          throw new Error('catalog exploded');
        },
        current: () => 'read-only',
        set: () => {},
      },
    });
    const result = applySessionPermission({ ctx: makeCtx(services), sessionId: 'session-abc', preset: 'workspace-write' });
    record('apply-catalog-failure-500', result.ok === false && result.status === 500 && result.error === 'permission/failed');
  }

  // 3. route handler ------------------------------------------------------
  {
    const { services } = makeHostServices();
    const { server } = makeServer(services); // real authorizeApi -> no token
    const result = await callRoute(server, { body: { sessionId: 'session-abc', preset: 'read-only' } });
    record('route-requires-auth', result.status === 401 && result.json?.error === 'auth/required');
    // auth happens before the body is read: an unauthorized garbage body is still 401
    const garbage = await callRoute(server, { body: 'not-an-object' });
    record('route-auth-before-body', garbage.status === 401);
    server.dispose();
  }
  {
    const { services } = makeHostServices();
    const { server, audit } = makeServer(services, { authorize: () => ({ device: { deviceId: 'dev-test' } }) });
    const result = await callRoute(server, { body: { sessionId: 'session-abc', preset: 'read-only' } });
    record('route-success-200', result.status === 200 && result.json?.ok === true && result.json.preset === 'read-only' && result.json.previous === 'workspace-write');
    record('route-success-returns-catalog', result.json?.catalog?.options?.length === 3);
    record(
      'route-success-audits',
      audit.some((entry) => entry.event === 'permission.set' && entry.data.deviceId === 'dev-test' && entry.data.sessionId === 'session-abc' && entry.data.preset === 'read-only' && entry.data.previous === 'workspace-write')
    );
    const badBody = await callRoute(server, { body: { sessionId: '', preset: '' } });
    record('route-bad-body-400', badBody.status === 400 && badBody.json?.error === 'permission/bad-request');
    const notFound = await callRoute(server, { body: { sessionId: 'session-missing', preset: 'read-only' } });
    record('route-session-not-found-404', notFound.status === 404 && notFound.json?.error === 'permission/session-not-found');
    record('route-rejected-audited', audit.some((entry) => entry.event === 'permission.rejected' && entry.data.error === 'permission/session-not-found'));
    const getMethod = await callRoute(server, { method: 'GET' });
    record('route-get-rejected', getMethod.status === 404);
    server.dispose();
  }
  {
    const { services } = makeHostServices();
    const { server } = makeServer(services, { authorize: () => ({ error: 'auth/revoked', status: 401 }) });
    const result = await callRoute(server, { body: { sessionId: 'session-abc', preset: 'read-only' } });
    record('route-revoked-401', result.status === 401 && result.json?.error === 'auth/revoked');
    server.dispose();
  }
  {
    const { services } = makeHostServices();
    const { server } = makeServer(services, { authorize: () => ({ device: { deviceId: 'dev-test' } }) });
    server.disposed = true; // simulate a zombie listener while the context is inactive
    const result = await callRoute(server, { body: { sessionId: 'session-abc', preset: 'read-only' } });
    record('route-inactive-context-503', result.status === 503 && result.json?.error === 'host/inactive');
    server.disposed = false;
    server.dispose();
  }

  // ---------------------------------------------------------------- report
  const failed = checks.filter((check) => check.ok !== true);
  const report = {
    suite: 'session-permission',
    startedAt: new Date(startedAt).toISOString(),
    durationMs: Date.now() - startedAt,
    total: checks.length,
    passed: checks.length - failed.length,
    failed: failed.length,
    checks,
  };
  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(join(OUT_DIR, 'session-permission.json'), JSON.stringify(report, null, 2) + '\n');
  console.log('\n== session permission: ' + (failed.length === 0 ? 'GO' : 'FAIL') + ' (' + report.passed + '/' + report.total + ') ==');
  console.log('evidence: ' + join(OUT_DIR, 'session-permission.json'));
  if (failed.length !== 0) process.exitCode = 1;
}

await run();
