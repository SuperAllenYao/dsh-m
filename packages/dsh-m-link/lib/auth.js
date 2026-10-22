/**
 * auth.js — device authentication for dsh-m-link (M1).
 *
 * Flow (all over the plugin's own TLS origin, after the phone pinned the CA):
 * 1. POST /auth/challenge Authorization: Bearer <long-term device credential>
 * body {purpose:"api"|"mux"} -> {challengeId, nonce, message, expiresAt}
 * 2. The phone signs the exact UTF-8 message with its Secure-Enclave P-256
 * key (ECDSA-P256-SHA256, DER, base64url) and calls
 * 3. POST /auth/verify {challengeId, signature} -> short-lived bearer token
 * ("api": reusable until expiry, "mux": single-use, bound to one upgrade).
 *
 * Properties enforced here: one-time nonces with a time window (challenge TTL),
 * signature verification against the stored public key, per-device failure
 * rate limiting, revocation check on every step, and tokens that never touch
 * disk (in-memory map, keyed by sha256 of the token).
 */

import { createHash, randomBytes, randomUUID, timingSafeEqual, verify } from 'node:crypto';

import { keyFingerprint256 } from './devices.js';

export const AUTH_MESSAGE_PREFIX = 'dsh-m-link/1';
const PURPOSES = new Set(['api', 'mux']);
const MAX_CHALLENGES = 1024;

/** Canonical challenge message; the phone must sign these exact bytes. */
export function buildChallengeMessage({ deviceId, challengeId, nonce, purpose, issuedAt }) {
  return [
    AUTH_MESSAGE_PREFIX,
    'deviceId=' + deviceId,
    'challengeId=' + challengeId,
    'nonce=' + nonce,
    'purpose=' + purpose,
    'issuedAt=' + String(issuedAt),
  ].join('\n');
}

function sha256Base64Url(value) {
  return createHash('sha256').update(value).digest('base64url');
}

/** Convert a raw 64-byte r||s ECDSA signature to ASN.1 DER. */
export function rawSignatureToDer(raw) {
  if (raw.length !== 64) throw new Error('raw signature must be 64 bytes');
  const trim = (bytes) => {
    let index = 0;
    while (index < bytes.length - 1 && bytes[index] === 0) index += 1;
    let out = bytes.subarray(index);
    if ((out[0] & 0x80) !== 0) out = Buffer.concat([Buffer.from([0]), out]);
    return out;
  };
  const r = trim(raw.subarray(0, 32));
  const s = trim(raw.subarray(32));
  const body = Buffer.concat([Buffer.from([0x02, r.length]), r, Buffer.from([0x02, s.length]), s]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
}

function decodeSignature(value) {
  if (typeof value !== 'string' || value.length === 0) throw new Error('signature missing');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length === 64) return rawSignatureToDer(bytes);
  if (bytes.length > 8 && bytes[0] === 0x30) return bytes;
  throw new Error('signature must be base64url DER or a raw 64-byte r||s value');
}

export class AuthService {
 /**
 * @param {{
 * devices: import('./devices.js').DeviceStore,
 * audit: import('./audit.js').AuditLog,
 * config: {challengeTtlMs: number, apiTokenTtlMs: number, muxTokenTtlMs: number, maxAuthFailuresPerMinute: number, maxChallenges?: number},
 * log?: (message: string) => void,
 * }} options
 */
  constructor({ devices, audit, config, log = () => {} }) {
    this.devices = devices;
    this.audit = audit;
    this.config = config;
    this.log = log;
 /** @type {Map<string, {id: string, nonce: string, purpose: string, deviceId: string, issuedAt: number, expiresAt: number, message: string, ip?: string}>} */
    this.challenges = new Map();
 /** @type {Map<string, {deviceId: string, purpose: string, expiresAt: number, issuedAt: number}>} */
    this.tokens = new Map();
 /** @type {Map<string, {minuteStart: number, failures: number}>} */
    this.failures = new Map();
  }

 /** Register one successful or failed auth attempt for rate limiting. */
  noteFailure(deviceId) {
    const now = Date.now();
    const record = this.failures.get(deviceId);
    if (record === undefined || now - record.minuteStart > 60_000) {
      this.failures.set(deviceId, { minuteStart: now, failures: 1 });
      return;
    }
    record.failures += 1;
  }

