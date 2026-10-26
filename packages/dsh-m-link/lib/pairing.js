/**
 * pairing.js — one-time QR pairing sessions and the signed pairing payload.
 *
 * The payload is the only thing that crosses the out-of-band channel (the QR
 * code shown in the desktop UI). It carries: host identity (Ed25519 public key
 * + a host id derived from it), every usable link origin, the CA/leaf pins, and
 * a one-time pair token with a 90s expiry. It is signed by the host key so the
 * phone can reject a spliced payload; the phone's trust anchor is the QR scan
 * itself. See PAIRING.zh.md for the field-by-field contract the iOS client
 * must implement.
 */

import { randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';

import { canonicalJson } from './canonical.js';
import { normalizeDevicePublicKey } from './devices.js';

export const PAIR_PROTOCOL = 'dsh-m/1';
export const PAIR_KIND = 'dsh-m.pair';
export const DEFAULT_CAPS = ['session.read', 'session.write', 'approval.answer', 'pair.post'];
const MAX_TOKEN_COMPARE = 256;

/** Normalize a user-supplied device name the same way for both pairing channels. */
export function trimDeviceName(value, fallback) {
  if (typeof value !== 'string') return fallback;
  const trimmed = value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 64);
  return trimmed.length > 0 ? trimmed : fallback;
}

function constantTimeEquals(left, right) {
  const a = Buffer.from(String(left));
  const b = Buffer.from(String(right));
  return a.length === b.length && a.length <= MAX_TOKEN_COMPARE && timingSafeEqual(a, b);
}

/** True for loopback hosts that are meaningless on a phone (127.0.0.1/localhost/[::1]). */
export function isLoopbackHost(hostname) {
  if (typeof hostname !== 'string' || hostname.length === 0) return false;
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, '');
  return host === 'localhost' || host === '::1' || host === '0:0:0:0:0:0:0:1' || host === '::ffff:127.0.0.1' || /^127(\.|$)/.test(host);
}

/** True when a URL points at this Mac's loopback interface. */
export function isLoopbackUrl(url) {
  try {
    return isLoopbackHost(new URL(url).hostname);
  } catch {
    return false;
  }
}

/**
 * Endpoints that are actually reachable from a phone.
 *
 * Loopback URLs only make sense on the Mac itself (desktop UI / simulator); a
 * phone resolving 127.0.0.1 reaches *itself* and gets ECONNREFUSED. So whenever
 * at least one non-loopback endpoint exists (LAN IP, mDNS name or a configured
 * tunnel/relay origin), the QR payload carries only those. If the deployment is
 * loopback-only (bindHost=127.0.0.1, desktop development), loopback is kept as
 * the single fallback so local simulators still work.
 */
export function selectDeviceEndpoints(endpoints) {
  const nonLoopback = endpoints.filter((endpoint) => endpoint.loopback !== true && !isLoopbackUrl(endpoint.url));
  return nonLoopback.length > 0 ? nonLoopback : endpoints.slice();
}

/** Public payload fields for one endpoint (internal flags never reach the QR). */
function publicEndpoint(endpoint) {
  return {
    url: endpoint.url,
    kind: endpoint.kind,
    pri: endpoint.pri,
    trust: endpoint.trust,
    ...(endpoint.pin === undefined ? {} : { pin: endpoint.pin }),
    ...(endpoint.leafPin === undefined ? {} : { leafPin: endpoint.leafPin }),
  };
}

/**
 * Build the endpoint list advertised in the QR payload.
 * @param {{config: Record<string, unknown>, certs: Record<string, unknown>, lanIps: string[], hostname?: string, log?: Function}} input
 */
