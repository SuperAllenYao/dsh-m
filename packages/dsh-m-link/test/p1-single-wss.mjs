/**
 * p1-single-wss.mjs — P1 single-WSS transport prototype: real TLS integration.
 *
 * Starts an isolated LinkServer (own temp home, own certs, 127.0.0.1) with
 * `features.muxRpc: true`, hands it `test/lib/ws-server-lite.mjs` through the
 * documented `DSH_M_LINK_WS_PATH` hook (plain Node has no `ws` package), and
 * speaks the P1 protocol over the real pinned WSS listener:
 *
 *   1. anonymous `?proto=2` upgrade, in-band hello auth (one-time mux token);
 *   2. unary RPC + concurrent RPC over that same socket, one TLS connection;
 *   3. upstream stream frames → `down{sid}` envelopes on the same socket;
 *   4. network drop, frames arriving while the phone is away, reconnect with a
 *      resume ticket + `resume{logEpoch,sid}` → exact increment replay;
 *   5. auth negative paths (tampered ticket), resume epoch mismatch;
 *   6. dual-stack guard: a feature-off plugin rejects the `proto=2` upgrade 401
 *      (old clients keep the M1 path untouched).
 *
 * Runs standalone (no DSH host, no ~/.dsh, no real device):
 *   node test/p1-single-wss.mjs [--out-dir <dir>]
 */

import { EventEmitter } from 'node:events';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { LinkServer } from '../lib/link-server.js';
import { WsClient } from './lib/ws-client.mjs';

const WS_SERVER_LITE = resolve(new URL('./lib/ws-server-lite.mjs', import.meta.url).pathname);
// Test hook documented in lib/ws-provider.js: the plugin loads this instead of
// the DSH-shipped `ws` (which lives inside Electron's asar and is unreachable
// from plain Node).
process.env.DSH_M_LINK_WS_PATH = WS_SERVER_LITE;

const DEFAULT_OUT = resolve(new URL('results', import.meta.url).pathname);
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

async function waitFor(predicate, { timeoutMs = 4000, label = 'condition', intervalMs = 5 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await sleep(intervalMs);
  }
  throw new Error('timed out waiting for ' + label);
}

// --------------------------------------------------------------- test fixtures

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
    configurable: true,
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

/** Fake upstream (`ws` remote mux) socket; the plugin only needs this surface. */
class FakeUpstreamMux extends EventEmitter {
  constructor() {
    super();
    this.readyState = 1;
    this.sent = [];
    this.closed = false;
  }

  send(text) {
    this.sent.push(text);
  }

  inject(text) {
    this.emit('message', text, false);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.readyState = 3;
    this.emit('close');
  }
}

/** One P1 phone connection over WSS; collects frames and lets tests await them. */
class P1Client {
  constructor(port, { search = '?proto=2', headers = {} } = {}) {
    this.url = 'wss://127.0.0.1:' + port + '/api/remote.mux' + search;
    this.ws = new WsClient(this.url, { headers });
    this.inbox = [];
    this.waiters = [];
    this.closed = undefined;
    this.rejection = undefined;
    this.ws.on('message', (text) => {
      try {
        this.inbox.push(JSON.parse(text));
      } catch {
        this.inbox.push({ type: 'unparsable', raw: String(text) });
      }
      this.flush();
    });
    this.ws.on('close', (event) => {
      this.closed = event;
      this.flush();
    });
  }

  async open() {
    await new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => reject(new Error('client open timeout')), 5000);
      this.ws.once('open', () => {
        clearTimeout(timer);
        resolvePromise();
      });
      this.ws.once('close', (event) => {
        clearTimeout(timer);
        reject(event?.error ?? new Error('closed before open'));
      });
      this.ws.connect();
    });
    this.rejection = this.ws.rejection;
    return this;
  }

  send(value) {
    this.ws.send(JSON.stringify(value));
  }

  hello(extra = {}) {
    this.send({ type: 'hello', v: 2, client: { name: 'p1-single-wss-test' }, ...extra });
  }

  flush() {
    for (const waiter of [...this.waiters]) waiter();
  }

  waitForFrame(predicate, { timeoutMs = 4000, label = 'frame' } = {}) {
    const found = () => this.inbox.find(predicate);
    if (found() !== undefined) return Promise.resolve(found());
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error('timeout waiting for ' + label + ' (inbox ' + JSON.stringify(this.inbox.map((frame) => frame.type)) + ')'));
      }, timeoutMs);
      const waiter = () => {
        const value = found();
        if (value === undefined) return;
        cleanup();
        resolvePromise(value);
      };
      const cleanup = () => {
        clearTimeout(timer);
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
      };
      this.waiters.push(waiter);
    });
  }

  waitClose({ timeoutMs = 4000 } = {}) {
    if (this.closed !== undefined) return Promise.resolve(this.closed);
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout waiting for close')), timeoutMs);
      const waiter = () => {
        if (this.closed === undefined) return;
        clearTimeout(timer);
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        resolvePromise(this.closed);
      };
      this.waiters.push(waiter);
    });
  }

  terminate() {
    this.ws.terminate();
  }

  close() {
    try {
      this.ws.close();
    } catch {
      /* already gone */
    }
  }
}

