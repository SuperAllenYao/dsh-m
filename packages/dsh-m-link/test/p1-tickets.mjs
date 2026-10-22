/**
 * p1-tickets.mjs — P1-2 plugin companion: pair-issued resume tickets, `/health`
 * capability probe and ticket single-use (jti + grace replay).
 *
 * Covers (isolated Node process, temp home, fake upstream, no TLS listener, no
 * `~/.dsh`, no desktop DSH restart):
 *
 *   1. mux-rpc unit: minted ticket carries `jti` + device binding; verify
 *      rejects a correctly-signed payload without `jti`; TicketUseGuard allows
 *      one use + one grace replay, then rejects, and sweeps expired entries.
 *   2. pair/redeem + pair/code/redeem (features.muxRpc on) return exactly two
 *      `connectTickets`, each bound to the freshly paired deviceId.
 *   3. feature-flag off: both redeem responses keep the M1/M2 shape (no
 *      `connectTickets`) — old App clients see a byte-compatible document.
 *   4. `/health`: `features.muxRpc` bool + `proto` array, and no ticket/secret
 *      material anywhere in the document.
 *   5. hello auth: a pair-issued ticket authenticates the device; the same
 *      ticket is accepted once more inside the grace window (lost welcome), the
 *      third use is `auth/ticket-replayed`; a rotated secret (plugin restart)
 *      invalidates old tickets → App falls back to ECDSA.
 *
 * Runs standalone:
 *   node test/p1-tickets.mjs [--out-dir <dir>]
 */

import { createHmac, generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';

import { DeviceStore } from '../lib/devices.js';
import { ensureHostIdentity } from '../lib/host-identity.js';
import { LinkServer } from '../lib/link-server.js';
import { mintResumeTicket, TicketUseGuard, verifyResumeTicket } from '../lib/mux-rpc.js';

const DEFAULT_OUT = resolve(new URL('results', import.meta.url).pathname);
const TEST_CERTS = {
  caPin: 'CA-PIN-TEST',
  leafPin: 'LEAF-PIN-TEST',
  caFingerprint256: 'AA:BB:CC',
  leafFingerprint256: 'DD:EE:FF',
  leafNotAfter: 'Oct 20 16:27:30 2027 GMT',
};
const TEST_PAIR_CODE = '12345678';
const startedAt = Date.now();
const checks = [];

function record(name, ok, detail) {
  checks.push({ name, ok: ok === true, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' — ' + JSON.stringify(detail)));
  if (!ok) throw new Error('check failed: ' + name);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// --------------------------------------------------------------- HTTP fakes

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
    setHeader(name, value) {
      this.headers[name] = value;
    },
    getHeader(name) {
      return this.headers[name];
    },
    end(chunk) {
      this.body = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk ?? '');
    },
  };
}

function fakeRequest({ method = 'POST', url = '/', body } = {}) {
  const request = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  request.method = method;
  request.url = url;
  request.headers = {};
  request.socket = { remoteAddress: '127.0.0.1' };
  return request;
}

async function call(server, { method = 'POST', path = '/', body } = {}) {
  const response = fakeResponse();
  await server.handleRequest(fakeRequest({ method, url: path, body }), response);
  let json;
  try {
    json = JSON.parse(response.body);
  } catch {
    json = undefined;
  }
  return { status: response.statusCode, json, text: response.body };
}

function devicePublicKey() {
  const { publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return publicKey.export({ type: 'spki', format: 'der' }).toString('base64url');
}

// --------------------------------------------------------------- test server

/**
 * Build a fully wired LinkServer without a TLS listener (same handler-level
 * pattern as m2-paircode.mjs). Upstream, pairing payload and the 8-digit code
 * are stubbed; device store / host identity are real (temp dir).
 */
function makeServer({ features } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'dshm-p1-tickets-'));
  const ctx = {
    state: { active: true },
    get: (name) => (name === 'dshHomePath' ? home : undefined),
    webServer: { getOrigin: () => 'http://127.0.0.1:62001' },
    connection: { authenticatedUrl: (url) => url },
    on() {},
    effect() {
      return () => {};
    },
  };
  const config = {
    port: 3467,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
    ...(features === undefined ? {} : { features }),
  };
  const server = new LinkServer(ctx, config);
  const dataDir = join(home, 'plugin-data', 'dsh-m-link');
  server.audit = { record: () => {} };
  server.hostIdentity = ensureHostIdentity({ dir: dataDir, log: () => {} });
  server.devices = new DeviceStore({ dir: dataDir, hostId: server.hostIdentity.hostId, log: () => {} }).load();
  server.certs = { ...TEST_CERTS };
  server.hostname = 'test-mac';
  server.lanIps = [];
  server.started = true;
  server.disposed = false;
  server.starting = false;
  server.qr = { renderDataUrl: async () => ({ ok: false, error: 'unit-test-no-qr' }), dispose: () => {} };
  server.apns = {
    mode: 'stub',
    reason: 'test',
    topic: null,
    info: () => ({ mode: 'stub', reason: 'test', environment: 'test', topic: null }),
    dispose: () => {},
  };
  server.notifier = { dispose: () => {} };
  server.auth = { sweep: () => {}, dispose: () => {} };
  server.server = undefined;
  server.contract = { ok: true, skipped: true };
  server.endpoints = ['https://127.0.0.1:3467'];
  server.baseEndpoints = ['https://127.0.0.1:3467'];
  server.deviceEndpoints = ['https://127.0.0.1:3467'];
  server.pairing = {
    redeem: ({ devicePubKey, deviceName, platform }) => ({
      name: typeof deviceName === 'string' && deviceName.length > 0 ? deviceName : 'Test Phone',
      publicKey: devicePubKey,
      platform: typeof platform === 'string' ? platform : 'ios',
    }),
    payload: () => ({ test: true }),
    payloadText: () => '{"test":true}',
    refresh: () => {},
  };
  server.pairCode = {
    check: (code) => (code === TEST_PAIR_CODE ? {} : { error: 'code/invalid', remaining: 4 }),
    consume: () => {},
    current: () => undefined,
  };
  server.ensurePeer = () => ({ connect: async () => {} });
  return { server, home, dataDir };
}

