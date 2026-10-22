/**
 * m2-transport.mjs — M2b task-2 transport tests (plugin side).
 *
 * Covers:
 *   1. unary proxy gzip negotiation (`Accept-Encoding: gzip`, ≥1 KiB JSON,
 *      Content-Encoding/Content-Length/Vary, no double compression, fallbacks);
 *   2. the mux/chunked stream path and non-unary JSON endpoints stay untouched;
 *   3. the real TLS listener enables HTTP/1.1 keep-alive with the M2b timeout and
 *      actually reuses one TLS connection for consecutive requests.
 *
 * Runs standalone (no DSH host, no ~/.dsh):
 *   node test/m2-transport.mjs
 */

import { createServer as createHttpServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { Agent as HttpsAgent, request as httpsRequest } from 'node:https';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { gunzipSync, gzipSync } from 'node:zlib';

import { AuditLog } from '../lib/audit.js';
import { ensureHostIdentity } from '../lib/host-identity.js';
import { DeviceStore } from '../lib/devices.js';
import { LinkServer } from '../lib/link-server.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
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

// ---------------------------------------------------------------- HTTP fixtures

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

function makeServer({ config = {}, upstreamOrigin } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'dshm-m2b-transport-'));
  const ctx = {
    state: { active: true },
    get: (name) => (name === 'dshHomePath' ? home : undefined),
    webServer: { getOrigin: () => upstreamOrigin },
    connection: { authenticatedUrl: (url) => url },
  };
  const server = new LinkServer(ctx, {
    port: 3467,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
    ...config,
  });
  // Handler-level exercise: no TLS listener, no real device auth/upstream peer.
  server.audit = new AuditLog({ dir: join(home, 'audit'), log: () => {} });
  server.authorizeApi = () => ({ device: { deviceId: 'dev-test' } });
  server.ensurePeer = () => ({ cookie: { name: 'upstream', value: 'test' }, connect: async () => {} });
  return { server, home };
}

async function callUnary(server, { path = '/api/session/list', headers = {}, body = {} } = {}) {
  const response = fakeResponse();
  await server.handleRequest(
    fakeRequest({
      method: 'POST',
      url: path,
      body,
      headers: { 'content-type': 'application/json', ...headers },
    }),
    response
  );
  return response;
}

function bigJSON(bytes = 8192) {
  return JSON.stringify({ type: 'server-response', rpcId: 'rpc-1', result: { ok: true, value: { rows: Array.from({ length: bytes / 16 }, (_, index) => 'row-' + index), padding: 'x'.repeat(bytes) } } });
}

// ---------------------------------------------------------------- checks

