/**
 * m2-tunnel.mjs — M2a task-3 tests: relay tunnel client, dynamic relay origin
 * injection and the real-relay integration path.
 *
 * Runs standalone (no DSH host, no ~/.dsh, no desktop plugin):
 *   node test/m2-tunnel.mjs [--out-dir <dir>] [--skip-real-relay]
 *
 * Three layers:
 *   1. protocol unit tests (frame codec, hello HMAC, cert pin forms, secret IO);
 *   2. a Node "fake relay" implementing design §4.4/§4.5 on a real TLS socket —
 *      handshake, ready, code publish, bridge echo, half-close, reconnect,
 *      drain, pin/secret rejection, heartbeat;
 *   3. link-server integration at the handler level (relay origin + top-level
 *      payload relay object + /health.deviceEndpoints + tunnel disabled = M1),
 *      and — when Go and packages/dsh-m-relay are available — the real relay
 *      binary: `init --print-json` -> `serve --addr-file` -> tunnel -> lookup ->
 *      bridge echo (phone sends its first bytes and waits, i.e. TLS ClientHello
 *      semantics) -> drain/reconnect.
 *
 * The real relay binary is built to a temp dir, never into the repo.
 */

import { execFileSync, spawn } from 'node:child_process';
import { createHash, createHmac, createPublicKey, verify } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { request as httpsRequest } from 'node:https';
import { connect as netConnect, createServer as createNetServer } from 'node:net';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer as createTlsServer } from 'node:tls';

import { AuditLog } from '../lib/audit.js';
import { canonicalJson } from '../lib/canonical.js';
import { ensureCerts, rotateLeaf } from '../lib/certs.js';
import { DeviceStore } from '../lib/devices.js';
import { ensureHostIdentity } from '../lib/host-identity.js';
import { LinkServer } from '../lib/link-server.js';
import { buildEndpoints, PairCodeService, PairingService, selectDeviceEndpoints } from '../lib/pairing.js';
import {
  certPin,
  certPinFromFingerprint,
  computeHelloAuth,
  consumeFrames,
  encodeDataFrame,
  encodeFrame,
  FRAME_TYPE,
  RELAY_ALPN,
  resolveSecret,
  TunnelClient,
} from '../lib/tunnel.js';

const REPO_ROOT = resolve(new URL('../../..', import.meta.url).pathname);
const RELAY_DIR = join(REPO_ROOT, 'packages', 'dsh-m-relay');
const DEFAULT_OUT = resolve(new URL('results', import.meta.url).pathname);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const TEST_CERTS = {
  caPin: 'CA-PIN-TEST',
  leafPin: 'LEAF-PIN-TEST',
  caFingerprint256: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
  leafFingerprint256: '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00',
  leafNotAfter: 'Oct 20 16:27:30 2027 GMT',
  // C scheme: public CA certificate as DER base64 (real suites use ensureCerts()).
  caCertDerBase64: Buffer.from('unit-test-ca-cert-der').toString('base64'),
};

// ---------------------------------------------------------------- helpers
function fakeResponse() {
  return {
    statusCode: 0,
    headers: {},
    headersSent: false,
    body: '',
    writeHead(status, headers) {
      this.statusCode = status;
      this.headers = headers ?? {};
      this.headersSent = true;
    },
    end(chunk) {
      if (chunk !== undefined && chunk !== null) this.body = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
    },
  };
}

function makeServer({ config = {} } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'dshm-m2-tunnel-'));
  const ctx = {
    get: (name) => (name === 'dshHomePath' ? home : undefined),
    webServer: { getOrigin: () => 'http://127.0.0.1:62001' },
    connection: { authenticatedUrl: (url) => url },
  };
  const server = new LinkServer(ctx, {
    port: 3468,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: true, adminToken: 'test-admin-token' },
    ...config,
  });
  const dataDir = join(home, 'plugin-data', 'dsh-m-link');
  server.audit = new AuditLog({ dir: dataDir, log: () => {} });
  server.hostIdentity = ensureHostIdentity({ dir: dataDir, log: () => {} });
  server.devices = new DeviceStore({ dir: dataDir, hostId: server.hostIdentity.hostId, log: () => {} }).load();
  server.certs = { ...TEST_CERTS };
  server.hostname = 'test-mac';
  server.lanIps = [];
  server.started = true;
  server.disposed = false;
  server.starting = false;
  server.qr = { renderDataUrl: async () => ({ ok: false, error: 'unit-test-no-qr' }), dispose: () => {} };
  server.apns = { mode: 'stub', reason: 'test', topic: null, info: () => ({ mode: 'stub' }), dispose: () => {} };
  server.notifier = { dispose: () => {} };
  server.auth = { sweep: () => {}, dispose: () => {} };
  const endpoints = buildEndpoints({ config: { port: 3468, bindHost: '127.0.0.1' }, certs: TEST_CERTS, lanIps: [] });
  server.endpoints = endpoints;
  server.baseEndpoints = endpoints.slice();
  server.deviceEndpoints = selectDeviceEndpoints(endpoints);
  server.pairing = new PairingService({
    config: { pairTtlMs: 90_000, hostName: 'Test Mac' },
    certs: TEST_CERTS,
    hostIdentity: server.hostIdentity,
    endpoints: server.deviceEndpoints,
    audit: server.audit,
  });
  server.pairing.refresh('test');
  server.pairCode = new PairCodeService({ config: server.config, audit: server.audit, autoRotate: false, log: () => {} });
  server.pairCode.start('startup');
  server.ensurePeer = () => ({ connect: async () => {} });
  return { server, home };
}

function verifyPayloadSignature(payload, payloadText) {
  if (payloadText !== canonicalJson(payload)) return false;
  const { sig, ...unsigned } = payload;
  const keyDer = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(payload.host.key, 'base64url')]);
  const key = createPublicKey({ key: keyDer, format: 'der', type: 'spki' });
  return verify(null, Buffer.from(canonicalJson(unsigned), 'utf8'), key, Buffer.from(String(sig ?? ''), 'base64url'));
}

async function freePort() {
  return new Promise((done, fail) => {
    const server = createNetServer();
    server.once('error', fail);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => done(port));
    });
  });
}

/** Find a small contiguous free TCP port range (bridge pool). */
async function freeRange(size = 4) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const base = 20000 + Math.floor(Math.random() * 30000);
    const servers = [];
    let ok = true;
    for (let offset = 0; offset < size; offset += 1) {
      try {
        servers.push(await new Promise((done, fail) => {
          const server = createNetServer();
          server.once('error', fail);
          server.listen(base + offset, '127.0.0.1', () => done(server));
        }));
      } catch {
        ok = false;
        break;
      }
    }
    await Promise.all(servers.map((server) => new Promise((done) => server.close(done))));
    if (ok) return { start: base, end: base + size - 1 };
  }
  throw new Error('could not find a free bridge port range');
}

function echoServer() {
  const server = createNetServer({ allowHalfOpen: true }, (socket) => socket.pipe(socket));
  return new Promise((done) => server.listen(0, '127.0.0.1', () => done({ server, port: server.address().port })));
}

function closeNetServer(server) {
  return new Promise((done) => {
    try {
      server.close(() => done());
    } catch {
      done();
    }
  });
}

async function waitFor(predicate, { timeoutMs = 8000, intervalMs = 20, label = 'condition' } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value !== false && value !== undefined) return value;
    await sleep(intervalMs);
  }
  throw new Error('timed out waiting for ' + label);
}

// ------------------------------------------------------------- fake relay
/**
 * Minimal relay implementing design §4.4/§4.5 over real TLS with the product
 * certificate generator. Deliberately independent of the tunnel's own helpers
 * for the hello HMAC (test computes it with createHmac directly).
 */
