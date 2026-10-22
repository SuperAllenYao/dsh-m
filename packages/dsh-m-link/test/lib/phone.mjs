/**
 * phone.mjs — "iPhone" simulator for the M1 tests.
 *
 * Speaks exactly what the iOS client must speak (see PAIRING.zh.md):
 *   HTTPS  GET  /health
 *   HTTPS  POST /pair/redeem            (one-time QR token + P-256 device public key)
 *   HTTPS  POST /auth/challenge         (long-term credential -> nonce message)
 *   HTTPS  POST /auth/verify            (ECDSA-P256 signature -> short-lived token)
 *   HTTPS  POST /api/<endpoint>         (api token in Authorization)
 *   WSS    /api/remote.mux              (single-use mux token in Authorization)
 * plus TLS pinning with the pins carried by the QR payload.
 */

import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { request as httpsRequest } from 'node:https';

import { collectStream, MuxConnection, sleep } from './mux.mjs';
import { WsClient } from './ws-client.mjs';

/** HTTPS JSON call with TLS leaf fingerprint pinning. */
export function httpsJson(origin, method, path, options = {}) {
  const { body, headers = {}, pin } = options;
  return new Promise((resolve, reject) => {
    const url = new URL(path, origin);
    const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const requestHeaders = { ...headers };
    if (payload !== undefined) {
      requestHeaders['content-type'] = requestHeaders['content-type'] ?? 'application/json';
      requestHeaders['content-length'] = String(payload.length);
    }
    const request = httpsRequest(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method,
        headers: requestHeaders,
        rejectUnauthorized: false,
        // A fresh TLS handshake per call: Node's default agent caches TLS
        // sessions, and a resumed session makes getPeerCertificate() empty —
        // that would silently skip the pin check (M0 had this latent flaw).
        agent: false,
      },
      (response) => {
        const peer = response.socket.getPeerCertificate();
        const fingerprint = peer?.fingerprint256;
        if (typeof pin === 'string' && pin.length > 0 && fingerprint !== pin) {
          response.destroy();
          reject(new Error('TLS pin mismatch on ' + method + ' ' + path + ': expected ' + pin + ', got ' + String(fingerprint)));
          return;
        }
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json;
          try {
            json = JSON.parse(text);
          } catch {
            json = undefined;
          }
          resolve({ status: response.statusCode, headers: response.headers, text, json, peerFingerprint: fingerprint });
        });
      },
    );
    request.on('error', reject);
    if (payload !== undefined) request.write(payload);
    request.end();
  });
}

/** One simulated phone with its own Secure-Enclave-shaped P-256 key. */
export class PhoneLink {
  /**
   * @param {{origin: string, pin?: string, deviceName?: string, log?: (message: string) => void}} options
   */
  constructor({ origin, pin, deviceName = 'M1 phone simulator', log = () => {} }) {
    this.origin = origin;
    this.pin = pin;
    this.deviceName = deviceName;
    this.log = log;
    const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    this.privateKey = privateKey;
    this.publicKeySpki = publicKey.export({ type: 'spki', format: 'der' });
    this.publicKeyBase64Url = this.publicKeySpki.toString('base64url');
    this.deviceId = undefined;
    this.credential = undefined;
    this.keyId = undefined;
    this.apiToken = undefined;
    this.apiTokenExpiresAt = undefined;
    this.mux = undefined;
    this.frameLog = [];
  }

  /** Learn pins from /health the way a real app would after scanning the QR. */
  static async discover(origin) {
    const response = await httpsJson(origin, 'GET', '/health');
    return {
      health: response.json,
      caFingerprint256: response.json?.tls?.caFingerprint256,
      leafFingerprint256: response.json?.tls?.leafFingerprint256,
      peerFingerprint: response.peerFingerprint,
    };
  }

  async pair(payload) {
    const endpoint = payload.endpoints?.find((entry) => entry.url === this.origin) ?? payload.endpoints?.[0];
    const response = await httpsJson(this.origin, 'POST', '/pair/redeem', {
      pin: payload.tls?.leafFingerprint256,
      body: {
        pairToken: payload.pair?.token,
        devicePubKey: this.publicKeyBase64Url,
        deviceName: this.deviceName,
        platform: 'ios-simulator',
      },
    });
    if (response.status !== 200 || response.json?.ok !== true) {
      throw new Error('pair/redeem failed: HTTP ' + String(response.status) + ' ' + response.text.slice(0, 300));
    }
    this.deviceId = response.json.deviceId;
    this.credential = response.json.credential;
    this.keyId = response.json.keyId;
    this.serverInfo = response.json.server;
    if (endpoint === undefined) throw new Error('payload has no endpoint for ' + this.origin);
    this.log('paired as ' + this.deviceId + ' (key ' + String(this.keyId).slice(0, 12) + '…)');
    return response.json;
  }

  authHeaders() {
    return this.credential === undefined ? {} : { authorization: 'Bearer ' + this.credential };
  }

  /** PKCS8 PEM of the device key (test plumbing for the post-restart recovery check). */
  privateKeyPem() {
    return this.privateKey.export({ type: 'pkcs8', format: 'pem' });
  }

  /** request a challenge for one purpose and return the challenge document */
  async challenge(purpose) {
    const response = await httpsJson(this.origin, 'POST', '/auth/challenge', {
      pin: this.pin,
      headers: this.authHeaders(),
      body: { purpose },
    });
    if (response.status !== 200 || response.json?.ok !== true) {
      throw new Error('auth/challenge failed: HTTP ' + String(response.status) + ' ' + response.text.slice(0, 300));
    }
    return response.json;
  }