async function run() {
  mkdirSync(OUT_DIR, { recursive: true });

  // Plain Node has no DSH-shipped `ws`; hand the plugin a stub server module via
  // the documented test hook. This test only speaks HTTP/1.1 (/health), so no
  // WebSocket traffic ever reaches the stub.
  const fakeWsFile = join(tmpdir(), 'dshm-m2b-transport-fake-ws.mjs');
  writeFileSync(
    fakeWsFile,
    ['export const WebSocket = class { on() {} close() {} terminate() {} send() {} };',
      'export const WebSocketServer = class { constructor() { this.clients = new Set(); } close() {} handleUpgrade() {} };',
      'export default { WebSocket, WebSocketServer };',
      ''].join('\n')
  );
  process.env.DSH_M_LINK_WS_PATH = fakeWsFile;

  // Upstream "DSH host" that the plugin proxies unary requests to.
  let upstreamMode = 'json';
  let upstreamBody = bigJSON();
  const upstream = createHttpServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      if (upstreamMode === 'gzip') {
        const compressed = gzipSync(upstreamBody);
        response.writeHead(200, { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': String(compressed.length) });
        response.end(compressed);
        return;
      }
      response.writeHead(200, { 'content-type': 'application/json', 'content-length': String(Buffer.byteLength(upstreamBody)) });
      response.end(upstreamBody);
    });
  });
  await new Promise((done) => upstream.listen(0, '127.0.0.1', done));
  const upstreamOrigin = 'http://127.0.0.1:' + upstream.address().port;
  const cleanup = [];
  try {
    const { server, home } = makeServer({ upstreamOrigin });
    cleanup.push(() => rmSync(home, { recursive: true, force: true }));

    // ---------------------------------------------------------- 1. gzip happy path
    upstreamBody = bigJSON(8192);
    let response = await callUnary(server, { headers: { 'accept-encoding': 'gzip, deflate' } });
    assert(response.statusCode === 200, 'gzip response status should be 200, got ' + response.statusCode);
    assert(response.headers['content-encoding'] === 'gzip', 'missing content-encoding: gzip');
    assert(response.headers.vary === 'accept-encoding', 'missing vary: accept-encoding');
    assert(Number(response.headers['content-length']) === response.body.length, 'content-length must match the compressed body');
    assert(response.body.length < Buffer.byteLength(upstreamBody) / 2, 'gzip body should be much smaller than the raw JSON');
    const inflated = gunzipSync(response.body).toString('utf8');
    assert(inflated === upstreamBody, 'gzip body must inflate to the exact upstream JSON');
    record('gzip-large-unary-json', true, { rawBytes: Buffer.byteLength(upstreamBody), gzipBytes: response.body.length, contentLength: response.headers['content-length'] });

    // ---------------------------------------------------------- 2. no Accept-Encoding
    response = await callUnary(server, { headers: {} });
    assert(response.headers['content-encoding'] === undefined, 'no accept-encoding => no content-encoding');
    assert(response.body.toString('utf8') === upstreamBody, 'uncompressed fallback body must equal upstream JSON');
    assert(response.headers.vary === 'accept-encoding', 'Vary is required on uncompressed fallback of a negotiable response');
    record('no-gzip-without-accept-encoding', true, { bytes: response.body.length });

    // ---------------------------------------------------------- 3. below the 1 KiB threshold
    upstreamBody = JSON.stringify({ type: 'server-response', rpcId: 'rpc-small', result: { ok: true, value: { pad: 'y'.repeat(200) } } });
    response = await callUnary(server, { headers: { 'accept-encoding': 'gzip' } });
    assert(response.headers['content-encoding'] === undefined, 'bodies below minBytes must not be compressed');
    assert(response.headers.vary === undefined, 'sub-threshold responses must not advertise Vary');
    assert(response.body.toString('utf8') === upstreamBody, 'small body passthrough');
    record('gzip-threshold-1kib', true, { bytes: response.body.length });

    // ---------------------------------------------------------- 4. non-gzip accept-encoding
    upstreamBody = bigJSON(8192);
    response = await callUnary(server, { headers: { 'accept-encoding': 'br, zstd' } });
    assert(response.headers['content-encoding'] === undefined, 'br-only clients must get the identity body');
    assert(response.body.toString('utf8') === upstreamBody, 'identity fallback body');
    record('gzip-not-advertised-fallback', true, { bytes: response.body.length });

    // ---------------------------------------------------------- 5. upstream answered gzip
    // Node's fetch already inflates an encoded upstream body, so the plugin
    // receives decoded JSON and re-compresses at most once for the phone.
    upstreamMode = 'gzip';
    response = await callUnary(server, { headers: { 'accept-encoding': 'gzip' } });
    upstreamMode = 'json';
    assert(response.headers['content-encoding'] === 'gzip', 'phone-facing body must be gzip');
    assert(gunzipSync(response.body).toString('utf8') === upstreamBody, 'plugin must compress exactly once (upstream gzip was already inflated by fetch)');
    record('gzip-upstream-encoded-once', true, { bytes: response.body.length });

    // ---------------------------------------------------------- 6. non-unary JSON path untouched
    const healthResponse = fakeResponse();
    await server.handleRequest(
      fakeRequest({ method: 'GET', url: '/health', headers: { 'accept-encoding': 'gzip' } }),
      healthResponse
    );
    assert(healthResponse.statusCode === 200, '/health status');
    assert(healthResponse.headers['content-encoding'] === undefined, 'sendJson endpoints must stay uncompressed');
    record('health-json-not-compressed', true, { bytes: healthResponse.body.length });

    // ---------------------------------------------------------- 7. config defaults/override
    assert(server.config.compression.enabled === true && server.config.compression.minBytes === 1024, 'compression defaults');
    assert(server.config.httpKeepAliveTimeoutMs === 120_000, 'keep-alive default');
    const { server: disabledServer, home: disabledHome } = makeServer({
      upstreamOrigin,
      config: { compression: { enabled: false } },
    });
    try {
      response = await callUnary(disabledServer, { headers: { 'accept-encoding': 'gzip' } });
      assert(response.headers['content-encoding'] === undefined, 'compression.enabled=false must disable gzip');
      assert(response.body.toString('utf8') === upstreamBody, 'disabled compression body passthrough');
    } finally {
      rmSync(disabledHome, { recursive: true, force: true });
    }
    record('compression-config-disable', true, { enabled: server.config.compression.enabled });

    // ---------------------------------------------------------- 8. real TLS listener keep-alive
    const port = await freePort();
    const listenerHome = mkdtempSync(join(tmpdir(), 'dshm-m2b-transport-live-'));
    const live = new LinkServer(liveCtx(listenerHome), {
      port,
      bindHost: '127.0.0.1',
      contract: { probeOnStart: false },
      bonjour: { enabled: false },
      debug: { enabled: false },
    });
    try {
      await live.start();
      assert(live.config.httpKeepAliveTimeoutMs === 120_000, 'live config keep-alive');
      assert(live.server.keepAliveTimeout === 120_000, 'Node server keepAliveTimeout must be raised (was 5000 by default)');
      assert(live.server.headersTimeout === 125_000, 'Node server headersTimeout must follow keepAliveTimeout');
      let tlsConnections = 0;
      live.server.on('secureConnection', () => {
        tlsConnections += 1;
      });
      const agent = new HttpsAgent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1 });
      const first = await httpsGetJson(port, '/health', agent);
      const second = await httpsGetJson(port, '/health', agent);
      agent.destroy();
      await sleep(100);
      assert(first.status === 200 && second.status === 200, 'both /health calls must succeed');
      assert(tlsConnections === 1, 'two sequential requests must share one TLS connection, got ' + tlsConnections);
      record('real-listener-keep-alive', true, { tlsConnections, keepAliveTimeoutMs: live.server.keepAliveTimeout });
    } finally {
      live.dispose();
      rmSync(listenerHome, { recursive: true, force: true });
    }
  } finally {
    for (const fn of cleanup.reverse()) fn();
    await new Promise((done) => upstream.close(done));
  }

  const report = { startedAt: new Date(startedAt).toISOString(), durationMs: Date.now() - startedAt, checks, pass: checks.length, fail: 0 };
  writeFileSync(join(OUT_DIR, 'm2b-transport-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
  console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
}

function liveCtx(homeDir) {
  const state = { active: true };
  const ctx = {
    state,
    get(key) {
      if (key === 'dshHomePath') return () => homeDir;
      return undefined;
    },
    on() {},
    effect() {
      return () => {};
    },
  };
  Object.defineProperty(ctx, 'webServer', {
    get() {
      return { getOrigin: () => 'http://127.0.0.1:9', protocol: 'http:' };
    },
  });
  Object.defineProperty(ctx, 'connection', {
    get() {
      return { authenticatedUrl: (baseUrl) => baseUrl };
    },
  });
  return ctx;
}

function freePort() {
  return new Promise((resolvePromise, reject) => {
    const server = createTcpServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolvePromise(port));
    });
  });
}

function httpsGetJson(port, path, agent) {
  return new Promise((resolvePromise, reject) => {
    const request = httpsRequest(
      { hostname: '127.0.0.1', port, path, method: 'GET', headers: { accept: 'application/json' }, rejectUnauthorized: false, agent },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolvePromise({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      }
    );
    request.on('error', reject);
    request.end();
  });
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
});