export function buildEndpoints({ config, certs, lanIps = [], hostname }) {
  const port = Number(config.port);
  const bindHost = typeof config.bindHost === 'string' ? config.bindHost : '127.0.0.1';
  const endpoints = [];
  const add = (url, kind, pri, extra = {}) => {
    endpoints.push({
      url,
      kind,
      pri,
      trust: 'localCA',
      pin: certs.caPin,
      leafPin: certs.leafPin,
      loopback: isLoopbackUrl(url),
      ...extra,
    });
  };
  const loopbackUrl = 'https://127.0.0.1:' + String(port);
  if (bindHost === '0.0.0.0' || bindHost === '::' || bindHost === 'localhost' || bindHost === '127.0.0.1' || bindHost === '::1') {
    add(loopbackUrl, 'lan', 10);
  } else if (/^\d{1,3}(\.\d{1,3}){3}$/.test(bindHost)) {
    add('https://' + bindHost + ':' + String(port), 'lan', 10);
  } else {
    add(loopbackUrl, 'lan', 10);
    add('https://' + bindHost + ':' + String(port), 'lan', 15);
  }
  if (bindHost === '0.0.0.0' || bindHost === '::') {
 // IPv4 LAN candidates in interface order; loopback and link-local
 // (169.254.0.0/16, APIPA) addresses are never useful to a phone.
    const candidates = [];
    const seen = new Set();
    for (const ip of lanIps) {
      if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) continue;
      if (ip.startsWith('127.') || ip.startsWith('169.254.') || seen.has(ip)) continue;
      seen.add(ip);
      candidates.push(ip);
    }
    let pri = 20;
    for (const ip of candidates) {
      add('https://' + ip + ':' + String(port), 'lan', pri);
      pri += 5;
    }
  }
 // Extra origins (tunnel / relay / alternate LAN) come straight from config.
  const configured = Array.isArray(config.origins) ? config.origins : [];
  let extraPri = 100;
  for (const entry of configured) {
    if (typeof entry === 'string') {
      if (entry.length === 0) continue;
      const isHttps = entry.startsWith('https://');
      const url = entry.replace(/\/+$/, '');
      endpoints.push({
        url,
        kind: isHttps && /^https:\/\/[^/]*\d+$/.test(entry) ? 'lan' : 'tunnel',
        pri: extraPri,
        trust: isHttps ? 'pinSpki' : 'systemCA',
        loopback: isLoopbackUrl(url),
        ...(isHttps ? { pin: certs.caPin, leafPin: certs.leafPin } : {}),
      });
      extraPri += 10;
      continue;
    }
    if (entry !== null && typeof entry === 'object' && typeof entry.url === 'string' && entry.url.length > 0) {
      endpoints.push({
        url: entry.url,
        kind: typeof entry.kind === 'string' ? entry.kind : 'tunnel',
        pri: Number.isFinite(entry.pri) ? entry.pri : extraPri,
        trust: typeof entry.trust === 'string' ? entry.trust : 'systemCA',
        loopback: isLoopbackUrl(entry.url),
        ...(typeof entry.pin === 'string' ? { pin: entry.pin } : {}),
        ...(typeof entry.leafPin === 'string' ? { leafPin: entry.leafPin } : {}),
      });
      extraPri += 10;
    }
  }
  return endpoints;
}

/** One-time pairing session + signed QR payload builder. */
export class PairingService {
 /**
 * @param {{
 * config: Record<string, unknown>,
 * certs: Record<string, unknown>,
 * hostIdentity: ReturnType<typeof import('./host-identity.js').ensureHostIdentity>,
 * endpoints: ReturnType<typeof buildEndpoints>,
 * audit: import('./audit.js').AuditLog,
 * log?: (message: string) => void,
 * caps?: string[],
 * }} options
 */
  constructor({ config, certs, hostIdentity, endpoints, audit, log = () => {}, caps = DEFAULT_CAPS }) {
    this.config = config;
    this.certs = certs;
    this.hostIdentity = hostIdentity;
    this.endpoints = endpoints;
    this.audit = audit;
    this.log = log;
    this.caps = caps;
    this.hostName = typeof config.hostName === 'string' && config.hostName.length > 0 ? config.hostName.slice(0, 64) : 'DeepSeek Harness Mac';
    this.ttlMs = Number.isInteger(config.pairTtlMs) ? config.pairTtlMs : 90_000;
 /** @type {{id: string, token: string, issuedAt: number, expiresAt: number} | undefined} */
    this.session = undefined;
 /**
 * Optional top-level `relay` object (M2a): `{origin, pin, v:1}`. Set after
 * the tunnel reports `ready`; the App saves it as its server config so it
 * can run the public rendezvous lookup for the 8-digit code.
 *
 * §5.4 / P1: `origin` is the relay **control-plane** origin (code lookup,
 * normalised https, never the bridge data port) and `pin` is the *relay's*
 * certificate pin (not the Mac's). The bridge data origin stays in
 * `endpoints[]` with the Mac CA/leaf pin — the two planes must not mix.
 * @type {{origin: string, pin: string, v: number} | undefined}
 */
    this.relay = undefined;
  }