async function pairViaToken(server, name = 'Tickets Phone') {
  const result = await call(server, {
    path: '/pair/redeem',
    body: { pairToken: 'test-pair-token', devicePubKey: devicePublicKey(), deviceName: name, platform: 'ios' },
  });
  assert(result.status === 200 && result.json?.ok === true, 'pair/redeem failed: ' + result.status + ' ' + result.text.slice(0, 200));
  return result.json;
}

async function pairViaCode(server, name = 'Code Phone') {
  const result = await call(server, {
    path: '/pair/code/redeem',
    body: { code: TEST_PAIR_CODE, devicePubKey: devicePublicKey(), deviceName: name, platform: 'ios' },
  });
  assert(result.status === 200 && result.json?.ok === true, 'pair/code/redeem failed: ' + result.status + ' ' + result.text.slice(0, 200));
  return result.json;
}

/** Recursively collect object keys (health document must not carry secrets). */
function collectKeys(value, out = []) {
  if (Array.isArray(value)) {
    for (const entry of value) collectKeys(entry, out);
  } else if (value !== null && typeof value === 'object') {
    for (const [key, entry] of Object.entries(value)) {
      out.push(key);
      collectKeys(entry, out);
    }
  }
  return out;
}

function craftTicket(secret, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  const signature = createHmac('sha256', secret).update(body).digest('base64url');
  return body + '.' + signature;
}

// ----------------------------------------------------------------------- main

