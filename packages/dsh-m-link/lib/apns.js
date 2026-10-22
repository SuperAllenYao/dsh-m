/**
 * apns.js — APNs provider for dsh-m-link (M1, direct from the Mac plugin).
 *
 * Configuration (cordis patch row, never committed):
 *   apns:
 *     keyFile: /Users/me/.dsh/plugin-data/dsh-m-link/apns/AuthKey_ABC123.p8
 *     keyId: ABC123DEFG
 *     teamId: TEAM123456
 *     topic: com.example.dshm            # the iOS app bundle id
 *     environment: production            # or sandbox
 *
 * Without a complete configuration the provider degrades to an explicit stub:
 * notifications are reported as "stub" in the audit log and the admin UI shows
 * "APNs: stub (not configured)". The .p8 key is only read at startup, never
 * logged, never copied, and never written by the plugin.
 */

import { createHash, createPrivateKey, sign } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename } from 'node:path';
import http2 from 'node:http2';

const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};
const SEND_TIMEOUT_MS = 8000;

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

/** Convert an ASN.1 DER ECDSA signature to the raw 64-byte r||s JOSE form. */
export function derSignatureToRaw(der) {
  let offset = 0;
  if (der[offset] !== 0x30) throw new Error('apns: signature is not a DER sequence');
  offset += 1;
  const seqLength = der[offset];
  offset += 1;
  if (seqLength > 0x80) {
    const lengthBytes = seqLength & 0x7f;
    offset += lengthBytes;
  }
  if (der[offset] !== 0x02) throw new Error('apns: signature r is not an INTEGER');
  offset += 1;
  let rLength = der[offset];
  offset += 1;
  const r = der.subarray(offset, offset + rLength);
  offset += rLength;
  if (der[offset] !== 0x02) throw new Error('apns: signature s is not an INTEGER');
  offset += 1;
  let sLength = der[offset];
  offset += 1;
  const s = der.subarray(offset, offset + sLength);
  const pad = (bytes) => {
    let value = bytes;
    while (value.length > 32 && value[0] === 0) value = value.subarray(1);
    return value.length >= 32 ? value.subarray(value.length - 32) : Buffer.concat([Buffer.alloc(32 - value.length), value]);
  };
  return Buffer.concat([pad(r), pad(s)]);
}

/** Short non-reversible label for a device token (never log the token itself). */
export function tokenFingerprint(token) {
  return createHash('sha256').update(String(token)).digest('hex').slice(0, 10);
}

/** Expand a leading "~/" in a configured path. */
export function expandHome(filePath) {
  if (typeof filePath !== 'string' || filePath.length === 0) return filePath;
  if (filePath === '~') return homedir();
  if (filePath.startsWith('~/')) return homedir() + filePath.slice(1);
  return filePath;
}

/**
 * Parse the small, flat APNs config file users keep outside the repository.
 *
 * Accepts JSON or the documented YAML subset:
 *   apns:
 *     keyFile: /Users/me/.dsh/keys/AuthKey_XXX.p8
 *     keyId: XXXXXXXXXX
 *     teamId: XXXXXXXXXX
 *     topic: com.example.app
 *     environment: sandbox
 *
 * Only identifiers and the key path live in this file; the .p8 content never
 * leaves its own 0600 file.
 */
