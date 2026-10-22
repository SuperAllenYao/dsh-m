/**
 * m2-paircode.mjs — M2a task-2 tests: 8-digit pairing code service, the
 * /pair/code/redeem contract, the desktop admin surfaces and the zero-dependency
 * mDNS responder.
 *
 * Runs standalone (no DSH host, no network listener, no ~/.dsh):
 *   node test/m2-paircode.mjs [--out-dir <dir>]
 *
 * The LinkServer is exercised at the handler level: a real instance is built
 * with an injected Cordis-like ctx and a stubbed upstream peer, then
 * handleRequest() is driven with tiny fake IncomingMessage/ServerResponse
 * objects. That covers routing + status codes + response shapes without binding
 * a TLS port (the isolated DSH regression in test/run-m1.sh covers the live
 * listener path).
 */

import { createPublicKey, generateKeyPairSync, verify, X509Certificate } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';

import { AuditLog } from '../lib/audit.js';
import { BonjourResponder, encodeName, readName, SERVICE_TYPE } from '../lib/bonjour.js';
import { canonicalJson } from '../lib/canonical.js';
import { ensureCerts } from '../lib/certs.js';
import { DeviceStore } from '../lib/devices.js';
import { ensureHostIdentity } from '../lib/host-identity.js';
import { LinkServer, PLUGIN_VERSION } from '../lib/link-server.js';
import { buildEndpoints, generatePairCode, PairCodeService, PairingService, selectDeviceEndpoints } from '../lib/pairing.js';

const DEFAULT_OUT = resolve(new URL('results', import.meta.url).pathname);
const TEST_CERTS = {
  caPin: 'CA-PIN-TEST',
  leafPin: 'LEAF-PIN-TEST',
  caFingerprint256: 'AA:BB:CC',
  leafFingerprint256: 'DD:EE:FF',
  leafNotAfter: 'Oct 20 16:27:30 2027 GMT',
  // C scheme: public CA certificate as DER base64. Real suites generate this via
  // ensureCerts(); fixture suites just need a stable placeholder value.
  caCertDerBase64: Buffer.from('unit-test-ca-cert-der').toString('base64'),
};
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function makeAudit(dir, sink) {
  return new AuditLog({ dir, log: () => {} });
}

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

function fakeRequest({ method = 'POST', url = '/', body, ip = '127.0.0.1' } = {}) {
  const request = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  request.method = method;
  request.url = url;
  request.headers = {};
  request.socket = { remoteAddress: ip };
  return request;
}

async function call(server, { method = 'POST', path = '/', body, ip = '127.0.0.1' } = {}) {
  const response = fakeResponse();
  await server.handleRequest(fakeRequest({ method, url: path, body, ip }), response);
  let json;
  try {
    json = JSON.parse(response.body);
  } catch {
    json = undefined;
  }
  return { status: response.statusCode, json, text: response.body };
}

/** Build a fully wired LinkServer without starting the TLS listener. */
function makeServer({ config = {}, dir, certs } = {}) {
  const home = dir ?? mkdtempSync(join(tmpdir(), 'dshm-m2-paircode-'));
  const ctx = {
    get: (name) => (name === 'dshHomePath' ? home : undefined),
    webServer: { getOrigin: () => 'http://127.0.0.1:62001' },
    connection: { authenticatedUrl: (url) => url },
  };
  const server = new LinkServer(ctx, {
    port: 3467,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: true, adminToken: 'test-admin-token' },
    ...config,
  });
  const serverCerts = certs ?? { ...TEST_CERTS };
  const dataDir = join(home, 'plugin-data', 'dsh-m-link');
  server.audit = makeAudit(dataDir);
  server.hostIdentity = ensureHostIdentity({ dir: dataDir, log: () => {} });
  server.devices = new DeviceStore({ dir: dataDir, hostId: server.hostIdentity.hostId, log: () => {} }).load();
  server.certs = serverCerts;
  server.hostname = 'test-mac';
  server.lanIps = [];
  server.started = true;
  server.disposed = false;
  server.starting = false;
  server.qr = { renderDataUrl: async () => ({ ok: false, error: 'unit-test-no-qr' }), dispose: () => {} };
  server.apns = { mode: 'stub', reason: 'test', topic: null, info: () => ({ mode: 'stub', reason: 'test' }), dispose: () => {} };
  server.notifier = { dispose: () => {} };
  server.auth = { sweep: () => {}, dispose: () => {} };
  server.server = undefined;
  server.contract = { ok: true, skipped: true };
  const endpoints = buildEndpoints({ config: { port: 3467, bindHost: '127.0.0.1' }, certs: serverCerts, lanIps: [] });
  server.endpoints = endpoints;
  server.baseEndpoints = endpoints.slice();
  server.deviceEndpoints = selectDeviceEndpoints(endpoints);
  server.pairing = new PairingService({
    config: { pairTtlMs: 90_000, hostName: 'Test Mac' },
    certs: serverCerts,
    hostIdentity: server.hostIdentity,
    endpoints: server.deviceEndpoints,
    audit: server.audit,
  });
  server.pairing.refresh('test');
  server.pairCode = new PairCodeService({ config: server.config, audit: server.audit, autoRotate: true, log: () => {} });
  server.pairCode.start('startup');
  server.ensurePeer = () => ({ connect: async () => {} });
  return { server, home, dataDir };
}