  isRateLimited(deviceId) {
    const record = this.failures.get(deviceId);
    if (record === undefined) return false;
    if (Date.now() - record.minuteStart > 60_000) {
      this.failures.delete(deviceId);
      return false;
    }
    return record.failures >= this.config.maxAuthFailuresPerMinute;
  }

  sweep() {
    const now = Date.now();
    for (const [id, challenge] of this.challenges) {
      if (challenge.expiresAt <= now) this.challenges.delete(id);
    }
    for (const [hash, token] of this.tokens) {
      if (token.expiresAt <= now) this.tokens.delete(hash);
    }
    if (this.challenges.size > MAX_CHALLENGES) {
      const ordered = [...this.challenges.entries()].sort((left, right) => left[1].issuedAt - right[1].issuedAt);
      for (const [id] of ordered.slice(0, ordered.length - MAX_CHALLENGES)) this.challenges.delete(id);
    }
  }

 /** Resolve the device behind a long-term credential (only valid for challenges). */
  deviceForCredential(credential, { ip } = {}) {
    const device = this.devices.findByCredential(credential);
    if (device === undefined) return { error: 'auth/invalid' };
    if (device.revokedAt !== undefined) {
      this.audit.record('auth.revoked-attempt', { deviceId: device.deviceId, keyId: device.keyId, ip });
      return { error: 'auth/revoked' };
    }
    return { device };
  }

 /** Issue a one-time challenge for a purpose ("api" or "mux"). */
  issueChallenge({ credential, purpose, ip }) {
    if (!PURPOSES.has(purpose)) return { error: 'auth/bad-purpose' };
    const resolved = this.deviceForCredential(credential, { ip });
    if (resolved.error !== undefined) return resolved;
    const device = resolved.device;
    if (this.isRateLimited(device.deviceId)) {
      this.audit.record('auth.rate-limited', { deviceId: device.deviceId, keyId: device.keyId, ip });
      return { error: 'auth/rate-limited' };
    }
    this.sweep();
    const challengeId = randomUUID();
    const nonce = randomBytes(32).toString('base64url');
    const issuedAt = Date.now();
    const expiresAt = issuedAt + this.config.challengeTtlMs;
    const message = buildChallengeMessage({ deviceId: device.deviceId, challengeId, nonce, purpose, issuedAt });
    this.challenges.set(challengeId, { id: challengeId, nonce, purpose, deviceId: device.deviceId, issuedAt, expiresAt, message, ip });
    this.audit.record('auth.challenge', { deviceId: device.deviceId, keyId: device.keyId, purpose, ip });
    return { challenge: { challengeId, nonce, purpose, deviceId: device.deviceId, issuedAt, expiresAt, message } };
  }

