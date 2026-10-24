/**
 * link-server.js — the dsh-m-link host service (M1).
 *
 * A self-hosted TLS origin (never the official loopback listener) that bridges
 * phones to the loopback DSH Remote API:
 *
 * GET /health minimal liveness + contract/certificate state
 * POST /pair/redeem one-time pair token -> device credential (P-256 stored)
 * POST /auth/challenge credential -> one-time nonce + exact message to sign
 * POST /auth/verify ECDSA-P256 signature -> short-lived bearer token
 * POST /devices/push-token register the phone's APNs device token
 * POST /session/permission switch a session's permission preset (host service bridge)
 * POST /api/<ns/method> transparent unary proxy (api bearer token)
 * WSS /api/remote.mux frame-level 1:1 proxy (single-use mux bearer token)
 * POST /debug/admin test-only admin channel (config.debug.enabled)
 *
 * The proxied traffic is never parsed or re-encoded: unary bodies and mux
 * frames are forwarded byte-for-byte. The one opt-in exception is the P1.5-A
 * lite `session/list` projection trim (lib/list-lite.js): it runs only when a
 * client explicitly asks for it, old clients keep the legacy bytes. The
 * separate `POST /session/permission` route (lib/session-permission.js) is not
 * a proxy: it authenticates the device and calls the host `permissionPresets`
 * service directly, because the Remote protocol has no preset write endpoint.
 * A read-only frame inspector feeds the APNs notifier; it never modifies a
 * frame.
 *
 * Security model (<internal-doc> §8):
 * - the long-term device credential is only accepted on /auth/challenge and
 * stored as a sha256 hash in devices.json;
 * - every connection needs a fresh ECDSA-P256 signature over a one-time,
 * time-windowed nonce; api tokens are short-lived, mux tokens single-use;
 * - revocation closes the live sockets immediately and blocks re-auth;
 * - the pairing token is only rendered in the desktop UI / debug switch,
 * never logged and never persisted by default.
 */

import { createHash, randomBytes, timingSafeEqual, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:https';
import { homedir, hostname as osHostname, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';

import { registerAdminRoute, ADMIN_PATH } from './admin.js';
import { ApnsProvider, tokenFingerprint } from './apns.js';
import { AuditLog } from './audit.js';
import { AuthService } from './auth.js';
import { ensureCerts, rotateCa as rotateCaCerts, rotateLeaf as rotateLeafCerts } from './certs.js';
import { probeWithRetries } from './contract.js';
import { DeviceStore, keyFingerprint256, normalizeDevicePublicKey } from './devices.js';
import { FrameAudit } from './frame-audit.js';
import { ensureHostIdentity } from './host-identity.js';
import { APPROVAL_CATEGORY, Notifier } from './notifier.js';
import { createHostTurnEventHandler, TurnWatcher } from './session-watcher.js';
import { buildEndpoints, PairCodeService, PairingService, selectDeviceEndpoints, trimDeviceName } from './pairing.js';
import { BonjourResponder } from './bonjour.js';
import { QrRenderer } from './qr.js';
import { applySessionPermission, normalizePermissionRequest, SESSION_PERMISSION_PATH } from './session-permission.js';
import { UpstreamPeer } from './upstream-peer.js';
import { loadWs, wsBindings, wsLoadedFrom } from './ws-provider.js';
import { mintResumeTicket, MuxRpcChannel, P1_LIMITS, TicketUseGuard, verifyResumeTicket } from './mux-rpc.js';
import { detectListLiteRequest, LIST_LITE_HEADER, trimSessionListResponse } from './list-lite.js';

const PLUGIN_NAME = 'dsh-m-link';
const PLUGIN_VERSION = '2.8.0';
const MUX_PATH = '/api/remote.mux';

/**
 * 同一设备只允许一条 mux（协议不变量）。旧连接**静默**超过这个窗口即视为死连接：
 * 网络切换（Wi-Fi→蜂窝/换网段）后服务端 socket 往往仍是 ESTABLISHED，但不会再
 * 有任何帧；此时新连接必须能**接管**旧 socket，而不是用 409 让手机白等到心跳
 * 超时（用户 要求：任何网络都要连得上，且极致快）。
 * 活跃连接（窗口内有帧）仍按 409 拒绝，防止两个客户端抢流。
 */
export const MUX_TAKEOVER_STALE_MS = 1500;

const ENDPOINT_RE = /^\/api\/[A-Za-z0-9_$.-]+\/[A-Za-z0-9_$.-]+$/;
const MAX_BODY_BYTES = 32 * 1024 * 1024;
const SMALL_BODY_BYTES = 64 * 1024;
const PROTOCOL = 'dsh-m/1';
const PASSTHROUGH_RESPONSE_HEADERS = new Set([
  'content-type',
  'content-disposition',
  'content-encoding',
  'etag',
  'last-modified',
  'x-content-type-options',
]);

const DEFAULTS = {
  port: 3466,
  bindHost: '127.0.0.1',
  pairTtlMs: 90_000,
  upstreamIdleMs: 5_000,
  hostName: '',
  origins: [],
 // M2a: 8-digit pairing code (design §5.1). TTL, wrong-attempt cap and the
 // per-IP rate limit are all configurable; the defaults are the user-decided
 // values and must not be lowered silently.
  pairCodeTtlMs: 120_000,
  pairCodeMaxAttempts: 5,
  pairCodeRateLimitPerMin: 10,
 // M2a: zero-dependency mDNS advertisement (_dshm._tcp) for LAN discovery.
 // Only active for a wildcard bindHost; failure never blocks the plugin.
  bonjour: {
    enabled: true,
  },
 // M2a: outbound tunnel to the user's own relay (transparent L4 relay).
 // Disabled => plugin behaviour is byte-for-byte M1.
  tunnel: {
    enabled: false,
    controlOrigin: '',
    pin: '',
    secret: '',
    secretFile: '',
    wantPort: 0,
  },
  security: {
    challengeTtlMs: 90_000,
    apiTokenTtlMs: 60 * 60 * 1000,
    muxTokenTtlMs: 120_000,
    maxAuthFailuresPerMinute: 5,
    allowLegacyCredential: false,
  },
  tls: {
    additionalHosts: [],
  },
  notifications: {
    enabled: true,
    approval: true,
    turnEnd: true,
    failure: true,
 // M4: question-request notifications + coalesced background (silent) pushes.
    questions: true,
    silent: true,
    silentMinIntervalMs: 3000,
 // task-5: turn-end pushes must not depend on the phone following the session.
 // Primary source is the in-process host event bus (`ctx.on('session/event')`,
 // real-time and free). The polling watcher below is a fallback for hosts that
 // do not expose the bus — off by default because it costs a session/list poll.
    watchSessions: false,
    pollIntervalMs: 2000,
    requestTimeoutMs: 1500,
  },
  apns: {},
  fetchRoutes: {
    enabled: true,
 // Exact-fetch GET routes the phone may reach through the link. These are
 // the documented DSH web routes for the file-change review UI; the list is
 // exact-match and read-only (GET/HEAD), so the proxy cannot be turned into
 // a generic loopback HTTP client.
    allow: ['/api/changes.summary', '/api/changes.diff', '/api/file'],
  },
 // M2b: unary response compression. Large JSON proxy responses (session/list
 // is ~158 KB) are gzipped when the phone advertises `Accept-Encoding: gzip`;
 // the iOS client inflates them with libcompression. Chunked/stream paths are
 // untouched (only the buffered unary proxy body is compressed).
  compression: {
    enabled: true,
    minBytes: 1024,
  },
 // M2b: phone unary keep-alive. Node's default 5s idle timeout would close a
 // pooled connection between screens; the iOS pool keeps connections at most
 // 30s, so 120s guarantees the server never closes one first.
  httpKeepAliveTimeoutMs: 120_000,
 // P1 (<internal-doc>): single-WSS transport with
 // in-band `hello` auth, `rpc/unary` over the mux socket and session
 // `resume{logEpoch,sid}`. DEFAULT OFF: when off the plugin behaves exactly
 // like M1/M2b (two-TLS protocol, frame-level byte bridge). Enabling it only
 // changes behaviour for clients that opt in with `GET /api/remote.mux?proto=2`;
 // legacy clients keep using the old path, which is the dual-stack rollout.
  features: {
    muxRpc: false,
    muxRpcResumeWindowMs: P1_LIMITS.resumeWindowMs,
    muxRpcReplayBytes: P1_LIMITS.replayBytes,
    muxRpcReplayFrames: P1_LIMITS.replayFrames,
    muxRpcRpcMaxInFlight: P1_LIMITS.rpcMaxInFlight,
    muxRpcRpcTimeoutMs: P1_LIMITS.rpcTimeoutMs,
    muxRpcHelloTimeoutMs: P1_LIMITS.helloTimeoutMs,
    muxRpcTicketTtlMs: P1_LIMITS.ticketTtlMs,
    muxRpcTicketReplayGraceMs: P1_LIMITS.ticketReplayGraceMs,
    muxRpcMaxPendingUpgrades: 8,
 // P1.5-A (<internal-doc>): honor the opt-in "lite"
 // `session/list` projection trim (header `x-dshm-list-lite: 1` or the
 // legacy-shaped body hint `_request.listMode=lite`). DEFAULT ON, but it
 // only changes behaviour for clients that explicitly ask: a request with
 // no signal gets the untouched upstream bytes (old App byte-identical).
    listLite: true,
  },
  contract: {
    probeOnStart: true,
    retryAttempts: 10,
    retryDelayMs: 1500,
  },
  debug: {
    enabled: false,
    adminToken: '',
    pairPayloadFile: false,
    reissuePairToken: false,
  },
};

function log(message) {
  process.stderr.write('[dsh-m-link] ' + message + '\n');
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function mergeConfig(base, override) {
  if (!isPlainObject(override)) return base;
  const merged = { ...base };
  for (const [key, value] of Object.entries(override)) {
    if (isPlainObject(value) && isPlainObject(base[key])) merged[key] = mergeConfig(base[key], value);
    else if (value !== undefined) merged[key] = value;
  }
  return merged;
}

export function resolveConfig(raw) {
  const merged = mergeConfig(DEFAULTS, raw ?? {});
  merged.port = Number.isInteger(merged.port) ? merged.port : DEFAULTS.port;
  merged.pairTtlMs = Number.isInteger(merged.pairTtlMs) && merged.pairTtlMs >= 5000 ? merged.pairTtlMs : DEFAULTS.pairTtlMs;
  merged.upstreamIdleMs = Number.isInteger(merged.upstreamIdleMs) && merged.upstreamIdleMs >= 0 ? merged.upstreamIdleMs : DEFAULTS.upstreamIdleMs;
  merged.pairCodeTtlMs = Number.isInteger(merged.pairCodeTtlMs) && merged.pairCodeTtlMs >= 200 ? merged.pairCodeTtlMs : DEFAULTS.pairCodeTtlMs;
  merged.pairCodeMaxAttempts = Number.isInteger(merged.pairCodeMaxAttempts) && merged.pairCodeMaxAttempts >= 1 && merged.pairCodeMaxAttempts <= 20 ? merged.pairCodeMaxAttempts : DEFAULTS.pairCodeMaxAttempts;
  merged.pairCodeRateLimitPerMin = Number.isInteger(merged.pairCodeRateLimitPerMin) && merged.pairCodeRateLimitPerMin >= 1 && merged.pairCodeRateLimitPerMin <= 1200 ? merged.pairCodeRateLimitPerMin : DEFAULTS.pairCodeRateLimitPerMin;
  merged.bonjour = mergeConfig(DEFAULTS.bonjour, merged.bonjour);
  merged.bonjour.enabled = merged.bonjour.enabled !== false;
  merged.tunnel = mergeConfig(DEFAULTS.tunnel, merged.tunnel);
  merged.tunnel.enabled = merged.tunnel.enabled === true;
  merged.tunnel.controlOrigin = typeof merged.tunnel.controlOrigin === 'string' ? merged.tunnel.controlOrigin.trim() : '';
  merged.tunnel.pin = typeof merged.tunnel.pin === 'string' ? merged.tunnel.pin.trim() : '';
  merged.tunnel.secret = typeof merged.tunnel.secret === 'string' ? merged.tunnel.secret : '';
  merged.tunnel.secretFile = typeof merged.tunnel.secretFile === 'string' ? merged.tunnel.secretFile.trim() : '';
  merged.tunnel.wantPort = Number.isInteger(merged.tunnel.wantPort) && merged.tunnel.wantPort > 0 && merged.tunnel.wantPort < 65536 ? merged.tunnel.wantPort : 0;
  merged.security = mergeConfig(DEFAULTS.security, merged.security);
  merged.tls = mergeConfig(DEFAULTS.tls, merged.tls);
  merged.notifications = mergeConfig(DEFAULTS.notifications, merged.notifications);
  merged.notifications.watchSessions = merged.notifications.watchSessions === true;
  merged.notifications.pollIntervalMs =
    Number.isInteger(merged.notifications.pollIntervalMs) &&
    merged.notifications.pollIntervalMs >= 250 &&
    merged.notifications.pollIntervalMs <= 600_000
      ? merged.notifications.pollIntervalMs
      : DEFAULTS.notifications.pollIntervalMs;
  merged.notifications.requestTimeoutMs =
    Number.isInteger(merged.notifications.requestTimeoutMs) &&
    merged.notifications.requestTimeoutMs >= 100 &&
    merged.notifications.requestTimeoutMs <= 60_000
      ? merged.notifications.requestTimeoutMs
      : DEFAULTS.notifications.requestTimeoutMs;
  merged.contract = mergeConfig(DEFAULTS.contract, merged.contract);
  merged.fetchRoutes = mergeConfig(DEFAULTS.fetchRoutes, merged.fetchRoutes);
  if (!Array.isArray(merged.fetchRoutes.allow)) merged.fetchRoutes.allow = DEFAULTS.fetchRoutes.allow;
  merged.fetchRoutes.allow = merged.fetchRoutes.allow.filter((entry) => typeof entry === 'string' && entry.startsWith('/api/') && !entry.includes('..'));
  merged.compression = mergeConfig(DEFAULTS.compression, merged.compression);
  merged.compression.enabled = merged.compression.enabled !== false;
  merged.compression.minBytes = Number.isInteger(merged.compression.minBytes) && merged.compression.minBytes >= 0 ? merged.compression.minBytes : DEFAULTS.compression.minBytes;
  merged.httpKeepAliveTimeoutMs = Number.isInteger(merged.httpKeepAliveTimeoutMs) && merged.httpKeepAliveTimeoutMs >= 1000 ? merged.httpKeepAliveTimeoutMs : DEFAULTS.httpKeepAliveTimeoutMs;
  merged.features = mergeConfig(DEFAULTS.features, merged.features);
  merged.features.muxRpc = merged.features.muxRpc === true;
  merged.features.listLite = merged.features.listLite !== false;
  for (const key of ['muxRpcResumeWindowMs', 'muxRpcReplayBytes', 'muxRpcReplayFrames', 'muxRpcRpcMaxInFlight', 'muxRpcRpcTimeoutMs', 'muxRpcHelloTimeoutMs', 'muxRpcTicketTtlMs', 'muxRpcTicketReplayGraceMs', 'muxRpcMaxPendingUpgrades']) {
    const fallback = DEFAULTS.features[key];
    merged.features[key] = Number.isInteger(merged.features[key]) && merged.features[key] > 0 ? merged.features[key] : fallback;
  }
  merged.debug = mergeConfig(DEFAULTS.debug, merged.debug);
  return merged;
}

function sendJson(response, status, value, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.length),
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  response.end(body);
}

function sendText(response, status, text) {
  const body = Buffer.from(text);
  response.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'content-length': String(body.length) });
  response.end(body);
}

/** Read a request body with a hard size cap. */
function readBody(request, maxBytes = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(new Error('request body too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks)));
    request.on('error', reject);
  });
}

async function readJson(request, maxBytes = SMALL_BODY_BYTES) {
  const body = await readBody(request, maxBytes);
  return JSON.parse(body.toString('utf8'));
}

/** Bridge a raw HTTP upgrade rejection before the ws library takes the socket. */
function rejectUpgrade(socket, status, reason, extraHeaders = {}) {
  const body = reason + '\n';
  const headers = Object.entries({
    connection: 'close',
    'content-type': 'text/plain; charset=utf-8',
    'content-length': String(Buffer.byteLength(body)),
    ...extraHeaders,
  })
    .map(([name, value]) => name + ': ' + value)
    .join('\r\n');
  socket.end('HTTP/1.1 ' + String(status) + ' ' + reason + '\r\n' + headers + '\r\n\r\n' + body);
}

/** Resolve the Harness home without importing DSH packages. */
function resolveHome(ctx) {
  try {
    const provider = ctx.get('dshHomePath');
    if (typeof provider === 'function') return provider();
    if (typeof provider === 'string' && provider.length > 0) return provider;
  } catch {
 /* service not available yet; fall through */
  }
  const fromEnv = process.env.DSH_HOME;
  if (typeof fromEnv === 'string' && fromEnv.trim().length > 0) return fromEnv;
  return join(homedir(), '.dsh');
}

/** Non-loopback IPv4 addresses of this Mac (for the LAN endpoint list). */
function collectLanIps() {
  const result = [];
  try {
    const interfaces = networkInterfaces();
    for (const entries of Object.values(interfaces)) {
      for (const entry of entries ?? []) {
        if (entry.family === 'IPv4' && !entry.internal) result.push(entry.address);
      }
    }
  } catch {
 /* environment without network interfaces */
  }
  return [...new Set(result)];
}

/** A hostname we are willing to show to the user (not an IP literal, not empty). */
function isUsableHostName(value) {
  return typeof value === 'string' && value.length > 0 && /^[A-Za-z0-9.-]+$/.test(value) && !/^\d{1,3}(\.\d{1,3}){3}$/.test(value);
}

function parseBearer(header) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return undefined;
  const value = header.slice('Bearer '.length).trim();
  return value.length === 0 ? undefined : value;
}

/**
 * base64url sha256 of a certificate DER, from the colon-hex
 * `leafFingerprint256` form the cert module exposes (relay lookup contract
 * §4.5: leafPin = base64url SHA-256(cert DER)).
 */
function certDerPin(fingerprint256) {
  if (typeof fingerprint256 !== 'string') return undefined;
  const hex = fingerprint256.replace(/[^0-9A-Fa-f]/g, '');
  if (hex.length !== 64) return undefined;
  return Buffer.from(hex, 'hex').toString('base64url');
}

/**
 * Live LinkServer instances of *this host process*, grouped by TLS port.
 *
 * Cordis re-applies the plugin on a profile reload (a desktop setting write
 * hot-reloads the patch layer). The previous fiber's `dispose()` is not
 * guaranteed to have finished before the new instance starts, and Node keeps a
 * server's port bound until every accepted socket is gone — a phone's open WSS
 * therefore holds the port even after `server.close()`. Without a hand-off the
 * new instance burns its EADDRINUSE retries, records
 * `server.startup-failed/host/port-in-use`, and the phone is left with no
 * listener at all (observed, and again right after a
 * desktop model switch rewrote the profile config). Same-port instances of this
 * process are the only ones we can reach, so the newest starter reclaims the
 * port from them.
 *
 * @type {Map<number, Set<LinkServer>>}
 */