 /** Update the trust material after a certificate rotation without dropping the session. */
  setTrust({ certs, endpoints }) {
    this.certs = certs;
    this.endpoints = endpoints;
    if (this.hostName.length === 0) this.hostName = 'DeepSeek Harness Mac';
  }

 /**
 * Attach/clear the top-level relay rendezvous object carried in the signed
 * payload (M2a §5.4). The last known relay config is kept across tunnel
 * disconnects: it is the App's server config, not a liveness signal.
 */
  setRelay(relay) {
    if (relay === undefined || relay === null) {
      this.relay = undefined;
      return;
    }
    if (typeof relay.origin !== 'string' || relay.origin.length === 0) return;
    if (typeof relay.pin !== 'string' || relay.pin.length === 0) return;
    this.relay = { origin: relay.origin, pin: relay.pin, v: 1 };
  }

 /** Current relay object (undefined when the tunnel has never been ready). */
  relayInfo() {
    return this.relay === undefined ? undefined : { ...this.relay };
  }

 /** Mint a fresh one-time pairing session (replacing any previous one). */
  refresh(reason = 'manual') {
    const issuedAt = Date.now();
    const session = {
      id: randomUUID(),
      token: randomBytes(24).toString('base64url'),
      issuedAt,
      expiresAt: issuedAt + this.ttlMs,
    };
    this.session = session;
    this.audit.record('pair.issued', { pairId: session.id, expiresAt: new Date(session.expiresAt).toISOString(), reason });
    return session;
  }

  current() {
    if (this.session === undefined || this.session.expiresAt <= Date.now()) return undefined;
    return this.session;
  }

  status() {
    const session = this.current();
    if (session === undefined) return { active: false, ttlMs: this.ttlMs };
    return {
      active: true,
      pairId: session.id,
      issuedAt: session.issuedAt,
      expiresAt: session.expiresAt,
      ttlMs: this.ttlMs,
    };
  }

 /** Drop the pending pairing session on dispose (never reuse a token). */
  dispose() {
    this.session = undefined;
  }

 /**
 * Build the signed QR payload for the current session, issuing one when there
 * is none **or when the current one has expired** (P2/D5). Admin `pairing`
 * (polled by the desktop panel every 5s) and the debug payload writer both go
 * through here, so a QR on screen can never carry a dead one-time token: an
 * expired session is re-signed transparently with reason `auto`.
 */
  payload() {
    if (this.session === undefined || this.session.expiresAt <= Date.now()) this.refresh('auto');
    const session = this.session;
    const deviceEndpoints = this.endpoints.map(publicEndpoint);
    const unsigned = {
      v: 1,
      kind: PAIR_KIND,
      host: {
        id: this.hostIdentity.hostId,
        name: this.hostName,
        key: this.hostIdentity.publicKeyBase64Url,
      },
      mode: deviceEndpoints.every((endpoint) => endpoint.kind === 'lan') ? 'lan' : 'mixed',
      origins: deviceEndpoints.map((endpoint) => endpoint.url),
      endpoints: deviceEndpoints,
      tls: {
        kind: 'self-signed-ca',
 // C scheme: the public CA certificate (DER base64) lets the phone pin the
 // long-lived CA instead of the leaf DER, so later leaf re-issues (expiry
 // or a manual rotateLeaf) never require re-pairing. Public material only.
        caCert: this.certs.caCertDerBase64,
        caPin: this.certs.caPin,
        leafPin: this.certs.leafPin,
        caFingerprint256: this.certs.caFingerprint256,
        leafFingerprint256: this.certs.leafFingerprint256,
        leafNotAfter: this.certs.leafNotAfter,
      },
      pair: {
        id: session.id,
        token: session.token,
        exp: Math.floor(session.expiresAt / 1000),
        caps: this.caps,
        proto: PAIR_PROTOCOL,
      },
 // Optional public-rendezvous config (M2a). Present only after the tunnel
 // reported ready, so a LAN-only deployment keeps the M1 payload shape.
      ...(this.relay === undefined ? {} : { relay: { ...this.relay } }),
    };
    const text = canonicalJson(unsigned);
    return { ...unsigned, sig: this.hostIdentity.sign(text) };
  }