function devicePublicKey() {
  const { publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return publicKey.export({ type: 'spki', format: 'der' }).toString('base64url');
}

function verifyPayloadSignature(payload, payloadText) {
  if (payloadText !== canonicalJson(payload)) return false;
  const { sig, ...unsigned } = payload;
  const keyDer = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(payload.host.key, 'base64url')]);
  const key = createPublicKey({ key: keyDer, format: 'der', type: 'spki' });
  return verify(null, Buffer.from(canonicalJson(unsigned), 'utf8'), key, Buffer.from(String(sig ?? ''), 'base64url'));
}

/** True when some (possibly nested) value is exactly the needle (no substring false positives). */
function deepEqualsValue(value, needle) {
  if (typeof value === 'string') return value === needle;
  if (Array.isArray(value)) return value.some((entry) => deepEqualsValue(entry, needle));
  if (value !== null && typeof value === 'object') return Object.values(value).some((entry) => deepEqualsValue(entry, needle));
  return false;
}

/** Minimal DNS answer parser used by the mDNS assertions. */
function parseAnswers(buffer) {
  const header = { id: buffer.readUInt16BE(0), flags: buffer.readUInt16BE(2), qdcount: buffer.readUInt16BE(4), ancount: buffer.readUInt16BE(6) };
  const answers = [];
  let offset = 12;
  for (let index = 0; index < header.qdcount; index += 1) {
    const read = readName(buffer, offset);
    offset = read.next + 4;
  }
  for (let index = 0; index < header.ancount; index += 1) {
    const read = readName(buffer, offset);
    const type = buffer.readUInt16BE(read.next);
    const klass = buffer.readUInt16BE(read.next + 2);
    const ttl = buffer.readUInt32BE(read.next + 4);
    const length = buffer.readUInt16BE(read.next + 8);
    const rdataStart = read.next + 10;
    answers.push({ name: read.name, type, klass, ttl, rdata: buffer.subarray(rdataStart, rdataStart + length) });
    offset = rdataStart + length;
  }
  return { header, answers };
}

function txtPairs(rdata) {
  const pairs = {};
  let offset = 0;
  while (offset < rdata.length) {
    const length = rdata[offset];
    if (length === 0) break;
    const entry = rdata.subarray(offset + 1, offset + 1 + length).toString('utf8');
    const eq = entry.indexOf('=');
    if (eq > 0) pairs[entry.slice(0, eq)] = entry.slice(eq + 1);
    offset += 1 + length;
  }
  return pairs;
}

function buildQuery(name, type = 12) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0);
  header.writeUInt16BE(0, 2);
  header.writeUInt16BE(1, 4);
  const tail = Buffer.alloc(4);
  tail.writeUInt16BE(type, 0);
  tail.writeUInt16BE(1, 2);
  return Buffer.concat([header, encodeName(name), tail]);
}

class FakeSocket {
  constructor() {
    this.handlers = new Map();
    this.sent = [];
    this.closed = false;
    this.membership = false;
  }
  on(event, handler) {
    if (!this.handlers.has(event)) this.handlers.set(event, []);
    this.handlers.get(event).push(handler);
    return this;
  }
  emit(event, ...args) {
    for (const handler of this.handlers.get(event) ?? []) handler(...args);
  }
  bind(port, address, callback) {
    this.bound = { port, address };
    setImmediate(() => callback?.());
    return this;
  }
  setMulticastTTL() {}
  setMulticastLoopback() {}
  addMembership() {
    this.membership = true;
  }
  send(packet, offset, length, port, address, callback) {
    this.sent.push({ packet: Buffer.from(packet), port, address });
    callback?.(null);
    return true;
  }
  close() {
    this.closed = true;
  }
}