const liveInstancesByPort = new Map();

/** @param {LinkServer} server */
function registerLiveInstance(server) {
  const port = server.config.port;
  let instances = liveInstancesByPort.get(port);
  if (instances === undefined) {
    instances = new Set();
    liveInstancesByPort.set(port, instances);
  }
  instances.add(server);
}

/** @param {LinkServer} server */
function unregisterLiveInstance(server) {
  const port = server.config.port;
  const instances = liveInstancesByPort.get(port);
  if (instances === undefined) return;
  instances.delete(server);
  if (instances.size === 0) liveInstancesByPort.delete(port);
}

/**
 * Dispose every other instance that still holds `port` (a previous fiber of this
 * same plugin in this process) and report how many were reclaimed.
 *
 * A listener owned by a *different* process is unreachable here; that case keeps
 * the explicit port-in-use startup error.
 *
 * @param {number} port
 * @param {LinkServer} self
 * @returns {number}
 */
function reclaimPortFromPreviousInstances(port, self) {
  const instances = liveInstancesByPort.get(port);
  if (instances === undefined) return 0;
  let reclaimed = 0;
  for (const instance of [...instances]) {
    if (instance === self || instance.disposed) continue;
    try {
      instance.dispose();
      reclaimed += 1;
    } catch {
 /* a zombie that cannot even dispose must not stop the new fiber */
    }
  }
  return reclaimed;
}

export class LinkServer {
 /**
 * @param {object} ctx Cordis plugin context (webServer + connection available).
 * @param {Record<string, unknown>} [config]
 */
  constructor(ctx, config = {}) {
    this.ctx = ctx;
    this.config = resolveConfig(config);
    this.dataDir = join(resolveHome(ctx), 'plugin-data', PLUGIN_NAME);
    this.server = undefined;
    this.wss = undefined;
    this.started = false;
    this.certs = undefined;
    this.hostIdentity = undefined;
    this.devices = undefined;
    this.auth = undefined;
    this.audit = undefined;
 /**
 * Bug1 (HANDOFF §5) debug-only frame observer. `undefined` unless
 * `config.debug.enabled === true`; every call site is guarded by an
 * `undefined` check, so the bridge has zero extra work when debug is off.
 * @type {import('./frame-audit.js').FrameAudit | undefined}
 */
    this.frameAudit = undefined;
    this.apns = undefined;
    this.notifier = undefined;
 /** task-5: host-side turn watcher (created in startInternal). */
    this.sessionWatcher = undefined;
 /** task-5b: disposers for the in-process host event subscriptions. */
    this.hostEventDisposers = [];
 /** task-5b: true while the host session-event bus drives turn-end pushes. */
    this.hostTurnEventsActive = false;
    this.qr = undefined;
    this.pairing = undefined;
 /** M2a 8-digit pairing-code service (pairing.js PairCodeService). */
    this.pairCode = undefined;
 /** M2a zero-dependency mDNS responder (undefined when disabled/failed). */
    this.bonjour = undefined;
 /** M2a outbound relay tunnel client (undefined when tunnel.enabled=false). */
    this.tunnel = undefined;
 /** Phone-visible relay origin injected after the tunnel is ready. */
    this.tunnelEndpoint = undefined;
 /** Endpoints reachable from this Mac (desktop UI / simulator). */
    this.endpoints = [];
 /** Base LAN endpoints before any tunnel origin is merged in. */
    this.baseEndpoints = [];
 /** Endpoints advertised to phones (loopback excluded whenever a LAN/tunnel endpoint exists). */
    this.deviceEndpoints = [];
    this.contract = undefined;
    this.contractPending = undefined;
    this.adminDisposer = undefined;
    this.sweepTimer = undefined;
 /** Set synchronously by dispose(); all later async continuations must bail out. */
    this.disposed = false;
    this.starting = false;
 /** @type {{code: string, message: string, at: string, retries?: number} | undefined} */
    this.startupError = undefined;
    this.lanIps = [];
    this.hostname = undefined;
 /** @type {Map<string, {windowStart: number, count: number}>} */
    this.pairAttempts = new Map();
 /** @type {Map<string, {windowStart: number, count: number}>} */
    this.pairCodeAttempts = new Map();
 /** @type {Map<string, {windowStart: number, count: number}>} */
    this.challengeAttempts = new Map();
 /** P1: one logical channel per device (survives phone socket reconnects). @type {Map<string, import('./mux-rpc.js').MuxRpcChannel>} */
    this.p1Channels = new Map();
 /** P1: anonymous `?proto=2` upgrades waiting for their first-frame `hello`. @type {Set<{downstream: unknown, timer: ReturnType<typeof setTimeout>}>} */
    this.p1Pending = new Set();
 /** P1: one-shot debug hello delay applied to the next upgrade (task-11 E2E). */
    this.p1NextHelloHoldMs = 0;
 /** P1: lazy HMAC key for stateless resume tickets (in-memory only). */
    this.p1TicketSecret = undefined;
 /** P1: single-use jti table for resume tickets (in-memory, swept by ticket TTL). */
    this.p1TicketUses = new TicketUseGuard({ graceMs: this.config.features.muxRpcTicketReplayGraceMs });
    this.counters = {
      redeemed: 0,
      pairRejected: 0,
      pairCodeRejected: 0,
      authOk: 0,
      authFailed: 0,
      proxiedUnary: 0,
      proxiedFetch: 0,
      fetchRouteDenied: 0,
      proxyErrors: 0,
 // P1.5-A lite `session/list`: opt-in responses only (full vs lite JSON
 // bytes are the uncompressed buffer sizes, measured before gzip).
      listLiteResponses: 0,
      listLiteFullBytes: 0,
      listLiteBytes: 0,
      muxOpened: 0,
      muxRejected409: 0,
      muxTakeovers: 0,
      muxRejected401: 0,
      revokedDevices: 0,
      notifications: 0,
      p1Upgrades: 0,
      p1Rejected: 0,
      p1Channels: 0,
      p1RpcOk: 0,
      p1RpcFailed: 0,
      p1ResumeOk: 0,
      p1ResumeReset: 0,
 // task-11: frames re-delivered after a `hello.resume` replay (design §7.3;
 // task-11 host assertion reads this together with p1ResumeOk).
      p1ReplayFrames: 0,
      p1ProtocolErrors: 0,
      p1UpstreamClosed: 0,
    };
 // Port hand-off bookkeeping: a later start of this plugin (same process) can
 // reclaim the TLS port from this instance even if its dispose is cut short.
    registerLiveInstance(this);
  }

  get loopbackOrigin() {
    return this.ctx.webServer.getOrigin();
  }

 /**
 * Return the device's upstream API Peer, creating it lazily.
 *
 * A device loaded from devices.json after a host restart has no peer (runtime
 * objects are deliberately not persisted). The first unary call or mux upgrade
 * for that device re-creates the peer from the stored credential — no
 * re-pairing needed (the credential/private key never left the phone).
 */
  ensurePeer(device) {
    if (!this.ctxActive()) {
      const error = new Error('dsh-m-link: plugin context is inactive (HMR/restart in progress)');
      error.code = 'ctx-inactive';
      throw error;
    }
    if (device.peer !== undefined) return device.peer;
    const frameAudit = this.frameAudit;
    const observeFrame = (data, isBinary) => this.notifier.observe(device, data, isBinary);
    device.peer = new UpstreamPeer({
      deviceId: device.deviceId,
      loopbackOrigin: this.loopbackOrigin,
      authenticatedUrl: (baseUrl) => this.ctx.connection.authenticatedUrl(baseUrl),
      log,
 // Bug1: the existing read-only `onFrame` observer is the upstream mux
 // ingress point (local DSH -> plugin). The debug frame audit rides on it
 // (no upstream-peer.js API/protocol change); debug off keeps the exact
 // pre-existing closure so nothing extra runs per frame.
      onFrame:
        frameAudit === undefined
          ? observeFrame
          : (data, isBinary) => {
              observeFrame(data, isBinary);
              frameAudit.fromUpstream(device.deviceId, data, isBinary);
            },
    });
    log('device ' + device.deviceId + ': upstream peer created lazily (' + (this.contract?.ok === true ? 'host ready' : 'host not ready') + ')');
    return device.peer;
  }

 // ------------------------------------------------- task-5 turn watcher ---

 /** Active devices that can receive an APNs push (the watcher's coverage set). */
  watchableDevices() {
    if (this.devices === undefined) return [];
    return this.devices
      .active()
      .filter((device) => typeof device.pushToken === 'string' && device.pushToken.length > 0);
  }

 /** Start/stop the turn watcher after a device or push-token change. */
  syncSessionWatcher() {
    try {
      this.sessionWatcher?.sync?.();
    } catch (error) {
      log('turn watcher sync failed: ' + String(error?.message ?? error));
    }
  }

 /**
 * Fan one completed turn out to every push-token device. While the watcher is
 * active this is the only turn-end source (the frame path is suppressed), so
 * the push is delivered even if the phone never followed the session.
 */
 /**
 * Active devices that can receive a push, **deduped by APNs token**.
 *
 * 同一台手机在重复配对/重装后会留下多条 active 设备记录（同 keyId、同 push token），
 * 逐设备发送会让同一条通知重复 N 次。
 * 这里按 token 去重，只保留 lastSeenAt 最新的一条；同一 token 只发一次。
 */
  pushTargets() {
    if (this.devices === undefined) return [];
    const byToken = new Map();
    for (const device of this.devices.active()) {
      const token = device.pushToken;
      if (typeof token !== 'string' || token.length === 0) continue;
      const previous = byToken.get(token);
      if (previous === undefined || (device.lastSeenAt ?? 0) > (previous.lastSeenAt ?? 0)) {
        byToken.set(token, device);
      }
    }
    return [...byToken.values()];
  }

  notifyTurnEndAllDevices(sessionId) {
    if (this.disposed || typeof sessionId !== 'string' || sessionId.length === 0) return 0;
    if (this.notifier === undefined || this.devices === undefined) return 0;
    let sent = 0;
    const targets = typeof this.pushTargets === 'function'
      ? this.pushTargets()
      : this.devices.active().filter((device) => typeof device.pushToken === 'string' && device.pushToken.length > 0);
    for (const device of targets) {
      this.notifier.notify(device, {
        kind: 'turn-end',
        collapseId: 'turn-end:' + sessionId,
        title: 'DSH 回合完成',
        body: '任务已在 Mac 上完成',
        threadId: sessionId,
        data: { type: 'turn-end', sessionId },
      });
      sent += 1;
    }
    return sent;
  }

 /** Push a finished-with-error turn to every push-capable device (host event bus). */
  notifyTurnFailureAllDevices(sessionId) {
    if (this.disposed || typeof sessionId !== 'string' || sessionId.length === 0) return 0;
    if (this.notifier === undefined || this.devices === undefined) return 0;
    let sent = 0;
    const targets = typeof this.pushTargets === 'function'
      ? this.pushTargets()
      : this.devices.active().filter((device) => typeof device.pushToken === 'string' && device.pushToken.length > 0);
    for (const device of targets) {
      this.notifier.notify(device, {
        kind: 'failure',
        collapseId: 'turn-failure:' + sessionId,
        title: 'DSH 回合失败',
        body: '任务执行出错，打开 App 查看详情',
        threadId: sessionId,
        data: { type: 'failure', sessionId },
      });
      sent += 1;
    }
    return sent;
  }

 /**
 * Revoke older active device records that represent the same physical phone as
 * `keepDevice` (same device public-key fingerprint or same APNs push token).
 * Used by pairing and by startup migration; returns the number revoked.
 */
  revokeDuplicateDevices(keepDevice) {
    if (keepDevice === undefined || this.devices === undefined) return 0;
    const keepKeyId = typeof keepDevice.keyId === 'string' && keepDevice.keyId.length > 0 ? keepDevice.keyId : undefined;
    const keepToken = typeof keepDevice.pushToken === 'string' && keepDevice.pushToken.length > 0 ? keepDevice.pushToken : undefined;
    let revoked = 0;
    for (const other of this.devices.active()) {
      if (other.deviceId === keepDevice.deviceId) continue;
      const sameKey = keepKeyId !== undefined && other.keyId === keepKeyId;
      const sameToken = keepToken !== undefined && other.pushToken === keepToken;
      if (!sameKey && !sameToken) continue;
      this.devices.revoke(other.deviceId, 'duplicate-pairing');
      this.audit.record('device.deduped', {
        deviceId: other.deviceId,
        keptDeviceId: keepDevice.deviceId,
        reason: sameToken ? 'push-token' : 'keyId',
      });
      revoked += 1;
    }
    return revoked;
  }

 /**
 * Startup migration: collapse pre-existing duplicate active device records
 * (left behind by older plugin versions that never deduped pairing) so turn-end
 * pushes fan out once per physical phone instead of once per stale record.
 */
  dedupeActiveDevicesAtStartup() {
    if (this.devices === undefined) return 0;
    let revoked = 0;
    const seenKeys = new Map();
    const seenTokens = new Map();
    const active = [...this.devices.active()].sort((a, b) => (b.lastSeenAt ?? 0) - (a.lastSeenAt ?? 0));
    for (const device of active) {
      if (device.revokedAt !== undefined) continue;
      const keyId = typeof device.keyId === 'string' && device.keyId.length > 0 ? device.keyId : undefined;
      const token = typeof device.pushToken === 'string' && device.pushToken.length > 0 ? device.pushToken : undefined;
      if ((keyId !== undefined && seenKeys.has(keyId)) || (token !== undefined && seenTokens.has(token))) {
        this.devices.revoke(device.deviceId, 'startup-duplicate');
 // audit 可能还没初始化（构造函数早期），这里做可选调用。
        this.audit?.record?.('device.deduped', { deviceId: device.deviceId, reason: 'startup' });
        revoked += 1;
        continue;
      }
      if (keyId !== undefined) seenKeys.set(keyId, device.deviceId);
      if (token !== undefined) seenTokens.set(token, device.deviceId);
    }
    return revoked;
  }

 /**
 * Subscribe to the host's in-process session event bus. This is the primary
 * turn-end source: it fires for every session on this host, independent of
 * device connections and of which session any phone happens to follow.
 */
  subscribeHostTurnEvents() {
    if (this.hostEventDisposers.length > 0) return;
    const ctx = this.ctx;
    if (ctx === undefined || typeof ctx.on !== 'function') {
      log('host event bus unavailable: turn-end notifications fall back to the frame watcher');
      return;
    }
    const handler = createHostTurnEventHandler({
      notifyTurnEnd: (sessionId) => this.notifyTurnEndAllDevices(sessionId),
      notifyFailure: (sessionId) => this.notifyTurnFailureAllDevices(sessionId),
      config: this.config.notifications,
      isEnabled: () => this.disposed !== true,
    });
    try {
 // `global: true` matches how the host's own packages listen: a scoped
 // context only receives its own sessions' events otherwise.
      const dispose = ctx.on('session/event', handler, { global: true });
      if (typeof dispose === 'function') this.hostEventDisposers.push(dispose);
      this.hostTurnEventsActive = true;
      log('host session-event subscription active (turn-end notifications are event-driven)');
    } catch (error) {
      log('session/event subscribe failed: ' + String(error?.message ?? error));
    }
  }

 /**
 * One loopback `session/list` for the watcher: the same target the phone
 * unary proxy uses, authenticated with a device peer cookie. Only
 * `sessionId` + `running` are kept, so the transient full projection object
 * (up to ~1.5 MB) is dropped immediately and the watcher never holds list data.
 */
  async fetchSessionListForWatcher(device) {
    const peer = this.ensurePeer(device);
    if (peer.cookie === undefined) await peer.connect('answer');
    const envelope = {
      type: 'client-request',
      rpcId: 'turn-watch-' + randomUUID(),
      method: 'session/list',
      payload: { args: {} },
    };
    const timeoutMs = this.config.notifications.requestTimeoutMs;
    const response = await fetch(this.loopbackOrigin + '/api/session/list', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
 // Ask for the lite projection the App uses; the link layer may serve it
 // trimmed (an older host ignores the hint — harmless).
        [LIST_LITE_HEADER]: '1',
        cookie: peer.cookie.name + '=' + peer.cookie.value,
      },
      body: JSON.stringify(envelope),
      redirect: 'manual',
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (response.status === 401 || response.status === 403) {
 // The cookie was minted for a peer the host has since disposed (device
 // reconnected, host restarted): drop it so the next poll re-connects
 // instead of retrying a dead credential forever.
      peer.cookie = undefined;
      throw new Error('session/list HTTP ' + response.status);
    }
    if (!response.ok) throw new Error('session/list HTTP ' + response.status);
    const bytes = Buffer.from(await response.arrayBuffer());
    let parsed;
    try {
      parsed = JSON.parse(bytes.toString('utf8'));
    } catch {
      throw new Error('session/list response is not JSON');
    }
    const value = parsed?.result?.ok === true ? parsed.result.value : undefined;
    if (value === undefined || !Array.isArray(value.items)) {
      throw new Error('session/list envelope is not ok');
    }
    return value.items
      .map((item) =>
        item !== null && typeof item === 'object'
          ? { sessionId: item.sessionId, running: item.running === true }
          : null
      )
      .filter((item) => item !== null && typeof item.sessionId === 'string');
  }

 /**
 * True when the plugin can serve phones: not disposed, listener started, no
 * startup error, Cordis context still active and the contract probe passed.
 */
  get ready() {
    return this.readinessError() === undefined;
  }

 /**
 * Is the Cordis context backing this LinkServer still alive?
 *
 * HMR disposes the old plugin fiber while its TLS listener may still be
 * closing; touching an inactive context's services throws
 * "cannot get required service... in inactive context". Every request path
 * that depends on webServer/connection must ask this first.
 */
  ctxActive() {
    if (this.disposed) return false;
    try {
      const webServer = this.ctx.webServer;
      if (webServer === undefined || typeof webServer.getOrigin !== 'function') return false;
      const connection = this.ctx.connection;
      if (connection === undefined || typeof connection.authenticatedUrl !== 'function') return false;
      return true;
    } catch {
      return false;
    }
  }

 /**
 * Why the plugin cannot serve phones right now (undefined when ready).
 * @returns {{code: string, message: string, status?: number} | undefined}
 */
  readinessError() {
    if (this.disposed) {
      return { code: 'host/inactive', message: 'the plugin instance has been disposed (HMR/restart); the host will load a new instance', status: 503 };
    }
    if (!this.ctxActive()) {
      return { code: 'host/inactive', message: 'the plugin context is inactive (HMR/restart in progress); retry after the host reloads the plugin', status: 503 };
    }
    if (this.startupError !== undefined) {
      return { code: this.startupError.code, message: this.startupError.message, status: 503 };
    }
    if (!this.started) {
      return { code: 'host/starting', message: 'the link listener is still starting', status: 503 };
    }
    if (this.config.contract.probeOnStart !== false) {
      if (this.contract === undefined) return { code: 'host/starting', message: 'the /connect contract self-check is still running', status: 503 };
      if (this.contract.ok !== true) return { code: 'host/incompatible', message: String(this.contract.error ?? 'DSH /connect contract self-check failed'), status: 503 };
    }
    return undefined;
  }