 /** Serialized payload used both for the QR image and manual entry. */
  payloadText() {
    return canonicalJson(this.payload());
  }

 /**
 * Validate a redeem attempt. Returns the normalized device public key and
 * consumes the one-time token on success.
 */
  redeem({ pairToken, devicePubKey, deviceName, platform }) {
    if (this.session === undefined) return { error: 'pair/invalid' };
    if (typeof pairToken !== 'string' || pairToken.length === 0 || !constantTimeEquals(pairToken, this.session.token)) {
      return { error: 'pair/invalid' };
    }
    if (this.session.expiresAt <= Date.now()) {
      this.session = undefined;
      this.audit.record('pair.expired', {});
      return { error: 'pair/expired' };
    }
    let publicKey;
    try {
      publicKey = normalizeDevicePublicKey(devicePubKey);
    } catch (error) {
      return { error: 'pair/invalid-key', message: String(error?.message ?? error) };
    }
 // One-time use: consume before any further work.
    const pairId = this.session.id;
    this.session = undefined;
    return {
      pairId,
      publicKey,
      name: trimDeviceName(deviceName, 'iOS device'),
      platform: typeof platform === 'string' ? platform.slice(0, 32) : 'ios',
    };
  }
}

/**
 * M2a 8-digit pairing code service (m2-tunnel-design §5.1/§5.2).
 *
 * Separate from the one-time QR pair token on purpose:
 * - the QR token is a long random string carried in a signed payload;
 * - the code is 8 human-typeable digits, so it needs a short TTL, a strict
 * wrong-attempt cap and single use. It never enters the signed QR payload,
 * /health, audit lines or logs.
 *
 * Lifecycle: one active code at a time, auto-rotated every `pairCodeTtlMs`
 * (default 120s) so the desktop panel can always show a live code. A successful
 * redeem consumes the code and immediately issues the next one (the desktop
 * stays usable for another phone). Wrong codes burn `pairCodeMaxAttempts`
 * (default 5) attempts; the code is then locked until the desktop refreshes it.
 *
 * Events (no event carries the code value): pair.code.issued /
 * pair.code.refreshed / pair.code.refreshed-auto / pair.code.redeemed (recorded
 * by the link server, which knows the deviceId) / pair.code.rejected /
 * pair.code.expired / pair.code.locked.
 */
export const PAIR_CODE_LENGTH = 8;
export const PAIR_CODE_TTL_MS = 120_000;
export const PAIR_CODE_MAX_ATTEMPTS = 5;
/** How long an expired/consumed code is remembered for clearer error mapping. */
const PAIR_CODE_HISTORY_MS = 10 * 60_000;
const PAIR_CODE_HISTORY_LIMIT = 8;
const TICK_MS = 1_000;

/** 8-digit code: crypto.randomInt(0, 1e8), zero-padded (no modulo bias). */
export function generatePairCode() {
  return String(randomInt(0, 100_000_000)).padStart(PAIR_CODE_LENGTH, '0');
}

export class PairCodeService {
 /**
 * @param {{
 * config?: Record<string, unknown>,
 * audit: {record: (event: string, fields?: Record<string, unknown>) => void},
 * log?: (message: string) => void,
 * onChange?: (status: Record<string, unknown>, meta: {reason: string}) => void,
 * now?: => number,
 * ttlMs?: number,
 * maxAttempts?: number,
 * autoRotate?: boolean,
 * }} options
 */
  constructor({ config = {}, audit, log = () => {}, onChange = () => {}, now = () => Date.now(), ttlMs, maxAttempts, autoRotate = true } = {}) {
    this.audit = audit ?? { record: () => {} };
    this.log = log;
    this.onChange = onChange;
    this.now = now;
    this.ttlMs = Number.isInteger(ttlMs) && ttlMs >= 200
      ? ttlMs
      : Number.isInteger(config.pairCodeTtlMs) && config.pairCodeTtlMs >= 200
        ? config.pairCodeTtlMs
        : PAIR_CODE_TTL_MS;
    this.maxAttempts = Number.isInteger(maxAttempts) && maxAttempts >= 1
      ? maxAttempts
      : Number.isInteger(config.pairCodeMaxAttempts) && config.pairCodeMaxAttempts >= 1
        ? config.pairCodeMaxAttempts
        : PAIR_CODE_MAX_ATTEMPTS;
    this.autoRotate = autoRotate;
 /** @type {{value: string, issuedAt: number, expiresAt: number, attempts: number} | undefined} */
    this.session = undefined;
 /** @type {Map<string, {state: 'consumed'|'expired'|'locked', at: number}>} */
    this.history = new Map();
 /** Set while the current code is locked; cleared by the next issue(). */
    this.locked = false;
    this.timer = undefined;
  }