 /** Verify one challenge signature and mint a bearer token. */
  verifyChallenge({ challengeId, signature, ip }) {
 // Look the challenge up before sweeping so an expired-but-known challenge
 // reports "expired" (a distinct, actionable error) instead of "invalid".
    const challenge = typeof challengeId === 'string' ? this.challenges.get(challengeId) : undefined;
    if (challenge === undefined) {
      this.sweep();
      return { error: 'auth/challenge-invalid' };
    }
 // One-time: consume before verification so a replay cannot retry.
    this.challenges.delete(challenge.id);
    this.sweep();
    if (challenge.expiresAt <= Date.now()) {
      this.audit.record('auth.challenge-expired', { deviceId: challenge.deviceId, ip });
      return { error: 'auth/challenge-expired' };
    }
    const device = this.devices.get(challenge.deviceId);
    if (device === undefined) return { error: 'auth/invalid' };
    if (device.revokedAt !== undefined) {
      this.audit.record('auth.revoked-attempt', { deviceId: device.deviceId, keyId: device.keyId, ip });
      return { error: 'auth/revoked' };
    }
    if (this.isRateLimited(device.deviceId)) {
      this.audit.record('auth.rate-limited', { deviceId: device.deviceId, keyId: device.keyId, ip });
      return { error: 'auth/rate-limited' };
    }
    let ok = false;
    try {
      const key = { key: Buffer.from(device.publicKey, 'base64url'), format: 'der', type: 'spki' };
      ok = verify('sha256', Buffer.from(challenge.message, 'utf8'), key, decodeSignature(signature));
    } catch {
      ok = false;
    }
    if (!ok) {
      this.noteFailure(device.deviceId);
      this.audit.record('auth.signature-invalid', { deviceId: device.deviceId, keyId: device.keyId, purpose: challenge.purpose, ip });
      return { error: 'auth/signature-invalid' };
    }
    const token = randomBytes(32).toString('base64url');
    const expiresAt = Date.now() + (challenge.purpose === 'api' ? this.config.apiTokenTtlMs : this.config.muxTokenTtlMs);
    this.tokens.set(sha256Base64Url(token), {
      deviceId: device.deviceId,
      purpose: challenge.purpose,
      issuedAt: Date.now(),
      expiresAt,
    });
    device.lastSeenAt = Date.now();
    if (typeof ip === 'string') device.lastIp = ip;
    this.devices.save();
    this.audit.record('auth.ok', { deviceId: device.deviceId, keyId: device.keyId, purpose: challenge.purpose, ip, keyFingerprint: keyFingerprint256(Buffer.from(device.publicKey, 'base64url')).slice(0, 11) });
    return { token: { token, purpose: challenge.purpose, expiresAt, deviceId: device.deviceId } };
  }

 /** Look up a bearer token without consuming it (api purpose). */
  peekToken(value, purpose) {
    if (typeof value !== 'string' || value.length === 0) return { error: 'auth/required' };
    const record = this.tokens.get(sha256Base64Url(value));
    if (record === undefined || record.purpose !== purpose) return { error: 'auth/invalid' };
    if (record.expiresAt <= Date.now()) {
      this.tokens.delete(sha256Base64Url(value));
      return { error: 'auth/token-expired' };
    }
    if (record.revoked === true) {
      this.tokens.delete(sha256Base64Url(value));
      return { error: 'auth/revoked' };
    }
    const device = this.devices.get(record.deviceId);
    if (device === undefined) {
      this.tokens.delete(sha256Base64Url(value));
      return { error: 'auth/invalid' };
    }
    if (device.revokedAt !== undefined) {
      this.dropDeviceTokens(device.deviceId);
      return { error: 'auth/revoked' };
    }
    return { device, record };
  }

 /** Consume a single-use mux token. */
  consumeMuxToken(value) {
    const peeked = this.peekToken(value, 'mux');
    if (peeked.error !== undefined) return peeked;
    this.tokens.delete(sha256Base64Url(value));
    return peeked;
  }

 /**
 * Mark every token of one device revoked. The records are kept until their
 * natural expiry so a stolen-but-live token answers "auth/revoked" instead of
 * a generic "auth/invalid" — the iOS client uses that code to clear Keychain.
 */
  revokeDeviceTokens(deviceId) {
    let count = 0;
    for (const record of this.tokens.values()) {
      if (record.deviceId === deviceId && record.revoked !== true) {
        record.revoked = true;
        count += 1;
      }
    }
    return count;
  }

 /** Drop every token belonging to one device (used on dispose). */
  dropDeviceTokens(deviceId) {
    for (const [hash, record] of this.tokens) {
      if (record.deviceId === deviceId) this.tokens.delete(hash);
    }
  }

 /** Clear all in-memory challenges/tokens/rate-limit state (dispose path). */
  dispose() {
    try {
      this.challenges.clear();
      this.tokens.clear();
      this.failures.clear();
    } catch {
 /* nothing to clear */
    }
  }

 /** Bearer credential extraction helper for a raw Authorization header. */
  static bearer(header) {
    if (typeof header !== 'string' || !header.startsWith('Bearer ')) return undefined;
    const value = header.slice('Bearer '.length).trim();
    return value.length === 0 ? undefined : value;
  }

  static constantTimeEquals(left, right) {
    const a = Buffer.from(String(left));
    const b = Buffer.from(String(right));
    return a.length === b.length && timingSafeEqual(a, b);
  }
}