function clientRequest(method, args = {}) {
  return { type: 'client-request', rpcId: 'rpc-' + method.replace('/', '-') + '-' + Math.random().toString(36).slice(2, 8), method, payload: { args } };
}

// --------------------------------------------------------------------- setup

async function startFakeUpstream() {
  const requests = [];
  const server = createHttpServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      let body;
      try {
        body = JSON.parse(text);
      } catch {
        body = undefined;
      }
      requests.push({ endpoint: request.url, body, text });
      const method = body?.method ?? 'unknown';
      if (method === 'test/error') {
        response.writeHead(500, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ type: 'server-response', error: { code: 'upstream/boom' } }));
        return;
      }
      const delay = Number(body?.payload?.args?.delay ?? 0);
      setTimeout(() => {
        if (response.destroyed) return;
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ type: 'server-response', rpcId: body?.rpcId, result: { ok: true, method } }));
      }, delay);
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  return { server, origin: 'http://127.0.0.1:' + server.address().port, requests };
}

async function makeDevice(upstreamMux) {
  const device = { deviceId: 'dev-p1-live', downstream: undefined, peer: undefined };
  const peer = {
    cookie: { name: 'upstream', value: 'test-cookie' },
    connect: async () => {},
    ensureMux: async () => upstreamMux,
    close: () => {},
  };
  device.peer = peer;
  return { device, peer };
}

async function startLiveServer({ upstreamOrigin, features, device, peer }) {
  const home = mkdtempSync(join(tmpdir(), 'dshm-p1-live-'));
  const port = await freePort();
  const server = new LinkServer(liveCtx(home), {
    port,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
    ...(features === undefined ? {} : { features }),
  });
  // The fake upstream stands in for the DSH loopback origin.
  Object.defineProperty(server.ctx, 'webServer', {
    configurable: true,
    get() {
      return { getOrigin: () => upstreamOrigin, protocol: 'http:' };
    },
  });
  await server.start();
  server.auth.consumeMuxToken = (token) => (token === 'test-mux-token' ? { device } : { error: 'auth/invalid' });
  server.ensurePeer = () => peer;
  server.devices.get = (deviceId) => (deviceId === device.deviceId ? device : undefined);
  const connections = { count: 0 };
  server.server.on('secureConnection', () => {
    connections.count += 1;
  });
  return { server, home, port, connections };
}

// ----------------------------------------------------------------------- main