class FakeRelay {
  constructor({ certs, secret, heartbeatSec = 1, hostId = null, name = 'fake-relay', busyFirst = false, wrongHostId = false, portUnavailableFirst = false }) {
    this.certs = certs;
    this.secret = secret;
    this.heartbeatSec = heartbeatSec;
    this.expectedHostId = hostId;
    this.name = name;
    this.busyFirst = busyFirst;
    this.wrongHostId = wrongHostId;
    this.portUnavailableFirst = portUnavailableFirst;
    this.messages = [];
    this.frameTypes = [];
    this.helloCount = 0;
    this.bridgePort = undefined;
    this.bridgeServer = undefined;
    this.currentSession = undefined;
    this.control = undefined;
    this.controlBuffer = Buffer.alloc(0);
    this.streams = new Map();
    this.nextSid = 1;
    this.sessions = 0;
    this.sessionList = [];
    this.phoneSockets = new Set();
    this.errors = [];
    this.dataToTunnel = 0;
    this.dataFromTunnel = 0;
  }

  async start() {
    this.server = createTlsServer({
      key: readFileSync(this.certs.leafKey),
      cert: readFileSync(this.certs.leafCert),
      ALPNProtocols: [RELAY_ALPN],
    }, (socket) => this.onControl(socket));
    this.server.on('tlsClientError', (error) => this.errors.push(String(error?.message ?? error)));
    this.bridgeServer = createNetServer({ allowHalfOpen: true }, (phone) => this.onPhone(this.currentSession, phone));
    await new Promise((done) => this.bridgeServer.listen(0, '127.0.0.1', done));
    this.bridgePort = this.bridgeServer.address().port;
    await new Promise((done) => this.server.listen(0, '127.0.0.1', done));
    this.port = this.server.address().port;
    this.controlOrigin = 'https://127.0.0.1:' + String(this.port);
    return this;
  }

  get pin() {
    return certPinFromFingerprint(this.certs.leafFingerprint256);
  }

  onControl(socket) {
    this.sessions += 1;
    this.control = socket;
    this.controlBuffer = Buffer.alloc(0);
    const session = { socket, buffer: Buffer.alloc(0), ready: false, hellos: 0 };
    this.currentSession = session;
    this.sessionList.push(session);
    socket.on('data', (chunk) => {
      session.buffer = Buffer.concat([session.buffer, chunk]);
      try {
        session.buffer = consumeFrames(session.buffer, (type, payload) => this.onFrame(session, type, payload));
      } catch (error) {
        this.errors.push('frame: ' + String(error?.message ?? error));
        socket.destroy();
      }
    });
    socket.on('error', () => {});
    if (socket.alpnProtocol !== RELAY_ALPN) this.errors.push('alpn: got ' + String(socket.alpnProtocol));
  }

  onFrame(session, type, payload) {
    this.frameTypes.push(type);
    if (type === FRAME_TYPE.JSON) {
      let message;
      try {
        message = JSON.parse(payload.toString('utf8'));
      } catch {
        this.errors.push('bad json');
        session.socket.destroy();
        return;
      }
      this.messages.push(message);
      this.onMessage(session, message);
      return;
    }
    if (type === FRAME_TYPE.DATA) {
      const sid = payload.readUInt32BE(0);
      this.dataFromTunnel += payload.length - 4;
      const stream = this.streams.get(sid);
      if (stream !== undefined) stream.phone.write(payload.subarray(4));
      return;
    }
    if (type === FRAME_TYPE.FIN) {
      const stream = this.streams.get(payload.readUInt32BE(0));
      if (stream !== undefined) stream.phone.end();
      return;
    }
    if (type === FRAME_TYPE.RST) {
      const stream = this.streams.get(payload.readUInt32BE(0));
      if (stream !== undefined) stream.phone.destroy();
      return;
    }
  }

  onMessage(session, message) {
    switch (message.t) {
      case 'hello': {
        session.hellos += 1;
        this.helloCount += 1;
        if (session.hellos > 1) {
          this.errors.push('duplicate hello');
          return;
        }
        if (message.v !== 1) {
          this.sendJSON(session, { t: 'error', code: 'version/unsupported', message: 'bad version' });
          return;
        }
        if (this.expectedHostId !== null && message.hostId !== this.expectedHostId) this.errors.push('hostId mismatch');
        const port = message.wantPort === undefined ? '' : String(message.wantPort);
        const expected = createHmac('sha256', Buffer.from(this.secret, 'utf8'))
          .update('dshm-relay-hello/1\n' + message.hostId + '\n' + String(message.ts) + '\n' + message.nonce + '\n' + port)
          .digest('base64url');
        if (message.auth !== expected) {
          this.sendJSON(session, { t: 'error', code: 'auth/invalid', message: 'bad signature' });
          session.socket.destroy();
          return;
        }
        session.ready = true;
        if (this.busyFirst && this.helloCount === 1) {
          this.sendJSON(session, { t: 'error', code: 'server/busy', message: 'relay draining' });
          setTimeout(() => session.socket.destroy(), 10);
          return;
        }
        if (this.portUnavailableFirst && this.helloCount === 1) {
          this.sendJSON(session, { t: 'error', code: 'port/unavailable', message: 'bridge pool exhausted' });
          setTimeout(() => session.socket.destroy(), 10);
          return;
        }
        this.sendJSON(session, {
          t: 'ready',
          v: 1,
          hostId: this.wrongHostId ? 'some-other-host-id' : message.hostId,
          publicHost: '127.0.0.1',
          port: this.bridgePort,
          origin: 'https://127.0.0.1:' + String(this.bridgePort),
          heartbeatSec: this.heartbeatSec,
        });
        return;
      }
      case 'opened': {
        const stream = this.streams.get(message.sid);
        if (stream !== undefined) this.openStream(stream);
        return;
      }
      case 'open_failed': {
        const stream = this.streams.get(message.sid);
        if (stream !== undefined) {
          this.streams.delete(message.sid);
          stream.phone.destroy();
        }
        return;
      }
      case 'ping':
        this.sendJSON(session, { t: 'pong', ts: message.ts });
        return;
      case 'pong':
        return;
      default:
        return; // code / code_clear / drain are recorded in this.messages
    }
  }

  onPhone(session, phone) {
    if (session === undefined) {
      phone.destroy();
      return;
    }
    const sid = this.nextSid;
    this.nextSid += 2;
    const stream = { sid, phone, pending: [], opened: false, endPending: false };
    this.streams.set(sid, stream);
    this.phoneSockets.add(phone);
    phone.on('data', (data) => {
      if (stream.opened) {
        this.dataToTunnel += data.length;
        this.sendFrame(FRAME_TYPE.DATA, encodeDataFrame(sid, data).subarray(5));
      } else {
        stream.pending.push(data);
      }
    });
    phone.on('end', () => {
      if (stream.opened) this.sendFIN(sid);
      else stream.endPending = true;
    });
    phone.on('error', () => {});
    this.sendJSON(session, { t: 'open', sid });
  }

  openStream(stream) {
    if (stream.opened) return;
    stream.opened = true;
    for (const chunk of stream.pending) {
      this.dataToTunnel += chunk.length;
      this.sendFrame(FRAME_TYPE.DATA, encodeDataFrame(stream.sid, chunk).subarray(5));
    }
    stream.pending = [];
    if (stream.endPending) this.sendFIN(stream.sid);
  }

  sendFIN(sid) {
    const payload = Buffer.alloc(4);
    payload.writeUInt32BE(sid >>> 0, 0);
    this.sendFrame(FRAME_TYPE.FIN, payload);
  }

  sendFrame(type, payload) {
    const socket = this.control;
    if (socket === undefined || socket.destroyed) return false;
    try {
      return socket.write(encodeFrame(type, payload));
    } catch {
      return false;
    }
  }

  sendJSON(session, value) {
    const socket = (session ?? { socket: this.control }).socket;
    if (socket === undefined || socket.destroyed) return false;
    try {
      return socket.write(encodeFrame(FRAME_TYPE.JSON, Buffer.from(JSON.stringify(value), 'utf8')));
    } catch {
      return false;
    }
  }

  drain(reason = 'shutdown') {
    this.sendJSON(undefined, { t: 'drain', reason });
    setTimeout(() => this.control?.destroy(), 20);
  }

  sendOpens(count) {
    const sids = [];
    for (let index = 0; index < count; index += 1) {
      const sid = 1001 + index * 2;
      sids.push(sid);
      this.sendJSON(undefined, { t: 'open', sid });
    }
    return sids;
  }