 /** Issue the first code and start the auto-rotation ticker. */
  start(reason = 'startup') {
    if (this.session === undefined && this.locked === false) this.issue(reason);
    this.startTicker();
    return this.status({ ensure: false });
  }

  startTicker() {
    if (this.timer !== undefined || !this.autoRotate) return;
 // Tick at most once a second, but fast enough that a short configured TTL
 // (tests, aggressive policies) still rotates within a fraction of it.
    this.tickMs = Math.max(25, Math.min(TICK_MS, Math.floor(this.ttlMs / 4)));
    this.timer = setInterval(() => this.tick(), this.tickMs);
    if (typeof this.timer.unref === 'function') this.timer.unref();
  }

  tick() {
    const session = this.session;
    if (session !== undefined && session.expiresAt <= this.now()) {
      this.expireCurrent();
      this.issue('auto');
    }
  }

 /** Mint a fresh code (replacing any previous one). */
  issue(reason = 'manual') {
    const issuedAt = this.now();
    this.session = { value: generatePairCode(), issuedAt, expiresAt: issuedAt + this.ttlMs, attempts: 0 };
    this.locked = false;
 // A locked code is superseded by the fresh code: replaying it afterwards is
 // plain invalid (401), not "still locked" (423) — the lock applied to that
 // one code, and the desktop already refreshed it.
    for (const entry of this.history.values()) {
      if (entry.state === 'locked') entry.state = 'consumed';
    }
    const auto = reason !== 'manual' && reason !== 'startup';
    const event = reason === 'startup' ? 'pair.code.issued' : auto ? 'pair.code.refreshed-auto' : 'pair.code.refreshed';
    this.audit.record(event, { reason, expiresAt: new Date(this.session.expiresAt).toISOString() });
    this.notify(reason);
    return this.session;
  }

 /** Issue a code only when there is no live one (never reuses a code). */
  ensure(reason = 'auto') {
    const session = this.session;
    if (session !== undefined && session.expiresAt > this.now()) return session;
    if (session !== undefined) this.expireCurrent();
    return this.issue(reason);
  }

 /** Refresh on user request (desktop button). */
  refresh(reason = 'manual') {
    return this.issue(reason === 'manual' ? 'manual' : reason);
  }

 /** Active code without side effects (used by /health and Bonjour TXT). */
  current() {
    const session = this.session;
    if (session === undefined || session.expiresAt <= this.now()) return undefined;
    return session;
  }

 /**
 * Public/desktop status. `ensure: true` (default) auto-issues an expired code,
 * which is what keeps the desktop panel always usable.
 */
  status({ ensure = true } = {}) {
    if (ensure) this.ensure();
    const session = this.session;
    if (session === undefined) {
      return { active: false, value: null, expiresAt: null, attemptsLeft: this.maxAttempts, attemptsUsed: 0, maxAttempts: this.maxAttempts, ttlMs: this.ttlMs, remainingMs: 0, locked: this.locked };
    }
    const remainingMs = Math.max(0, session.expiresAt - this.now());
    return {
      active: remainingMs > 0 && this.locked === false,
      value: session.value,
      expiresAt: session.expiresAt,
      attemptsLeft: Math.max(0, this.maxAttempts - session.attempts),
      attemptsUsed: session.attempts,
      maxAttempts: this.maxAttempts,
      ttlMs: this.ttlMs,
      remainingMs,
      locked: this.locked || session.attempts >= this.maxAttempts,
    };
  }