async function main() {
  const outDir = process.argv.includes('--out-dir') ? process.argv[process.argv.indexOf('--out-dir') + 1] : DEFAULT_OUT;
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
  const cleanup = [];
  const track = (value) => {
    cleanup.push(value);
    return value;
  };

  // ------------------------------------------------------------ code service
  await check('pair-code-format', () => {
    const seen = new Set();
    for (let index = 0; index < 500; index += 1) {
      const code = generatePairCode();
      assert(/^\d{8}$/.test(code), 'code is not 8 digits: ' + code);
      seen.add(code);
    }
    assert(seen.size > 490, 'suspiciously low code entropy: ' + seen.size + '/500 unique');
    return { codes: 500, unique: seen.size };
  });

  await check('pair-code-single-use-and-refresh', () => {
    const events = [];
    const service = new PairCodeService({ audit: { record: (event, fields) => events.push({ event, fields }) }, autoRotate: false });
    service.start('startup');
    const first = service.current().value;
    assert(/^\d{8}$/.test(first), 'first code malformed');
    const result = service.check(first);
    assert(result.ok === true, 'correct code rejected: ' + JSON.stringify(result));
    service.consume();
    const second = service.current().value;
    assert(second !== first, 'consume did not rotate the code');
    assert(service.check(first).error === 'code/invalid', 'reusing a consumed code must be 401 code/invalid');
    assert(events.some((entry) => entry.event === 'pair.code.issued'), 'missing pair.code.issued audit event');
    service.refresh('manual');
    assert(events.some((entry) => entry.event === 'pair.code.refreshed'), 'manual refresh did not record pair.code.refreshed');
    service.dispose();
    return { firstLength: first.length, rotated: second !== first };
  });

  await check('pair-code-attempts-lock', () => {
    const events = [];
    const service = new PairCodeService({ audit: { record: (event, fields) => events.push({ event, fields }) }, autoRotate: false, maxAttempts: 5 });
    service.start('startup');
    const code = service.current().value;
    const wrong = code === '00000000' ? '11111111' : '00000000';
    const results = [];
    for (let index = 0; index < 5; index += 1) results.push(service.check(wrong, { ip: '127.0.0.1' }));
    assert(results.slice(0, 4).every((entry) => entry.error === 'code/invalid'), 'first four wrong attempts must be code/invalid');
    assert(results.slice(0, 4).map((entry) => entry.remaining).join(',') === '4,3,2,1', 'remaining countdown mismatch: ' + JSON.stringify(results.slice(0, 4)));
    assert(results[4].error === 'code/locked', 'fifth wrong attempt must lock the code');
    assert(service.check(code).error === 'code/locked', 'locked code must stay locked even for the right value until refresh');
    assert(events.some((entry) => entry.event === 'pair.code.rejected'), 'missing pair.code.rejected');
    assert(events.some((entry) => entry.event === 'pair.code.locked'), 'missing pair.code.locked');
    service.refresh('manual');
    assert(service.check(code).error === 'code/invalid', 'after manual refresh the old locked code must be invalid (not locked)');
    service.dispose();
    return { statuses: results.map((entry) => entry.error), remaining: results.map((entry) => entry.remaining) };
  });

  await check('pair-code-expiry-and-rotation', async () => {
    const events = [];
    const service = new PairCodeService({ audit: { record: (event, fields) => events.push({ event, fields }) }, autoRotate: true, ttlMs: 250 });
    service.start('startup');
    const first = service.current().value;
    await sleep(450);
    const second = service.current()?.value;
    assert(typeof second === 'string' && second !== first, 'ticker did not rotate the expired code');
    assert(service.check(first).error === 'code/expired', 'presenting the expired old code must be 410 code/expired');
    assert(events.some((entry) => entry.event === 'pair.code.refreshed-auto'), 'missing pair.code.refreshed-auto');
    assert(events.some((entry) => entry.event === 'pair.code.expired'), 'missing pair.code.expired');
    // audit event fields never contain the code value itself
    assert(events.every((entry) => !deepEqualsValue(entry.fields, first) && !deepEqualsValue(entry.fields, second)), 'audit event fields leaked the code value');
    service.dispose();
    return { first, second, expiredMapped: true };
  });

  await check('pair-code-malformed-does-not-burn-attempts', () => {
    const service = new PairCodeService({ audit: { record: () => {} }, autoRotate: false });
    service.start('startup');
    const code = service.current().value;
    const malformed = service.check('12ab', { ip: '127.0.0.1' });
    assert(malformed.error === 'code/invalid' && malformed.remaining === 5, 'malformed input must not burn an attempt: ' + JSON.stringify(malformed));
    assert(service.check(code).ok === true, 'correct code must still work after malformed input');
    service.dispose();
    return { malformedRemaining: malformed.remaining };
  });

  // ------------------------------------------------- /pair/code/redeem contract
  await check('code-redeem-success-contract', async () => {
    const { server, home } = track(makeServer());
    const code = server.pairCode.status().value;
    const pubKey = devicePublicKey();
    const { status, json } = await call(server, { path: '/pair/code/redeem', body: { code, devicePubKey: pubKey, deviceName: 'iPhone Test', platform: 'ios' } });
    assert(status === 200 && json?.ok === true, 'redeem failed: ' + status + ' ' + JSON.stringify(json));
    assert(typeof json.deviceId === 'string' && json.deviceId.length > 0, 'missing deviceId');
    assert(json.deviceName === 'iPhone Test', 'deviceName mismatch: ' + json.deviceName);
    assert(/^[A-Za-z0-9_-]{43}$/.test(json.keyId ?? ''), 'keyId is not a base64url sha256 pin');
    assert(/^[A-Za-z0-9_-]{43}$/.test(json.credential ?? ''), 'credential is not 32-byte base64url');
    assert(json.proto === 'dsh-m/1', 'proto mismatch');
    assert(json.server?.plugin === 'dsh-m-link' && json.server?.hostId === server.hostIdentity.hostId, 'server block mismatch');
    assert(json.tls?.caPin === TEST_CERTS.caPin && json.tls?.leafPin === TEST_CERTS.leafPin, 'tls pins missing');
    assert(json.tls?.caFingerprint256 === TEST_CERTS.caFingerprint256 && json.tls?.leafFingerprint256 === TEST_CERTS.leafFingerprint256, 'code channel must include DER fingerprints');
    assert(json.tls?.caCert === TEST_CERTS.caCertDerBase64, 'code channel must expose the public CA certificate (DER base64)');
    assert(json.auth?.challengePath === '/auth/challenge' && json.auth?.algorithm === 'ECDSA-P256-SHA256', 'auth block mismatch');
    assert(json.payload?.v === 1 && json.payload?.kind === 'dsh-m.pair', 'payload version/kind mismatch');
    assert(Array.isArray(json.payload?.endpoints) && json.payload.endpoints.length > 0, 'payload has no endpoints');
    assert(json.payload?.tls?.leafFingerprint256 === TEST_CERTS.leafFingerprint256, 'payload leaf fingerprint mismatch');
    assert(json.payload?.tls?.caCert === TEST_CERTS.caCertDerBase64, 'signed payload must expose the public CA certificate');
    assert(json.payload?.pair?.proto === 'dsh-m/1', 'payload pair proto mismatch');
    assert(typeof json.payloadText === 'string' && json.payloadText === canonicalJson(json.payload), 'payloadText is not the canonical signed payload');
    assert(verifyPayloadSignature(json.payload, json.payloadText) === true, 'Ed25519 signature over payloadText does not verify');
    assert(deepEqualsValue(json.payload, code) === false, 'the pairing code leaked into the signed payload');
    // single use
    const replay = await call(server, { path: '/pair/code/redeem', body: { code, devicePubKey: devicePublicKey(), deviceName: 'iPhone 2' } });
    assert(replay.status === 401 && replay.json?.error === 'code/invalid', 'code was not single-use: ' + replay.status + ' ' + JSON.stringify(replay.json));
    // audit: redeemed event with deviceId, no code value anywhere in audit.log
    const auditFile = join(home, 'plugin-data', 'dsh-m-link', 'audit.log');
    const auditLines = readFileSync(auditFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert(auditLines.some((line) => line.event === 'pair.code.redeemed' && line.deviceId === json.deviceId), 'missing pair.code.redeemed audit event with deviceId');
    assert(auditLines.every((line) => !deepEqualsValue(line, code)), 'audit.log leaked the pairing code');
    server.pairCode.dispose();
    return { deviceId: json.deviceId, payloadBytes: json.payloadText.length, endpoints: json.payload.endpoints.map((entry) => entry.url) };
  });

  await check('code-redeem-error-codes', async () => {
    const { server } = track(makeServer({ config: { pairCodeTtlMs: 300 } }));
    // wrong code -> 401 with remaining
    const wrong = server.pairCode.status().value === '00000000' ? '11111111' : '00000000';
    const mismatch = await call(server, { path: '/pair/code/redeem', body: { code: wrong, devicePubKey: devicePublicKey() } });
    assert(mismatch.status === 401 && mismatch.json?.error === 'code/invalid', 'wrong code must be 401 code/invalid: ' + mismatch.status);
    assert(mismatch.json?.remaining === 4, 'wrong code must report remaining attempts: ' + JSON.stringify(mismatch.json));
    // expired code -> 410 (ticker rotates; old code is remembered as expired)
    const expiredCode = server.pairCode.status().value;
    await sleep(450);
    const expired = await call(server, { path: '/pair/code/redeem', body: { code: expiredCode, devicePubKey: devicePublicKey() } });
    assert(expired.status === 410 && expired.json?.error === 'code/expired', 'expired code must be 410 code/expired: ' + expired.status + ' ' + JSON.stringify(expired.json));
    // malformed device key must not consume the live code
    const live = server.pairCode.status().value;
    const badKey = await call(server, { path: '/pair/code/redeem', body: { code: live, devicePubKey: 'not-a-key' } });
    assert(badKey.status === 401 && badKey.json?.error === 'pair/invalid-key', 'bad device key must be 401 pair/invalid-key: ' + badKey.status);
    const rescued = await call(server, { path: '/pair/code/redeem', body: { code: live, devicePubKey: devicePublicKey(), deviceName: 'iPhone Rescued' } });
    assert(rescued.status === 200, 'bad device key consumed the code: ' + rescued.status + ' ' + JSON.stringify(rescued.json));
    // lock after 5 wrong attempts -> 423
    const code = server.pairCode.status().value;
    const wrongCode = code === '22222222' ? '33333333' : '22222222';
    const attempts = [];
    for (let index = 0; index < 5; index += 1) attempts.push(await call(server, { path: '/pair/code/redeem', body: { code: wrongCode, devicePubKey: devicePublicKey() } }));
    assert(attempts.at(-1).status === 423 && attempts.at(-1).json?.error === 'code/locked', 'fifth wrong attempt must be 423 code/locked: ' + JSON.stringify(attempts.at(-1).json));
    const lockedRight = await call(server, { path: '/pair/code/redeem', body: { code, devicePubKey: devicePublicKey() } });
    assert(lockedRight.status === 423, 'locked code must stay 423 for the right value: ' + lockedRight.status);
    server.pairCode.dispose();
    return { mismatch: mismatch.json, expired: expired.json?.error, locked: lockedRight.json?.error };
  });

  await check('code-redeem-rate-limited', async () => {
    const { server } = track(makeServer({ config: { pairCodeRateLimitPerMin: 2 } }));
    const wrong = '00000000';
    const first = await call(server, { path: '/pair/code/redeem', body: { code: wrong, devicePubKey: devicePublicKey() } });
    const second = await call(server, { path: '/pair/code/redeem', body: { code: wrong, devicePubKey: devicePublicKey() } });
    const third = await call(server, { path: '/pair/code/redeem', body: { code: wrong, devicePubKey: devicePublicKey() } });
    assert(first.status === 401 && second.status === 401, 'first two attempts must pass the limiter: ' + first.status + '/' + second.status);
    assert(third.status === 429 && third.json?.error === 'code/rate-limited', 'third attempt must be 429 code/rate-limited: ' + third.status + ' ' + JSON.stringify(third.json));
    server.pairCode.dispose();
    return { statuses: [first.status, second.status, third.status] };
  });

  await check('pair-redeem-backward-compatible', async () => {
    const { server } = track(makeServer());
    server.pairing.refresh('test');
    const token = server.pairing.session.token;
    const { status, json } = await call(server, { path: '/pair/redeem', body: { pairToken: token, devicePubKey: devicePublicKey(), deviceName: 'Legacy Phone', platform: 'ios' } });
    assert(status === 200 && json?.ok === true, '/pair/redeem regressed: ' + status + ' ' + JSON.stringify(json));
    assert(json.payload === undefined && json.payloadText === undefined, '/pair/redeem must not gain the code-channel payload fields');
    assert(json.tls?.caFingerprint256 === undefined, '/pair/redeem tls shape must stay M1-compatible');
    assert(json.auth?.verifyPath === '/auth/verify', '/pair/redeem auth block regressed');
    server.pairCode.dispose();
    return { status, deviceId: json.deviceId };
  });

  await check('health-and-admin-do-not-leak-code', async () => {
    const { server } = track(makeServer());
    const code = server.pairCode.status().value;
    const health = server.health('1.2.3.4');
    assert(health.pairing?.codeActive === true, 'health.pairing.codeActive must be true');
    assert(typeof health.pairing?.expiresAt === 'number', 'health.pairing.expiresAt must be a number');
    assert(Object.keys(health.pairing).sort().join(',') === 'codeActive,expiresAt', 'health.pairing must only expose codeActive/expiresAt, got ' + Object.keys(health.pairing).join(','));
    assert(deepEqualsValue(health.pairing, code) === false, '/health leaked the pairing code');
    const pairingAction = await server.handleAdminAction({ action: 'pairing' });
    assert(pairingAction.ok === true && pairingAction.data?.code?.value === code, 'admin pairing action must return the live code');
    assert(typeof pairingAction.data.code.expiresAt === 'number' && pairingAction.data.code.attemptsLeft === 5, 'admin code shape mismatch');
    assert(deepEqualsValue(pairingAction.data.payload, code) === false, 'admin pairing payload leaked the code');
    const refreshed = await server.handleAdminAction({ action: 'pairing.code.refresh' });
    assert(refreshed.data?.code?.value !== code, 'pairing.code.refresh did not rotate the code');
    const debugCode = await server.handleAdminAction({ action: 'pair.code' });
    assert(debugCode.ok === true && /^\d{8}$/.test(debugCode.data.code), 'debug pair.code action missing: ' + JSON.stringify(debugCode));
    // debug-only action must be refused when the debug channel is off
    const { server: quiet } = track(makeServer({ config: { debug: { enabled: false, adminToken: '' } } }));
    const refused = await quiet.handleAdminAction({ action: 'pair.code' });
    assert(refused.ok === false && refused.error === 'admin/unknown-action', 'pair.code must be refused without debug.enabled');
    server.pairCode.dispose();
    quiet.pairCode.dispose();
    return { healthPairing: health.pairing, adminCodeKeys: Object.keys(pairingAction.data.code) };
  });

  await check('debug-admin-pair-code-action', async () => {
    const { server } = track(makeServer());
    const code = server.pairCode.status().value;
    const debugRequest = (headers, body) => {
      const request = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
      request.method = 'POST';
      request.url = '/debug/admin';
      request.headers = headers;
      request.socket = { remoteAddress: '127.0.0.1' };
      return request;
    };
    const unauthorized = fakeResponse();
    await server.handleDebugAdmin(debugRequest({}, { action: 'pair.code' }), unauthorized, '127.0.0.1');
    assert(unauthorized.statusCode === 401, 'debug admin without token must be 401, got ' + unauthorized.statusCode);
    const authorized = fakeResponse();
    await server.handleDebugAdmin(debugRequest({ 'x-dshm-debug-admin': 'test-admin-token' }, { action: 'pair.code' }), authorized, '127.0.0.1');
    assert(authorized.statusCode === 200, 'debug admin pair.code must be 200, got ' + authorized.statusCode);
    const data = JSON.parse(authorized.body);
    assert(data.ok === true, 'debug pair.code not ok: ' + authorized.body);
    assert(data.data.active === true && data.data.code === code, 'debug pair.code mismatch: ' + authorized.body);
    assert(typeof data.data.expiresAt === 'number' && data.data.attemptsLeft === 5, 'debug pair.code fields missing: ' + authorized.body);
    server.pairCode.dispose();
    return data.data;
  });

  await check('bonjour-start-guard', () => {
    const { server } = track(makeServer({ config: { bonjour: { enabled: true } } }));
    // non-wildcard bindHost -> no mDNS socket, no throw
    server.startBonjour();
    assert(server.bonjour === undefined, 'bonjour must not start for bindHost=127.0.0.1');
    // wildcard with no LAN IP -> skipped, also no socket
    server.config.bindHost = '0.0.0.0';
    server.lanIps = [];
    server.startBonjour();
    assert(server.bonjour === undefined, 'bonjour must not start without a LAN IPv4 address');
    server.pairCode.dispose();
    return { guarded: true };
  });

  // ------------------------------------------------------------ mDNS responder
  await check('bonjour-record-contents', () => {
    const responder = new BonjourResponder({
      hostId: '0123456789abcdef',
      hostName: 'TestMac',
      port: 3467,
      addresses: ['192.168.1.10', '10.0.0.5'],
      txt: { v: '1', hostId: '0123456789abcdef', hostName: 'TestMac 的 Mac', proto: 'dsh-m/1', ver: '0.1.0', pair: 'code', relay: 'https://203.0.113.10:443' },
      socketFactory: () => new FakeSocket(),
    });
    const descriptor = responder.descriptor();
    assert(descriptor.service === SERVICE_TYPE, 'service type mismatch');
    assert(descriptor.instance === 'TestMac-01234567._dshm._tcp.local', 'instance name mismatch: ' + descriptor.instance);
    assert(descriptor.target === 'dshm-01234567.local', 'target name mismatch: ' + descriptor.target);
    const { answers } = parseAnswers(responder.buildAnnouncement());
    const byType = (type) => answers.filter((entry) => entry.type === type);
    assert(byType(12).length >= 1, 'missing PTR answer');
    assert(byType(33).length === 1, 'missing SRV answer');
    assert(byType(16).length === 1, 'missing TXT answer');
    assert(byType(1).length === 2, 'expected two A answers, got ' + byType(1).length);
    assert(answers.every((entry) => entry.ttl === 120), 'announcement TTL must be 120s');
    const srv = byType(33)[0];
    assert(srv.rdata.readUInt16BE(4) === 3467, 'SRV port mismatch: ' + srv.rdata.readUInt16BE(4));
    const txt = txtPairs(byType(16)[0].rdata);
    assert(txt.v === '1' && txt.hostId === '0123456789abcdef', 'TXT static fields mismatch');
    assert(txt.pair === 'code', 'TXT pair must be the capability marker "code", got ' + String(txt.pair));
    assert(Object.keys(txt).every((key) => ['v', 'hostId', 'hostName', 'proto', 'ver', 'pair', 'relay'].includes(key)), 'TXT field not in the whitelist: ' + Object.keys(txt).join(','));
    assert(Object.values(txt).every((value) => !/^\d{8}$/.test(String(value))), 'TXT must never contain an 8-digit pairing code');
    assert(Object.keys(txt).every((key) => !['pin', 'secret', 'token', 'leafPin', 'caPin'].includes(key)), 'TXT must never contain pins/tokens/secrets');
    assert(txt.relay === 'https://203.0.113.10:443', 'TXT optional relay field missing');
    const aValues = byType(1).map((entry) => Array.from(entry.rdata).join('.')).sort();
    assert(aValues.join(',') === '10.0.0.5,192.168.1.10', 'A record addresses mismatch: ' + aValues.join(','));
    const goodbye = parseAnswers(responder.buildGoodbye());
    assert(goodbye.answers.length >= 4 && goodbye.answers.every((entry) => entry.ttl === 0), 'goodbye must advertise TTL=0');
    responder.close();
    return { instance: descriptor.instance, target: descriptor.target, answers: answers.length, aRecords: aValues };
  });

  await check('bonjour-txt-never-contains-pair-code', () => {
    const { server } = track(makeServer());
    const txt = server.bonjourTxt();
    assert(txt.pair === 'code', 'link-server TXT pair must be the capability marker, got ' + String(txt.pair));
    assert(Object.keys(txt).every((key) => ['v', 'hostId', 'hostName', 'proto', 'ver', 'pair', 'relay'].includes(key)), 'TXT field outside whitelist: ' + Object.keys(txt).join(','));
    assert(Object.values(txt).every((value) => !/^\d{8}$/.test(String(value))), 'TXT leaked an 8-digit code value');
    const before = JSON.stringify(server.bonjourTxt());
    const codes = [];
    for (let index = 0; index < 3; index += 1) {
      const status = server.pairCode.status();
      codes.push(status.value);
      server.pairCode.refresh('manual');
    }
    assert(JSON.stringify(server.bonjourTxt()) === before, 'pairing-code rotation must not change the TXT record');
    assert(codes.every((code) => !deepEqualsValue(server.bonjourTxt(), code)), 'TXT contains a live pairing code');
    const updates = [];
    server.bonjour = { update: (partial) => updates.push(partial), started: false, close: () => {} };
    server.onPairCodeChange({ active: true, value: '12345678' }, { reason: 'manual' });
    assert(updates.length === 0, 'onPairCodeChange must not push the pairing code (or anything) into Bonjour TXT');
    server.config.tunnel.enabled = true;
    server.config.tunnel.pin = 'x'.repeat(43);
    server.onTunnelReady({ origin: 'https://203.0.113.10:30001', port: 30001 });
    assert(updates.some((partial) => partial.relay === 'https://203.0.113.10:30001'), 'TXT relay origin must update after tunnel ready');
    assert(updates.every((partial) => !deepEqualsValue(partial, '12345678') && Object.keys(partial).every((key) => ['relay', 'pair'].includes(key))), 'Bonjour update payload outside whitelist: ' + JSON.stringify(updates));
    assert(updates.every((partial) => partial.pair === undefined), 'Bonjour update must never carry a pair value');
    server.pairCode.dispose();
    return { txtPair: txt.pair, txtKeys: Object.keys(txt), codeRotationKeepsTxt: true, relayDynamic: true };
  });

  await check('bonjour-announce-answer-update-goodbye', async () => {
    const socket = new FakeSocket();
    const responder = new BonjourResponder({
      hostId: '0123456789abcdef',
      hostName: 'TestMac',
      port: 3467,
      addresses: ['192.168.1.10'],
      txt: { v: '1', hostId: '0123456789abcdef', hostName: 'TestMac', proto: 'dsh-m/1', ver: '0.1.0', pair: 'code' },
      socketFactory: () => socket,
    });
    assert(responder.start().ok === true, 'responder failed to start');
    await sleep(30);
    assert(socket.bound?.port === 5353, 'responder must bind mDNS port 5353');
    assert(socket.membership === true, 'responder must join the multicast group');
    assert(socket.sent.length === 1, 'expected one initial announcement, got ' + socket.sent.length);
    assert(socket.sent[0].address === '224.0.0.251' && socket.sent[0].port === 5353, 'announcement not multicast to 224.0.0.251:5353');
    // answer a PTR query (case-insensitive) with the full record set
    socket.emit('message', buildQuery('_dshm._tcp.local', 12));
    assert(socket.sent.length === 2, 'PTR query was not answered');
    const answer = parseAnswers(socket.sent[1].packet);
    assert(answer.answers.some((entry) => entry.type === 33) && answer.answers.some((entry) => entry.type === 1), 'query answer must include SRV+A');
    // a foreign query must not be answered
    socket.emit('message', buildQuery('_other._tcp.local', 12));
    assert(socket.sent.length === 2, 'foreign service query must be ignored');
    // malformed datagram must not throw
    socket.emit('message', Buffer.from([1, 2, 3]));
    // Pairing codes rotate constantly but the TXT record must not change;
    // only the public relay origin is dynamic.
    responder.update({ pair: '87654321' });
    const unchanged = parseAnswers(socket.sent.at(-1).packet);
    const unchangedTxt = txtPairs(unchanged.answers.find((entry) => entry.type === 16).rdata);
    assert(unchangedTxt.pair === 'code', 'TXT pair must stay the capability marker after an update, got ' + String(unchangedTxt.pair));
    responder.update({ relay: 'https://203.0.113.10:443' });
    const updated = parseAnswers(socket.sent.at(-1).packet);
    const txt = txtPairs(updated.answers.find((entry) => entry.type === 16).rdata);
    assert(txt.relay === 'https://203.0.113.10:443', 'TXT relay origin must update dynamically');
    assert(txt.pair === 'code', 'TXT pair changed while updating relay');
    // goodbye on close
    const before = socket.sent.length;
    responder.close();
    assert(socket.sent.length === before + 1, 'close() must send a goodbye');
    const farewell = parseAnswers(socket.sent.at(-1).packet);
    assert(farewell.answers.every((entry) => entry.ttl === 0), 'goodbye TTL must be 0');
    await sleep(120);
    assert(socket.closed === true, 'socket must be closed after goodbye');
    return { announcements: before, goodbye: farewell.answers.length };
  });

  await check('bonjour-failure-isolated', async () => {
    const errors = [];
    const responder = new BonjourResponder({
      hostId: '0123456789abcdef',
      hostName: 'TestMac',
      port: 3467,
      addresses: ['192.168.1.10'],
      txt: {},
      socketFactory: () => {
        throw new Error('udp unavailable');
      },
      log: () => {},
      onError: (error) => errors.push(String(error?.message ?? error)),
    });
    let threw = false;
    let result;
    try {
      result = responder.start();
    } catch {
      threw = true;
    }
    assert(threw === false, 'bonjour start must never throw');
    assert(result.ok === false, 'expected start() to report failure');
    assert(errors.length === 1 && errors[0].includes('udp unavailable'), 'onError not invoked with the socket failure');
    responder.close();
    return { ok: result.ok, error: errors[0] };
  });

  // ------------------------------------------------- C scheme: public CA cert
  await check('plugin-version-matches-package-json', () => {
    const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    assert(typeof pkg.version === 'string' && pkg.version.length > 0, 'package.json has no version');
    assert(PLUGIN_VERSION === pkg.version, 'PLUGIN_VERSION drift: link-server.js=' + PLUGIN_VERSION + ', package.json=' + pkg.version);
    return { version: PLUGIN_VERSION };
  });

  await check('ca-cert-exposed-publicly-for-c-scheme', async () => {
    // Real ECDSA CA+leaf in a temp dir — never ~/.dsh/plugin-data/dsh-m-link/tls.
    const certDir = track(mkdtempSync(join(tmpdir(), 'dshm-m2-paircode-ca-')));
    const certs = ensureCerts({ dir: certDir, bindHost: '127.0.0.1', lanIps: [], hostname: 'localhost' });
    // ca.crt is PEM; the C-scheme field transports the DER bytes in base64.
    const caDer = new X509Certificate(readFileSync(certs.caCert)).raw;
    const { server } = track(makeServer({ certs }));
    // describe() exposes the exact public DER and nothing secret.
    assert(typeof certs.caCertDerBase64 === 'string' && certs.caCertDerBase64.length > 0, 'describe() must expose caCertDerBase64');
    assert(Buffer.from(certs.caCertDerBase64, 'base64').equals(caDer), 'caCertDerBase64 must be the exact ca.crt DER');
    const caX509 = new X509Certificate(caDer);
    assert(caX509.ca === true, 'exposed CA DER must parse as an X.509 CA certificate');

    // Signed QR/automation pairing payload: new field present, old fields intact.
    const payload = server.pairing.payload();
    const payloadText = canonicalJson(payload);
    assert(typeof payload.tls?.caCert === 'string' && payload.tls.caCert.length > 0, 'pairing payload tls.caCert missing');
    assert(Buffer.from(payload.tls.caCert, 'base64').equals(caDer), 'payload tls.caCert must decode to the exact ca.crt DER');
    assert(payload.tls.caPin === certs.caPin && payload.tls.caFingerprint256 === certs.caFingerprint256, 'payload CA pin fields must stay unchanged');
    assert(
      payload.tls.leafPin === certs.leafPin && payload.tls.leafFingerprint256 === certs.leafFingerprint256 && payload.tls.leafNotAfter === certs.leafNotAfter,
      'payload leaf fields must stay unchanged',
    );
    assert(payload.tls.kind === 'self-signed-ca', 'payload tls.kind regressed');
    assert(verifyPayloadSignature(payload, payloadText) === true, 'Ed25519 signature over the payload must still verify with tls.caCert present');
    const caKeyText = readFileSync(certs.caKey, 'utf8');
    assert(payloadText.includes('PRIVATE KEY') === false && payloadText.includes(caKeyText.trim()) === false, 'payload must never carry private key material');

    // Public /health document: same CA cert, same old fields.
    const health = server.health('127.0.0.1');
    assert(health.tls?.caCert === payload.tls.caCert, '/health tls.caCert must equal the pairing payload caCert');
    assert(health.tls.caPin === certs.caPin && health.tls.caFingerprint256 === certs.caFingerprint256, '/health CA pin fields must stay unchanged');
    assert(
      health.tls.leafPin === certs.leafPin && health.tls.leafFingerprint256 === certs.leafFingerprint256 && health.tls.leafNotAfter === certs.leafNotAfter,
      '/health leaf fields must stay unchanged',
    );
    assert(JSON.stringify(health).includes(caKeyText.trim()) === false, '/health must never carry private key material');

    // 8-digit-code pairing channel (the LAN TOFU flow): tls.caCert in both the
    // unsigned response block and the signed payload.
    const code = server.pairCode.status().value;
    const redeemed = await call(server, { path: '/pair/code/redeem', body: { code, devicePubKey: devicePublicKey(), deviceName: 'CA Phone', platform: 'ios' } });
    assert(redeemed.status === 200 && redeemed.json?.ok === true, 'code redeem with real certs failed: ' + redeemed.status + ' ' + JSON.stringify(redeemed.json));
    assert(redeemed.json.tls?.caCert === payload.tls.caCert, 'code-channel tls.caCert must equal the pairing payload caCert');
    assert(Buffer.from(redeemed.json.tls.caCert, 'base64').equals(caDer), 'code-channel tls.caCert DER mismatch');
    assert(redeemed.json.payload?.tls?.caCert === payload.tls.caCert, 'code-channel signed payload caCert mismatch');
    assert(verifyPayloadSignature(redeemed.json.payload, redeemed.json.payloadText) === true, 'code-channel payload signature must verify');
    server.pairCode.dispose();
    return {
      caDerBytes: caDer.length,
      caCertBase64Chars: payload.tls.caCert.length,
      caPin: payload.tls.caPin.slice(0, 8) + '…',
      healthCaCertMatches: health.tls.caCert === payload.tls.caCert,
      codeChannelCaCertMatches: redeemed.json.tls.caCert === payload.tls.caCert,
    };
  });

  // ------------------------------------------------------------------ summary
  const failed = checks.filter((entry) => entry.ok !== true).length;
  const report = { startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), passed: failed === 0, checks, summary: { checks: checks.length, failed } };
  const file = join(outDir, 'm2-paircode.json');
  writeFileSync(file, JSON.stringify(report, null, 2) + '\n');
  for (const path of cleanup) {
    try {
      rmSync(path, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }
  console.log('\n== pairing code + bonjour: ' + (failed === 0 ? 'GO' : 'NO-GO') + ' (' + String(checks.length - failed) + '/' + String(checks.length) + ') ==');
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error('PAIRCODE TEST ERROR: ' + String(error?.stack ?? error));
  process.exit(2);
});