  destroyControl() {
    this.control?.destroy();
  }

  async close() {
    for (const phone of this.phoneSockets) {
      try {
        phone.destroy();
      } catch {
        /* gone */
      }
    }
    this.phoneSockets.clear();
    try {
      this.control?.destroy();
    } catch {
      /* gone */
    }
    if (this.bridgeServer !== undefined) {
      try {
        await new Promise((done) => this.bridgeServer.close(() => done()));
      } catch {
        /* already closed */
      }
    }
    if (this.server !== undefined) {
      await new Promise((done) => this.server.close(() => done()));
    }
  }
}

/** Tunnel client with fast reconnect timings for tests. */
function makeTunnel({ controlOrigin, pin, secret, echoPort, hostId = 'm2tunnel-test-host-1', wantPort, onReady, backoffMs = [100, 200, 400] }) {
  const events = [];
  const tunnel = new TunnelClient({
    config: { enabled: true, controlOrigin, pin, secret, ...(wantPort === undefined ? {} : { wantPort }) },
    pluginPort: echoPort,
    hostId,
    hostName: 'M2 Tunnel Test Mac',
    pluginVersion: '0.2.0',
    log: () => {},
    audit: { record: (event, fields) => events.push({ event, fields }) },
    backoffMs,
    onReady: (info) => {
      events.push({ event: 'on-ready', info });
      onReady?.(info);
    },
  });
  return { tunnel, events };
}

function waitReady(tunnel, events, timeoutMs = 8000) {
  return new Promise((done, fail) => {
    const timer = setTimeout(() => fail(new Error('tunnel not ready: ' + JSON.stringify(tunnel.health()))), timeoutMs);
    const tick = setInterval(() => {
      if (tunnel.health().state === 'ready') {
        clearTimeout(timer);
        clearInterval(tick);
        done(tunnel.health());
      }
    }, 20);
  });
}

function waitState(tunnel, state, timeoutMs = 8000) {
  return new Promise((done, fail) => {
    const timer = setTimeout(() => fail(new Error('tunnel state != ' + state + ': ' + JSON.stringify(tunnel.health()))), timeoutMs);
    const tick = setInterval(() => {
      if (tunnel.health().state === state) {
        clearTimeout(timer);
        clearInterval(tick);
        done(tunnel.health());
      }
    }, 20);
  });
}