 /** Compact status for the desktop admin `pairing` action: {value, expiresAt, attemptsLeft}. */
  adminCode() {
    const status = this.status({ ensure: true });
    return {
      active: status.active,
      value: status.active ? status.value : null,
      expiresAt: status.expiresAt,
      attemptsLeft: status.attemptsLeft,
      remainingMs: status.remainingMs,
      ttlMs: this.ttlMs,
      maxAttempts: status.maxAttempts,
      locked: status.locked,
    };
  }

 /**
 * Validate a presented code without consuming it.
 *
 * Order matters for UX/security: recently consumed/expired codes are mapped
 * before comparing against the live code, so replaying an old code never
 * burns one of the live code's 5 attempts.
 *
 * @param {string} presented
 * @param {{ip?: string}} [meta]
 * @returns {{ok: true, session: object} | {error: string, remaining?: number}}
 */
  check(presented, { ip } = {}) {
    const now = this.now();
    const value = typeof presented === 'string' ? presented.trim() : '';
    if (this.session !== undefined && this.session.expiresAt <= now) {
      this.expireCurrent();
    }
    const remembered = this.rememberedState(value);
    if (remembered === 'locked') {
      this.audit.record('pair.code.rejected', { ip, remaining: 0, reason: 'locked' });
      return { error: 'code/locked' };
    }
    if (remembered === 'expired') {
      this.audit.record('pair.code.expired', { ip });
      return { error: 'code/expired' };
    }
    if (remembered === 'consumed') return { error: 'code/invalid', remaining: this.session === undefined ? 0 : Math.max(0, this.maxAttempts - this.session.attempts) };
    if (this.locked) return { error: 'code/locked' };
    const session = this.session;
    if (session === undefined) return { error: 'code/invalid', remaining: 0 };
 // Only well-formed 8-digit input burns an attempt: malformed junk from a
 // broken client should not lock a code the user is about to type.
    const wellFormed = value.length === PAIR_CODE_LENGTH && /^\d{8}$/.test(value);
    if (!constantTimeEquals(value, session.value)) {
      if (!wellFormed) return { error: 'code/invalid', remaining: Math.max(0, this.maxAttempts - session.attempts) };
      session.attempts += 1;
      const remaining = Math.max(0, this.maxAttempts - session.attempts);
      this.audit.record('pair.code.rejected', { ip, remaining });
      if (session.attempts >= this.maxAttempts) {
        this.locked = true;
        this.remember(session.value, 'locked');
        this.session = undefined;
        this.audit.record('pair.code.locked', { ip });
        this.notify('locked');
        return { error: 'code/locked' };
      }
      return { error: 'code/invalid', remaining };
    }
    return { ok: true, session };
  }

 /**
 * Consume the live code after a successful check (single use). The next code
 * is issued immediately so the desktop panel never shows a dead code.
 */
  consume() {
    const session = this.session;
    if (session === undefined) return undefined;
    this.remember(session.value, 'consumed');
    this.session = undefined;
    this.locked = false;
    this.issue('after-redeem');
    return session.value;
  }

 /** Drop everything (dispose): no code is reused after a restart. */
  dispose() {
    if (this.timer !== undefined) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
    this.session = undefined;
    this.locked = false;
    this.history.clear();
  }

  expireCurrent() {
    const session = this.session;
    if (session === undefined) return;
    this.remember(session.value, 'expired');
    this.session = undefined;
    this.audit.record('pair.code.expired', { reason: 'ttl' });
    this.notify('expired');
  }

  notify(reason) {
    try {
      this.onChange?.(this.status({ ensure: false }), { reason });
    } catch (error) {
      this.log('pair code onChange failed: ' + String(error?.message ?? error));
    }
  }

  remember(value, state) {
    if (typeof value !== 'string' || value.length === 0) return;
    const now = this.now();
    this.history.set(value, { state, at: now });
    for (const [key, entry] of this.history) {
      if (now - entry.at > PAIR_CODE_HISTORY_MS) this.history.delete(key);
    }
    while (this.history.size > PAIR_CODE_HISTORY_LIMIT) {
      const oldest = this.history.keys().next().value;
      this.history.delete(oldest);
    }
  }

  rememberedState(value) {
    if (typeof value !== 'string' || value.length === 0) return undefined;
    const entry = this.history.get(value);
    if (entry === undefined) return undefined;
    if (this.now() - entry.at > PAIR_CODE_HISTORY_MS) {
      this.history.delete(value);
      return undefined;
    }
    return entry.state;
  }
}