async function run() {
  const outDirArg = process.argv.indexOf('--out-dir');
  const outDir = outDirArg >= 0 ? resolve(process.argv[outDirArg + 1]) : DEFAULT_OUT;
  mkdirSync(outDir, { recursive: true });
  const upstream = await startFakeUpstream();
  const upstreamMux = new FakeUpstreamMux();
  const { device, peer } = await makeDevice(upstreamMux);
  /** @type {{server: LinkServer, home: string, port: number} | undefined} */
  let live;
  /** @type {{server: LinkServer, home: string, port: number} | undefined} */
  let legacy;
  live = await startLiveServer({
    upstreamOrigin: upstream.origin,
    features: { muxRpc: true, muxRpcResumeWindowMs: 20_000 },
    device,
    peer,
  });
  legacy = await startLiveServer({ upstreamOrigin: upstream.origin, features: undefined, device, peer });
  const clients = [];
  const cleanup = [];
  try {
    // ------------------------------------------------- 1. in-band hello over WSS
    const client1 = new P1Client(live.port);
    clients.push(client1);
    await client1.open();
    assert(client1.rejection === undefined, 'anonymous ?proto=2 upgrade must be accepted (in-band auth)');
    client1.hello({ auth: { muxToken: 'test-mux-token' } });
    const welcome1 = await client1.waitForFrame((frame) => frame.type === 'welcome', { label: 'welcome' });
    assert(welcome1.v === 2 && welcome1.proto === 'dsh-m/2', 'welcome negotiates dsh-m/2');
    assert(typeof welcome1.epoch === 'string' && welcome1.epoch.length > 8, 'welcome carries logEpoch');
    assert(typeof welcome1.ticket === 'string' && welcome1.ticket.includes('.'), 'welcome carries a resume ticket');
    assert(welcome1.resume.mode === 'fresh' && welcome1.sid === 0, 'fresh hello resumes nothing');
    record('in-band-hello-auth', true, { epoch: welcome1.epoch.slice(0, 8), ticketBytes: welcome1.ticket.length });

    // ------------------------------------- 2. unary + streams on one TLS socket
    const listRequest = clientRequest('session/list', {});
    client1.send({ type: 'rpc', id: 'list-1', endpoint: 'session/list', body: listRequest });
    const listResult = await client1.waitForFrame((frame) => frame.type === 'rpc/result' && frame.id === 'list-1', { label: 'rpc/result list-1' });
    assert(listResult.status === 200, 'rpc/result keeps the upstream status');
    assert(listResult.body?.type === 'server-response' && listResult.body.result.method === 'session/list', 'rpc/result body is the upstream server-response');
    // Controlled concurrency: the slow call was issued first but returns second.
    client1.send({ type: 'rpc', id: 'slow', endpoint: 'session/page', body: clientRequest('session/page', { delay: 120 }) });
    client1.send({ type: 'rpc', id: 'fast', endpoint: 'session/page', body: clientRequest('session/page', { delay: 0 }) });
    await client1.waitForFrame((frame) => frame.type === 'rpc/result' && frame.id === 'slow', { label: 'rpc/result slow' });
    const resultOrder = client1.inbox.filter((frame) => frame.type === 'rpc/result').map((frame) => frame.id);
    assert(resultOrder.indexOf('fast') < resultOrder.indexOf('slow'), 'responses correlate by id regardless of completion order');

    // Upstream stream frames are forwarded verbatim upstream and sequenced downstream.
    const openFrame = { type: 'open', streamId: 'sess-1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId: 'sess-1' } } } } };
    client1.send(openFrame);
    await waitFor(() => upstreamMux.sent.length >= 1, { label: 'upstream open frame' });
    assert(upstreamMux.sent[0] === JSON.stringify(openFrame), 'client stream frame is forwarded byte-for-byte upstream');
    upstreamMux.inject(JSON.stringify({ type: 'item', streamId: 'sess-1', value: { type: 'snapshot', cursor: 2, records: [] } }));
    const down1 = await client1.waitForFrame((frame) => frame.type === 'down' && frame.sid === 1, { label: 'down sid 1' });
    assert(down1.frame.type === 'item' && down1.frame.streamId === 'sess-1', 'down.frame is the upstream frame object');
    // An upstream HTTP failure is passed through as the same HTTP status.
    client1.send({ type: 'rpc', id: 'err-1', endpoint: 'test/error', body: clientRequest('test/error', {}) });
    const errResult = await client1.waitForFrame((frame) => frame.type === 'rpc/result' && frame.id === 'err-1', { label: 'rpc/result err-1' });
    assert(errResult.status === 500, 'business/HTTP errors are not rewritten by the plugin');
    assert(live.connections.count === 1, 'unary RPC + stream frames must share the one TLS connection, got ' + live.connections.count);
    record('one-tls-unary-and-stream', true, { tlsConnections: live.connections.count, rpcIds: resultOrder, upstreamFrames: upstreamMux.sent.length, downSid: down1.sid });

    // ------------------------------------------- 3. drop, gap frames, resume
    client1.terminate();
    await waitFor(() => device.downstream === undefined, { label: 'server noticed the drop' });
    assert(live.server.p1Channels.size === 1, 'exactly one logical channel is retained for the device');
    const channel = live.server.p1Channels.get(device.deviceId);
    assert(channel !== undefined && channel.replay.entries.length >= 1, 'replay log retained after the drop');
    // Frames produced while the phone is away are logged, not lost.
    upstreamMux.inject(JSON.stringify({ type: 'item', streamId: 'sess-1', value: { type: 'event', event: { seq: 3 } } }));
    upstreamMux.inject(JSON.stringify({ type: 'item', streamId: 'sess-1', value: { type: 'event', event: { seq: 4 } } }));
    await waitFor(() => channel.replay.lastSid === 3, { label: 'gap frames logged' });

    const client2 = new P1Client(live.port);
    clients.push(client2);
    await client2.open();
    client2.hello({ auth: { ticket: welcome1.ticket }, resume: { logEpoch: welcome1.epoch, sid: 1 } });
    const welcome2 = await client2.waitForFrame((frame) => frame.type === 'welcome', { label: 'resume welcome' });
    assert(welcome2.resume.ok === true && welcome2.resume.mode === 'replay', 'resume within the window replays instead of resetting');
    assert(welcome2.resume.replayed === 2, 'exactly the two missed frames are replayed, got ' + welcome2.resume.replayed);
    assert(welcome2.sid === 3, 'welcome reports the current sid');
    const replay1 = await client2.waitForFrame((frame) => frame.type === 'down' && frame.sid === 2, { label: 'replayed sid 2' });
    const replay2 = await client2.waitForFrame((frame) => frame.type === 'down' && frame.sid === 3, { label: 'replayed sid 3' });
    assert(replay1.frame.value.event.seq === 3 && replay2.frame.value.event.seq === 4, 'replayed frames are the missed upstream events');
    upstreamMux.inject(JSON.stringify({ type: 'item', streamId: 'sess-1', value: { type: 'event', event: { seq: 5 } } }));
    const down4 = await client2.waitForFrame((frame) => frame.type === 'down' && frame.sid === 4, { label: 'live frame after resume' });
    assert(down4.frame.value.event.seq === 5, 'live delivery continues on the same epoch');
    client2.send({ type: 'rpc', id: 'after-resume', endpoint: 'session/list', body: clientRequest('session/list', {}) });
    const afterResume = await client2.waitForFrame((frame) => frame.type === 'rpc/result' && frame.id === 'after-resume', { label: 'rpc after resume' });
    assert(afterResume.status === 200, 'unary works on the resumed socket too');
    record('resume-replay-after-drop', true, { replayed: welcome2.resume.replayed, welcomeSid: welcome2.sid, tlsConnections: live.connections.count });

    // The next two probes need the channel detached again (one socket per device).
    client2.close();
    await waitFor(() => device.downstream === undefined, { label: 'client2 closed' });

    // ------------------------------------------------ 4. auth / resume 负路径
    const tampered = new P1Client(live.port);
    clients.push(tampered);
    await tampered.open();
    tampered.hello({ auth: { ticket: welcome1.ticket.slice(0, -2) + 'AA' } });
    const tamperedClose = await tampered.waitClose();
    assert(tamperedClose?.code === 4401, 'tampered ticket is rejected with close 4401, got ' + JSON.stringify(tamperedClose));
    record('auth-tampered-ticket-rejected', true, { code: tamperedClose.code, reason: tamperedClose.reason });

    const mismatched = new P1Client(live.port);
    clients.push(mismatched);
    await mismatched.open();
    mismatched.hello({ auth: { ticket: welcome1.ticket }, resume: { logEpoch: 'epoch-from-another-process', sid: 0 } });
    const resetWelcome = await mismatched.waitForFrame((frame) => frame.type === 'welcome', { label: 'reset welcome' });
    assert(resetWelcome.resume.ok === false && resetWelcome.resume.reason === 'epoch-mismatch', 'unknown logEpoch yields resume reset');
    record('resume-epoch-mismatch-live', true, resetWelcome.resume);

    // ---------------------------------------------- 5. dual-stack / feature off
    const legacyClient = new P1Client(legacy.port);
    clients.push(legacyClient);
    let legacyRejected = false;
    try {
      await legacyClient.open();
    } catch {
      legacyRejected = true;
    }
    assert(legacyRejected === true, 'feature-off plugin must reject the ?proto=2 anonymous upgrade');
    assert(String(legacyClient.ws.rejection ?? '').includes('401'), 'rejection is the M1 401, got ' + String(legacyClient.ws.rejection));
    record('dual-stack-feature-off-rejects-proto2', true, { rejection: legacyClient.ws.rejection, muxRpc: legacy.server.config.features.muxRpc });

    const report = {
      startedAt: new Date(startedAt).toISOString(),
      durationMs: Date.now() - startedAt,
      checks,
      pass: checks.length,
      fail: 0,
    };
    writeFileSync(join(outDir, 'p1-single-wss-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
    console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
  } finally {
    for (const client of clients) {
      try {
        client.close();
      } catch {
        /* already closed */
      }
    }
    for (const entry of cleanup) entry();
    live?.server.dispose();
    legacy?.server.dispose();
    await new Promise((done) => upstream.server.close(done));
    rmSync(live.home, { recursive: true, force: true });
    rmSync(legacy.home, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
  // The fake upstream/HTTP fixtures keep handles open; fail fast instead of
  // letting a broken run look like a hang.
  setTimeout(() => process.exit(1), 100).unref();
});