async function run() {
  const outDirArg = process.argv.indexOf('--out-dir');
  const outDir = outDirArg >= 0 ? resolve(process.argv[outDirArg + 1]) : DEFAULT_OUT;
  mkdirSync(outDir, { recursive: true });

  const homes = [];
  const servers = [];
  try {
    // ------------------------------------------------- 1. mux-rpc unit layer
    const secret = randomBytes(32);
    const epoch = 'epoch-tickets-unit';
    const ticket = mintResumeTicket({ secret, deviceId: 'dev-unit', epoch, ttlMs: 60_000 });
    const verified = verifyResumeTicket({ secret, ticket });
    const decodedPayload = JSON.parse(Buffer.from(ticket.slice(0, ticket.indexOf('.')), 'base64url').toString('utf8'));
    assert(verified.ok === true, 'minted ticket must verify');
    assert(verified.deviceId === 'dev-unit' && verified.epoch === epoch, 'ticket is bound to deviceId/epoch');
    assert(typeof verified.jti === 'string' && verified.jti.length >= 8, 'verified ticket exposes jti');
    assert(decodedPayload.jti === verified.jti && decodedPayload.d === 'dev-unit', 'payload carries jti and device id');
    assert(Number.isInteger(verified.expiresAt) && verified.expiresAt > Date.now(), 'payload carries exp for the jti TTL window');
    const secondMint = verifyResumeTicket({ secret, ticket: mintResumeTicket({ secret, deviceId: 'dev-unit', epoch, ttlMs: 60_000 }) });
    assert(secondMint.ok === true && secondMint.jti !== verified.jti, 'each minted ticket gets a fresh jti');
    const noJtiTicket = craftTicket(secret, { v: 1, d: 'dev-unit', exp: Date.now() + 60_000, n: 'legacy-nonce' });
    const noJti = verifyResumeTicket({ secret, ticket: noJtiTicket });
    assert(noJti.ok === false && noJti.reason === 'malformed', 'a signed payload without jti is rejected, got ' + JSON.stringify(noJti));
    record('resume-ticket-jti-and-binding', true, { deviceId: verified.deviceId, jti: verified.jti.slice(0, 8), ttlMs: 60_000 });

    let clock = 1_000_000;
    const guard = new TicketUseGuard({ graceMs: 5_000, now: () => clock });
    const ticketExp = clock + 60_000;
    const firstUse = guard.use('jti-grace', ticketExp);
    clock += 100;
    const graceReplay = guard.use('jti-grace', ticketExp);
    clock += 100;
    const thirdUse = guard.use('jti-grace', ticketExp);
    assert(firstUse.ok === true && firstUse.replay === false, 'first ticket use is accepted');
    assert(graceReplay.ok === true && graceReplay.replay === true, 'a second use inside the grace window is a one-time replay');
    assert(thirdUse.ok === false && thirdUse.reason === 'replayed', 'third use is rejected even inside the grace window');
    const lateClock = { now: 0 };
    const lateGuard = new TicketUseGuard({ graceMs: 5_000, now: () => lateClock.now });
    assert(lateGuard.use('jti-late', 60_000).ok === true, 'late-guard first use accepted');
    lateClock.now = 5_001;
    const lateReplay = lateGuard.use('jti-late', 60_000);
    assert(lateReplay.ok === false && lateReplay.reason === 'replayed', 'replay after the grace window is rejected');
    const sweepClock = { now: 0 };
    const sweepGuard = new TicketUseGuard({ graceMs: 5_000, now: () => sweepClock.now });
    sweepGuard.use('jti-expired', 1_000);
    assert(sweepGuard.size === 1, 'used jti is tracked while its ticket is valid');
    sweepClock.now = 1_001;
    assert(sweepGuard.size === 0, 'used jti entries are swept once the ticket expires');
    record('ticket-use-guard-single-use-grace', true, { graceMs: 5_000, firstUse: firstUse.replay, secondUse: graceReplay.replay, thirdUse: thirdUse.reason });

    const restartedSecret = randomBytes(32);
    const oldTicket = mintResumeTicket({ secret, deviceId: 'dev-unit', ttlMs: 60_000 });
    const afterRestart = verifyResumeTicket({ secret: restartedSecret, ticket: oldTicket });
    assert(afterRestart.ok === false, 'a restarted plugin (new in-memory secret) rejects cached tickets');
    record('ticket-restart-falls-back-to-ecdsa', true, { reason: afterRestart.reason });

    // ------------------------------------- 2. pair responses sign connectTickets
    const live = makeServer({ features: { muxRpc: true } });
    homes.push(live.home);
    servers.push(live.server);
    const pairJson = await pairViaToken(live.server);
    const pairTickets = pairJson.connectTickets;
    assert(Array.isArray(pairTickets) && pairTickets.length === 2, 'pair/redeem returns exactly 2 connectTickets, got ' + JSON.stringify(pairTickets));
    const pairSecret = live.server.p1ResumeSecret();
    const pairTicketInfos = pairTickets.map((entry) => verifyResumeTicket({ secret: pairSecret, ticket: entry }));
    for (const info of pairTicketInfos) {
      assert(info.ok === true, 'pair-issued ticket verifies with the plugin secret');
      assert(info.deviceId === pairJson.deviceId, 'pair-issued ticket is bound to the paired deviceId');
      assert(info.epoch === undefined, 'pair ticket is not bound to a channel epoch (no channel yet)');
    }
    assert(pairTicketInfos[0].jti !== pairTicketInfos[1].jti, 'the two pair tickets carry distinct jti values');
    record('pair-redeem-connect-tickets', true, { deviceId: pairJson.deviceId, tickets: pairTickets.length, jtiPrefixes: pairTicketInfos.map((info) => info.jti.slice(0, 6)) });

    const codeJson = await pairViaCode(live.server);
    assert(Array.isArray(codeJson.connectTickets) && codeJson.connectTickets.length === 2, 'pair/code/redeem returns exactly 2 connectTickets');
    assert(codeJson.payload !== undefined && codeJson.payloadText !== undefined, 'pair/code/redeem keeps its M2 payload fields');
    const codeInfos = codeJson.connectTickets.map((entry) => verifyResumeTicket({ secret: pairSecret, ticket: entry }));
    assert(codeInfos.every((info) => info.ok === true && info.deviceId === codeJson.deviceId), 'code-pair tickets verify for the code-paired device');
    record('pair-code-redeem-connect-tickets', true, { deviceId: codeJson.deviceId, tickets: codeJson.connectTickets.length });

    // ------------------------------------------------- 3. flag-off compatibility
    const legacy = makeServer({ features: { muxRpc: false } });
    homes.push(legacy.home);
    servers.push(legacy.server);
    const legacyPair = await pairViaToken(legacy.server, 'Legacy Phone');
    assert(legacyPair.connectTickets === undefined, 'flag off: /pair/redeem must not gain connectTickets');
    assert(legacyPair.payload === undefined && legacyPair.payloadText === undefined, 'flag off: /pair/redeem keeps the exact M1 shape');
    const legacyCode = await pairViaCode(legacy.server, 'Legacy Code Phone');
    assert(legacyCode.connectTickets === undefined, 'flag off: /pair/code/redeem must not gain connectTickets');
    record('pair-flag-off-no-tickets', true, { legacyDevice: legacyPair.deviceId, legacyCodeDevice: legacyCode.deviceId });

    // ------------------------------------------- 4. /health capability discovery
    const healthOn = await call(live.server, { method: 'GET', path: '/health' });
    assert(healthOn.status === 200 && healthOn.json?.ok === true, '/health must stay a 200 liveness document');
    assert(healthOn.json.features?.muxRpc === true, '/health.features.muxRpc must advertise the enabled flag');
    assert(JSON.stringify(healthOn.json.proto) === JSON.stringify(['dsh-m/1', 'dsh-m/2']), '/health.proto must list both protocols, got ' + JSON.stringify(healthOn.json.proto));
    const healthText = JSON.stringify(healthOn.json);
    assert(healthText.includes(pairSecret.toString('base64url')) === false, '/health must not leak the HMAC secret');
    const healthKeys = collectKeys(healthOn.json);
    assert(healthKeys.some((key) => /ticket/i.test(key)) === false, '/health must not expose ticket fields: ' + healthKeys.filter((key) => /ticket/i.test(key)).join(','));
    assert(healthText.includes('"connectTickets"') === false, '/health must not carry connectTickets');
    record('health-capability-probe-on', true, { proto: healthOn.json.proto, muxRpc: healthOn.json.features.muxRpc, keys: healthKeys.length });

    const healthOff = await call(legacy.server, { method: 'GET', path: '/health' });
    assert(healthOff.status === 200 && healthOff.json?.features?.muxRpc === false, '/health must report muxRpc=false when the flag is off');
    assert(JSON.stringify(healthOff.json.proto) === JSON.stringify(['dsh-m/1']), 'flag off: /health.proto lists only dsh-m/1');
    record('health-capability-probe-off', true, { proto: healthOff.json.proto, muxRpc: healthOff.json.features.muxRpc });

    // -------------------------------------- 5. pair ticket → in-band hello auth
    const hello1 = live.server.resolveP1HelloAuth({ type: 'hello', v: 2, auth: { ticket: pairTickets[0] } });
    assert(hello1.error === undefined && hello1.device?.deviceId === pairJson.deviceId, 'pair-issued ticket authenticates the hello, got ' + JSON.stringify(hello1.error));
    const helloReplay = live.server.resolveP1HelloAuth({ type: 'hello', v: 2, auth: { ticket: pairTickets[0] } });
    assert(helloReplay.error === undefined && helloReplay.device?.deviceId === pairJson.deviceId, 'a used ticket replays once inside the grace window (lost welcome)');
    const helloRejected = live.server.resolveP1HelloAuth({ type: 'hello', v: 2, auth: { ticket: pairTickets[0] } });
    assert(helloRejected.error === 'auth/ticket-replayed', 'the third use of one ticket is rejected, got ' + JSON.stringify(helloRejected.error));
    const helloSpare = live.server.resolveP1HelloAuth({ type: 'hello', v: 2, auth: { ticket: pairTickets[1] } });
    assert(helloSpare.error === undefined && helloSpare.device?.deviceId === pairJson.deviceId, 'the spare pair ticket still authenticates');
    const helloMissing = live.server.resolveP1HelloAuth({ type: 'hello', v: 2, auth: {} });
    assert(helloMissing.error === 'auth/required', 'hello without credentials stays auth/required');
    assert(live.server.counters.authFailed >= 1 && live.server.counters.authOk >= 3, 'auth counters reflect ticket + replay results');
    record('ticket-hello-auth-single-use', true, {
      first: hello1.device?.deviceId,
      graceReplay: helloReplay.ok !== false,
      thirdUse: helloRejected.error,
      spareTicket: helloSpare.ok !== false,
      authOk: live.server.counters.authOk,
      authFailed: live.server.counters.authFailed,
    });

    const report = {
      startedAt: new Date(startedAt).toISOString(),
      durationMs: Date.now() - startedAt,
      checks,
      pass: checks.length,
      fail: 0,
    };
    writeFileSync(join(outDir, 'p1-tickets-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
    console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
  } finally {
    for (const server of servers) {
      try {
        server.dispose();
      } catch {
        /* already disposed */
      }
    }
    for (const home of homes) rmSync(home, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
  // Fake upstream/timers keep handles open; fail fast instead of hanging.
  setTimeout(() => process.exit(1), 100).unref();
});