  async start() {
    if (this.disposed) {
      this.startupError = { code: 'host/inactive', message: 'start() called after dispose()', at: new Date().toISOString() };
      return this;
    }
    this.starting = true;
    try {
      await this.startInternal();
    } catch (error) {
      this.recordStartupError(error);
    } finally {
      this.starting = false;
    }
    return this;
  }

 /** Map a startup failure to a stable code the desktop UI can display. */
  recordStartupError(error) {
    const code = error?.code === 'EADDRINUSE' ? 'host/port-in-use' : error?.code === 'ctx-inactive' ? 'host/inactive' : 'host/startup-failed';
    const message = error?.code === 'EADDRINUSE'
      ? 'TLS port ' + String(this.config.port) + ' is already in use (another dsh-m-link instance or zombie listener holds it); the host must release the port or be restarted'
      : String(error?.message ?? error);
    this.startupError = { code, message, at: new Date().toISOString() };
    log('STARTUP FAILED (' + code + '): ' + message);
    try {
      this.audit?.record('server.startup-failed', { code, message });
    } catch {
 /* audit is best effort during failure */
    }
  }

  async startInternal() {
    mkdirSync(this.dataDir, { recursive: true });
    this.audit = new AuditLog({ dir: this.dataDir, log });
 // Bug1 (HANDOFF §5): frame-level audit observation is debug-gated on the
 // profile switch. Debug off → no FrameAudit instance is created and the
 // per-frame call sites skip immediately (zero parsing/serialization).
    this.frameAudit = this.createFrameAudit();
    this.hostIdentity = ensureHostIdentity({ dir: this.dataDir, log });
    this.devices = new DeviceStore({ dir: this.dataDir, hostId: this.hostIdentity.hostId, log }).load();
    try {
      const dedupedAtStartup = this.dedupeActiveDevicesAtStartup();
      if (dedupedAtStartup > 0) log('deduped ' + dedupedAtStartup + ' stale duplicate device record(s) at startup');
    } catch (error) {
      log('device startup dedupe failed: ' + String(error?.message ?? error));
    }
    this.qr = new QrRenderer({ log });
    this.apns = new ApnsProvider({ config: this.config.apns, log }).init();
    this.notifier = new Notifier({
      devices: this.devices,
      apns: this.apns,
      audit: this.audit,
      config: this.config.notifications,
      log,
 // task-5: while the TurnWatcher owns turn-end delivery (a push-token
 // device exists), the frame path must not push a second time.
      isTurnEndWatched: () => this.hostTurnEventsActive === true || this.sessionWatcher?.active === true,
    });
 // task-5 (user requirement): turn completion must be delivered even when the
 // App is not following the session / not running. The watcher polls
 // session/list over the loopback channel and owns turn-end pushes; the frame
 // path only covers the no-watcher case.
    this.sessionWatcher = new TurnWatcher({
      listDevices: () => this.watchableDevices(),
      fetchSessionList: (device) => this.fetchSessionListForWatcher(device),
      notifyTurnEnd: (sessionId) => this.notifyTurnEndAllDevices(sessionId),
      isAvailable: () => this.disposed !== true && this.contract?.ok === true,
      config: this.config.notifications,
      log,
    });
    this.sessionWatcher.sync();
 // task-5b (user requirement): turn completion must be delivered even when the
 // App is not following the session / not running / killed. The host emits every
 // durable session event in-process — subscribe here instead of relying on the
 // device frame bridge (which only sees sessions the phone follows).
    this.subscribeHostTurnEvents();
    this.auth = new AuthService({ devices: this.devices, audit: this.audit, config: this.config.security, log });
    this.hostname = osHostname();
    this.lanIps = collectLanIps();
    const additionalHosts = Array.isArray(this.config.tls.additionalHosts) ? this.config.tls.additionalHosts : [];
    const certs = ensureCerts({
      dir: this.dataDir,
      bindHost: this.config.bindHost,
      lanIps: [...this.lanIps, ...additionalHosts],
      hostname: this.hostname,
      log,
    });
    this.certs = certs;
    if (certs.generated) this.audit.record('cert.generated', { caPin: certs.caPin, caFingerprint256: certs.caFingerprint256 });
    if (certs.leafRotated && !certs.generated) this.audit.record('cert.leaf-rotated', { leafPin: certs.leafPin, leafSans: certs.leafSans });
    this.endpoints = buildEndpoints({ config: this.config, certs, lanIps: this.lanIps, hostname: this.hostname });
    this.baseEndpoints = this.endpoints.slice();
 // The QR payload must never lead with 127.0.0.1: on a phone that address is
 // the phone itself (ECONNREFUSED). Loopback stays only as the fallback for a
 // loopback-only desktop deployment (local simulators).
    this.deviceEndpoints = selectDeviceEndpoints(this.endpoints);
    const defaultHostName = isUsableHostName(this.hostname) ? this.hostname.replace(/\.local$/, '') + ' 的 Mac' : 'DeepSeek Harness Mac';
    this.pairing = new PairingService({
      config: { ...this.config, hostName: this.config.hostName || defaultHostName },
      certs,
      hostIdentity: this.hostIdentity,
      endpoints: this.deviceEndpoints,
      audit: this.audit,
      log,
    });
    this.pairing.refresh('startup');
 // M2a 8-digit pairing code: issued at startup and auto-rotated by its own
 // ticker so the desktop panel always has a live code (design §5.1).
    this.pairCode = new PairCodeService({
      config: this.config,
      audit: this.audit,
      log,
      onChange: (status, meta) => this.onPairCodeChange(status, meta),
    });
    this.pairCode.start('startup');
    await this.writeDebugPairPayload();

    this.wsModule = await loadWs();
    log('ws implementation: ' + wsLoadedFrom());
    const { WebSocketServer } = wsBindings(this.wsModule);
    this.wss = new WebSocketServer({ noServer: true });
    this.server = createServer(
      {
        key: readFileSync(certs.leafKey),
        cert: readFileSync(certs.leafCert),
        minVersion: 'TLSv1.2',
        ciphers: 'ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL:!SHA1',
        honorCipherOrder: true,
      },
      (request, response) => {
        this.handleRequest(request, response).catch((error) => {
          this.counters.proxyErrors += 1;
          log('request handler failed: ' + (error?.stack ?? String(error)));
          if (!response.headersSent) sendJson(response, 500, { ok: false, error: 'internal', message: String(error?.message ?? error) });
          else response.end();
        });
      },
    );
 // M2b: keep-alive for phone unary connections. Node's default 5s idle
 // timeout would tear down the iOS pool's connections between screens; the
 // phone's own idle timeout (30s) stays well below this value.
    this.server.keepAliveTimeout = this.config.httpKeepAliveTimeoutMs;
    this.server.headersTimeout = this.config.httpKeepAliveTimeoutMs + 5_000;
    this.server.on('upgrade', (request, socket, head) => this.handleUpgrade(request, socket, head));
 // Register the desktop admin route *before* binding the port: when the
 // listener cannot start (zombie holding the port, cert error,...) the
 // desktop UI can still read the failure reason from the admin route.
    try {
      this.adminDisposer = registerAdminRoute({ ctx: this.ctx, server: this, log });
    } catch (error) {
      log('failed to register desktop admin route ' + ADMIN_PATH + ': ' + String(error?.message ?? error));
    }
    if (this.disposed) return this;
    await this.listenWithRetry();
    if (this.disposed) {
      this.closeListenerQuietly();
      return this;
    }
    this.started = true;
    this.startupError = undefined;
    this.sweepTimer = setInterval(() => this.auth.sweep(), 30_000);
    if (typeof this.sweepTimer.unref === 'function') this.sweepTimer.unref();
 // LAN addresses change when the Mac joins another Wi-Fi. /health
 // and the pairing payload refresh on demand; this timer covers idle windows so
 // mDNS is already correct when the phone comes back.
    this.endpointRefreshTimer = setInterval(() => this.refreshLanEndpoints(), 30_000);
    if (typeof this.endpointRefreshTimer.unref === 'function') this.endpointRefreshTimer.unref();
    log('TLS origin listening on https://' + this.config.bindHost + ':' + String(this.config.port));
    log('device-visible endpoints: ' + (this.deviceEndpoints.map((endpoint) => endpoint.url).join(', ') || 'none'));
    log('loopback origin: ' + this.loopbackOrigin);
    log('CA pin (spki sha256): ' + this.certs.caPin + ' · leaf pin: ' + this.certs.leafPin);
    this.audit.record('server.start', {
      port: this.config.port,
      bindHost: this.config.bindHost,
      caPin: this.certs.caPin,
      leafPin: this.certs.leafPin,
      leafNotAfter: this.certs.leafNotAfter,
      devices: this.devices.size(),
      apns: this.apns.mode,
      qr: 'capability-probed-on-first-use',
    });
    if (this.config.debug.enabled) {
      log('WARNING: debug admin channel enabled on the TLS origin (test only; never enable in production)');
    }
 // LAN discovery + relay tunnel start after the listener is bound: a failure
 // here is logged/audited only and never affects plugin readiness.
    this.startBonjour();
    this.startTunnel();
    if (this.config.contract.probeOnStart) this.contractPending = this.runContractProbe();
    else this.contract = { ok: true, skipped: true };
    return this;
  }