async function main() {
  const outDir = process.argv.includes('--out-dir') ? process.argv[process.argv.indexOf('--out-dir') + 1] : DEFAULT_OUT;
  const skipRealRelay = process.argv.includes('--skip-real-relay');
  mkdirSync(outDir, { recursive: true });
  const checks = [];
  const check = async (name, run) => {
    try {
      const evidence = await run();
      checks.push({ name, ok: true, evidence });
      console.log('PASS ' + name);
    } catch (error) {
      checks.push({ name, ok: false, error: String(error?.stack ?? error) });
      console.log('FAIL ' + name + ': ' + String(error?.message ?? error));
    }
  };
  const assert = (condition, message) => {
    if (!condition) throw new Error(message);
  };
  const cleanups = [];
  const track = (value) => {
    cleanups.push(value);
    return value;
  };

  // ---------------------------------------------------------- protocol units
  await check('frame-codec', () => {
    const json = encodeFrame(FRAME_TYPE.JSON, Buffer.from('{"t":"hello"}'));
    assert(json.readUInt32BE(0) === 1 + Buffer.byteLength('{"t":"hello"}'), 'JSON frame length must include the type byte');
    assert(json[4] === FRAME_TYPE.JSON, 'frame type byte mismatch');
    const data = encodeDataFrame(7, Buffer.from('abc'));
    assert(data.readUInt32BE(0) === 1 + 4 + 3, 'DATA frame length mismatch');
    assert(data.readUInt32BE(5) === 7 && data.subarray(9).toString() === 'abc', 'DATA payload mismatch');
    const frames = [];
    const combined = Buffer.concat([encodeFrame(FRAME_TYPE.JSON, Buffer.from('a')), encodeFrame(FRAME_TYPE.FIN, Buffer.from([0, 0, 0, 9]))]);
    const remainder = consumeFrames(combined, (type, payload) => frames.push({ type, payload }));
    assert(remainder.length === 0 && frames.length === 2, 'consumeFrames must consume both complete frames');
    const second = frames[1];
    assert(second.type === FRAME_TYPE.FIN && second.payload.length === 4, 'FIN payload mismatch');
    const partial = Buffer.concat([encodeFrame(FRAME_TYPE.JSON, Buffer.from('xyz')), Buffer.from([0, 0])]);
    const left = consumeFrames(partial, () => {});
    assert(left.length === 2, 'partial trailing frame must be returned as remainder');
    let threw = false;
    try {
      consumeFrames(Buffer.from([0, 0, 0, 0, 1]), () => {});
    } catch {
      threw = true;
    }
    assert(threw, 'zero-length frame must be rejected');
    return { jsonFrameBytes: json.length, dataFrameBytes: data.length };
  });

  await check('hello-auth-contract', () => {
    const secret = 'test-relay-secret';
    const hostId = 'host-abcdef12';
    const ts = 1792561234567;
    const nonce = 'nonce-abcdef12';
    const expected = createHmac('sha256', secret)
      .update('dshm-relay-hello/1\n' + hostId + '\n' + String(ts) + '\n' + nonce + '\n' + '30001')
      .digest('base64url');
    assert(computeHelloAuth({ secret, hostId, ts, nonce, wantPort: 30001 }) === expected, 'hello HMAC with wantPort mismatch');
    const expectedNoPort = createHmac('sha256', secret)
      .update('dshm-relay-hello/1\n' + hostId + '\n' + String(ts) + '\n' + nonce + '\n')
      .digest('base64url');
    assert(computeHelloAuth({ secret, hostId, ts, nonce }) === expectedNoPort, 'hello HMAC without wantPort mismatch');
    assert(computeHelloAuth({ secret: 'other', hostId, ts, nonce }) !== expectedNoPort, 'hello HMAC must depend on the secret');
    return { message: 'dshm-relay-hello/1\\n<hostId>\\n<ts>\\n<nonce>\\n<wantPort?>' };
  });

  await check('cert-pin-forms', () => {
    const fingerprintHex = TEST_CERTS.leafFingerprint256;
    const pin = certPinFromFingerprint(fingerprintHex);
    assert(/^[A-Za-z0-9_-]{43}$/.test(pin), 'DER pin must be 43-char base64url, got ' + String(pin));
    assert(Buffer.from(pin, 'base64url').length === 32, 'DER pin must decode to 32 bytes');
    assert(certPinFromFingerprint('not-a-fingerprint') === undefined, 'invalid fingerprint must return undefined');
    const fakeDer = Buffer.from(Array.from({ length: 64 }, (_, index) => index));
    assert(certPin(fakeDer) === createHash('sha256').update(fakeDer).digest('base64url'), 'certPin must be sha256(base64url)');
    return { pin };
  });

  // B fix (pairing durability): a SAN drift (new LAN IP / bindHost / hostname)
  // must never re-issue the leaf. Clients pin the leaf DER
  // (`leafFingerprint256`), so a re-signed leaf silently un-pairs every phone.
  // Only expiry or an explicit rotateLeaf()/rotateCa() may change it.
  // Fully offline: mkdtemp dir, TEST-NET-1 documentation IPs, never ~/.dsh.
  await check('cert-san-drift-keeps-leaf-pin', () => {
    const dir = track(mkdtempSync(join(tmpdir(), 'dshm-m2-sandrift-')));
    const logs = [];
    const log = (message) => logs.push(String(message));
    const sanA = { dir, bindHost: '127.0.0.1', lanIps: ['192.0.2.10'], hostname: 'mac-a.local', log };
    const first = ensureCerts(sanA);
    const metaFile = join(dir, 'tls', 'certs.json');
    const firstMeta = readFileSync(metaFile, 'utf8');
    assert(first.generated === true && first.leafRotated === false, 'first call must generate CA+leaf');
    assert(readFileSync(first.leafCert).equals(readFileSync(first.caCert)) === false, 'leaf and CA must be distinct certs');

    // Same inputs again: stable, nothing rotated, no drift log.
    logs.length = 0; // drop the first-run "generated CA" log
    const stable = ensureCerts(sanA);
    assert(stable.leafFingerprint256 === first.leafFingerprint256, 'unchanged SANs must keep the leaf pin');
    assert(stable.leafRotated === false && stable.generated === false, 'unchanged SANs must not rotate');
    assert(logs.length === 0, 'no drift log for unchanged SANs: ' + JSON.stringify(logs));

    // SAN drift: different LAN IP + mDNS hostname, same cert directory.
    const drifted = ensureCerts({ dir, bindHost: '127.0.0.1', lanIps: ['192.0.2.11'], hostname: 'mac-b.local', log });
    assert(drifted.leafFingerprint256 === first.leafFingerprint256, 'SAN drift must NOT re-issue the leaf (pairing stays valid)');
    assert(drifted.leafSans === first.leafSans, 'leaf SANs must stay unchanged after SAN drift');
    assert(drifted.caFingerprint256 === first.caFingerprint256, 'SAN drift must never touch the CA');
    assert(drifted.leafRotated === false && drifted.generated === false, 'SAN drift is not a rotation');
    assert(readFileSync(metaFile, 'utf8') === firstMeta, 'certs.json (expected-SAN cache) must stay unchanged on drift');
    assert(logs.some((line) => line.includes('SAN drift but leaf kept')), 'SAN drift must be logged while keeping the leaf: ' + JSON.stringify(logs));

    // Explicit manual rotation still works and re-issues the leaf (new key pair).
    const rotated = rotateLeaf({ dir, bindHost: '127.0.0.1', lanIps: ['192.0.2.11'], hostname: 'mac-b.local', log });
    assert(rotated.leafRotated === true, 'manual rotateLeaf must still rotate');
    assert(rotated.leafFingerprint256 !== first.leafFingerprint256, 'manual rotateLeaf must produce a new leaf pin');
    assert(rotated.caFingerprint256 === first.caFingerprint256, 'manual rotateLeaf must keep the CA');
    const rotatedMeta = JSON.parse(readFileSync(metaFile, 'utf8'));
    assert(rotatedMeta.leafSansExpected.includes('192.0.2.11'), 'manual rotation must write the current SAN list');

    // After the explicit rotation the new SANs are the baseline: a later
    // ensureCerts is stable again and never rotation-loops.
    const afterRotate = ensureCerts({ dir, bindHost: '127.0.0.1', lanIps: ['192.0.2.11'], hostname: 'mac-b.local', log });
    assert(afterRotate.leafFingerprint256 === rotated.leafFingerprint256, 'post-rotation ensureCerts must keep the new leaf');
    assert(afterRotate.leafRotated === false, 'post-rotation ensureCerts must not rotate again');
    return {
      generated: first.generated,
      leaf: first.leafFingerprint256.slice(0, 8),
      rotatedLeaf: rotated.leafFingerprint256.slice(0, 8),
      caStable: rotated.caFingerprint256 === first.caFingerprint256,
      driftLogs: logs.filter((line) => line.includes('SAN drift')).length,
    };
  });

  // The B fix keeps the expiry path: a leaf inside the 7-day renew window is
  // still re-issued (with a new key pair) so the origin never serves an expired
  // certificate; the CA stays put. Simulated by re-signing the leaf with a
  // 1-day validity against the generated CA (same shape as certs.js).
  await check('cert-expiry-rotation-keeps-ca', () => {
    const dir = track(mkdtempSync(join(tmpdir(), 'dshm-m2-expiring-')));
    const tlsDir = join(dir, 'tls');
    const logs = [];
    const log = (message) => logs.push(String(message));
    const args = { dir, bindHost: '127.0.0.1', lanIps: [], hostname: 'localhost', log };
    const first = ensureCerts(args);
    logs.length = 0;
    const openssl = (argv) => execFileSync('openssl', argv, { stdio: ['ignore', 'pipe', 'pipe'] });
    const extFile = join(dir, 'short-leaf.ext');
    writeFileSync(extFile, 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\n');
    openssl(['req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-sha256', '-nodes', '-keyout', join(tlsDir, 'leaf.key'), '-out', join(tlsDir, 'leaf.csr'), '-subj', '/CN=dsh-m-link']);
    openssl([
      'x509', '-req', '-in', join(tlsDir, 'leaf.csr'),
      '-CA', join(tlsDir, 'ca.crt'), '-CAkey', join(tlsDir, 'ca.key'), '-CAcreateserial',
      '-days', '1', '-sha256', '-out', join(tlsDir, 'leaf.crt'), '-extfile', extFile,
    ]);
    const renewed = ensureCerts(args);
    assert(renewed.leafRotated === true && renewed.generated === false, 'a leaf inside the renew window must be re-issued');
    assert(renewed.leafFingerprint256 !== first.leafFingerprint256, 'expiry rotation must produce a new leaf pin');
    assert(renewed.caFingerprint256 === first.caFingerprint256, 'expiry rotation must never touch the CA');
    assert(logs.some((line) => line.includes('rotating leaf certificate (expiring')), 'expiry rotation must be logged: ' + JSON.stringify(logs));
    const stableAfter = ensureCerts(args);
    assert(stableAfter.leafRotated === false && stableAfter.leafFingerprint256 === renewed.leafFingerprint256, 'renewed leaf must be stable afterwards');
    return { renewed: renewed.leafFingerprint256.slice(0, 8), caStable: renewed.caFingerprint256 === first.caFingerprint256 };
  });

  await check('secret-resolution', () => {
    const dir = track(mkdtempSync(join(tmpdir(), 'dshm-m2-secret-')));
    const inline = resolveSecret({ secret: '  inline-secret  ' });
    assert(inline.secret === 'inline-secret', 'inline secret must be trimmed');
    const file = join(dir, 'relay.secret');
    writeFileSync(file, 'file-secret\n', { mode: 0o600 });
    const fromFile = resolveSecret({ secretFile: file });
    assert(fromFile.secret === 'file-secret', 'secretFile must be read and trimmed');
    const missing = resolveSecret({});
    assert(missing.error === 'auth/secret-missing', 'missing secret must be reported');
    const unreadable = resolveSecret({ secretFile: join(dir, 'nope.secret') });
    assert(unreadable.error === 'auth/secret-file-unreadable', 'unreadable secret file must be reported');
    assert(resolveSecret({ secretFile: '~/definitely-not-there' }).file.startsWith(homedir()), '~ must expand to the home dir');
    return { inline: true, file: true, errors: [missing.error, unreadable.error] };
  });

  await check('tunnel-config-errors-isolated', () => {
    const make = (config) => new TunnelClient({ config, pluginPort: 1, hostId: 'config-error-host', hostName: 'Config Error', log: () => {}, backoffMs: [50] });
    const disabled = make({ enabled: false });
    disabled.start();
    assert(disabled.health().state === 'disabled', 'disabled tunnel must report state=disabled');
    const noSecret = make({ enabled: true, controlOrigin: 'https://127.0.0.1:443', pin: 'A'.repeat(43) });
    noSecret.start();
    assert(noSecret.health().state === 'error', 'missing secret must degrade to state=error, not throw');
    assert(noSecret.health().lastError === 'auth/secret-missing', 'missing secret error mismatch: ' + String(noSecret.health().lastError));
    assert(noSecret.permanent === true && noSecret.reconnectTimer === undefined, 'config errors must not reconnect-loop');
    const badOrigin = make({ enabled: true, controlOrigin: 'http://127.0.0.1:443', pin: 'A'.repeat(43), secret: 'x' });
    badOrigin.start();
    assert(badOrigin.health().state === 'error' && badOrigin.health().lastError === 'config/control-origin-not-https', 'non-https origin must be rejected: ' + JSON.stringify(badOrigin.health()));
    const badPin = make({ enabled: true, controlOrigin: 'https://127.0.0.1:443', pin: 'nope', secret: 'x' });
    badPin.start();
    assert(badPin.health().state === 'error' && badPin.health().lastError === 'config/invalid-pin', 'invalid pin must be rejected');
    for (const tunnel of [disabled, noSecret, badOrigin, badPin]) tunnel.dispose();
    return { disabled: disabled.health().state, missingSecret: noSecret.health().lastError, badOrigin: badOrigin.health().lastError, badPin: badPin.health().lastError };
  });

  // ------------------------------------------------------------- fake relay
  const fakeCerts = track(mkdtempSync(join(tmpdir(), 'dshm-m2-fakecerts-')));
  const certs = ensureCerts({ dir: fakeCerts, bindHost: '127.0.0.1', lanIps: [], hostname: 'localhost' });
  const otherCerts = ensureCerts({ dir: track(mkdtempSync(join(tmpdir(), 'dshm-m2-othercerts-'))), bindHost: '127.0.0.1', lanIps: [], hostname: 'localhost' });

  await check('fake-relay-handshake-ready', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-1', heartbeatSec: 1 }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-1', echoPort: echo.port, hostId: 'm2tunnel-test-host-1' });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    const health = await waitReady(tunnel, []);
    assert(health.state === 'ready' && health.origin === 'https://127.0.0.1:' + String(relay.bridgePort), 'tunnel origin mismatch: ' + JSON.stringify(health));
    assert(health.port === relay.bridgePort && typeof health.since === 'number', 'tunnel bridge port/since missing');
    const hello = relay.messages.find((message) => message.t === 'hello');
    assert(hello !== undefined, 'relay did not receive hello');
    assert(hello.hostId === 'm2tunnel-test-host-1' && hello.hostName === 'M2 Tunnel Test Mac', 'hello identity mismatch');
    assert(hello.v === 1 && typeof hello.ts === 'number' && typeof hello.nonce === 'string', 'hello version/ts/nonce missing');
    assert(hello.meta?.plugin === 'dsh-m-link' && hello.meta?.proto === 'dsh-m/1', 'hello meta mismatch: ' + JSON.stringify(hello.meta));
    assert(relay.helloCount === 1, 'expected exactly one hello, got ' + relay.helloCount);
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { origin: health.origin, port: health.port, heartbeatSec: 1 };
  });

  await check('fake-relay-code-publish', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-2' }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-2', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    // publish before the control channel is ready: must be sent after ready
    tunnel.publishCode('12345678', Date.now() + 120_000, certPinFromFingerprint(TEST_CERTS.leafFingerprint256), TEST_CERTS.leafFingerprint256, 'Test Mac');
    tunnel.start();
    await waitReady(tunnel, []);
    await waitFor(() => relay.messages.some((message) => message.t === 'code'), { label: 'code frame' });
    const code = relay.messages.find((message) => message.t === 'code');
    assert(code.code === '12345678', 'published code mismatch');
    assert(code.exp > Math.floor(Date.now() / 1000), 'code exp must be in the future (unix seconds)');
    assert(/^[A-Za-z0-9_-]{43}$/.test(code.leafPin ?? ''), 'code leafPin must be a DER sha256 base64url pin');
    assert(code.leafFingerprint256 === TEST_CERTS.leafFingerprint256, 'code leafFingerprint256 mismatch');
    assert(code.hostName === 'Test Mac', 'code hostName mismatch');
    tunnel.publishCode('87654321', Date.now() + 120_000, certPinFromFingerprint(TEST_CERTS.leafFingerprint256), TEST_CERTS.leafFingerprint256, 'Test Mac');
    await waitFor(() => relay.messages.filter((message) => message.t === 'code').length === 2, { label: 'second code frame' });
    tunnel.clearCode();
    await waitFor(() => relay.messages.some((message) => message.t === 'code_clear'), { label: 'code_clear frame' });
    // idle codes must not create stream traffic
    assert(relay.frameTypes.includes(FRAME_TYPE.DATA) === false, 'unexpected DATA frame without a phone connection');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { codeFrames: relay.messages.filter((message) => message.t === 'code').length, cleared: true };
  });

  await check('fake-relay-bridge-echo', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-3', heartbeatSec: 1 }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel, events } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-3', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitReady(tunnel, []);
    await waitFor(() => relay.bridgePort !== undefined, { label: 'bridge port' });

    const phoneEcho = (payload, halfClose) => new Promise((done, fail) => {
      const socket = netConnect({ host: '127.0.0.1', port: relay.bridgePort });
      const timer = setTimeout(() => {
        socket.destroy();
        fail(new Error('bridge echo timeout (' + payload.length + ' bytes; frames=' + JSON.stringify(relay.frameTypes) + '; relay->tunnel=' + relay.dataToTunnel + ' tunnel->relay=' + relay.dataFromTunnel + ')'));
      }, 10000);
      const chunks = [];
      socket.on('connect', () => {
        socket.write(payload);
        if (halfClose) socket.end();
      });
      socket.on('data', (chunk) => {
        chunks.push(chunk);
        if (Buffer.concat(chunks).length >= payload.length) {
          clearTimeout(timer);
          socket.end();
          done(Buffer.concat(chunks));
        }
      });
      socket.on('end', () => {
        if (Buffer.concat(chunks).length < payload.length) {
          clearTimeout(timer);
          fail(new Error('bridge echo truncated: ' + Buffer.concat(chunks).length + '/' + payload.length + ' bytes (frames=' + JSON.stringify(relay.frameTypes) + ')'));
        }
      });
      socket.on('error', (error) => {
        clearTimeout(timer);
        fail(error);
      });
    });

    const small = Buffer.from('hello-through-fake-relay');
    let smallEcho;
    try {
      smallEcho = await phoneEcho(small, false);
    } catch (error) {
      throw new Error(String(error?.message) + ' trace=' + JSON.stringify(relay.trace));
    }
    assert(smallEcho.equals(small), 'small bridge echo mismatch');
    const large = Buffer.alloc(128 * 1024);
    for (let index = 0; index < large.length; index += 1) large[index] = (index * 31 + 7) & 0xff;
    const largeEcho = await phoneEcho(large, true);
    assert(largeEcho.length === large.length && largeEcho.equals(large), 'large bridge echo mismatch (half-close path)');
    assert(relay.frameTypes.includes(FRAME_TYPE.DATA) && relay.frameTypes.includes(FRAME_TYPE.FIN), 'bridge must use DATA+FIN frames');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { small: small.length, large: large.length, dataFrames: relay.frameTypes.filter((type) => type === FRAME_TYPE.DATA).length, finFrames: relay.frameTypes.filter((type) => type === FRAME_TYPE.FIN).length };
  });

  await check('fake-relay-open-failed-closes-phone', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-4' }));
    await relay.start();
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-4', echoPort: 1 });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitReady(tunnel, []);
    await waitFor(() => relay.bridgePort !== undefined, { label: 'bridge port' });
    const closed = await new Promise((done) => {
      const socket = netConnect({ host: '127.0.0.1', port: relay.bridgePort });
      const timer = setTimeout(() => {
        socket.destroy();
        done(false);
      }, 4000);
      socket.on('close', () => {
        clearTimeout(timer);
        done(true);
      });
      socket.on('error', () => {
        clearTimeout(timer);
        done(true);
      });
    });
    assert(closed, 'phone connection must be closed when the tunnel cannot dial the local link port');
    await waitFor(() => relay.messages.some((message) => message.t === 'open_failed'), { label: 'open_failed frame' });
    const failed = relay.messages.find((message) => message.t === 'open_failed');
    assert(failed.code === 'local/dial-failed', 'open_failed code mismatch: ' + JSON.stringify(failed));
    tunnel.dispose();
    await relay.close();
    return { openFailed: failed.code };
  });

  await check('fake-relay-pin-mismatch-permanent', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-5' }));
    await relay.start();
    const echo = track(await echoServer());
    const wrongPin = certPinFromFingerprint(otherCerts.leafFingerprint256);
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: wrongPin, secret: 'relay-secret-5', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    const health = await waitState(tunnel, 'error', 5000);
    assert(health.lastError === 'pin-mismatch', 'expected pin-mismatch, got ' + String(health.lastError));
    assert(relay.helloCount === 0, 'relay must never receive a hello after a pin mismatch');
    await sleep(300);
    assert(tunnel.health().state === 'error', 'pin mismatch must not keep retrying (permanent config error)');
    assert(tunnel.reconnectTimer === undefined, 'pin mismatch must not schedule a reconnect');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { state: health.state, lastError: health.lastError, helloCount: relay.helloCount };
  });

  await check('fake-relay-secret-rejected', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-6' }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'wrong-secret', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    const health = await waitState(tunnel, 'error', 5000);
    assert(String(health.lastError).startsWith('auth/invalid'), 'expected auth/invalid, got ' + String(health.lastError));
    assert(relay.messages.some((message) => message.t === 'hello'), 'relay must receive the hello before rejecting');
    assert(relay.helloCount === 1, 'wrong secret must not be retried');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { lastError: health.lastError };
  });

  await check('fake-relay-reconnect-and-drain', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-7', heartbeatSec: 1 }));
    await relay.start();
    const echo = track(await echoServer());
    const readyInfos = [];
    const { tunnel, events } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-7', echoPort: echo.port, onReady: (info) => readyInfos.push(info) });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitReady(tunnel, events);
    const firstOrigin = tunnel.health().origin;
    // server-side drop: tunnel reconnects and becomes ready again
    relay.destroyControl();
    await sleep(60);
    assert(tunnel.health().state !== 'ready', 'tunnel must leave ready after the control connection drops');
    await waitReady(tunnel, events, 6000);
    assert(readyInfos.length >= 2, 'onReady must fire again after reconnect, got ' + readyInfos.length);
    assert(tunnel.health().origin === firstOrigin, 'reconnect must keep the same relay origin');
    // relay drain: tunnel drops and reconnects to the (same) new instance
    const sessionsBefore = relay.sessions;
    relay.drain('shutdown');
    await waitFor(() => events.some((entry) => entry.event === 'tunnel.drained'), { label: 'tunnel.drained audit' });
    await waitReady(tunnel, events, 6000);
    assert(relay.sessions > sessionsBefore, 'tunnel did not reconnect after drain');
    assert(events.some((entry) => entry.event === 'tunnel.drained'), 'drain audit event missing');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { readyCount: readyInfos.length, sessions: relay.helloCount, drains: 1 };
  });

  await check('fake-relay-heartbeat', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-8', heartbeatSec: 1 }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-8', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitReady(tunnel, []);
    await waitFor(() => relay.messages.filter((message) => message.t === 'ping').length >= 2, { timeoutMs: 3500, label: 'tunnel pings' });
    await sleep(500);
    assert(tunnel.health().state === 'ready', 'tunnel must stay ready while pong frames flow');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { pings: relay.messages.filter((message) => message.t === 'ping').length };
  });

  await check('fake-relay-server-busy-retry', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-10', busyFirst: true }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel, events } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-10', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    const health = await waitReady(tunnel, events, 6000);
    assert(health.state === 'ready', 'tunnel must recover from a transient server/busy rejection');
    assert(relay.helloCount >= 2, 'tunnel must retry after server/busy, helloCount=' + relay.helloCount);
    assert(events.some((entry) => entry.event === 'tunnel.rejected' && entry.fields?.code === 'server/busy'), 'server/busy rejection must be audited');
    assert(tunnel.permanent === false, 'server/busy must stay retryable (not permanent)');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { helloCount: relay.helloCount, state: health.state, rejected: true };
  });

  await check('fake-relay-port-unavailable-permanent', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-11', portUnavailableFirst: true }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-11', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    const health = await waitState(tunnel, 'error', 5000);
    assert(String(health.lastError).startsWith('port/unavailable'), 'expected port/unavailable, got ' + String(health.lastError));
    assert(relay.helloCount === 1, 'port/unavailable is a config error and must not retry, helloCount=' + relay.helloCount);
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { lastError: health.lastError, helloCount: relay.helloCount };
  });

  await check('fake-relay-ready-hostid-mismatch', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-12', wrongHostId: true }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-12', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitFor(() => tunnel.health().lastError === 'protocol/host-id-mismatch', { timeoutMs: 5000, label: 'host-id-mismatch' });
    assert(tunnel.health().state !== 'ready', 'a ready frame for another hostId must not be accepted');
    assert(tunnel.health().origin === null, 'no origin may be advertised after a hostId mismatch');
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { lastError: tunnel.health().lastError };
  });

  await check('fake-relay-local-stream-limit', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-13' }));
    await relay.start();
    const echo = track(await echoServer());
    const { tunnel } = makeTunnel({ controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-13', echoPort: echo.port });
    track({ dispose: () => tunnel.dispose() });
    tunnel.start();
    await waitReady(tunnel, []);
    assert(relay.bridgePort !== undefined, 'fake relay not ready');
    relay.sendOpens(40);
    await waitFor(() => relay.messages.filter((message) => message.t === 'open_failed').length >= 8, { timeoutMs: 5000, label: 'open_failed frames' });
    const failures = relay.messages.filter((message) => message.t === 'open_failed');
    assert(failures.every((message) => message.code === 'local/busy'), 'stream limit open_failed code mismatch: ' + JSON.stringify(failures.slice(0, 2)));
    assert(tunnel.streams.size === 32, 'tunnel must cap local streams at 32 (relay maxStreamsPerHost), got ' + tunnel.streams.size);
    assert(failures.length === 8, 'expected 8 rejected opens out of 40, got ' + failures.length);
    tunnel.dispose();
    await relay.close();
    await closeNetServer(echo.server);
    return { opened: tunnel.streams.size, rejected: failures.length, code: failures[0]?.code };
  });

  // ----------------------------------------------------- link-server integration
  await check('link-server-tunnel-disabled-is-m1', () => {
    const { server } = track(makeServer());
    const before = JSON.stringify(server.health().deviceEndpoints);
    server.startTunnel();
    assert(server.tunnel === undefined, 'tunnel must not be created when tunnel.enabled=false');
    assert(JSON.stringify(server.health().deviceEndpoints) === before, 'deviceEndpoints must not change when the tunnel is disabled');
    assert(server.health().tunnel === undefined, '/health must have no tunnel field when the tunnel is disabled');
    assert(server.statusPayload().tunnel === null, 'desktop status.tunnel must be null when the tunnel is disabled');
    server.dispose();
    return { deviceEndpoints: JSON.parse(before) };
  });

  await check('link-server-relay-origin-injection', async () => {
    const { server } = track(makeServer({ config: { tunnel: { enabled: true, controlOrigin: 'https://203.0.113.10:443', pin: 'x'.repeat(43) } } }));
    const published = [];
    server.tunnel = {
      health: () => ({ enabled: true, state: 'ready', origin: 'https://203.0.113.10:30001', port: 30001, since: 1792561234567, lastError: null }),
      publishCode: (...args) => published.push(args),
      dispose: () => {},
    };
    server.onTunnelReady({ origin: 'https://203.0.113.10:30001', port: 30001 });
    const health = server.health();
    assert(health.deviceEndpoints.includes('https://203.0.113.10:30001'), '/health.deviceEndpoints must include the relay origin: ' + JSON.stringify(health.deviceEndpoints));
    assert(health.tunnel?.state === 'ready' && health.tunnel.origin === 'https://203.0.113.10:30001', '/health.tunnel mismatch: ' + JSON.stringify(health.tunnel));
    assert(JSON.stringify(health.tunnel).includes('x'.repeat(43)) === false, '/health must not contain the relay pin/secret');
    const payload = server.pairing.payload();
    assert(payload.relay?.origin === 'https://203.0.113.10:30001', 'payload must carry the top-level relay object: ' + JSON.stringify(payload.relay));
    assert(payload.relay?.pin === 'x'.repeat(43) && payload.relay?.v === 1, 'payload.relay pin/v mismatch');
    assert(payload.origins.includes('https://203.0.113.10:30001'), 'payload origins must include the relay origin');
    assert(payload.endpoints.some((endpoint) => endpoint.url === 'https://203.0.113.10:30001' && endpoint.kind === 'relay' && endpoint.pri === 100), 'payload endpoint must be kind=relay pri=100');
    assert(verifyPayloadSignature(payload, server.pairing.payloadText()) === true, 'relay payload signature must still verify');
    const qrPayload = await server.pairingPayload();
    assert(JSON.stringify(qrPayload.payload).includes('https://203.0.113.10:30001'), 'QR payload must advertise the relay origin');
    // publishCode must forward the Mac DER pin (not the SPKI pin) to the relay
    assert(published.length >= 1, 'onTunnelReady must publish the current pairing code');
    const [code, exp, leafPin, leafFingerprint, hostName] = published.at(-1);
    assert(/^\d{8}$/.test(code), 'published code missing: ' + JSON.stringify(published.at(-1)));
    assert(typeof exp === 'number' && exp > Date.now(), 'published code expiry missing');
    assert(/^[A-Za-z0-9_-]{43}$/.test(leafPin), 'published leafPin must be base64url cert DER sha256, got ' + String(leafPin));
    assert(leafFingerprint === TEST_CERTS.leafFingerprint256, 'published leafFingerprint256 mismatch');
    assert(typeof hostName === 'string' && hostName.length > 0, 'published hostName missing');
    server.pairCode.dispose();
    server.dispose();
    return { deviceEndpoints: health.deviceEndpoints, tunnel: health.tunnel, relay: payload.relay, publishedCode: code };
  });

  await check('link-server-tunnel-client-e2e', async () => {
    const relay = track(new FakeRelay({ certs, secret: 'relay-secret-9', heartbeatSec: 2 }));
    await relay.start();
    const { server } = track(makeServer({
      config: { tunnel: { enabled: true, controlOrigin: relay.controlOrigin, pin: relay.pin, secret: 'relay-secret-9' } },
    }));
    try {
      server.startTunnel();
      await waitFor(() => server.tunnel !== undefined, { label: 'tunnel client' });
      await waitFor(() => server.tunnel.health().state === 'ready', { timeoutMs: 8000, label: 'tunnel ready' });
      const health = server.health();
      const relayOrigin = 'https://127.0.0.1:' + String(relay.bridgePort);
      assert(health.deviceEndpoints.includes(relayOrigin), '/health.deviceEndpoints missing relay origin: ' + JSON.stringify(health.deviceEndpoints));
      assert(health.tunnel?.origin === relayOrigin && health.tunnel?.state === 'ready', '/health.tunnel mismatch: ' + JSON.stringify(health.tunnel));
      assert(server.statusPayload().tunnel?.origin === relayOrigin, 'desktop status.tunnel mismatch');
      const payload = server.pairing.payload();
      assert(payload.relay?.origin === relayOrigin, 'signed payload must carry relay.origin: ' + JSON.stringify(payload.relay));
      assert(payload.origins.includes(relayOrigin), 'signed payload origins missing relay origin');
      const qr = await server.pairingPayload();
      assert(qr.payload.relay?.origin === relayOrigin, 'QR payload relay mismatch');
      // the pairing code must be mirrored to the relay for App lookup
      await waitFor(() => relay.messages.some((message) => message.t === 'code'), { label: 'relay code frame' });
      const published = relay.messages.find((message) => message.t === 'code');
      assert(published.code === server.pairCode.status().value, 'relay code frame does not match the live pairing code');
      assert(/^[A-Za-z0-9_-]{43}$/.test(published.leafPin ?? ''), 'relay code leafPin must be the Mac DER pin');
      server.dispose();
      await waitFor(() => relay.sessions >= 1, { label: 'relay session' });
      return { deviceEndpoints: health.deviceEndpoints, relay: payload.relay, publishedCode: published.code, tunnelHealth: health.tunnel };
    } finally {
      try {
        server.pairCode.dispose();
      } catch {
        /* already disposed */
      }
      await relay.close();
    }
  });

  // ------------------------------------------------------- real relay binary
  const relayReady = existsSync(join(RELAY_DIR, 'go.mod')) && !skipRealRelay;
  await check('real-relay-integration', async () => {
    if (!relayReady) return { skipped: true, reason: 'packages/dsh-m-relay missing or --skip-real-relay' };
    const goVersion = execFileSync('go', ['version'], { encoding: 'utf8' }).trim();
    const dir = track(mkdtempSync(join(tmpdir(), 'dshm-m2-realrelay-')));
    const relayBin = join(dir, 'dshm-relay');
    execFileSync('go', ['build', '-o', relayBin, '.'], { cwd: RELAY_DIR, encoding: 'utf8', timeout: 120_000 });
    const range = await freeRange(4);
    const init = JSON.parse(execFileSync(relayBin, [
      'init', '--public-host', '127.0.0.1', '--control-listen', '127.0.0.1:0',
      '--bridge-ports', '127.0.0.1:' + String(range.start) + '-' + String(range.end),
      '--out', dir, '--print-json',
    ], { encoding: 'utf8' }).trim());
    assert(init.tunnel?.enabled === true && /^[A-Za-z0-9_-]{43}$/.test(init.pin), 'relay init must print the tunnel config with a DER pin');
    assert(init.controlOrigin.startsWith('https://127.0.0.1:'), 'relay init controlOrigin mismatch: ' + init.controlOrigin);
    const addrFile = join(dir, 'addr.json');
    const children = [];
    const startRelay = async () => {
      const child = spawn(relayBin, ['serve', '--config', join(dir, 'relay.yaml'), '--addr-file', addrFile], { stdio: ['ignore', 'pipe', 'pipe'] });
      children.push(child);
      let stderr = '';
      child.stderr.on('data', (chunk) => (stderr += chunk));
      await waitFor(() => existsSync(addrFile), { timeoutMs: 5000, label: 'relay addr file' });
      return { child, addr: JSON.parse(readFileSync(addrFile, 'utf8')), stderr: () => stderr };
    };
    const stopRelay = async (child) => {
      if (child === undefined || child.exitCode !== null) return;
      child.kill('SIGTERM');
      await Promise.race([new Promise((done) => child.once('exit', done)), sleep(3000)]);
    };
    const cleanup = async () => {
      for (const child of children) await stopRelay(child);
    };
    try {
      const first = await startRelay();
      assert(first.addr.controlOrigin === init.controlOrigin, 'addr-file controlOrigin mismatch: ' + JSON.stringify(first.addr));
      const echo = await echoServer();
      const { tunnel, events } = makeTunnel({ controlOrigin: init.controlOrigin, pin: init.pin, secret: init.secret, echoPort: echo.port, hostId: 'm2tunnel-real-host-1', backoffMs: [200, 400, 800] });
      try {
        tunnel.start();
        const health = await waitReady(tunnel, events, 8000);
        assert(health.origin.startsWith('https://127.0.0.1:'), 'real relay origin mismatch: ' + JSON.stringify(health));
        assert(health.port >= range.start && health.port <= range.end, 'bridge port outside the configured pool: ' + String(health.port));
        // publish the current code + lookup over pinned HTTPS (pin checked by hand)
        const leafPin = certPinFromFingerprint(TEST_CERTS.leafFingerprint256);
        tunnel.publishCode('24681357', Date.now() + 120_000, leafPin, TEST_CERTS.leafFingerprint256, 'Real Relay Test Mac');
        const control = new URL(init.controlOrigin);
        const lookup = await new Promise((done, fail) => {
          const request = httpsRequest({ host: control.hostname, port: control.port, path: '/v1/lookup', method: 'POST', rejectUnauthorized: false, headers: { 'content-type': 'application/json' } }, (response) => {
            // Capture the peer certificate while the socket is attached; Node
            // detaches response.socket after 'end'.
            const peerPin = (() => {
              try {
                return certPin(response.socket.getPeerCertificate().raw);
              } catch {
                return undefined;
              }
            })();
            let body = '';
            response.on('data', (chunk) => (body += chunk));
            response.on('end', () => done({ status: response.statusCode, body: JSON.parse(body), pin: peerPin }));
          });
          request.on('error', fail);
          request.end(JSON.stringify({ code: '24681357' }));
        });
        assert(lookup.pin === init.pin, 'real relay lookup TLS pin mismatch');
        assert(lookup.status === 200 && lookup.body.ok === true, 'real relay lookup failed: ' + JSON.stringify(lookup));
        assert(lookup.body.hostId === 'm2tunnel-real-host-1', 'lookup hostId mismatch');
        assert(lookup.body.hostName === 'Real Relay Test Mac', 'lookup hostName mismatch: ' + lookup.body.hostName);
        assert(lookup.body.origin === health.origin, 'lookup origin must match ready origin: ' + lookup.body.origin + ' != ' + health.origin);
        assert(lookup.body.leafPin === leafPin, 'lookup leafPin must echo the Mac DER pin');
        assert(lookup.body.leafFingerprint256 === TEST_CERTS.leafFingerprint256, 'lookup leafFingerprint256 mismatch');
        // miss + expired
        const lookupCode = (code) => new Promise((done, fail) => {
          const request = httpsRequest({ host: control.hostname, port: control.port, path: '/v1/lookup', method: 'POST', rejectUnauthorized: false, headers: { 'content-type': 'application/json' } }, (response) => {
            let body = '';
            response.on('data', (chunk) => (body += chunk));
            response.on('end', () => done({ status: response.statusCode, body: JSON.parse(body) }));
          });
          request.on('error', fail);
          request.end(JSON.stringify({ code }));
        });
        const miss = await lookupCode('00000000');
        assert(miss.status === 404 && miss.body.error === 'code/not-found', 'lookup miss mismatch: ' + JSON.stringify(miss));
        // Expiry must round to a future unix second: the relay rejects
        // `exp <= now` at publish time, so leave >=1s of headroom.
        tunnel.publishCode('13572468', Date.now() + 2000, leafPin, TEST_CERTS.leafFingerprint256, 'Real Relay Test Mac');
        await sleep(2400);
        const expired = await lookupCode('13572468');
        assert(expired.status === 410 && expired.body.error === 'code/expired', 'lookup expired mismatch: ' + JSON.stringify(expired));
        tunnel.publishCode('24681357', Date.now() + 120_000, leafPin, TEST_CERTS.leafFingerprint256, 'Real Relay Test Mac');
        await sleep(100);
        // bridge echo, TLS-ClientHello semantics: phone writes first bytes then
        // waits for the echo (no half-close). This is the path the relay must
        // flush after `opened`.
        const bridgeOrigin = new URL(health.origin);
        const bridgeEcho = (payload) => new Promise((done, fail) => {
          const socket = netConnect({ host: bridgeOrigin.hostname, port: Number(bridgeOrigin.port) });
          const timer = setTimeout(() => {
            socket.destroy();
            fail(new Error('real relay bridge echo timeout (' + payload.length + ' bytes): relay did not forward the first phone bytes'));
          }, 8000);
          const chunks = [];
          socket.on('connect', () => socket.write(payload));
          socket.on('data', (chunk) => {
            chunks.push(chunk);
            if (Buffer.concat(chunks).length >= payload.length) {
              clearTimeout(timer);
              socket.end();
              done(Buffer.concat(chunks));
            }
          });
          socket.on('error', (error) => {
            clearTimeout(timer);
            fail(error);
          });
        });
        const smallEcho = await bridgeEcho(Buffer.from('real-relay-bridge-echo'));
        assert(smallEcho.toString() === 'real-relay-bridge-echo', 'real relay small echo mismatch');
        const large = Buffer.alloc(128 * 1024);
        for (let index = 0; index < large.length; index += 1) large[index] = (index * 17 + 3) & 0xff;
        const largeEcho = await bridgeEcho(large);
        assert(largeEcho.equals(large), 'real relay large echo mismatch');
        // task-9 error semantics: a wantPort that is inside the pool and not owned
        // by another host but temporarily unbindable (held by another OS process)
        // must produce a *transient* server/busy; the plugin backs off and the
        // retry succeeds once the port is released.
        const busyPort = range.start + 2;
        const holder = createNetServer({ allowHalfOpen: true }, (socket) => socket.destroy());
        await new Promise((done, reject) => {
          holder.once('error', reject);
          holder.listen(busyPort, '127.0.0.1', done);
        });
        const busyTunnel = makeTunnel({
          controlOrigin: init.controlOrigin,
          pin: init.pin,
          secret: init.secret,
          echoPort: echo.port,
          hostId: 'm2tunnel-real-busy-host',
          wantPort: busyPort,
          backoffMs: [200, 400, 800],
        });
        try {
          busyTunnel.tunnel.start();
          await waitFor(() => busyTunnel.events.some((entry) => entry.event === 'tunnel.rejected' && entry.fields?.code === 'server/busy'), { timeoutMs: 8000, label: 'real relay server/busy rejection' });
          assert(busyTunnel.tunnel.permanent === false, 'real relay server/busy must stay retryable (not permanent)');
          await new Promise((done) => holder.close(done));
          await waitReady(busyTunnel.tunnel, busyTunnel.events, 10_000);
          assert(busyTunnel.tunnel.health().port === busyPort, 'retry after server/busy must bind the requested wantPort ' + String(busyPort) + ', got ' + String(busyTunnel.tunnel.health().port));
          busyTunnel.tunnel.dispose();
        } finally {
          busyTunnel.tunnel.dispose();
          try {
            await new Promise((done) => holder.close(() => done()));
          } catch {
            /* already closed */
          }
        }
        assert(tunnel.health().state === 'ready', 'first tunnel must stay ready while the second host retries');
        // graceful drain: SIGTERM -> drain -> tunnel reconnects to a restarted relay
        await sleep(100);
        await stopRelay(first.child);
        await waitFor(() => events.some((entry) => entry.event === 'tunnel.drained') || events.some((entry) => entry.event === 'tunnel.disconnected'), { timeoutMs: 5000, label: 'drain/disconnect audit' });
        await sleep(300);
        const second = await startRelay();
        await waitReady(tunnel, events, 10_000);
        assert(tunnel.health().origin === health.origin, 'reconnect origin changed: ' + tunnel.health().origin);
        const echoAfterRestart = await bridgeEcho(Buffer.from('after-restart'));
        assert(echoAfterRestart.toString() === 'after-restart', 'bridge echo after relay restart failed');
        assert(events.some((entry) => entry.event === 'tunnel.ready'), 'tunnel.ready audit missing');
        await closeNetServer(echo.server);
        return {
          relayVersion: execFileSync(relayBin, ['version'], { encoding: 'utf8' }).trim(),
          go: goVersion,
          bridgePorts: first.addr.bridgePorts,
          origin: health.origin,
          lookup: { status: lookup.status, hostId: lookup.body.hostId, leafPinMatches: lookup.body.leafPin === leafPin },
          miss: miss.status,
          expired: expired.status,
          bridge: { small: smallEcho.length, large: largeEcho.length, afterRestart: echoAfterRestart.length },
          serverBusyRetry: { wantPort: busyPort, retried: true },
          reconnects: events.filter((entry) => entry.event === 'tunnel.ready').length,
        };
      } finally {
        tunnel.dispose();
        await closeNetServer(echo.server);
      }
    } finally {
      await cleanup();
    }
  });

  const failed = checks.filter((entry) => entry.ok !== true).length;
  const report = {
    startedAt: new Date().toISOString(),
    finishedAt: new Date().toISOString(),
    passed: failed === 0,
    checks,
    summary: { checks: checks.length, failed },
  };
  const file = join(outDir, 'm2-tunnel.json');
  writeFileSync(file, JSON.stringify(report, null, 2) + '\n');
  for (const value of cleanups) {
    try {
      if (typeof value === 'string') rmSync(value, { recursive: true, force: true });
      else value?.dispose?.();
    } catch {
      /* best effort */
    }
  }
  console.log('\n== tunnel: ' + (failed === 0 ? 'GO' : 'NO-GO') + ' (' + String(checks.length - failed) + '/' + String(checks.length) + ') ==');
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error('TUNNEL TEST ERROR: ' + String(error?.stack ?? error));
  process.exit(2);
});