  /** Sign a challenge message with the device key (Secure Enclave equivalent). */
  signMessage(message) {
    return sign('sha256', Buffer.from(message, 'utf8'), this.privateKey).toString('base64url');
  }

  async verify(challengeId, signature) {
    return httpsJson(this.origin, 'POST', '/auth/verify', {
      pin: this.pin,
      body: { challengeId, signature },
    });
  }

  /** Obtain a bearer token for one purpose; returns the response document. */
  async authenticate(purpose, { tamperSignature = false } = {}) {
    const challenge = await this.challenge(purpose);
    const signature = tamperSignature
      ? this.signMessage(challenge.message + 'tampered')
      : this.signMessage(challenge.message);
    return { challenge, response: await this.verify(challenge.challengeId, signature) };
  }

  async ensureApiToken() {
    if (this.apiToken !== undefined && (this.apiTokenExpiresAt ?? 0) > Date.now() + 5000) return this.apiToken;
    const { response } = await this.authenticate('api');
    if (response.status !== 200 || response.json?.ok !== true) {
      throw new Error('auth/verify(api) failed: HTTP ' + String(response.status) + ' ' + response.text.slice(0, 300));
    }
    this.apiToken = response.json.token;
    this.apiTokenExpiresAt = response.json.expiresAt;
    return this.apiToken;
  }

  /** Remote unary call with the api bearer token (auto-refresh once on expiry). */
  async unary(endpoint, args = {}, options = {}) {
    if (this.credential === undefined) throw new Error('unary requires pair() first');
    const token = options.token ?? (await this.ensureApiToken());
    const rpcId = randomUUID();
    const envelope = { type: 'client-request', rpcId, method: endpoint, payload: { args } };
    const response = await httpsJson(this.origin, 'POST', '/api/' + endpoint, {
      pin: this.pin,
      headers: { authorization: 'Bearer ' + token },
      body: envelope,
    });
    if (response.status === 401 && options.retry !== false) {
      if (response.json?.error === 'auth/token-expired' || response.json?.error === 'auth/invalid') {
        this.apiToken = undefined;
        return this.unary(endpoint, args, { ...options, retry: false });
      }
    }
    if (response.status !== 200) {
      throw new Error('unary ' + endpoint + ': HTTP ' + String(response.status) + ' ' + response.text.slice(0, 300));
    }
    const parsed = response.json;
    if (parsed?.type !== 'server-response' || parsed.rpcId !== rpcId) {
      throw new Error('unary ' + endpoint + ': invalid server-response envelope: ' + response.text.slice(0, 300));
    }
    return parsed.result;
  }

  /** Raw unary (no envelope validation) for auth-boundary assertions. */
  async rawUnary(endpoint, token) {
    return httpsJson(this.origin, 'POST', '/api/' + endpoint, {
      pin: this.pin,
      headers: { authorization: 'Bearer ' + token },
      body: { type: 'client-request', rpcId: randomUUID(), method: endpoint, payload: { args: {} } },
    });
  }

  /** Mint a single-use mux token. */
  async muxToken() {
    const { response } = await this.authenticate('mux');
    if (response.status !== 200 || response.json?.ok !== true) {
      throw new Error('auth/verify(mux) failed: HTTP ' + String(response.status) + ' ' + response.text.slice(0, 300));
    }
    return response.json.token;
  }

  /** Open the phone's WSS mux through the link origin with a fresh mux token. */
  async openMux(options = {}) {
    if (this.credential === undefined) throw new Error('openMux requires pair() first');
    const token = options.token ?? (await this.muxToken());
    const wsUrl = this.origin.replace(/^http/, 'ws') + '/api/remote.mux';
    const ws = new WsClient(wsUrl, {
      pinFingerprint256: options.pin ?? this.pin,
      headers: { authorization: 'Bearer ' + token },
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('phone mux open timeout')), 15000);
      ws.once('open', () => {
        clearTimeout(timer);
        resolve();
      });
      ws.once('close', (event) => {
        clearTimeout(timer);
        reject(event?.error ?? new Error('phone mux closed before open'));
      });
      ws.connect();
    });
    this.mux = new MuxConnection(ws, (entry) => this.frameLog.push(entry));
    this.log('phone mux open through link origin');
    return { ws, mux: this.mux, rejection: ws.rejection, peerFingerprint: ws.peerFingerprint };
  }

  /** One mux upgrade attempt with an explicit token; resolves the raw rejection. */
  async tryMuxWithToken(token, options = {}) {
    const wsUrl = this.origin.replace(/^http/, 'ws') + '/api/remote.mux';
    const ws = new WsClient(wsUrl, {
      pinFingerprint256: options.pin ?? this.pin,
      headers: { authorization: 'Bearer ' + token },
    });
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        ws.terminate();
        resolve({ opened: false, rejection: ws.rejection, error: 'timeout' });
      }, 6000);
      ws.once('open', () => {
        clearTimeout(timer);
        resolve({ opened: true, rejection: ws.rejection, ws });
      });
      ws.once('close', (event) => {
        clearTimeout(timer);
        resolve({ opened: false, rejection: ws.rejection, error: event?.error?.message, code: event?.code, reason: event?.reason });
      });
      ws.connect();
    });
  }

  async registerPushToken(token, environment = 'sandbox') {
    return httpsJson(this.origin, 'POST', '/devices/push-token', {
      pin: this.pin,
      headers: { authorization: 'Bearer ' + (await this.ensureApiToken()) },
      body: { token, environment },
    });
  }

  closeMux() {
    try {
      this.mux?.close();
    } catch {
      /* already closed */
    }
    this.mux = undefined;
  }

  close() {
    this.closeMux();
  }
}

export { collectStream, sleep };