 /**
 * Bind the TLS listener; retry briefly on EADDRINUSE (HMR hand-off race).
 *
 * Two distinct holders are possible:
 * - a previous fiber of this plugin in *this* process (profile reload). It is
 * reachable through the live-instance registry and is disposed here, which
 * terminates its phone sockets and releases the port for this instance;
 * - a foreign process. Unreachable, so the retry window stays short and the
 * explicit `host/port-in-use` error is still reported.
 */
  async listenWithRetry(attempts = 8, delayMs = 350) {
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      if (this.disposed) {
        const error = new Error('disposed while waiting for the listener');
        error.code = 'ctx-inactive';
        throw error;
      }
      try {
        await new Promise((resolve, reject) => {
          const onError = (error) => {
            this.server.off('listening', onListening);
            reject(error);
          };
          const onListening = () => {
            this.server.off('error', onError);
            resolve();
          };
          this.server.once('error', onError);
          this.server.once('listening', onListening);
          this.server.listen(this.config.port, this.config.bindHost);
        });
        return;
      } catch (error) {
        if (error?.code !== 'EADDRINUSE') throw error;
 // Newest fiber wins: reclaim the port from a previous instance of this
 // plugin that still holds the listener (its dispose may have been cut
 // short, and Node keeps the port bound until its phone sockets die).
        const reclaimed = reclaimPortFromPreviousInstances(this.config.port, this);
        if (reclaimed > 0) {
          const suffix = reclaimed === 1 ? 'instance' : 'instances';
          log(
            'TLS port ' + String(this.config.port) + ' was held by ' + String(reclaimed) + ' previous dsh-m-link ' + suffix +
              ' in this host; disposed it and retrying the bind (attempt ' + String(attempt) + '/' + String(attempts) + ')'
          );
          continue;
        }
        const retryable = attempt < attempts;
        if (!retryable) throw error;
        log('TLS port ' + String(this.config.port) + ' is busy (attempt ' + String(attempt) + '/' + String(attempts) + '); retrying in ' + String(delayMs) + 'ms — a previous plugin instance may still be closing its listener (HMR)');
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }

 /**
 * Bug1 (HANDOFF §5): build the frame-level audit observer.
 *
 * Returns `undefined` unless `debug.enabled` is on, so debug-off runs create
 * no recorder at all and every per-frame call site short-circuits on the
 * `undefined` check (no parsing, serialization or allocation).
 * @returns {import('./frame-audit.js').FrameAudit | undefined}
 */
  createFrameAudit() {
    return this.config.debug.enabled === true ? new FrameAudit({ audit: this.audit }) : undefined;
  }

 /** Best-effort listener teardown used by dispose() and start/dispose races. */
  closeListenerQuietly() {
    try {
      this.server?.closeAllConnections?.();
    } catch {
 /* not available / already closed */
    }
    try {
      this.server?.closeIdleConnections?.();
    } catch {
 /* not available / already closed */
    }
    if (this.server !== undefined) {
      try {
        this.server.close();
      } catch {
 /* ERR_SERVER_NOT_RUNNING is fine */
      }
      this.server = undefined;
    }
  }

  async runContractProbe() {
    const result = await probeWithRetries({
      authenticatedUrl: (baseUrl) => this.ctx.connection.authenticatedUrl(baseUrl),
      loopbackOrigin: this.loopbackOrigin,
      log,
      attempts: this.config.contract.retryAttempts,
      delayMs: this.config.contract.retryDelayMs,
    });
    this.contract = result;
    if (result.ok) {
      this.audit.record('contract.ok', { muxPath: result.muxPath, durationMs: result.durationMs });
    } else {
      log('CONTRACT SELF-CHECK FAILED: this DSH build is incompatible with ' + PLUGIN_NAME + ' — ' + result.error);
      log('The desktop UI will show "当前 DSH 版本不兼容" and pairing is disabled until a compatible build is installed.');
      this.audit.record('contract.failed', { error: result.error });
    }
    return result;
  }

 /** Public liveness document (no device names, no secrets). */
  health(ip) {
 // root-cause fix: a phone probe is the best moment to refresh the
 // Mac's current LAN endpoints (cheap getifaddrs; only rebuilds on change).
    this.refreshLanEndpoints();
    return {
      ok: true,
      plugin: PLUGIN_NAME,
      version: PLUGIN_VERSION,
 // P1 capability probe (design §6): the M2 App reads this before dialing
 // `?proto=2`, so a v2 plugin is detected without paying a 401 first. The
 // App accepts either a legacy string or this array; no ticket/secret here.
      proto: this.config.features.muxRpc === true ? [PROTOCOL, 'dsh-m/2'] : [PROTOCOL],
      features: { muxRpc: this.config.features.muxRpc === true },
      ready: this.ready,
      inactive: this.disposed || !this.ctxActive(),
      startupError: this.startupError ?? null,
      contract: this.contract === undefined ? { ok: false, pending: true } : { ok: this.contract.ok === true, error: this.contract.error, checkedAt: this.contract.checkedAt, muxPath: this.contract.muxPath },
      tls: {
        bindHost: this.config.bindHost,
        port: this.config.port,
 // C scheme: public CA certificate (DER base64) as the long-lived trust
 // anchor, so a leaf re-issue never invalidates an existing pairing.
        caCert: this.certs?.caCertDerBase64,
        caPin: this.certs?.caPin,
        leafPin: this.certs?.leafPin,
        caFingerprint256: this.certs?.caFingerprint256,
        leafFingerprint256: this.certs?.leafFingerprint256,
        leafNotAfter: this.certs?.leafNotAfter,
      },
 // Both lists on purpose: `endpoints` is what this Mac can reach (desktop
 // UI / simulator), `deviceEndpoints` is what the phone-facing QR payload
 // advertises. Loopback appears in the former and only in the latter when
 // no non-loopback address exists.
      endpoints: this.endpoints.map((endpoint) => endpoint.url),
      deviceEndpoints: this.deviceEndpoints.map((endpoint) => endpoint.url),
      fetchRoutes: this.config.fetchRoutes.enabled === false ? [] : this.config.fetchRoutes.allow,
 // M2a: never the code itself — only liveness metadata (design §5.2).
      pairing: this.pairCode === undefined
        ? { codeActive: false, expiresAt: null }
        : { codeActive: this.pairCode.current() !== undefined, expiresAt: this.pairCode.current()?.expiresAt ?? null },
 // M2a tunnel is optional; the field only appears when configured, so an
 // untouched M1 / LAN-only deployment keeps the exact M1 health document.
      ...(this.config.tunnel.enabled === true
        ? { tunnel: this.tunnel?.health?.() ?? { enabled: true, state: 'connecting', origin: null, port: null, since: null, lastError: null } }
        : {}),
      devices: { total: this.devices?.size() ?? 0, active: this.devices?.active().length ?? 0 },
      apns: {
        mode: this.apns?.mode,
        reason: this.apns?.reason,
        environment: this.apns?.info?.().environment,
        topic: this.apns?.topic ?? null,
        keyIdConfigured: this.apns?.mode === 'ready',
      },
      counters: this.counters,
    };
  }

 /**
 * M2a: fan out pairing-code changes to the relay tunnel. The LAN TXT record
 * is deliberately NOT touched: `pair` there is a capability marker
 * (`pair=code`), never the code value — mDNS is a public broadcast channel.
 */
  onPairCodeChange() {
    this.publishTunnelCode();
  }

 /** Relay origin advertised in the Bonjour TXT record (optional). */
  tunnelRelayOrigin() {
    try {
      const relay = this.tunnel?.relayInfo?.();
      if (typeof relay?.origin === 'string' && relay.origin.length > 0) return relay.origin;
    } catch {
 /* tunnel not ready */
    }
    if (this.config.tunnel.enabled === true && typeof this.config.tunnel.controlOrigin === 'string' && this.config.tunnel.controlOrigin.length > 0) {
      return this.config.tunnel.controlOrigin;
    }
    return undefined;
  }

 /**
 * TXT values for the mDNS responder (design §5.3). `pair` is the fixed
 * capability marker `code` — never the 8-digit code value (security: mDNS is
 * a LAN-wide broadcast). `relay` is the public relay origin (not a secret).
 */
  bonjourTxt() {
    const relay = this.tunnelRelayOrigin();
    return {
      v: '1',
      hostId: this.hostIdentity?.hostId ?? '',
      hostName: this.pairing?.hostName ?? this.hostname ?? '',
      proto: PROTOCOL,
      ver: PLUGIN_VERSION,
      pair: 'code',
      ...(typeof relay === 'string' ? { relay } : {}),
    };
  }

 /**
 * real-device root-cause fix: re-collect the Mac's LAN IPv4 addresses
 * and rebuild everything derived from them.
 *
 * Why: `this.lanIps` used to be captured **once in the constructor** (`:876`).
 * After a Wi-Fi/subnet change the mDNS A records, `/health.deviceEndpoints`, the
 * pairing payload and `selectDeviceEndpoints()` kept advertising the *old*
 * addresses forever. Live evidence on the user's iPhone: the plugin started with
 * 192.168.5.10 / 172.28.95.194, the Mac now sits on 172.24.116.36, the phone kept
 * probing dead LAN origins and every authenticated connection since 08:31 went
 * through the relay (566 relay auths, 0 LAN auths) — the LAN-direct scenario in
 * the matrix had become unreachable without any user-visible error.
 *
 * The leaf certificate is intentionally **not** re-issued here: the iOS client
 * pins the CA (`CATrust.evaluate` uses `SecPolicyCreateSSL(true, nil)`, hostname
 * matching replaced by the pinned-CA trust decision), so a new IP works with the
 * existing leaf. Refreshing on demand (every `/health`, pairing payload, 30s
 * timer) keeps the cost at one getifaddrs call and rebuilds only on change.
 *
 * @returns {boolean} true when the advertised endpoint set changed
 */
  refreshLanEndpoints() {
    let next;
    try {
      next = collectLanIps();
    } catch {
      return false;
    }
    const before = [...this.lanIps].sort().join(',');
    const after = [...next].sort().join(',');
    if (before === after) return false;
    const previous = this.lanIps;
    try {
      this.lanIps = next;
      this.endpoints = buildEndpoints({ config: this.config, certs: this.certs, lanIps: this.lanIps, hostname: this.hostname });
      this.baseEndpoints = this.endpoints.slice();
      this.deviceEndpoints = selectDeviceEndpoints(this.endpoints);
      this.pairing?.setTrust?.({ certs: this.certs, endpoints: this.deviceEndpoints });
    } catch (error) {
      this.lanIps = previous;
      log('endpoints: LAN refresh failed, keeping previous: ' + String(error?.message ?? error));
      return false;
    }
    try {
      if (this.bonjour !== undefined) {
        this.bonjour.update({}, { addresses: this.lanIps });
      } else {
        this.startBonjour();
      }
    } catch (error) {
      log('bonjour: LAN address refresh failed: ' + String(error?.message ?? error));
    }
    try {
      this.audit?.record('endpoints.refreshed', { previous, current: this.lanIps });
    } catch {
 /* audit is best effort */
    }
    log('endpoints: LAN addresses changed -> ' + (this.deviceEndpoints.map((endpoint) => endpoint.url).join(', ') || 'none'));
    return true;
  }

 /**
 * Start the zero-dependency mDNS responder. Only for a wildcard bindHost; any
 * failure is audited/logged and the plugin keeps serving (design §5.3).
 */
  startBonjour() {
    if (this.config.bonjour.enabled === false) return;
    const bindHost = this.config.bindHost;
    if (bindHost !== '0.0.0.0' && bindHost !== '::') {
      log('bonjour: LAN discovery disabled (bindHost=' + String(bindHost) + ' is not wildcard)');
      return;
    }
    if (this.lanIps.length === 0) {
      log('bonjour: no non-loopback IPv4 address; LAN discovery skipped');
      this.audit?.record('bonjour.skipped', { reason: 'no-lan-ip' });
      return;
    }
    try {
      const displayName = typeof this.config.hostName === 'string' && this.config.hostName.length > 0
        ? this.config.hostName
        : isUsableHostName(this.hostname) ? this.hostname.replace(/\.local$/, '') : 'Mac';
      this.bonjour = new BonjourResponder({
        hostId: this.hostIdentity.hostId,
        hostName: displayName,
        port: this.config.port,
        addresses: this.lanIps,
        txt: this.bonjourTxt(),
        ttlSeconds: 120,
        log,
        onError: (error) => {
          try {
            this.audit?.record('bonjour.failed', { message: String(error?.message ?? error) });
          } catch {
 /* audit is best effort */
          }
        },
      });
      const started = this.bonjour.start();
      if (started.ok !== true) {
        this.audit?.record('bonjour.failed', { message: String(started.error ?? 'unknown') });
        this.bonjour = undefined;
        return;
      }
      this.audit?.record('bonjour.started', { instance: this.bonjour.instanceFqdn, port: this.config.port, addresses: this.lanIps.length });
    } catch (error) {
      log('bonjour: failed to start (plugin continues): ' + String(error?.message ?? error));
      try {
        this.audit?.record('bonjour.failed', { message: String(error?.message ?? error) });
      } catch {
 /* audit is best effort */
      }
      this.bonjour = undefined;
    }
  }

 /**
 * Push the current pairing code + Mac TLS pins to the relay tunnel. Called on
 * every code change and on tunnel ready; a no-op while the tunnel is disabled
 * or not connected (the tunnel keeps the latest values and sends them on
 * ready).
 */
  publishTunnelCode() {
    if (this.tunnel === undefined) return;
    try {
      const status = this.pairCode?.status({ ensure: false });
      const code = status?.active === true ? status.value : undefined;
 // The relay lookup contract (design §4.5) wants the *certificate DER*
 // sha256 base64url, while certs.leafPin is the SPKI pin. Derive the DER
 // pin from the colon-hex fingerprint the cert module already exposes.
      const derPin = certDerPin(this.certs?.leafFingerprint256);
      this.tunnel.publishCode?.(code, status?.expiresAt, derPin, this.certs?.leafFingerprint256, this.pairing?.hostName);
    } catch (error) {
      log('tunnel: publishCode failed: ' + String(error?.message ?? error));
    }
  }

 /**
 * Start the outbound relay tunnel when configured. Implemented by
 * lib/tunnel.js (M2a §4.6); disabled => identical M1 behaviour.
 */
  startTunnel() {
    if (this.config.tunnel.enabled !== true) return;
    this.startTunnelClient().catch((error) => {
      log('tunnel: failed to start (plugin continues): ' + String(error?.stack ?? error));
      try {
        this.audit?.record('tunnel.failed', { message: String(error?.message ?? error) });
      } catch {
 /* audit is best effort */
      }
    });
  }

 /** Overridden by the tunnel integration (kept separate so tests can stub it). */
  async startTunnelClient() {
    const { startTunnelClient } = await import('./tunnel.js');
    const tunnel = startTunnelClient({
      config: this.config.tunnel,
      pluginPort: this.config.port,
      hostId: this.hostIdentity?.hostId,
      hostName: this.pairing?.hostName ?? this.hostname ?? 'Mac',
      pluginVersion: PLUGIN_VERSION,
      log,
      audit: this.audit,
      onReady: (ready) => this.onTunnelReady(ready),
      onStateChange: () => {
 /* health reads tunnel.health() directly */
      },
    });
    this.tunnel = tunnel;
    await tunnel.start();
    this.publishTunnelCode();
    return tunnel;
  }

 /**
 * M2b-1 runtime tunnel (re)activation — no plugin reload required.
 *
 * A live desktop plugin cannot be reliably reloaded to pick up a new
 * `tunnel` config: HMR disposes the old Cordis fiber but the old TLS
 * listener/timers can survive (observed: the new instance failed
 * with `server.startup-failed code=host/port-in-use` and the plugin only came
 * back after changing its port). The one-click deploy therefore activates the
 * tunnel in-process: explicit `{controlOrigin, pin, secret|secretFile}`
 * values replace the current TunnelClient at runtime.
 *
 * Priority: profile `tunnel.*` values still win at plugin startup (a restart
 * reverts to them); this method overrides the *runtime instance* until then.
 *
 * @param {{controlOrigin?: string, pin?: string, secret?: string, secretFile?: string, wantPort?: number, timeoutMs?: number}} [activation]
 * @returns {Promise<{ok: boolean, state: string, origin: string|null, port: number|null, pin: string|null, error?: string, unchanged?: boolean, rolledBack?: boolean, restoredState?: string, current?: object}>}
 */
  async activateTunnel(activation = {}) {
    if (this.disposed) return { ok: false, state: 'host/disposed', origin: null, port: null, pin: null, error: 'plugin instance disposed' };
    const controlOrigin = typeof activation.controlOrigin === 'string' ? activation.controlOrigin.trim().replace(/\/+$/u, '') : '';
    let originOk = false;
    try {
      originOk = new URL(controlOrigin).protocol === 'https:';
    } catch {
      originOk = false;
    }
    if (originOk !== true) {
      return { ok: false, state: 'config/invalid-origin', origin: null, port: null, pin: null, error: 'controlOrigin 必须是有效的 https:// 地址' };
    }
    const pin = typeof activation.pin === 'string' ? activation.pin.trim() : '';
    if (!/^[A-Za-z0-9_-]{43,128}$/u.test(pin)) {
      return { ok: false, state: 'config/invalid-pin', origin: null, port: null, pin: null, error: 'pin 必须是 43 字符以上的 base64url 字符串' };
    }
    const inlineSecret = typeof activation.secret === 'string' && activation.secret.trim().length >= 16 ? activation.secret.trim() : '';
    const requestedSecretFile = typeof activation.secretFile === 'string' ? activation.secretFile.trim() : '';
    const previousConfig = { ...this.config.tunnel };
    const previousHealth = this.tunnel?.health?.();
    const tunnelConfig = {
      ...previousConfig,
      enabled: true,
      controlOrigin,
      pin,
      secret: inlineSecret,
      secretFile: inlineSecret.length > 0 ? '' : requestedSecretFile.length > 0 ? requestedSecretFile : previousConfig.secretFile,
      wantPort: Number.isInteger(activation.wantPort) && activation.wantPort > 0 ? activation.wantPort : previousConfig.wantPort,
    };
 // True idempotency: the requested target is already the healthy runtime one.
 // The secret may come from `secret` or `secretFile`, so resolve the current
 // config before deciding; a matching target must not churn the phone path.
    let previousSecretMatches = inlineSecret.length === 0;
    if (inlineSecret.length > 0) {
      if (previousConfig.secret === inlineSecret) {
        previousSecretMatches = true;
      } else if (typeof previousConfig.secretFile === 'string' && previousConfig.secretFile.length > 0) {
        try {
          const { resolveSecret } = await import('./tunnel.js');
          const resolved = resolveSecret({ secret: previousConfig.secret, secretFile: previousConfig.secretFile });
          previousSecretMatches = resolved?.secret === inlineSecret;
        } catch {
          previousSecretMatches = false;
        }
      }
    }
    if (previousHealth?.state === 'ready' && previousConfig.enabled === true && previousConfig.controlOrigin === controlOrigin && previousConfig.pin === pin && previousSecretMatches) {
      return { ok: true, state: 'ready', origin: previousHealth.origin ?? null, port: previousHealth.port ?? null, pin, unchanged: true, current: previousHealth };
    }
    const timeoutMs = Number.isInteger(activation.timeoutMs) ? Math.min(30_000, Math.max(1_000, activation.timeoutMs)) : 10_000;
    const stopCurrentTunnel = () => {
      try {
        this.tunnel?.dispose?.();
      } catch {
 /* already gone */
      }
      this.tunnel = undefined;
      this.tunnelEndpoint = undefined;
      this.endpoints = this.baseEndpoints.slice();
      this.deviceEndpoints = selectDeviceEndpoints(this.endpoints);
      try {
        this.pairing?.setTrust?.({ certs: this.certs, endpoints: this.deviceEndpoints });
      } catch {
 /* pairing may be unavailable during startup */
      }
      try {
        this.pairing?.setRelay?.(undefined);
      } catch {
 /* best effort */
      }
      try {
        this.bonjour?.update?.({ relay: '' });
      } catch {
 /* best effort */
      }
    };
    stopCurrentTunnel();
    this.config = { ...this.config, tunnel: tunnelConfig };
    const attempt = await this._startActivatedTunnel(tunnelConfig, timeoutMs);
    if (attempt.ok !== true && previousConfig.enabled === true) {
 // Fall back to the previous tunnel configuration so a bad activation does
 // not leave the phone path dead; report both states to the UI.
      stopCurrentTunnel();
      this.config = { ...this.config, tunnel: previousConfig };
      const restored = await this._startActivatedTunnel(previousConfig, timeoutMs);
      try {
        this.audit?.record('tunnel.activate', { ok: false, state: attempt.state, origin: controlOrigin, error: String(attempt.error ?? ''), rolledBack: restored.ok === true, restoredState: restored.state });
      } catch {
 /* audit best effort */
      }
      return {
        ok: false,
        state: attempt.state,
        origin: attempt.origin ?? controlOrigin,
        port: attempt.port ?? null,
        pin,
        error: attempt.error ?? 'activation failed',
        rolledBack: restored.ok === true,
        restoredState: restored.state,
        previousState: previousHealth?.state ?? null,
        current: this.tunnel?.health?.() ?? null,
      };
    }
    try {
      this.audit?.record('tunnel.activate', { ok: attempt.ok === true, state: attempt.state, origin: attempt.origin ?? controlOrigin, port: attempt.port ?? null, error: attempt.ok === true ? undefined : String(attempt.error ?? '') });
    } catch {
 /* audit best effort */
    }
    return { ...attempt, pin, current: this.tunnel?.health?.() ?? null };
  }

 /**
 * Start one TunnelClient and resolve on the first ready/error/timeout event.
 * Kept separate so unit tests can stub it (activateTunnel contract tests).
 *
 * @param {object} tunnelConfig
 * @param {number} timeoutMs
 */
  async _startActivatedTunnel(tunnelConfig, timeoutMs) {
    const { startTunnelClient } = await import('./tunnel.js');
    let settle;
    const firstEvent = new Promise((resolve) => {
      settle = resolve;
    });
    const tunnel = startTunnelClient({
      config: tunnelConfig,
      pluginPort: this.config.port,
      hostId: this.hostIdentity?.hostId,
      hostName: this.pairing?.hostName ?? this.hostname ?? 'Mac',
      pluginVersion: PLUGIN_VERSION,
      log,
      audit: this.audit,
      onReady: (ready) => {
        this.onTunnelReady(ready);
        settle({ event: 'ready', origin: ready?.origin ?? null, port: ready?.port ?? null });
      },
      onStateChange: (health) => {
        if (health?.state === 'error') settle({ event: 'error', state: health.state, origin: health.origin ?? null, port: health.port ?? null, error: health.lastError ?? 'tunnel error' });
        else if (health?.state === 'disabled') settle({ event: 'error', state: health.state, origin: null, port: null, error: 'tunnel disabled' });
      },
    });
    this.tunnel = tunnel;
    await tunnel.start();
    this.publishTunnelCode();
    let timer;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => resolve({ event: 'timeout', error: 'timeout after ' + String(timeoutMs) + 'ms' }), timeoutMs);
    });
    const outcome = await Promise.race([firstEvent, timeout]);
    clearTimeout(timer);
    const health = tunnel.health();
    const ok = outcome.event === 'ready';
    return {
      ok,
      state: ok ? 'ready' : 'error',
      origin: ok ? (outcome.origin ?? health.origin ?? null) : (health.origin ?? null),
      port: ok ? (outcome.port ?? health.port ?? null) : (health.port ?? null),
      error: ok ? undefined : String(outcome.error ?? health.lastError ?? 'activation failed'),
      since: health.since ?? null,
    };
  }

 /** Current runtime tunnel health (undefined when the tunnel was never started). */
  tunnelHealth() {
    return this.tunnel?.health?.() ?? null;
  }

 /** Merge the relay origin into the phone-visible endpoints after tunnel ready. */
  onTunnelReady({ origin, port }) {
    if (typeof origin !== 'string' || origin.length === 0) return;
    this.tunnelEndpoint = {
      url: origin.replace(/\/+$/, ''),
      kind: 'relay',
      pri: 100,
      trust: 'pinSpki',
      loopback: false,
      pin: this.certs?.caPin,
      leafPin: this.certs?.leafPin,
    };
    this.endpoints = [...this.baseEndpoints, this.tunnelEndpoint];
 // selectDeviceEndpoints keeps the loopback exclusion rule: with a relay
 // origin present the QR/health list is phone-visible only.
    this.deviceEndpoints = selectDeviceEndpoints(this.endpoints);
    this.pairing?.setTrust({ certs: this.certs, endpoints: this.deviceEndpoints });
    this.pairing?.setRelay({ origin: this.tunnelEndpoint.url, pin: this.config.tunnel.pin });
    log('tunnel: relay origin injected into endpoints: ' + this.tunnelEndpoint.url + (port ? ' (bridge port ' + String(port) + ')' : ''));
    this.audit?.record('tunnel.ready', { origin: this.tunnelEndpoint.url, port: port ?? null });
 // TXT `relay=<origin>` is dynamic (public origin appears after ready); the
 // `pair` capability marker stays fixed.
    try {
      this.bonjour?.update({ relay: this.tunnelEndpoint.url });
    } catch (error) {
      log('bonjour: relay TXT update failed: ' + String(error?.message ?? error));
    }
    this.publishTunnelCode();
    this.writeDebugPairPayload().catch((error) => log('debug pair payload write failed: ' + String(error?.message ?? error)));
  }

  async handleRequest(request, response) {
    const url = new URL(request.url ?? '/', 'https://link.invalid');
    const ip = request.socket?.remoteAddress ?? undefined;
    if (url.pathname === '/health' && request.method === 'GET') return sendJson(response, 200, this.health(ip));
    if (!this.ctxActive()) {
 // A zombie listener from a disposed HMR fiber: never touch the inactive
 // context again — answer 503 so the phone shows a host error, not a 500.
      this.counters.proxyErrors += 1;
      return sendJson(response, 503, {
        ok: false,
        error: 'host/inactive',
        message: 'the plugin context is inactive (HMR/restart in progress); retry after the host reloads the plugin',
      });
    }
    if (url.pathname === '/pair/redeem' && request.method === 'POST') return this.handlePairRedeem(request, response, ip);
    if (url.pathname === '/pair/code/redeem' && request.method === 'POST') return this.handlePairCodeRedeem(request, response, ip);
    if (url.pathname === '/auth/challenge' && request.method === 'POST') return this.handleAuthChallenge(request, response, ip);
    if (url.pathname === '/auth/verify' && request.method === 'POST') return this.handleAuthVerify(request, response, ip);
    if (url.pathname === '/devices/push-token' && request.method === 'POST') return this.handlePushToken(request, response, ip);
    if (url.pathname === SESSION_PERMISSION_PATH && request.method === 'POST') return this.handleSessionPermission(request, response, ip);
    if (url.pathname === '/debug/admin' && request.method === 'POST') return this.handleDebugAdmin(request, response, ip);
    if (this.isAllowedFetchRoute(url.pathname)) return this.handleFetchRoute(request, response, url, ip);
    if (ENDPOINT_RE.test(url.pathname)) {
      if (request.method !== 'POST') return sendText(response, 405, 'method not allowed');
      const authorized = this.authorizeApi(request, ip);
      if (authorized.device === undefined) {
        return sendJson(response, authorized.status ?? 401, { ok: false, error: authorized.error ?? 'auth/required', message: 'authenticate with POST /auth/challenge + /auth/verify first' });
      }
      return this.proxyUnary(authorized.device, request, response, url, ip);
    }
    if (url.pathname.startsWith('/api/')) {
      this.counters.fetchRouteDenied += 1;
      return sendJson(response, 404, {
        ok: false,
        error: 'route/not-allowed',
        message: 'GET exact-fetch route is not allowlisted by dsh-m-link',
        allowed: this.config.fetchRoutes.enabled === false ? [] : this.config.fetchRoutes.allow,
      });
    }
    return sendText(response, 404, 'not found');
  }

 /** True when a pathname is an exact-fetch route the phone may reach. */
  isAllowedFetchRoute(pathname) {
    if (this.config.fetchRoutes.enabled === false) return false;
    return this.config.fetchRoutes.allow.includes(pathname);
  }

 /**
 * Proxy one read-only exact-fetch route (GET/HEAD) with device auth.
 *
 * DSH serves a few non-RPC routes directly on its web server (file change
 * summary/diff, file bytes). iOS needs them for the file-change view, but a
 * generic HTTP proxy would let a paired phone reach arbitrary loopback
 * endpoints, so the proxy is restricted to an exact allowlist and read-only
 * methods. Auth is the same short-lived api bearer token as unary calls.
 */
  async handleFetchRoute(request, response, url, ip) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return sendText(response, 405, 'method not allowed (GET/HEAD only)');
    }
    const authorized = this.authorizeApi(request, ip);
    if (authorized.device === undefined) {
      return sendJson(response, authorized.status ?? 401, { ok: false, error: authorized.error ?? 'auth/required', message: 'authenticate with POST /auth/challenge + /auth/verify first' });
    }
    return this.proxyFetchRoute(authorized.device, request, response, url);
  }

  async proxyFetchRoute(device, request, response, url) {
    const peer = this.ensurePeer(device);
    if (peer.cookie === undefined) {
      try {
        await peer.connect('answer');
      } catch (error) {
        this.counters.proxyErrors += 1;
        this.audit.record('fetchroute.upstream-failed', { deviceId: device.deviceId, path: url.pathname, message: String(error?.message ?? error) });
        return sendJson(response, 502, { ok: false, error: 'upstream-connect-failed', message: String(error?.message ?? error) });
      }
    }
    const headers = { cookie: peer.cookie.name + '=' + peer.cookie.value };
    for (const name of ['accept', 'accept-language', 'if-none-match', 'if-modified-since', 'range']) {
      const value = request.headers[name];
      if (typeof value === 'string' && value.length > 0) headers[name] = value;
    }
    const target = this.loopbackOrigin + url.pathname + url.search;
    let upstream;
    try {
      upstream = await fetch(target, { method: 'GET', headers, redirect: 'manual' });
    } catch (error) {
      this.counters.proxyErrors += 1;
      this.audit.record('fetchroute.upstream-failed', { deviceId: device.deviceId, path: url.pathname, message: String(error?.message ?? error) });
      return sendJson(response, 502, { ok: false, error: 'upstream-unreachable', message: String(error?.message ?? error) });
    }
    const bytes = Buffer.from(await upstream.arrayBuffer());
    const passHeaders = {};
    for (const [name, value] of upstream.headers) {
      if (PASSTHROUGH_RESPONSE_HEADERS.has(name.toLowerCase())) passHeaders[name.toLowerCase()] = value;
    }
    passHeaders['content-length'] = String(bytes.length);
    passHeaders['cache-control'] = 'no-store';
    this.counters.proxiedFetch += 1;
    this.audit.record('fetchroute.proxied', { deviceId: device.deviceId, path: url.pathname, status: upstream.status, bytes: bytes.length });
    response.writeHead(upstream.status, passHeaders);
    if (request.method === 'HEAD') {
      response.end();
    } else {
      response.end(bytes);
    }
    return undefined;
  }

 /** Authenticate a unary API call with a short-lived api token. */
  authorizeApi(request, ip) {
    const token = parseBearer(request.headers.authorization);
    if (token === undefined) return { error: 'auth/required', status: 401 };
    const peeked = this.auth.peekToken(token, 'api');
    if (peeked.error !== undefined) {
      if (this.config.security.allowLegacyCredential) {
        const device = this.devices.findByCredential(token);
        if (device !== undefined && device.revokedAt === undefined) {
          this.audit.record('auth.legacy-credential', { deviceId: device.deviceId, ip });
          return { device };
        }
      }
      this.counters.authFailed += 1;
      return { error: peeked.error, status: 401 };
    }
    return { device: peeked.device };
  }

 /** Rate-limit unauthenticated pairing attempts per client IP. */
  pairRateLimited(ip) {
    const now = Date.now();
    const record = this.pairAttempts.get(ip ?? 'unknown');
    if (record === undefined || now - record.windowStart > 5 * 60_000) {
      this.pairAttempts.set(ip ?? 'unknown', { windowStart: now, count: 1 });
      return false;
    }
    record.count += 1;
    return record.count > 10;
  }

 /**
 * Rate-limit POST /pair/code/redeem per client IP (design §5.1: isolated
 * default 10/min, config pairCodeRateLimitPerMin). A separate map from the QR
 * token limiter so the two pairing channels cannot starve each other; the
 * per-code dimension is the 5-wrong-attempts lock in PairCodeService.
 */
  pairCodeRateLimited(ip) {
    const key = ip ?? 'unknown';
    const now = Date.now();
    const record = this.pairCodeAttempts.get(key);
    if (record === undefined || now - record.windowStart > 60_000) {
      this.pairCodeAttempts.set(key, { windowStart: now, count: 1 });
      return false;
    }
    record.count += 1;
    return record.count > this.config.pairCodeRateLimitPerMin;
  }

  challengeRateLimited(ip) {
    const now = Date.now();
    const record = this.challengeAttempts.get(ip ?? 'unknown');
    if (record === undefined || now - record.windowStart > 60_000) {
      this.challengeAttempts.set(ip ?? 'unknown', { windowStart: now, count: 1 });
      return false;
    }
    record.count += 1;
    return record.count > 60;
  }

 /** Auth descriptor shared by both pairing channels (design §5.2: same auth). */
  authDescriptor() {
    return {
      challengePath: '/auth/challenge',
      verifyPath: '/auth/verify',
      algorithm: 'ECDSA-P256-SHA256',
      messageEncoding: 'utf8',
      signatureFormat: 'der-base64url',
      purposes: ['api', 'mux'],
      apiTokenTtlMs: this.config.security.apiTokenTtlMs,
      muxTokenTtlMs: this.config.security.muxTokenTtlMs,
    };
  }

 /**
 * Shared "create device + connect its upstream peer" path used by both
 * /pair/redeem and /pair/code/redeem (design §5.2). Returns {status, body} so
 * the caller only sends the response; a failed upstream connect never leaves
 * a half-created device behind.
 */
  async completeRedeem({ name, publicKey, platform, ip, includePayload = false }) {
    const credential = randomBytes(32).toString('base64url');
    const device = this.devices.create({
      name,
      publicKey,
      platform,
      credential,
      ip,
    });
    device.downstream = undefined;
    device.idleTimer = undefined;
    try {
      await this.ensurePeer(device).connect('answer');
    } catch (error) {
      this.devices.remove(device.deviceId);
      this.counters.pairRejected += 1;
      if (error?.code === 'ctx-inactive' || !this.ctxActive()) {
        this.audit.record('pair.inactive-context', { deviceId: device.deviceId, ip });
        return { status: 503, body: { ok: false, error: 'host/inactive', message: 'the plugin context is inactive (HMR/restart in progress)' } };
      }
      this.audit.record('pair.upstream-failed', { deviceId: device.deviceId, message: String(error?.message ?? error), ip });
      return { status: 502, body: { ok: false, error: 'upstream-connect-failed', message: String(error?.message ?? error) } };
    }
    this.counters.redeemed += 1;
 // 同一把设备公钥/同一 push token 的旧记录会在重装/重新配对时残留为多条 active 设备；
 // 推送是按设备逐条发送的，重复记录会让同一条通知弹 N 次。
 // 配对成功即撤销旧重复记录，只保留本次这条。
    const deduped = this.revokeDuplicateDevices(device);
    this.audit.record('pair.redeemed', { deviceId: device.deviceId, keyId: device.keyId, name: device.name, platform: device.platform, ip, deduped });
    log('pair/redeem ok: device ' + device.deviceId + ' (' + device.name + ', key ' + String(device.keyId).slice(0, 12) + '…)');
    if (this.config.debug.reissuePairToken) {
      this.pairing.refresh('debug-reissue');
      await this.writeDebugPairPayload();
    }
    const body = {
      ok: true,
      deviceId: device.deviceId,
      deviceName: device.name,
      keyId: device.keyId,
      credential,
      proto: PROTOCOL,
      server: {
        plugin: PLUGIN_NAME,
        version: PLUGIN_VERSION,
        hostId: this.hostIdentity.hostId,
        hostName: this.config.hostName,
      },
      tls: { caPin: this.certs.caPin, leafPin: this.certs.leafPin },
      auth: this.authDescriptor(),
 // P1: the pair response is the first place a phone can cache resume
 // tickets (design §4.3), so its cold start skips challenge/verify. Two
 // tickets cover a lost first `welcome`; the field is omitted entirely
 // when the flag is off (M1/M2 response stays byte-identical).
      ...(this.config.features.muxRpc === true
        ? { connectTickets: [this.mintP1Ticket(device), this.mintP1Ticket(device)] }
        : {}),
    };
    if (includePayload) {
 // The code channel additionally returns the full signed payload +
 // payloadText so the phone can do the §5.3 pin-consistency check and
 // Ed25519 verification (LAN TOFU flow). /pair/redeem keeps the exact M1
 // shape (backward compatible: fields added, none changed).
      body.tls = {
 // C scheme: expose the public CA certificate on the code channel too, so
 // the 8-digit-code pairing flow can pin the CA as its trust anchor.
        caCert: this.certs.caCertDerBase64,
        caPin: this.certs.caPin,
        leafPin: this.certs.leafPin,
        caFingerprint256: this.certs.caFingerprint256,
        leafFingerprint256: this.certs.leafFingerprint256,
      };
      body.payload = this.pairing.payload();
      body.payloadText = this.pairing.payloadText();
    }
    return { status: 200, body };
  }

  async handlePairRedeem(request, response, ip) {
    const notReady = this.readinessError();
    if (notReady !== undefined) {
      return sendJson(response, notReady.status ?? 503, { ok: false, error: notReady.code, message: notReady.message });
    }
    if (this.pairRateLimited(ip)) return sendJson(response, 429, { ok: false, error: 'pair/rate-limited' });
    let body;
    try {
      body = await readJson(request);
    } catch {
      this.counters.pairRejected += 1;
      return sendJson(response, 400, { ok: false, error: 'bad-request', message: 'body must be JSON' });
    }
    const redeemed = this.pairing.redeem({
      pairToken: body?.pairToken,
      devicePubKey: body?.devicePubKey,
      deviceName: body?.deviceName,
      platform: body?.platform,
    });
    if (redeemed.error !== undefined) {
      this.counters.pairRejected += 1;
      this.audit.record('pair.rejected', { reason: redeemed.error, ip });
      const status = redeemed.error === 'pair/expired' ? 410 : 401;
      return sendJson(response, status, { ok: false, error: redeemed.error, message: redeemed.message });
    }
    const result = await this.completeRedeem({ name: redeemed.name, publicKey: redeemed.publicKey, platform: redeemed.platform, ip });
    return sendJson(response, result.status, result.body);
  }

 /**
 * POST /pair/code/redeem — M2a 8-digit code pairing (design §5.2).
 *
 * body: {"code":"12345678","devicePubKey":"<P-256 SPKI b64url>",
 * "deviceName":"iPhone","platform":"ios"}
 * 200 / 401 code/invalid (+remaining) / 410 code/expired / 423 code/locked /
 * 429 code/rate-limited / 503 host/*.
 *
 * Order: rate limit -> JSON -> code (constant-time, wrong key must not consume
 * the code) -> device key -> consume -> shared device/upstream path.
 */
  async handlePairCodeRedeem(request, response, ip) {
    const notReady = this.readinessError();
    if (notReady !== undefined) {
      return sendJson(response, notReady.status ?? 503, { ok: false, error: notReady.code, message: notReady.message });
    }
    if (this.pairCodeRateLimited(ip)) return sendJson(response, 429, { ok: false, error: 'code/rate-limited' });
    let body;
    try {
      body = await readJson(request);
    } catch {
      this.counters.pairCodeRejected += 1;
      return sendJson(response, 400, { ok: false, error: 'bad-request', message: 'body must be JSON' });
    }
    const checked = this.pairCode.check(body?.code, { ip });
    if (checked.error !== undefined) {
      this.counters.pairCodeRejected += 1;
      const status = checked.error === 'code/expired' ? 410 : checked.error === 'code/locked' ? 423 : 401;
      return sendJson(response, status, { ok: false, error: checked.error, ...(checked.remaining === undefined ? {} : { remaining: checked.remaining }) });
    }
    let publicKey;
    try {
      publicKey = normalizeDevicePublicKey(body?.devicePubKey);
    } catch (error) {
 // A malformed device key must not burn the user's 5 attempts (the code is
 // only consumed after this point).
      this.counters.pairCodeRejected += 1;
      log('pair/code/redeem rejected: invalid device key: ' + String(error?.message ?? error));
      return sendJson(response, 401, { ok: false, error: 'pair/invalid-key', message: String(error?.message ?? error) });
    }
    this.pairCode.consume();
    const result = await this.completeRedeem({
      name: trimDeviceName(body?.deviceName, 'iOS device'),
      publicKey,
      platform: typeof body?.platform === 'string' ? body.platform.slice(0, 32) : 'ios',
      ip,
      includePayload: true,
    });
    if (result.status === 200) {
      this.audit.record('pair.code.redeemed', { deviceId: result.body.deviceId, ip });
    }
    return sendJson(response, result.status, result.body);
  }

  async handleAuthChallenge(request, response, ip) {
    const notReady = this.readinessError();
    if (notReady !== undefined) return sendJson(response, notReady.status ?? 503, { ok: false, error: notReady.code, message: notReady.message });
    if (this.challengeRateLimited(ip)) return sendJson(response, 429, { ok: false, error: 'auth/rate-limited' });
    let body;
    try {
      body = await readJson(request);
    } catch {
      return sendJson(response, 400, { ok: false, error: 'auth/bad-request' });
    }
    const credential = parseBearer(request.headers.authorization);
    if (credential === undefined) return sendJson(response, 401, { ok: false, error: 'auth/required' });
    const issued = this.auth.issueChallenge({ credential, purpose: body?.purpose ?? 'api', ip });
    if (issued.error !== undefined) {
      this.counters.authFailed += 1;
      return sendJson(response, issued.error === 'auth/rate-limited' ? 429 : 401, { ok: false, error: issued.error });
    }
    const challenge = issued.challenge;
    return sendJson(response, 200, {
      ok: true,
      challengeId: challenge.challengeId,
      nonce: challenge.nonce,
      purpose: challenge.purpose,
      deviceId: challenge.deviceId,
      issuedAt: challenge.issuedAt,
      expiresAt: challenge.expiresAt,
      message: challenge.message,
      algorithm: 'ECDSA-P256-SHA256',
      messageEncoding: 'utf8',
      signatureFormat: 'der-base64url',
    });
  }

  async handleAuthVerify(request, response, ip) {
    const notReady = this.readinessError();
    if (notReady !== undefined) return sendJson(response, notReady.status ?? 503, { ok: false, error: notReady.code, message: notReady.message });
    let body;
    try {
      body = await readJson(request);
    } catch {
      return sendJson(response, 400, { ok: false, error: 'auth/bad-request' });
    }
    const verified = this.auth.verifyChallenge({ challengeId: body?.challengeId, signature: body?.signature, ip });
    if (verified.error !== undefined) {
      this.counters.authFailed += 1;
      return sendJson(response, verified.error === 'auth/rate-limited' ? 429 : 401, { ok: false, error: verified.error });
    }
    this.counters.authOk += 1;
    return sendJson(response, 200, {
      ok: true,
      token: verified.token.token,
      tokenType: 'Bearer',
      purpose: verified.token.purpose,
      expiresAt: verified.token.expiresAt,
      deviceId: verified.token.deviceId,
      serverTime: Date.now(),
    });
  }

  async handlePushToken(request, response, ip) {
    const authorized = this.authorizeApi(request, ip);
    if (authorized.device === undefined) return sendJson(response, 401, { ok: false, error: authorized.error ?? 'auth/required' });
    let body;
    try {
      body = await readJson(request);
    } catch {
      return sendJson(response, 400, { ok: false, error: 'bad-request' });
    }
 // iOS may use either "deviceToken" (Apple's term) or "token"; both mean the
 // 64-hex APNs registration token. Accept only hex so a pasted payload can
 // never smuggle arbitrary text into the registry.
    const rawToken = typeof body?.deviceToken === 'string' ? body.deviceToken : typeof body?.token === 'string' ? body.token : '';
    const token = rawToken.trim();
    if (!/^[0-9a-fA-F]{64,256}$/.test(token)) {
      return sendJson(response, 400, {
        ok: false,
        error: 'push-token-invalid',
        message: 'deviceToken must be 64-256 hex characters (APNs registration token)',
      });
    }
    const environment = body?.environment === 'sandbox' || body?.environment === 'production' ? body.environment : undefined;
    if (body?.environment !== undefined && environment === undefined) {
      return sendJson(response, 400, { ok: false, error: 'push-environment-invalid', message: 'environment must be sandbox or production' });
    }
    const device = authorized.device;
    let renamed = false;
    if (typeof body?.name === 'string' && body.name.trim().length > 0) {
      const name = body.name.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 64);
      if (name.length > 0 && name !== device.name) {
        device.name = name;
        renamed = true;
      }
    }
    this.devices.setPushToken(device.deviceId, token, environment);
 // task-5: a newly push-capable device starts the host-side turn watcher.
    this.syncSessionWatcher();
    const fingerprint = tokenFingerprint(token);
    this.audit.record('device.push-token', {
      deviceId: device.deviceId,
      tokenFingerprint: fingerprint,
      environment,
      renamed,
 // Never the token itself: only the short fingerprint goes to the audit.
    });
    return sendJson(response, 200, {
      ok: true,
      deviceId: device.deviceId,
      mode: this.apns.mode,
      environment: environment ?? this.apns.environment,
      topic: this.apns.topic ?? null,
      tokenFingerprint: fingerprint,
      renamed,
    });
  }

 // ------------------------------------------------ M5 session permission ---

 /**
 * `POST /session/permission` — switch one session's permission preset from the
 * phone. Device-authenticated like the unary proxy; the actual write is
 * delegated to the host `permissionPresets` service (see
 * lib/session-permission.js for why this cannot ride the Remote protocol).
 */
  async handleSessionPermission(request, response, ip) {
    const authorized = this.authorizeApi(request, ip);
    if (authorized.device === undefined) {
      return sendJson(response, authorized.status ?? 401, {
        ok: false,
        error: authorized.error ?? 'auth/required',
        message: 'authenticate with POST /auth/challenge + /auth/verify first',
      });
    }
    let body;
    try {
      body = await readJson(request);
    } catch {
      return sendJson(response, 400, { ok: false, error: 'permission/bad-request', message: 'body must be JSON' });
    }
    const normalized = normalizePermissionRequest(body);
    if (normalized.error !== undefined) {
      return sendJson(response, normalized.status, { ok: false, error: normalized.error, message: normalized.message });
    }
    if (!this.ctxActive()) {
      return sendJson(response, 503, {
        ok: false,
        error: 'host/inactive',
        message: 'the plugin context is inactive (HMR/restart in progress); retry after the host reloads the plugin',
      });
    }
    const result = applySessionPermission({ ctx: this.ctx, sessionId: normalized.sessionId, preset: normalized.preset });
    if (result.ok) {
      this.audit.record('permission.set', {
        deviceId: authorized.device.deviceId,
        sessionId: result.sessionId,
        preset: result.preset,
        previous: result.previous,
      });
      return sendJson(response, 200, result);
    }
    this.audit.record('permission.rejected', {
      deviceId: authorized.device.deviceId,
      sessionId: normalized.sessionId,
      preset: normalized.preset,
      error: result.error,
    });
    return sendJson(response, result.status, result);
  }

 // ------------------------------------------------------------ P1.5 lite list ---

 /** P1.5-A: the lite `session/list` trim is allowed unless explicitly disabled. */
  listLiteEnabled() {
    return this.config.features.listLite !== false;
  }

 /**
 * Inspect one unary request for the opt-in lite signal (per request, no state).
 * Old clients never send a signal, so their path never reaches the trimmer.
 */
  planListLite(endpoint, headers, bodyText) {
    if (!this.listLiteEnabled()) return { lite: false };
    return detectListLiteRequest({ endpoint, headers, bodyText });
  }

 /** Counters + audit for one trimmed `session/list` response (metadata only). */
  recordListLite(device, endpoint, transport, plan, stats) {
    this.counters.listLiteResponses += 1;
    this.counters.listLiteFullBytes += stats.fullBytes;
    this.counters.listLiteBytes += stats.liteBytes;
    this.audit.record('unary.list-lite', {
      deviceId: device.deviceId,
      endpoint,
      transport,
      source: plan.source,
      items: stats.items,
      fullBytes: stats.fullBytes,
      liteBytes: stats.liteBytes,
      savedRatio: stats.savedRatio,
    });
  }

 /** Trim one response body when the request opted in; otherwise pass through. */
  applyListLite(device, endpoint, transport, plan, bytes) {
    if (plan.lite !== true) return { bytes, stats: undefined };
    const trimmed = trimSessionListResponse(bytes);
 // Not a successful `session/list` envelope: never rewrite it, so an upstream
 // error body or a future protocol change reaches the phone untouched.
    if (trimmed === undefined) return { bytes, stats: undefined };
    this.recordListLite(device, endpoint, transport, plan, trimmed.stats);
    return { bytes: trimmed.bytes, stats: trimmed.stats };
  }

 /**
 * Transparent unary proxy: byte-for-byte body, only transport headers touched.
 *
 * P1.5-A exception, opt-in only: when the request carries the lite signal
 * (`x-dshm-list-lite: 1` header or the `_request.listMode=lite` body hint for
 * `session/list`), the projection block is trimmed and the body hint is
 * stripped before the upstream call (see lib/list-lite.js). No signal =>
 * the upstream request and response bytes are exactly the legacy bytes.
 */
  async proxyUnary(device, request, response, url, ip) {
    let peer;
    try {
      peer = this.ensurePeer(device);
    } catch (error) {
      if (error?.code === 'ctx-inactive') return sendJson(response, 503, { ok: false, error: 'host/inactive', message: String(error.message) });
      return sendJson(response, 500, { ok: false, error: 'internal', message: String(error?.message ?? error) });
    }
    if (peer.cookie === undefined) {
      try {
        await peer.connect('answer');
      } catch (error) {
        this.counters.proxyErrors += 1;
        this.audit.record('unary.upstream-failed', { deviceId: device.deviceId, endpoint: url.pathname, message: String(error?.message ?? error) });
        return sendJson(response, 502, { ok: false, error: 'upstream-connect-failed', message: String(error?.message ?? error) });
      }
    }
    const contentType = request.headers['content-type'];
    if (typeof contentType !== 'string' || !contentType.toLowerCase().startsWith('application/json')) {
      return sendText(response, 415, 'content type must be application/json');
    }
    const body = await readBody(request);
 // P1.5-A: the frozen iOS transport cannot attach headers, so the current App
 // sends the opt-in inside the legacy-shaped envelope; strip it here so the
 // upstream DSH request is byte-identical to the pre-lite request.
    const listLitePlan = this.planListLite(url.pathname, request.headers, body.toString('utf8'));
    const upstreamBody = listLitePlan.bodyText === undefined ? body : Buffer.from(listLitePlan.bodyText, 'utf8');
    const target = this.loopbackOrigin + url.pathname + url.search;
    const headers = { 'content-type': contentType, cookie: peer.cookie.name + '=' + peer.cookie.value };
    const accept = request.headers.accept;
    if (typeof accept === 'string' && accept.length > 0) headers.accept = accept;
    let upstream;
    try {
      upstream = await fetch(target, { method: 'POST', headers, body: upstreamBody, redirect: 'manual' });
    } catch (error) {
      this.counters.proxyErrors += 1;
      this.audit.record('unary.upstream-failed', { deviceId: device.deviceId, endpoint: url.pathname, message: String(error?.message ?? error) });
      return sendJson(response, 502, { ok: false, error: 'upstream-unreachable', message: String(error?.message ?? error) });
    }
    const fullBytes = Buffer.from(await upstream.arrayBuffer());
    this.counters.proxiedUnary += 1;
    const listLite = this.applyListLite(device, url.pathname, 'legacy', listLitePlan, fullBytes);
    const bytes = listLite.bytes;
    const outHeaders = {
      'content-type': upstream.headers.get('content-type') ?? 'application/octet-stream',
      'content-length': String(bytes.length),
      'cache-control': 'no-store',
    };
 // Tell the caller (and the bench parser) that the projection was trimmed.
 // Only lite responses get the marker; the legacy response headers are
 // byte-for-byte unchanged.
    if (listLite.stats !== undefined) outHeaders[LIST_LITE_HEADER] = '1';
 // M2b: gzip large unary JSON responses for the phone (M2b §3.3 candidate 4).
 // Only this buffered unary proxy body is compressed: the mux/chunked stream
 // path and exact-fetch routes are untouched. `Vary` is required on every
 // response of a negotiable resource, including the uncompressed fallback.
 // (Node's fetch already inflated any upstream encoding, so `bytes` is plain
 // JSON and it is compressed at most once here.)
    const compression = this.config.compression;
    const isJson = String(outHeaders['content-type']).toLowerCase().includes('json');
    if (compression.enabled !== false && isJson && bytes.length >= compression.minBytes) {
      outHeaders.vary = 'accept-encoding';
      const acceptEncoding = request.headers['accept-encoding'];
      if (typeof acceptEncoding === 'string' && /\bgzip\b/i.test(acceptEncoding)) {
        const compressed = gzipSync(bytes, { level: 6 });
        outHeaders['content-encoding'] = 'gzip';
        outHeaders['content-length'] = String(compressed.length);
        this.audit.record('unary.compressed', {
          deviceId: device.deviceId,
          endpoint: url.pathname,
          bytes: bytes.length,
          compressedBytes: compressed.length,
        });
        response.writeHead(upstream.status, outHeaders);
        response.end(compressed);
        return undefined;
      }
    }
    response.writeHead(upstream.status, outHeaders);
    response.end(bytes);
    return undefined;
  }

 /**
 * 同一设备的 mux 冲突处理。
 *
 * 旧连接**静默**超过 `MUX_TAKEOVER_STALE_MS`（网络切换后 socket 仍显示
 * ESTABLISHED，但手机已经放弃它）→ 由新连接接管：清掉 device.downstream、
 * 用 4409 关掉旧 socket，让新 upgrade 继续。活跃连接 → 仍 409 拒绝。
 *
 * @returns {boolean} true = 已接管/无冲突，可以继续升级；false = 应 409 拒绝
 */
  tryTakeOverStaleDownstream(device) {
    const existing = device.downstream;
    if (existing === undefined) return true;
    const lastActivity = Number(device.lastDownstreamActivityAt) || 0;
    const silentMs = Date.now() - lastActivity;
    if (silentMs < MUX_TAKEOVER_STALE_MS) return false;
    this.counters.muxTakeovers += 1;
    device.downstream = undefined;
    device.lastDownstreamActivityAt = 0;
    log('device ' + device.deviceId + ': stale downstream mux taken over (silent ' + String(silentMs) + 'ms)');
    this.audit.record('conn.takeover', { deviceId: device.deviceId, silentMs });
    try {
      existing.close(4409, 'session takeover');
    } catch {
 /* already gone */
    }
    return true;
  }

  handleUpgrade(request, socket, head) {
    let url;
    try {
      url = new URL(request.url ?? '/', 'https://link.invalid');
    } catch {
      return rejectUpgrade(socket, 400, 'Bad Request');
    }
    if (url.pathname !== MUX_PATH) return rejectUpgrade(socket, 404, 'Not Found');
    const notReady = this.readinessError();
    if (notReady !== undefined) return rejectUpgrade(socket, 503, 'Host Not Ready', { 'x-dshm-error': notReady.code });
 // P1 dual-stack: only clients that opt in with?proto=2 enter the new path.
 // Every other client keeps the M1 authenticated upgrade + byte bridge below.
    if (this.config.features.muxRpc === true && url.searchParams.get('proto') === '2') {
      return this.handleP1Upgrade(request, socket, head);
    }
    const token = parseBearer(request.headers.authorization);
    if (token === undefined) {
      this.counters.muxRejected401 += 1;
      return rejectUpgrade(socket, 401, 'Unauthorized', { 'x-dshm-error': 'auth/required' });
    }
    const consumed = this.auth.consumeMuxToken(token);
    if (consumed.error !== undefined) {
      this.counters.muxRejected401 += 1;
      this.audit.record('conn.rejected', { reason: consumed.error });
      return rejectUpgrade(socket, 401, 'Unauthorized', { 'x-dshm-error': consumed.error });
    }
    const device = consumed.device;
    if (!this.tryTakeOverStaleDownstream(device)) {
      this.counters.muxRejected409 += 1;
      log('device ' + device.deviceId + ': second downstream mux rejected with 409 (one socket per device)');
      return rejectUpgrade(socket, 409, 'Conflict', { 'x-dshm-error': 'conn/conflict' });
    }
    return this.wss.handleUpgrade(request, socket, head, (ws) => this.attachDownstream(device, ws));
  }

 /**
 * P1 upgrade: the WSS is accepted first and the phone authenticates in-band
 * with the first-frame `hello` (either a one-time mux token or a resume
 * ticket). The anonymous branch never binds resources beyond one socket and
 * a `muxRpcHelloTimeoutMs` timer; the device/upstream are only attached after
 * the hello verifies.
 */
  handleP1Upgrade(request, socket, head) {
    const token = parseBearer(request.headers.authorization);
    if (token === undefined) {
      if (this.p1Pending.size >= this.config.features.muxRpcMaxPendingUpgrades) {
        this.counters.p1Rejected += 1;
        return rejectUpgrade(socket, 503, 'Busy', { 'x-dshm-error': 'p1/too-many-pending' });
      }
      this.counters.p1Upgrades += 1;
      return this.wss.handleUpgrade(request, socket, head, (ws) => this.attachP1Downstream(undefined, ws));
    }
    const consumed = this.auth.consumeMuxToken(token);
    if (consumed.error !== undefined) {
      this.counters.muxRejected401 += 1;
      this.counters.p1Rejected += 1;
      this.audit.record('conn.rejected', { reason: consumed.error, proto: 'dsh-m/2' });
      return rejectUpgrade(socket, 401, 'Unauthorized', { 'x-dshm-error': consumed.error });
    }
    const device = consumed.device;
    if (!this.tryTakeOverStaleDownstream(device)) {
      this.counters.muxRejected409 += 1;
      this.counters.p1Rejected += 1;
      log('device ' + device.deviceId + ': second downstream mux rejected with 409 (one socket per device)');
      return rejectUpgrade(socket, 409, 'Conflict', { 'x-dshm-error': 'conn/conflict' });
    }
    this.counters.p1Upgrades += 1;
    return this.wss.handleUpgrade(request, socket, head, (ws) => this.attachP1Downstream(device, ws));
  }

 /**
 * Frame-level 1:1 bridge between the phone mux and the device's upstream mux.
 *
 * The upstream socket is opened asynchronously, but the phone may already
 * send frames right after its WSS handshake (e.g. the first stream open).
 * Those frames are buffered here and flushed once the upstream is ready;
 * dropping them would silently lose the first stream (M0 architectural fix,
 * kept regression-tested by test/m1-sim.mjs).
 */
  attachDownstream(device, downstream) {
    clearTimeout(device.idleTimer);
    device.idleTimer = undefined;
 // 静默判定基线（takeover 依赖它）：从 attach 起算，之后每条来自手机的帧刷新。
    device.lastDownstreamActivityAt = Date.now();
    let peer;
    try {
      peer = this.ensurePeer(device);
    } catch (error) {
      log('device ' + device.deviceId + ': refusing mux, context inactive: ' + String(error?.message ?? error));
      try {
        downstream.close(1011, 'host inactive');
      } catch {
 /* already gone */
      }
      return;
    }
 /** @type {Array<[unknown, boolean]>} */
    const pendingDownstream = [];
 /** @type {Array<[unknown, boolean]>} */
    const pendingUpstream = [];
    let bridged = false;
    let upstream;
 // Bug1: debug-gated frame observation for the legacy (M1) byte bridge.
    const frameAudit = this.frameAudit;
    const onDownstreamMessage = (data, isBinary) => {
      device.lastDownstreamActivityAt = Date.now();
      if (frameAudit !== undefined) frameAudit.fromDevice(device.deviceId, data, isBinary);
 // task-2: learn the stream -> session map so turn-end pushes carry a deep link.
      this.notifier?.observeDevice?.(device, data, isBinary);
      if (bridged) {
        if (upstream.readyState === 1) {
          if (frameAudit !== undefined) frameAudit.toUpstream(device.deviceId, data, isBinary);
          upstream.send(data, { binary: isBinary });
        }
      } else {
        pendingDownstream.push([data, isBinary]);
      }
    };
    const onUpstreamMessage = (data, isBinary) => {
      if (bridged) {
        if (downstream.readyState === 1) downstream.send(data, { binary: isBinary });
      } else {
        pendingUpstream.push([data, isBinary]);
      }
    };
    const onUpstreamClose = () => {
      if (bridged && downstream.readyState === 1) downstream.close(1011, 'upstream mux closed');
      if (device.downstream === downstream) device.downstream = undefined;
      peer.ws = undefined;
    };
    const onUpstreamError = () => {};
    downstream.on('message', onDownstreamMessage);
    downstream.on('error', () => {});
    downstream.once('close', () => {
      downstream.off('message', onDownstreamMessage);
      if (device.downstream === downstream) {
        device.downstream = undefined;
        device.lastDownstreamActivityAt = 0;
      }
      if (upstream !== undefined) {
        upstream.off('message', onUpstreamMessage);
        upstream.off('close', onUpstreamClose);
        upstream.off('error', onUpstreamError);
      }
      this.audit.record('conn.closed', { deviceId: device.deviceId });
      this.scheduleUpstreamIdle(device);
    });
    (async () => {
      try {
        upstream = await peer.ensureMux();
      } catch (error) {
        log('device ' + device.deviceId + ': cannot open upstream mux: ' + String(error?.message ?? error));
        this.audit.record('conn.upstream-unavailable', { deviceId: device.deviceId, message: String(error?.message ?? error) });
        try {
          downstream.close(1011, 'upstream unavailable');
        } catch {
 /* already gone */
        }
        return;
      }
      upstream.on('message', onUpstreamMessage);
      upstream.once('close', onUpstreamClose);
      upstream.on('error', onUpstreamError);
      device.downstream = downstream;
      this.counters.muxOpened += 1;
      this.audit.record('conn.open', { deviceId: device.deviceId });
      log('device ' + device.deviceId + ': downstream mux bridged');
      bridged = true;
      if (downstream.readyState === 1) {
        for (const [data, isBinary] of pendingDownstream.splice(0)) {
          if (frameAudit !== undefined) frameAudit.toUpstream(device.deviceId, data, isBinary);
          upstream.send(data, { binary: isBinary });
        }
        for (const [data, isBinary] of pendingUpstream.splice(0)) downstream.send(data, { binary: isBinary });
      } else {
        pendingDownstream.length = 0;
        pendingUpstream.length = 0;
      }
    })().catch((error) => log('attachDownstream failed: ' + (error?.stack ?? String(error))));
  }

 // ----------------------------------------------------------------- P1 WSS ---
 //
 // P1 (<internal-doc>): one pinned WSS carries
 // unary RPC + upstream streams. The legacy path above stays byte-identical;
 // this section is only reachable when `features.muxRpc` is on AND the client
 // asked for `?proto=2`.

 /**
 * Accept a P1 downstream socket.
 *
 * Two shapes:
 * - `deviceHint` known (upgrade carried a one-time mux token): bind at once,
 * the first frame is still `hello` for negotiation/resume;
 * - `deviceHint` undefined (in-band auth): hold the socket for at most
 * `muxRpcHelloTimeoutMs`, then resolve the device from `hello.auth`
 * (resume ticket or one-time mux token) before touching upstream state.
 *
 * The phone may pipeline `open`/`rpc` frames right behind `hello`; they are
 * buffered by the channel until the upstream mux is attached.
 */
  attachP1Downstream(deviceHint, downstream) {
    let device = deviceHint;
    let channel;
    let helloSeen = false;
 // task-11 E2E: one-shot hello delay for the next reconnect (debug action
 // `p1.drop`); consumed here so only this socket is affected.
    let helloHoldMs = Number(this.p1NextHelloHoldMs) > 0 ? Number(this.p1NextHelloHoldMs) : 0;
    this.p1NextHelloHoldMs = 0;
 /** @type {{downstream: unknown, timer: ReturnType<typeof setTimeout>} | undefined} */
    let pendingEntry;
 // Bug1: debug-gated observation of every plugin->phone frame (welcome /
 // pong / rpc result / sequenced `down` envelopes), recorded just before
 // the socket write so `sent:false` means "replay log only, phone away".
    const frameAudit = this.frameAudit;
    const send = (text) => {
      const delivered = downstream.readyState === 1;
      if (frameAudit !== undefined) frameAudit.toDevice(device?.deviceId, text, delivered);
      if (delivered) downstream.send(text);
    };
    const close = (code, reason) => {
      try {
        downstream.close(code, String(reason ?? '').slice(0, 120));
      } catch {
 /* already gone */
      }
    };
    const settlePending = () => {
      if (pendingEntry === undefined) return;
      clearTimeout(pendingEntry.timer);
      this.p1Pending.delete(pendingEntry);
      pendingEntry = undefined;
    };
    if (device === undefined) {
      pendingEntry = {
        downstream,
        timer: setTimeout(() => {
          this.p1Pending.delete(pendingEntry);
          this.counters.p1Rejected += 1;
          this.audit.record('p1.hello-timeout', {});
          close(4408, 'hello timeout');
        }, this.config.features.muxRpcHelloTimeoutMs),
      };
      this.p1Pending.add(pendingEntry);
      if (typeof pendingEntry.timer.unref === 'function') pendingEntry.timer.unref();
    }
    const onMessage = (data, isBinary) => {
 // Bug1: every frame the phone sends lands here exactly once (the first
 // `hello` included; the device is still unknown at that point).
      if (device !== undefined && device.downstream === downstream) {
        device.lastDownstreamActivityAt = Date.now();
      }
      if (frameAudit !== undefined) frameAudit.fromDevice(device?.deviceId, data, isBinary);
      if (isBinary === true) {
        this.counters.p1ProtocolErrors += 1;
        settlePending();
        close(1003, 'text frames required');
        return;
      }
      const text = typeof data === 'string' ? data : Buffer.from(data).toString('utf8');
      if (channel !== undefined) {
        channel.handleClient(text);
        return;
      }
      if (helloSeen === true) {
        close(4408, 'hello required');
        return;
      }
      let hello;
      try {
        hello = JSON.parse(text);
      } catch {
        hello = undefined;
      }
      if (hello === null || typeof hello !== 'object' || Array.isArray(hello) || hello.type !== 'hello') {
        this.counters.p1ProtocolErrors += 1;
        settlePending();
        close(4408, 'hello required');
        return;
      }
      helloSeen = true;
      const beginHello = () => {
        if (device === undefined) {
          const resolved = this.resolveP1HelloAuth(hello);
          if (resolved.error !== undefined) {
            this.counters.p1Rejected += 1;
            this.counters.muxRejected401 += 1;
            this.audit.record('p1.rejected', { reason: resolved.error });
            settlePending();
            close(4401, resolved.error);
            return;
          }
          device = resolved.device;
          settlePending();
        }
        if (device.downstream !== undefined) {
          if (!this.tryTakeOverStaleDownstream(device)) {
            this.counters.p1Rejected += 1;
            this.audit.record('p1.rejected', { deviceId: device.deviceId, reason: 'conn/conflict' });
            close(4409, 'conn/conflict');
            return;
          }
        }
        try {
          channel = this.openP1Channel(device, downstream, send, close);
        } catch (error) {
 // A racing reconnect/duplicate hello must not escape the socket handler
 // (EventEmitter would treat it as an uncaught exception); fail closed.
          log('device ' + device.deviceId + ': P1 channel bind failed: ' + String(error?.message ?? error));
          this.audit.record('p1.bind-failed', { deviceId: device.deviceId, message: String(error?.message ?? error) });
          close(1011, 'channel bind failed');
          return;
        }
        if (channel === undefined) {
          close(1011, 'host inactive');
          return;
        }
        channel.handleClient(text);
      };
      if (device === undefined && helloHoldMs > 0) {
 // task-11 E2E hook (debug-only, set by the `p1.drop` admin action): hold
 // the next reconnect's hello for a few hundred ms to emulate a slow
 // reconnect, so the frames the upstream produces in the gap are replayed
 // deterministically. Production sockets never take this branch
 // (`p1NextHelloHoldMs` is only written by the debug admin action).
        const hold = helloHoldMs;
        helloHoldMs = 0;
        this.audit.record('p1.hello-held', { holdMs: hold });
        const timer = setTimeout(() => {
          if (downstream.readyState === 1) beginHello();
        }, hold);
        if (typeof timer.unref === 'function') timer.unref();
        return;
      }
      beginHello();
    };
    downstream.on('message', onMessage);
    downstream.on('error', () => {});
    downstream.once('close', (code, reason) => {
      downstream.off('message', onMessage);
      settlePending();
      if (channel !== undefined) channel.detachTransport();
      if (device !== undefined && device.downstream === downstream) {
        device.downstream = undefined;
        device.lastDownstreamActivityAt = 0;
      }
      if (channel !== undefined) this.scheduleP1Disposal(device, channel);
 // task-11: the close code/reason is what tells an E2E drop (4000) apart
 // from a transport failure; metadata only (no frame payloads).
      this.audit.record('conn.closed', { deviceId: device?.deviceId, proto: 'dsh-m/2', code, reason: String(reason ?? '') });
    });
  }

 /** Resolve the device from the in-band hello credentials (ticket or mux token). */
  resolveP1HelloAuth(hello) {
    const auth = hello?.auth;
    if (auth === null || typeof auth !== 'object' || Array.isArray(auth)) return { error: 'auth/required' };
    if (typeof auth.ticket === 'string' && auth.ticket.length > 0) {
      const verified = verifyResumeTicket({ secret: this.p1ResumeSecret(), ticket: auth.ticket, now: Date.now() });
      if (verified.ok !== true) {
        this.counters.authFailed += 1;
        return { error: 'auth/invalid-ticket' };
      }
 // Single-use + one grace replay (design §4.2 #1): a used ticket may be
 // replayed once inside the grace window (a reconnect whose `welcome` was
 // lost), then it is rejected, so a leaked ticket is not usable for its
 // whole TTL. The jti table is in-memory only: a plugin restart drops it
 // together with the HMAC secret and the App falls back to ECDSA.
      if (this.p1TicketUses.use(verified.jti, verified.expiresAt).ok !== true) {
        this.counters.authFailed += 1;
        return { error: 'auth/ticket-replayed' };
      }
      const device = this.devices?.get(verified.deviceId);
      if (device === undefined || device.revokedAt !== undefined) {
        this.counters.authFailed += 1;
        return { error: 'auth/revoked' };
      }
      this.counters.authOk += 1;
      return { device };
    }
    if (typeof auth.muxToken === 'string' && auth.muxToken.length > 0) {
      const consumed = this.auth.consumeMuxToken(auth.muxToken);
      if (consumed.error !== undefined) {
        this.counters.authFailed += 1;
        return { error: consumed.error };
      }
      const device = consumed.device;
      if (device.revokedAt !== undefined) {
        this.counters.authFailed += 1;
        return { error: 'auth/revoked' };
      }
      this.counters.authOk += 1;
      return { device };
    }
    return { error: 'auth/required' };
  }

 /** In-memory HMAC key for resume tickets (process lifetime; never persisted). */
  p1ResumeSecret() {
    if (this.p1TicketSecret === undefined) this.p1TicketSecret = randomBytes(32);
    return this.p1TicketSecret;
  }

 /**
 * P1: fold a channel's protocol-engine stats into the process-wide counters
 * exposed by `statusPayload().counters` (design §7.3).
 *
 * `MuxRpcChannel` owns the authoritative per-channel numbers; the global
 * counters are deltas of the channel snapshot so repeated syncs (status poll,
 * resume reattach, idle disposal) never double count and a channel that is
 * dropped after the resume window still contributes its final values.
 */
  syncP1Counters(channel) {
    const stats = channel?.stats;
    if (stats === undefined) return;
    const previous = channel.counterSnapshot ?? {
      rpcOk: 0,
      rpcFailed: 0,
      replayed: 0,
      resumes: 0,
      resumeResets: 0,
      protocolErrors: 0,
    };
    const resumes = Number(stats.resumes) || 0;
    const resumeResets = Number(stats.resumeResets) || 0;
    this.counters.p1RpcOk += Math.max(0, (Number(stats.rpcOk) || 0) - previous.rpcOk);
    this.counters.p1RpcFailed += Math.max(0, (Number(stats.rpcFailed) || 0) - previous.rpcFailed);
    this.counters.p1ReplayFrames += Math.max(0, (Number(stats.replayed) || 0) - previous.replayed);
 // Only resumes the channel accepted for replay count as "resume ok"; a
 // rejected cursor (epoch mismatch/evicted) is a reset instead.
    this.counters.p1ResumeOk += Math.max(0, (resumes - resumeResets) - (previous.resumes - previous.resumeResets));
    this.counters.p1ResumeReset += Math.max(0, resumeResets - previous.resumeResets);
    this.counters.p1ProtocolErrors += Math.max(0, (Number(stats.protocolErrors) || 0) - previous.protocolErrors);
    channel.counterSnapshot = {
      rpcOk: Number(stats.rpcOk) || 0,
      rpcFailed: Number(stats.rpcFailed) || 0,
      replayed: Number(stats.replayed) || 0,
      resumes,
      resumeResets,
      protocolErrors: Number(stats.protocolErrors) || 0,
    };
  }

 /** Mint the ticket handed to the phone in `welcome` (skip /auth/challenge+verify). */
  mintP1Ticket(device, epoch) {
    return mintResumeTicket({
      secret: this.p1ResumeSecret(),
      deviceId: device.deviceId,
      epoch,
      ttlMs: this.config.features.muxRpcTicketTtlMs,
    });
  }

 /**
 * Get-or-create the device's logical P1 channel and wire the upstream mux.
 *
 * A reconnect within `muxRpcResumeWindowMs` reuses the existing channel (its
 * replay log and epoch) without touching the upstream peer; otherwise a new
 * channel/epoch is created and the phone's `resume` is answered with a reset.
 */
  openP1Channel(device, downstream, send, close) {
    if (!this.ctxActive()) return undefined;
    const existing = this.p1Channels.get(device.deviceId);
    if (existing !== undefined && existing.disposed !== true) {
      clearTimeout(existing.disposeTimer);
      existing.disposeTimer = undefined;
      existing.attachTransport({ send, close });
      device.downstream = downstream;
      device.lastDownstreamActivityAt = Date.now();
      device.p1Channel = existing;
      this.audit.record('p1.channel-reattached', { deviceId: device.deviceId, epoch: existing.epoch });
      log('device ' + device.deviceId + ': P1 channel reattached (epoch ' + existing.epoch.slice(0, 8) + '…)');
      return existing;
    }
    let peer;
    try {
      peer = this.ensurePeer(device);
    } catch (error) {
      log('device ' + device.deviceId + ': refusing P1 mux, context inactive: ' + String(error?.message ?? error));
      return undefined;
    }
    const channel = new MuxRpcChannel({
      deviceId: device.deviceId,
      forwardUnary: (request) => this.forwardP1Unary(device, request),
 // `channel` is referenced lazily: the callback only runs on a `hello`.
      issueTicket: () => this.mintP1Ticket(device, channel.epoch),
      limits: {
        rpcMaxInFlight: this.config.features.muxRpcRpcMaxInFlight,
        rpcTimeoutMs: this.config.features.muxRpcRpcTimeoutMs,
        replayBytes: this.config.features.muxRpcReplayBytes,
        replayFrames: this.config.features.muxRpcReplayFrames,
      },
      log,
    });
    this.p1Channels.set(device.deviceId, channel);
    device.downstream = downstream;
    device.lastDownstreamActivityAt = Date.now();
    device.p1Channel = channel;
    channel.attachTransport({ send, close });
    this.counters.p1Channels += 1;
    log('device ' + device.deviceId + ': P1 channel opened (epoch ' + channel.epoch.slice(0, 8) + '…)');
    this.audit.record('p1.channel-open', { deviceId: device.deviceId, epoch: channel.epoch });
    (async () => {
      try {
        const upstream = await peer.ensureMux();
        if (channel.disposed || this.disposed) return;
        const onUpstreamMessage = (data, isBinary) => {
          if (channel.disposed || isBinary === true) return;
          channel.onUpstreamMessage(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'));
        };
        const onUpstreamClose = () => {
          if (channel.disposed) return;
          this.counters.p1UpstreamClosed += 1;
          this.syncP1Counters(channel);
          if (this.p1Channels.get(device.deviceId) === channel) this.p1Channels.delete(device.deviceId);
          device.p1Channel = undefined;
          channel.detachUpstream('upstream mux closed');
          this.audit.record('p1.upstream-closed', { deviceId: device.deviceId });
        };
        upstream.on('message', onUpstreamMessage);
        upstream.once('close', onUpstreamClose);
        upstream.on('error', () => {});
        channel.attachUpstream({
          send: (text) => {
 // Bug1: the frame actually handed to the local DSH mux (a phone
 // frame forwarded verbatim, or a plugin-generated `cancel`).
            if (this.frameAudit !== undefined) this.frameAudit.toUpstream(device.deviceId, text, false);
 // task-2: learn the stream -> session map so turn-end pushes carry a deep link.
            this.notifier?.observeDevice?.(device, text, false);
            if (upstream.readyState === 1) upstream.send(text);
          },
        });
        this.counters.muxOpened += 1;
        this.audit.record('conn.open', { deviceId: device.deviceId, proto: 'dsh-m/2' });
        log('device ' + device.deviceId + ': P1 upstream mux attached');
      } catch (error) {
        log('device ' + device.deviceId + ': cannot open P1 upstream mux: ' + String(error?.message ?? error));
        this.audit.record('p1.upstream-unavailable', { deviceId: device.deviceId, message: String(error?.message ?? error) });
        this.syncP1Counters(channel);
        if (this.p1Channels.get(device.deviceId) === channel) this.p1Channels.delete(device.deviceId);
        device.p1Channel = undefined;
        channel.dispose('upstream unavailable');
        close(1011, 'upstream unavailable');
      }
    })().catch((error) => log('P1 upstream attach failed: ' + (error?.stack ?? String(error))));
    return channel;
  }

 /** Keep a detached channel (replay log) for the resume window, then drop it. */
  scheduleP1Disposal(device, channel) {
    if (this.disposed || channel.disposed) return;
    clearTimeout(channel.disposeTimer);
    channel.disposeTimer = setTimeout(() => {
      channel.disposeTimer = undefined;
      this.syncP1Counters(channel);
      if (this.p1Channels.get(device.deviceId) === channel) this.p1Channels.delete(device.deviceId);
      if (device.p1Channel === channel) device.p1Channel = undefined;
      channel.dispose('resume window expired');
      this.audit.record('p1.channel-idle-closed', { deviceId: device.deviceId });
      try {
        device.peer?.close('idle');
      } catch {
 /* already closed */
      }
    }, this.config.features.muxRpcResumeWindowMs);
    if (typeof channel.disposeTimer.unref === 'function') channel.disposeTimer.unref();
  }

 /**
 * Forward one `rpc` frame to the loopback DSH API (the same target as
 * proxyUnary), but return the raw response to the channel instead of writing
 * an HTTP response. The body is the exact `client-request` envelope the phone
 * would have POSTed, so upstream semantics are unchanged.
 *
 * P1.5-A: a `rpc` frame may carry `headers` (protocol §3.2); the lite opt-in
 * header or the legacy-shaped body hint is honored exactly like proxyUnary.
 */
  async forwardP1Unary(device, { endpoint, bodyText, headers } = {}) {
    const peer = this.ensurePeer(device);
    if (peer.cookie === undefined) await peer.connect('answer');
    const body = Buffer.from(String(bodyText ?? ''), 'utf8');
    if (body.length === 0 || body.length > MAX_BODY_BYTES) throw new Error('rpc body size out of range');
    let request;
    try {
      request = JSON.parse(body.toString('utf8'));
    } catch {
      throw new Error('rpc body is not valid JSON');
    }
    if (request?.type !== 'client-request' || request?.method !== endpoint) {
      throw new Error('rpc body does not match the declared endpoint');
    }
    const listLitePlan = this.planListLite(endpoint, headers, body.toString('utf8'));
    const upstreamBody = listLitePlan.bodyText === undefined ? body : Buffer.from(listLitePlan.bodyText, 'utf8');
    const upstream = await fetch(this.loopbackOrigin + '/api/' + endpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        cookie: peer.cookie.name + '=' + peer.cookie.value,
      },
      body: upstreamBody,
      redirect: 'manual',
    });
    const fullBytes = Buffer.from(await upstream.arrayBuffer());
    this.counters.proxiedUnary += 1;
    this.audit.record('p1.rpc', { deviceId: device.deviceId, endpoint, status: upstream.status, bytes: fullBytes.length });
    const listLite = this.applyListLite(device, endpoint, 'p1', listLitePlan, fullBytes);
    return {
      status: upstream.status,
      contentType: upstream.headers.get('content-type') ?? 'application/octet-stream',
      bytes: listLite.bytes,
 // Undefined for the legacy/full path; useful for P1 channel diagnostics.
      listLite: listLite.stats,
    };
  }

 /** Keep the upstream peer alive briefly after the phone drops (resume window). */
  scheduleUpstreamIdle(device) {
    if (this.disposed) return;
    clearTimeout(device.idleTimer);
    device.idleTimer = setTimeout(() => {
      device.idleTimer = undefined;
      if (device.downstream !== undefined) return;
      log('device ' + device.deviceId + ': closing idle upstream mux');
      device.peer?.close('idle');
    }, this.config.upstreamIdleMs);
    if (typeof device.idleTimer.unref === 'function') device.idleTimer.unref();
  }

 // ------------------------------------------------------------------ admin ---

  statusPayload() {
 // task-11: keep the global P1 counters fresh before anyone reads them
 // (the channel owns the authoritative stats until it is dropped).
    for (const channel of this.p1Channels.values()) this.syncP1Counters(channel);
    return {
      plugin: PLUGIN_NAME,
      version: PLUGIN_VERSION,
      proto: PROTOCOL,
      ready: this.ready,
      started: this.started,
      starting: this.starting,
      inactive: this.disposed || !this.ctxActive(),
      disposed: this.disposed,
      startupError: this.startupError ?? null,
      listener: this.server === undefined ? 'closed' : this.server.listening ? 'listening' : 'closed',
      hostId: this.hostIdentity?.hostId,
      hostName: this.config.hostName,
      dataDir: this.dataDir,
      loopbackOrigin: this.loopbackOrigin,
      contract: this.contract ?? { ok: false, pending: true },
      tls: {
        bindHost: this.config.bindHost,
        port: this.config.port,
        caPin: this.certs?.caPin,
        leafPin: this.certs?.leafPin,
        caFingerprint256: this.certs?.caFingerprint256,
        leafFingerprint256: this.certs?.leafFingerprint256,
        caNotAfter: this.certs?.caNotAfter,
        leafNotAfter: this.certs?.leafNotAfter,
        leafSans: this.certs?.leafSans,
      },
      endpoints: this.endpoints,
      deviceEndpoints: this.deviceEndpoints,
      fetchRoutes: this.config.fetchRoutes.enabled === false ? [] : this.config.fetchRoutes.allow,
      devices: { total: this.devices?.size() ?? 0, active: this.devices?.active().length ?? 0 },
      apns: this.apns?.info(),
 // Desktop panel: M2a tunnel status + LAN discovery state (no secrets).
      tunnel: this.config.tunnel.enabled === true
        ? (this.tunnel?.health?.() ?? { enabled: true, state: 'starting', origin: null, port: null, since: null, lastError: null })
        : null,
      bonjour: this.config.bonjour.enabled === false
        ? { enabled: false, active: false }
        : { enabled: true, active: this.bonjour?.started === true, instance: this.bonjour?.instanceFqdn ?? null },
      counters: this.counters,
 // P1 (feature-flagged): per-channel transport state, no secrets.
      features: this.config.features,
      p1: {
        enabled: this.config.features.muxRpc === true,
        pendingUpgrades: this.p1Pending.size,
        channels: [...this.p1Channels.values()].map((channel) => channel.info()),
      },
      notifications: this.config.notifications,
      debugEnabled: this.config.debug.enabled,
    };
  }

  async pairingPayload() {
 // The QR payload must advertise the Mac's *current* LAN origin: refreshing here
 // prevents a re-pair (or a second device) from being pinned to stale addresses.
    this.refreshLanEndpoints();
    const payload = this.pairing.payload();
    const payloadText = this.pairing.payloadText();
    const qr = await this.qr.renderDataUrl(payloadText);
    return {
      payload,
      payloadText,
      qr: { ok: qr.ok === true, dataUrl: qr.dataUrl, error: qr.error },
      status: this.pairing.status(),
    };
  }

  refreshPairing(reason = 'manual') {
    this.pairing.refresh(reason);
    this.writeDebugPairPayload().catch((error) => log('debug pair payload write failed: ' + String(error?.message ?? error)));
    return this.pairing.status();
  }

  certsInfo() {
    return {
      caPin: this.certs?.caPin,
      leafPin: this.certs?.leafPin,
      caFingerprint256: this.certs?.caFingerprint256,
      leafFingerprint256: this.certs?.leafFingerprint256,
      caSubject: this.certs?.caSubject,
      leafSubject: this.certs?.leafSubject,
      leafSans: this.certs?.leafSans,
      caNotAfter: this.certs?.caNotAfter,
      leafNotAfter: this.certs?.leafNotAfter,
      tls: { bindHost: this.config.bindHost, port: this.config.port },
      rotation: {
        leaf: 'certs.rotateLeaf re-signs the leaf with the same CA; QR pins stay valid',
        ca: 'certs.rotateCa archives the CA and revokes every device; all phones must re-pair',
      },
    };
  }

  listDevices() {
    return this.devices.publicList();
  }

  revokeDevice(deviceId, reason = 'manual') {
    if (typeof deviceId !== 'string' || deviceId.length === 0) return { error: 'device/invalid' };
    const device = this.devices.revoke(deviceId, reason);
    if (device === undefined) return { error: 'device/not-found' };
    this.counters.revokedDevices += 1;
    this.auth.revokeDeviceTokens(device.deviceId);
    clearTimeout(device.idleTimer);
    device.idleTimer = undefined;
    try {
      device.downstream?.close(1008, 'device revoked');
    } catch {
 /* already gone */
    }
    device.downstream = undefined;
    device.peer?.close('device revoked');
    device.peer = undefined;
    this.audit.record('device.revoked', { deviceId: device.deviceId, keyId: device.keyId, reason });
    log('device ' + device.deviceId + ' revoked (' + reason + ')');
 // task-5: the watcher coverage set shrank; stop it when no push device is left.
    this.syncSessionWatcher();
    return { device: this.devices.publicList().find((entry) => entry.deviceId === device.deviceId) };
  }

  revokeAllDevices(reason = 'manual') {
    const revoked = this.devices.revokeAll(reason);
    for (const device of revoked) {
      this.counters.revokedDevices += 1;
      this.auth.revokeDeviceTokens(device.deviceId);
      clearTimeout(device.idleTimer);
      device.idleTimer = undefined;
      try {
        device.downstream?.close(1008, 'device revoked');
      } catch {
 /* already gone */
      }
      device.downstream = undefined;
      device.peer?.close('device revoked');
      device.peer = undefined;
    }
    this.audit.record('device.revoked-all', { count: revoked.length, reason });
    this.syncSessionWatcher();
    return { revoked: revoked.length };
  }

  async rotateLeafNow() {
    const certs = rotateLeafCerts({
      dir: this.dataDir,
      bindHost: this.config.bindHost,
      lanIps: [...this.lanIps, ...(this.config.tls.additionalHosts ?? [])],
      hostname: this.hostname,
      log,
    });
    this.applyCerts(certs);
    this.audit.record('cert.leaf-rotated', { leafPin: certs.leafPin, leafSans: certs.leafSans, reason: 'admin' });
    return this.certsInfo();
  }

  async rotateCaNow(confirm) {
    if (confirm !== 'ROTATE-CA') throw new Error('CA rotation requires confirm: "ROTATE-CA" (every device must re-pair)');
    const certs = rotateCaCerts({
      dir: this.dataDir,
      bindHost: this.config.bindHost,
      lanIps: [...this.lanIps, ...(this.config.tls.additionalHosts ?? [])],
      hostname: this.hostname,
      log,
    });
    this.applyCerts(certs);
    const revoked = this.revokeAllDevices('ca-rotated');
    this.pairing.refresh('ca-rotated');
    await this.writeDebugPairPayload();
    this.audit.record('cert.ca-rotated', { caPin: certs.caPin, archive: certs.archive, revokedDevices: revoked.revoked });
    return { ...this.certsInfo(), archive: certs.archive, revokedDevices: revoked.revoked };
  }

 /** Swap the live leaf certificate without dropping the listener. */
  applyCerts(certs) {
    this.certs = certs;
    if (this.server !== undefined) {
      this.server.setSecureContext({ key: readFileSync(certs.leafKey), cert: readFileSync(certs.leafCert) });
    }
    this.endpoints = buildEndpoints({ config: this.config, certs, lanIps: this.lanIps, hostname: this.hostname });
    this.baseEndpoints = this.endpoints.slice();
    if (this.tunnelEndpoint !== undefined) this.endpoints = [...this.baseEndpoints, this.tunnelEndpoint];
    this.deviceEndpoints = selectDeviceEndpoints(this.endpoints);
    this.pairing?.setTrust?.({ certs, endpoints: this.deviceEndpoints });
 // The relay lookup response carries the Mac leaf pin/fingerprint, so a leaf
 // rotation must republish the current code with the new material.
    this.publishTunnelCode();
  }

  auditTail(limit = 50) {
    const file = join(this.dataDir, 'audit.log');
    try {
      const lines = readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
      const slice = lines.slice(-Math.max(1, Math.min(500, limit)));
      return slice.map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return { raw: line };
        }
      });
    } catch {
      return [];
    }
  }

  apnsInfo() {
    return this.apns.info();
  }

 /**
 * Send a test push.
 *
 * With `deviceToken` it is a direct probe (dummy/real APNs token) returning
 * the raw APNs status + reason — useful for validating.p8/Key/Team/Topic
 * before a phone is involved. Without it, every registered device token is
 * targeted (normal真机验证 path); stub mode reports stub deliveries.
 */
 /**
 * Build the payload variant for `apns.test` (M4 device verification).
 *
 * `kind`:
 * - `approval`: alert push carrying category `dshm-approval` + a dummy
 * eventId, so the OS renders 允许/拒绝; tapping one proves the
 * action → unlock → answer chain (the Host rejects the dummy event, which
 * exercises the app's fallback path).
 * - `question`: alert push of type `question` (question-request notice).
 * - `silent` (or `silent:true`): content-available background push, no banner.
 * - absent/`default`: the plain test notification.
 */
  apnsTestVariant({ kind, silent, deepLink } = {}) {
    const link = deepLink ?? {};
    if (silent === true || kind === 'silent') {
      return { silent: true, data: { type: 'sync', reason: 'test', ...link } };
    }
    if (kind === 'approval') {
      return {
        title: 'DSH 需要审批',
        body: '工具调用 bash 等待你的确认（测试通知）',
        category: APPROVAL_CATEGORY,
        data: { type: 'approval', toolName: 'bash', eventId: 'test-event', ...link },
      };
    }
    if (kind === 'question') {
      return {
        title: 'DSH 需要你的回答',
        body: '有 2 个问题等待你回答（测试通知）',
        data: { type: 'question', eventId: 'test-question', questionCount: 2, ...link },
      };
    }
    return {
      title: 'DSH 测试通知',
      body: '如果你看到这条通知，APNs 配置可用。',
      data: { type: 'test', ...link },
    };
  }

  async apnsTest({ deviceToken, environment, sessionId, kind, silent } = {}) {
    const info = this.apns.info();
    const topic = this.apns.topic ?? null;
 // Optional deep-link target: a real-device test push may carry a session id so
 // tapping the banner proves the notification-to-session path (task-4).
    const deepLink = typeof sessionId === 'string' && sessionId.trim().length > 0 ? { sessionId: sessionId.trim() } : {};
    const variant = this.apnsTestVariant({ kind, silent, deepLink });
    if (typeof deviceToken === 'string' && deviceToken.trim().length > 0) {
      const token = deviceToken.trim();
      if (!/^[0-9a-fA-F]{64,256}$/.test(token)) return { mode: info.mode, environment, topic, delivered: 0, probe: { error: 'push-token-invalid' }, results: [] };
      const result = await this.apns.send({
        deviceToken: token,
        environment,
        topic,
        silent: variant.silent,
        category: variant.category,
        title: variant.silent === true ? undefined : 'DSH-m APNs 探针',
        body: variant.silent === true ? undefined : '这是一条 dummy token 探针通知。',
        data: variant.silent === true ? variant.data : { type: 'apns-test', probe: true, ...deepLink },
      });
      this.audit.record('apns.test', {
        delivery: info.mode,
        devices: 1,
        probe: true,
        tokenFingerprint: tokenFingerprint(token),
        status: result.status ?? null,
        reason: result.reason ?? result.error ?? null,
      });
      return {
        mode: info.mode,
        environment: info.environment,
        topic,
        delivered: result.ok === true ? 1 : 0,
        probe: {
          tokenFingerprint: tokenFingerprint(token),
          ok: result.ok === true,
          status: result.status ?? null,
          reason: result.reason ?? null,
          error: result.error ?? null,
          stub: result.stub === true,
        },
        results: [],
        reason: result.reason ?? result.error ?? undefined,
      };
    }
    const devices = this.pushTargets();
    const results = [];
    for (const device of devices) {
      const result = await this.apns.send({
        deviceToken: device.pushToken,
        environment: device.pushEnvironment ?? environment,
        topic,
        silent: variant.silent,
        category: variant.category,
        title: variant.title,
        body: variant.body,
        data: variant.data,
      });
      results.push({
        deviceId: device.deviceId,
        tokenFingerprint: tokenFingerprint(device.pushToken),
        ok: result.ok === true,
        status: result.status ?? null,
        reason: result.reason ?? null,
        error: result.error ?? null,
        stub: result.stub === true,
      });
    }
    const delivered = results.filter((entry) => entry.ok).length;
    this.audit.record('apns.test', {
      delivery: info.mode,
      devices: results.length,
      ...(deepLink.sessionId === undefined ? {} : { sessionId: deepLink.sessionId }),
      ...(variant.silent === true ? { silent: true } : {}),
      ...(typeof kind === 'string' && kind.length > 0 ? { kind } : {}),
    });
    return {
      mode: info.mode,
      environment: info.environment,
      topic,
      delivered,
      results,
      reason: results.length === 0 ? (info.mode === 'stub' ? info.reason : 'no registered device token') : undefined,
    };
  }

 /** Shared action dispatcher for the authenticated desktop route and the test debug route. */
  async handleAdminAction(body) {
    const action = typeof body?.action === 'string' ? body.action : '';
    switch (action) {
      case 'status':
        return { ok: true, data: this.statusPayload() };
      case 'pairing': {
        const data = await this.pairingPayload();
        data.code = this.pairCode.adminCode();
        return { ok: true, data };
      }
      case 'pairing.refresh': {
        this.refreshPairing('manual');
 // A fresh pairing cycle also rotates the 8-digit code (design §5.1).
        this.pairCode.refresh('manual');
        const data = await this.pairingPayload();
        data.code = this.pairCode.adminCode();
        return { ok: true, data };
      }
      case 'pairing.code':
        return { ok: true, data: { code: this.pairCode.adminCode() } };
      case 'pairing.code.refresh':
        this.pairCode.refresh('manual');
        return { ok: true, data: { code: this.pairCode.adminCode() } };
      case 'pair.code': {
 // Debug-only convenience for the E2E scripts: same-origin /debug/admin
 // already requires the debug admin token, and this action is refused
 // entirely unless config.debug.enabled is on. The code never reaches
 // /health, audit or logs.
        if (this.config.debug.enabled !== true) return { ok: false, error: 'admin/unknown-action', message: action };
        const code = this.pairCode.adminCode();
        return { ok: true, data: { active: code.active, code: code.value, expiresAt: code.expiresAt, attemptsLeft: code.attemptsLeft } };
      }
      case 'devices.list':
        return { ok: true, data: { devices: this.listDevices() } };
      case 'devices.revoke': {
        const result = this.revokeDevice(body.deviceId, typeof body.reason === 'string' ? body.reason : 'desktop-ui');
        return result.error === undefined ? { ok: true, data: result } : { ok: false, error: result.error };
      }
      case 'devices.revokeAll':
        return { ok: true, data: this.revokeAllDevices('desktop-ui') };
      case 'certs.info':
        return { ok: true, data: this.certsInfo() };
      case 'certs.rotateLeaf':
        return { ok: true, data: await this.rotateLeafNow() };
      case 'certs.rotateCa':
        return { ok: true, data: await this.rotateCaNow(body.confirm) };
      case 'p1.drop': {
 // task-11 E2E only: force the current dsh-m/2 downstream socket closed
 // without touching the logical channel/upstream, so the App's reconnect
 // loop performs `hello.resume` inside the resume window (design §5).
 // `holdHelloMs` delays handling of the NEXT reconnect's hello (default
 // 500ms, max 2000ms): the simulator reconnects in-process within ~5ms,
 // so without a held hello the gap contains no frames and a lossless
 // resume legitimately replays nothing. Holding the hello emulates a
 // slow (cellular) reconnect and makes `p1ReplayFrames>0` deterministic.
 // Refused unless the debug admin channel is on, same as `pair.code`.
        if (this.config.debug.enabled !== true) return { ok: false, error: 'admin/unknown-action', message: action };
        const wanted = typeof body.deviceId === 'string' && body.deviceId.length > 0 ? body.deviceId : undefined;
        const requestedHold = Number(body.holdHelloMs);
        const holdHelloMs = Number.isFinite(requestedHold) && requestedHold >= 0
          ? Math.min(2000, Math.floor(requestedHold))
          : 500;
        const dropped = [];
        for (const [deviceId, channel] of this.p1Channels) {
          if (wanted !== undefined && deviceId !== wanted) continue;
          const transport = channel.transport;
          if (transport === undefined || typeof transport.close !== 'function') continue;
          try {
            transport.close(4000, 'debug p1.drop');
            dropped.push(deviceId);
          } catch {
 /* socket already gone */
          }
        }
        if (dropped.length > 0) this.p1NextHelloHoldMs = holdHelloMs;
        this.audit.record('debug.p1-drop', { dropped: dropped.length, deviceId: wanted, holdHelloMs });
        return { ok: true, data: { dropped, channels: this.p1Channels.size, holdHelloMs } };
      }
      case 'audit.tail':
        return { ok: true, data: { lines: this.auditTail(Number(body.limit) || 50) } };
      case 'apns.info':
        return { ok: true, data: this.apnsInfo() };
      case 'apns.test':
        return {
          ok: true,
          data: await this.apnsTest({
            deviceToken: body.deviceToken,
            environment: body.environment,
            sessionId: body.sessionId,
            kind: body.kind,
            silent: body.silent,
          }),
        };
      default:        return { ok: false, error: 'admin/unknown-action', message: action };
    }
  }

 /** Test-only admin channel on the TLS origin (config.debug.*). */
  async handleDebugAdmin(request, response, ip) {
    if (!this.config.debug.enabled || typeof this.config.debug.adminToken !== 'string' || this.config.debug.adminToken.length === 0) {
      return sendText(response, 404, 'not found');
    }
    const presented = request.headers['x-dshm-debug-admin'];
    const expected = this.config.debug.adminToken;
    if (typeof presented !== 'string' || presented.length !== expected.length || !timingSafeEqual(Buffer.from(presented), Buffer.from(expected))) {
      this.audit.record('debug.unauthorized', { ip });
      return sendText(response, 401, 'unauthorized');
    }
    let body;
    try {
      body = await readJson(request);
    } catch {
      return sendJson(response, 400, { ok: false, error: 'bad-request' });
    }
    const result = await this.handleAdminAction(body);
    return sendJson(response, 200, result);
  }

 /** Debug-only mirror of the pairing payload for the test simulator. */
  async writeDebugPairPayload() {
    if (this.config.debug.pairPayloadFile !== true) return;
    const data = await this.pairingPayload();
    const file = join(this.dataDir, 'pair-payload.debug.json');
    writeFileSync(
      file,
      JSON.stringify(
        {
          note: 'DEBUG ONLY — written because debug.pairPayloadFile=true. Contains a one-time pair token; never enable in production.',
          generatedAt: new Date().toISOString(),
          payload: data.payload,
          payloadText: data.payloadText,
          qr: data.qr,
          status: data.status,
        },
        null,
        2,
      ) + '\n',
      { mode: 0o600 },
    );
  }

 /**
 * Tear everything down. Synchronous and idempotent: HMR calls this from a
 * context that is already being disposed, and any throw here used to leave a
 * zombie TLS listener holding the port while the context was dead.
 */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
 // Teardown must reach the listener even when an earlier step throws (a dead
 // Cordis service, a route disposer from an inactive context,...): a skipped
 // listener close is exactly the zombie that keeps the TLS port bound and
 // leaves the phone without a link after a reload. Logging is guarded as
 // well — it was the one call outside the try block below.
    try {
      log('disposing link server');
    } catch {
 /* nothing left to log to */
    }
    try {
      this.started = false;
      try {
        clearInterval(this.sweepTimer);
      } catch {
 /* already cleared */
      }
      try {
        clearInterval(this.endpointRefreshTimer);
      } catch {
 /* never set */
      }
      try {
        clearTimeout(this.listenRetryTimer);
      } catch {
 /* never set */
      }
      this.sweepTimer = undefined;
      this.endpointRefreshTimer = undefined;
      try {
        this.adminDisposer?.();
      } catch {
 /* already gone */
      }
      this.adminDisposer = undefined;
 // P1: drop replay logs and reject anonymous hello-pending sockets.
      for (const channel of [...this.p1Channels.values()]) {
        try {
          channel.dispose('link dispose');
        } catch {
 /* already disposed */
        }
      }
      this.p1Channels.clear();
      for (const entry of [...this.p1Pending]) {
        try {
          clearTimeout(entry.timer);
          entry.downstream.close(1001, 'link dispose');
        } catch {
 /* already gone */
        }
      }
      this.p1Pending.clear();
      try {
        this.qr?.dispose?.();
      } catch {
 /* renderer already gone */
      }
      try {
        this.auth?.dispose?.();
      } catch {
 /* already cleared */
      }
      try {
        this.pairing?.dispose?.();
      } catch {
 /* already cleared */
      }
      try {
        this.pairCode?.dispose?.();
      } catch {
 /* already cleared */
      }
      try {
        this.bonjour?.close?.();
      } catch {
 /* already closed */
      }
      this.bonjour = undefined;
      try {
        this.tunnel?.dispose?.();
      } catch {
 /* already closed */
      }
      this.tunnel = undefined;
      try {
        this.sessionWatcher?.dispose?.();
      } catch {
 /* already stopped */
      }
      this.sessionWatcher = undefined;
      for (const dispose of this.hostEventDisposers) {
        try {
          dispose();
        } catch {
 /* host bus already gone */
        }
      }
      this.hostEventDisposers = [];
      this.hostTurnEventsActive = false;
      try {
        this.notifier?.dispose?.();
      } catch {
 /* already cleared */
      }
      const devices = this.devices !== undefined ? [...this.devices.devices.values()] : [];
      for (const device of devices) {
        try {
          clearTimeout(device.idleTimer);
        } catch {
 /* already cleared */
        }
        device.idleTimer = undefined;
        try {
          device.downstream?.close(1001, 'link disposed');
        } catch {
 /* already gone */
        }
        device.downstream = undefined;
        try {
          device.peer?.close('link disposed');
        } catch {
 /* already gone */
        }
        device.peer = undefined;
      }
      try {
        if (this.wss !== undefined) {
          for (const client of this.wss.clients) {
            try {
              client.terminate();
            } catch {
 /* already gone */
            }
          }
          this.wss.close();
        }
      } catch {
 /* already closed */
      }
      this.wss = undefined;
      try {
        this.audit?.record('server.stop', { counters: this.counters, disposedBy: 'hmr-or-shutdown' });
      } catch {
 /* audit is best effort during teardown */
      }
    } catch (error) {
      try {
        log('dispose failed (continuing): ' + String(error?.message ?? error));
      } catch {
 /* nothing left to log to */
      }
    } finally {
 // Always last: release what the *next* instance needs even when a step
 // above threw (closeListenerQuietly also destroys keep-alive sockets and
 // stops accepting), then drop this instance from the hand-off registry.
      try {
        this.closeListenerQuietly();
      } catch {
 /* a foreign listener still fails the bind with an explicit error */
      }
      unregisterLiveInstance(this);
    }
  }

 /** Stable short hash for logs (no secrets). */
  static fingerprint(value) {
    return createHash('sha256').update(String(value)).digest('hex').slice(0, 12);
  }
}

export { PLUGIN_NAME, PLUGIN_VERSION, PROTOCOL };

// Re-export small helpers that other modules/tests may want.
export { collectLanIps, keyFingerprint256 };