export function readApnsConfigFile(filePath) {
  const resolved = expandHome(filePath);
  if (!existsSync(resolved)) throw new Error('apns config file does not exist: ' + resolved);
  const text = readFileSync(resolved, 'utf8');
  const trimmed = text.trim();
  if (trimmed.startsWith('{')) {
    const parsed = JSON.parse(trimmed);
    return { ...(parsed.apns ?? parsed) };
  }
  const result = {};
  let inApns = false;
  for (const rawLine of text.split('\n')) {
    const withoutComment = rawLine.replace(/\s+#.*$/, '');
    const line = withoutComment.trimEnd();
    if (line.trim().length === 0) continue;
    const keyMatch = line.match(/^([A-Za-z0-9_]+):\s*$/);
    if (keyMatch !== null) {
      inApns = keyMatch[1] === 'apns';
      continue;
    }
    if (!inApns) continue;
    if (!/^\s+\S/.test(line)) {
      inApns = false;
      continue;
    }
    const pair = line.trim().match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (pair === null) continue;
    let value = pair[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    result[pair[1]] = value;
  }
  return result;
}

/**
 * Build the APNs JSON body for one notification.
 *
 * Apple's contract keeps `aps` reserved for system keys (alert/sound/badge/
 * thread-id); custom keys belong at the **payload root**. The previous M1
 * implementation nested the caller `data` inside `aps` under `"dsh-m"`
 * (delivered fine, but non-standard — real-device notification actions lost
 * sessionId because of the mismatched decode). The iOS app
 * (`PushNotificationPayload`) accepts the root form, the legacy
 * `aps["dsh-m"]` form and `root["dsh-m"]`, so both old and new app builds
 * decode this payload. See docs/design/apns-payload-root-level.patch.md.
 *
 * Exported as a pure function so test/apns-payload-shape.mjs can assert the
 * wire shape without touching Apple's servers.
 *
 * Two modes (M4 notification hardening):
 * - alert (default): `{aps:{alert,sound,"thread-id",category?}, ...data}`;
 *   `category` makes iOS show the registered notification actions (approval
 *   allow/deny for `dshm-approval`).
 * - silent: `{aps:{"content-available":1}, ...data}` — background refresh
 *   push, no visible alert; iOS delivers it through
 *   `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
 *
 * @param {{title?: string, body?: string, threadId?: string, data?: object,
 *          category?: string, silent?: boolean}} [input]
 * @returns {string} JSON payload
 */
export function buildApnsPayload({ title, body, threadId, data, category, silent } = {}) {
  const root = data === undefined ? {} : data;
  if (silent === true) {
    // Background push: content-available only; custom keys stay at the root.
    return JSON.stringify({ aps: { 'content-available': 1 }, ...root });
  }
  const aps = {
    alert: { title, body },
    sound: 'default',
    'thread-id': threadId,
    // Only when the caller registered the matching UNNotificationCategory
    // (iOS: `dshm-approval`). Absent for every other notification kind.
    ...(typeof category === 'string' && category.length > 0 ? { category } : {}),
  };
  // `undefined` values are dropped by JSON.stringify, so an absent threadId
  // simply omits "thread-id" — same behaviour as before the change.
  return JSON.stringify({ aps, ...root });
}

/**
 * APNs HTTP/2 headers for an alert vs a background (silent) push.
 *
 * Apple requires `apns-push-type: background` + `apns-priority: 5` for
 * content-available pushes; a mismatch makes APNs reject the request.
 *
 * @param {{silent?: boolean}} [input]
 * @returns {{'apns-push-type': string, 'apns-priority': string}}
 */
export function buildApnsHeaders({ silent } = {}) {
  return silent === true
    ? { 'apns-push-type': 'background', 'apns-priority': '5' }
    : { 'apns-push-type': 'alert', 'apns-priority': '10' };
}

export class ApnsProvider {
  /**
   * @param {{
   *   config?: {keyFile?: string, keyId?: string, teamId?: string, topic?: string, environment?: string},
   *   log?: (message: string) => void,
   * }} options
   */
  constructor({ config, log = () => {} } = {}) {
    this.config = config ?? {};
    this.log = log;
    /** @type {'stub'|'ready'|'error'} */
    this.mode = 'stub';
    this.reason = 'not configured';
    this.key = undefined;
    this.topic = undefined;
    this.environment = 'production';
    this.initialized = false;
    this.lastError = undefined;
    this.sent = 0;
    this.failed = 0;
  }

  init() {
    if (this.initialized) return this;
    this.initialized = true;
    this.configSource = 'inline';
    let config = { ...this.config };
    if (typeof config.configFile === 'string' && config.configFile.length > 0) {
      const resolved = expandHome(config.configFile);
      try {
        const fromFile = readApnsConfigFile(resolved);
        // Inline config wins over the file, so a profile can override one field.
        config = { ...fromFile, ...Object.fromEntries(Object.entries(this.config).filter(([, value]) => value !== undefined && value !== '')) };
        this.configSource = 'file';
        this.configFile = resolved;
        this.log('APNs config loaded from ' + resolved + ' (key file: ' + basename(expandHome(String(config.keyFile ?? 'missing'))) + ')');
      } catch (error) {
        this.mode = 'error';
        this.reason = 'cannot read apns.configFile: ' + String(error?.message ?? error);
        this.log('APNs error: ' + this.reason);
        return this;
      }
    }
    const { keyId, teamId, topic, environment } = config;
    const keyFile = typeof config.keyFile === 'string' ? expandHome(config.keyFile) : undefined;
    this.keyFile = keyFile;
    if (typeof keyFile !== 'string' || keyFile.length === 0) {
      this.mode = 'stub';
      this.reason = 'apns.keyFile not configured';
      this.log('APNs stub: ' + this.reason + '; notifications are logged as stub and not delivered');
      return this;
    }
    if (typeof keyId !== 'string' || keyId.length === 0 || typeof teamId !== 'string' || teamId.length === 0) {
      this.mode = 'error';
      this.reason = 'apns.keyId/apns.teamId missing';
      this.log('APNs error: ' + this.reason + '; notifications will fail');
      return this;
    }
    if (!existsSync(keyFile)) {
      this.mode = 'error';
      this.reason = 'apns.keyFile does not exist: ' + keyFile;
      this.log('APNs error: ' + this.reason);
      return this;
    }
    if (keyFile.includes('/packages/dsh-m-link/') || keyFile.includes('/dsh-m/packages/')) {
      this.log('WARNING: apns.keyFile points inside the dsh-m repository (' + keyFile + '); move it outside the repo — .p8 keys must never be committed');
    }
    try {
      this.key = createPrivateKey({ key: readFileSync(keyFile), format: 'pem' });
      if (this.key.asymmetricKeyType !== 'ec') throw new Error('key is not an EC private key');
      this.keyId = keyId;
      this.teamId = teamId;
      this.topic = typeof topic === 'string' && topic.length > 0 ? topic : undefined;
      this.environment = environment === 'sandbox' ? 'sandbox' : 'production';
      this.mode = 'ready';
      this.reason = 'configured';
      this.log('APNs ready (environment ' + this.environment + (this.topic === undefined ? ', topic from registration required' : ', topic ' + this.topic) + ')');
    } catch (error) {
      this.mode = 'error';
      this.reason = 'cannot load apns.keyFile: ' + String(error?.message ?? error);
      this.log('APNs error: ' + this.reason);
    }
    return this;
  }

  get configured() {
    return this.mode === 'ready';
  }

  /** Build the ES256 provider JWT (Apple token-based auth). */
  buildProviderToken(nowSeconds = Math.floor(Date.now() / 1000)) {
    if (this.mode !== 'ready') throw new Error('APNs provider is not configured');
    const header = base64UrlJson({ alg: 'ES256', kid: this.keyId });
    const claims = base64UrlJson({ iss: this.teamId, iat: nowSeconds });
    const signingInput = header + '.' + claims;
    const der = sign('sha256', Buffer.from(signingInput, 'utf8'), this.key);
    return signingInput + '.' + derSignatureToRaw(der).toString('base64url');
  }

  /**
   * Deliver one short notification. Stub mode reports success with stub:true so
   * callers can uniformly audit the attempt.
   *
   * `silent: true` sends a background (content-available) push; `category`
   * attaches an iOS notification category (only meaningful for alert pushes).
   */
  async send({ deviceToken, environment, topic, title, body, threadId, data, category, silent }) {
    if (typeof deviceToken !== 'string' || deviceToken.length === 0) {
      return { ok: false, error: 'apns/device-token-missing' };
    }
    if (this.mode !== 'ready') {
      return this.mode === 'stub'
        ? { ok: true, stub: true, reason: this.reason }
        : { ok: false, stub: false, error: 'apns/not-configured', reason: this.reason };
    }
    const env = environment === 'sandbox' ? 'sandbox' : this.environment;
    const apnsTopic = topic ?? this.topic;
    if (apnsTopic === undefined) return { ok: false, error: 'apns/topic-missing' };
    // Custom keys go at the payload root (Apple convention); see
    // buildApnsPayload() above for the compatibility notes.
    const payload = buildApnsPayload({ title, body, threadId, data, category, silent });
    const path = '/3/device/' + deviceToken;
    let client;
    try {
      client = http2.connect(APNS_HOSTS[env]);
      const jwt = this.buildProviderToken();
      const status = await new Promise((resolve, reject) => {
        let settled = false;
        const finish = (value) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(value);
        };
        const timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          reject(new Error('APNs request timed out'));
        }, SEND_TIMEOUT_MS);
        const request = client.request({
          ':method': 'POST',
          ':path': path,
          authorization: 'bearer ' + jwt,
          'apns-topic': apnsTopic,
          ...buildApnsHeaders({ silent }),
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(payload),
        });
        request.on('response', (headers) => {
          const chunks = [];
          request.on('data', (chunk) => chunks.push(chunk));
          request.on('end', () => {
            let reason;
            try {
              const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
              if (typeof parsed?.reason === 'string') reason = parsed.reason;
            } catch {
              /* APNs error bodies are JSON but tolerate empty/non-JSON */
            }
            finish({ status: Number(headers[':status']), apnsId: headers['apns-id'], reason });
          });
        });
        request.on('error', (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(error);
        });
        request.end(payload);
      });
      if (status.status === 200) {
        this.sent += 1;
        this.lastResult = { ok: true, status: 200, at: new Date().toISOString() };
        return { ok: true, status: 200, apnsId: status.apnsId };
      }
      this.failed += 1;
      this.lastResult = { ok: false, status: status.status, reason: status.reason, at: new Date().toISOString() };
      return {
        ok: false,
        status: status.status,
        reason: status.reason,
        error: status.reason === undefined ? 'apns/http-' + String(status.status) : 'apns/' + status.reason,
      };
    } catch (error) {
      this.failed += 1;
      return { ok: false, error: String(error?.message ?? error) };
    } finally {
      try {
        client?.close();
      } catch {
        /* already gone */
      }
    }
  }

  info() {
    return {
      mode: this.mode,
      reason: this.reason,
      environment: this.mode === 'ready' ? this.environment : this.environment,
      topic: this.topic ?? null,
      keyId: this.mode === 'ready' ? this.keyId : null,
      teamIdConfigured: this.mode === 'ready',
      configuredFrom: this.configSource ?? 'inline',
      keyFile: this.keyFile === undefined ? null : basename(this.keyFile),
      sent: this.sent,
      failed: this.failed,
      lastResult: this.lastResult ?? null,
    };
  }
}