/**
 * tunnel.js — outbound relay tunnel client for the DSH-m Mac plugin (M2a).
 *
 * The Mac plugin connects OUT to the user's own relay (packages/dsh-m-relay),
 * authenticates with a shared secret, asks the relay for a public bridge port,
 * and then bridges opaque TCP streams from that port to the local link-server
 * TLS listener:
 *
 *   手机 --TLS(端到端到 Mac)--> relay:bridgePort <==控制连接== this client
 *        --TCP--> 127.0.0.1:<link-server port>
 *
 * The relay never terminates TLS and never sees plaintext: the phone pins the
 * Mac certificate (design §4.4/§4.6). This module is pure Node built-ins.
 *
 * Protocol (design §4.4, v0):
 *   frame      = u32be length + u8 type + payload, length = 1 + payload bytes
 *   type 0x01  JSON control (UTF-8)
 *   type 0x02  DATA: u32be sid + bytes
 *   type 0x03  FIN : u32be sid              (half close this direction)
 *   type 0x04  RST : u32be sid + u8 code
 *
 * Handshake: TLS (ALPN dshm-relay/1, pin = base64url SHA-256 of the relay cert
 * DER, checked here — no system CA) -> hello (HMAC) -> ready. Heartbeats are
 * ping/pong; 3 missed intervals tear the connection down. Reconnects use
 * exponential backoff 1s/2s/5s/10s/30s with 0–20% jitter. The relay can send
 * `drain` on shutdown; we drop the connection and reconnect to the new instance.
 *
 * Security: the secret is only used for the hello HMAC. It is never logged,
 * never put in /health and never persisted by this module. The relay cert pin
 * is not secret and may be logged.
 */

import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { isIP } from 'node:net';
import { connect as netConnect } from 'node:net';
import { homedir } from 'node:os';
import { connect as tlsConnect } from 'node:tls';

export const TUNNEL_PROTOCOL_VERSION = 1;
export const RELAY_ALPN = 'dshm-relay/1';
export const HELLO_PREFIX = 'dshm-relay-hello/1\n';
export const PLUGIN_PROTOCOL = 'dsh-m/1';
export const PLUGIN_NAME = 'dsh-m-link';

export const FRAME_TYPE = { JSON: 0x01, DATA: 0x02, FIN: 0x03, RST: 0x04 };
const MAX_FRAME_LEN = 1 << 20; // relay wire.MaxFrameLen
const MAX_PAYLOAD_LEN = MAX_FRAME_LEN - 1;
// Matches the relay's default maxStreamsPerHost (design §4.3). Keeping the
// local cap equal means the relay rejects first and the tunnel never opens a
// local socket the relay would immediately RST.
const MAX_LOCAL_STREAMS = 32;
const DEFAULT_HELLO_TIMEOUT_MS = 10_000;
const DEFAULT_BACKOFF_MS = [1_000, 2_000, 5_000, 10_000, 30_000];
const DEFAULT_HEARTBEAT_SEC = 15;

const sidBuffer = (sid) => {
  const buf = Buffer.alloc(4);
  buf.writeUInt32BE(sid >>> 0, 0);
  return buf;
};

/** Encode one wire frame (length counts the type byte + payload). */
export function encodeFrame(type, payload = Buffer.alloc(0)) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  if (!Number.isInteger(type) || type < 1 || type > 255) throw new Error('tunnel: invalid frame type ' + String(type));
  if (body.length > MAX_PAYLOAD_LEN) throw new Error('tunnel: frame payload too large (' + body.length + ' bytes)');
  const frame = Buffer.allocUnsafe(5 + body.length);
  frame.writeUInt32BE(body.length + 1, 0);
  frame[4] = type;
  body.copy(frame, 5);
  return frame;
}

export function encodeDataFrame(sid, data) {
  const body = Buffer.isBuffer(data) ? data : Buffer.from(data);
  return encodeFrame(FRAME_TYPE.DATA, Buffer.concat([sidBuffer(sid), body]));
}

/**
 * Consume complete frames from a stream buffer.
 * @param {Buffer} buffer accumulated bytes
 * @param {(type: number, payload: Buffer) => void} onFrame
 * @returns {Buffer} unconsumed remainder
 */
export function consumeFrames(buffer, onFrame) {
  let offset = 0;
  while (buffer.length - offset >= 5) {
    const length = buffer.readUInt32BE(offset);
    if (length < 1 || length > MAX_FRAME_LEN) throw new Error('tunnel: invalid frame length ' + String(length));
    const total = 4 + length; // length prefix + (type + payload)
    if (buffer.length - offset < total) break;
    const type = buffer[offset + 4];
    const payload = buffer.subarray(offset + 5, offset + total);
    onFrame(type, payload);
    offset += total;
  }
  return offset === 0 ? buffer : buffer.subarray(offset);
}

/** base64url sha256 of a certificate DER (the pin form used by relay config). */
export function certPin(der) {
  return createHash('sha256').update(der).digest('base64url');
}

/** base64url sha256 DER pin from a colon-hex certificate fingerprint. */
export function certPinFromFingerprint(fingerprint256) {
  if (typeof fingerprint256 !== 'string') return undefined;
  const hex = fingerprint256.replace(/[^0-9A-Fa-f]/g, '');
  if (hex.length !== 64) return undefined;
  return Buffer.from(hex, 'hex').toString('base64url');
}

/**
 * The hello HMAC, fixed by design §4.4:
 * base64url(HMAC-SHA256(secret, "dshm-relay-hello/1\n" + hostId + "\n" + ts +
 * "\n" + nonce + "\n" + (wantPort ?? "")))
 */
export function computeHelloAuth({ secret, hostId, ts, nonce, wantPort }) {
  const port = wantPort === undefined || wantPort === null ? '' : String(wantPort);
  const message = HELLO_PREFIX + String(hostId) + '\n' + String(ts) + '\n' + String(nonce) + '\n' + port;
  return createHmac('sha256', Buffer.from(String(secret), 'utf8')).update(Buffer.from(message, 'utf8')).digest('base64url');
}

/** Expand a leading ~ and read the relay secret file (trimmed). */
export function resolveSecret({ secret, secretFile, homeDir = homedir() } = {}) {
  if (typeof secret === 'string' && secret.trim().length > 0) return { secret: secret.trim() };
  if (typeof secretFile === 'string' && secretFile.trim().length > 0) {
    const file = secretFile.trim().replace(/^~(?=$|\/)/, homeDir);
    try {
      const value = readFileSync(file, 'utf8').trim();
      if (value.length === 0) return { error: 'auth/secret-empty', file };
      return { secret: value, file };
    } catch (error) {
      return { error: 'auth/secret-file-unreadable', file, message: String(error?.message ?? error) };
    }
  }
  return { error: 'auth/secret-missing' };
}

function constantTimeEqualString(left, right) {
  const a = Buffer.from(String(left ?? ''));
  const b = Buffer.from(String(right ?? ''));
  return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}

function mask(value) {
  const text = String(value ?? '');
  return text.length <= 4 ? '***' : text.slice(0, 3) + '…' + text.slice(-3);
}

/**
 * One tunnel client instance. LinkServer creates one when config.tunnel.enabled
 * is true; with the tunnel disabled this class is never constructed and the
 * plugin behaves exactly like M1.
 */
export class TunnelClient {
  /**
   * @param {{
   *   config: Record<string, unknown>,
   *   pluginPort: number,
   *   hostId: string,
   *   hostName: string,
   *   pluginVersion?: string,
   *   log?: (message: string) => void,
   *   audit?: {record: (event: string, fields?: Record<string, unknown>) => void},
   *   onReady?: (info: {origin: string, port: number, publicHost?: string, hostId: string}) => void,
   *   onStateChange?: (state: {state: string, origin?: string, port?: number, lastError?: string}) => void,
   *   backoffMs?: number[],
   *   helloTimeoutMs?: number,
   *   homeDir?: string,
   * }} options
   */
  constructor({ config = {}, pluginPort, hostId, hostName, pluginVersion = '0.1.0', log = () => {}, audit, onReady = () => {}, onStateChange = () => {}, backoffMs, helloTimeoutMs, homeDir }) {
    this.config = config ?? {};
    this.pluginPort = Number(pluginPort);
    this.hostId = String(hostId ?? '');
    this.hostName = String(hostName ?? 'Mac');
    this.pluginVersion = String(pluginVersion);
    this.log = log;
    this.audit = audit ?? { record: () => {} };
    this.onReady = onReady;
    this.onStateChange = onStateChange;
    this.backoffMs = Array.isArray(backoffMs) && backoffMs.length > 0 ? backoffMs : DEFAULT_BACKOFF_MS;
    this.helloTimeoutMs = Number.isInteger(helloTimeoutMs) ? helloTimeoutMs : DEFAULT_HELLO_TIMEOUT_MS;
    this.homeDir = homeDir;

    this.state = this.config.enabled === true ? 'connecting' : 'disabled';
    this.origin = undefined;
    this.port = undefined;
    this.since = undefined;
    this.lastError = undefined;
    this.socket = undefined;
    this.buffer = Buffer.alloc(0);
    this.streams = new Map();
    /** Streams whose local socket asked us to pause the control reader. */
    this.pausedReads = new Set();
    this.secret = undefined;
    this.control = undefined;
    this.permanent = false;
    this.disposed = false;
    this.started = false;
    this.ready = false;
    this.retryIndex = 0;
    this.reconnectTimer = undefined;
    this.heartbeatTimer = undefined;
    this.helloTimer = undefined;
    this.heartbeatSec = DEFAULT_HEARTBEAT_SEC;
    this.lastFrameAt = 0;
    /** Latest pairing-code publish request; flushed on ready. */
    this.pendingCode = undefined;
  }

  /** Parse + validate the control origin once. */
  parseControl() {
    const value = typeof this.config.controlOrigin === 'string' ? this.config.controlOrigin.trim() : '';
    if (value.length === 0) return { error: 'config/missing-control-origin' };
    let url;
    try {
      url = new URL(value);
    } catch {
      return { error: 'config/invalid-control-origin' };
    }
    if (url.protocol !== 'https:') return { error: 'config/control-origin-not-https' };
    const port = url.port === '' ? 443 : Number(url.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: 'config/invalid-control-port' };
    return { host: url.hostname.replace(/^\[|\]$/g, ''), port, servername: isIP(url.hostname.replace(/^\[|\]$/g, '')) ? undefined : url.hostname };
  }

  health() {
    return {
      enabled: this.config.enabled === true,
      state: this.disposed ? 'disabled' : this.state,
      origin: this.origin ?? null,
      port: this.port ?? null,
      since: this.since ?? null,
      lastError: this.lastError ?? null,
    };
  }

  /** Relay rendezvous info (not secret): used for Bonjour TXT / payload relay. */
  relayInfo() {
    return {
      origin: this.origin ?? null,
      controlOrigin: typeof this.config.controlOrigin === 'string' ? this.config.controlOrigin : null,
      pin: typeof this.config.pin === 'string' ? this.config.pin : null,
    };
  }

  /** Begin connecting. Never throws; permanent config errors become state=error. */
  start() {
    if (this.started || this.disposed) return this;
    this.started = true;
    if (this.config.enabled !== true) {
      this.setState('disabled');
      return this;
    }
    this.control = this.parseControl();
    if (this.control.error !== undefined) {
      this.fail(this.control.error, { permanent: true });
      return this;
    }
    const pin = typeof this.config.pin === 'string' ? this.config.pin.trim() : '';
    if (!/^[A-Za-z0-9_-]{43,128}$/.test(pin)) {
      this.fail('config/invalid-pin', { permanent: true });
      return this;
    }
    this.pin = pin;
    const resolved = resolveSecret({ secret: this.config.secret, secretFile: this.config.secretFile, homeDir: this.homeDir });
    if (resolved.error !== undefined) {
      this.fail(resolved.error + (resolved.file ? ' (' + resolved.file + ')' : ''), { permanent: true });
      return this;
    }
    this.secret = resolved.secret;
    this.connect();
    return this;
  }

  setState(state) {
    this.state = state;
    try {
      this.onStateChange(this.health());
    } catch (error) {
      this.log('tunnel: onStateChange failed: ' + String(error?.message ?? error));
    }
  }

  fail(message, { permanent = false } = {}) {
    this.lastError = String(message);
    this.ready = false;
    this.permanent = permanent === true;
    this.setState('error');
    this.log('tunnel: error: ' + this.lastError);
    this.audit.record('tunnel.failed', { message: this.lastError, permanent: this.permanent });
    if (!this.permanent && !this.disposed) this.scheduleReconnect();
  }

  connect() {
    if (this.disposed || this.control?.error !== undefined) return;
    this.cleanupSocket();
    this.buffer = Buffer.alloc(0);
    this.ready = false;
    this.setState('connecting');
    const { host, port, servername } = this.control;
    this.log('tunnel: connecting to relay ' + host + ':' + String(port) + ' (pin ' + mask(this.pin) + ')');
    let socket;
    try {
      socket = tlsConnect({
        host,
        port,
        ...(servername === undefined ? {} : { servername }),
        rejectUnauthorized: false, // pin is checked explicitly below; no system CA
        ALPNProtocols: [RELAY_ALPN],
        minVersion: 'TLSv1.2',
      });
    } catch (error) {
      this.lastError = 'connect-failed';
      this.log('tunnel: connect failed: ' + String(error?.message ?? error));
      this.scheduleReconnect();
      this.setState('connecting');
      return;
    }
    this.socket = socket;
    socket.setNoDelay(true);
    socket.once('secureConnect', () => this.onSecureConnect(socket));
    socket.on('data', (chunk) => this.onData(chunk));
    socket.on('drain', () => this.resumeLocalStreams());
    socket.on('error', (error) => this.onSocketError(error));
    socket.on('close', () => this.onSocketClose());
    this.helloTimer = setTimeout(() => {
      this.helloTimer = undefined;
      if (this.ready) return;
      this.lastError = 'handshake-timeout';
      this.log('tunnel: relay did not become ready within ' + String(this.helloTimeoutMs) + 'ms');
      socket.destroy();
    }, this.helloTimeoutMs);
    if (typeof this.helloTimer.unref === 'function') this.helloTimer.unref();
  }

  onSecureConnect(socket) {
    if (this.socket !== socket || this.disposed) return;
    const alpn = socket.alpnProtocol;
    if (alpn !== RELAY_ALPN) {
      this.lastError = 'alpn-mismatch';
      this.log('tunnel: relay did not negotiate ' + RELAY_ALPN + ' (got ' + String(alpn) + ')');
      socket.destroy();
      return;
    }
    let der;
    try {
      der = socket.getPeerCertificate(true)?.raw;
    } catch {
      der = undefined;
    }
    if (!Buffer.isBuffer(der) || der.length === 0) {
      this.lastError = 'pin-unavailable';
      this.log('tunnel: relay did not present a certificate');
      socket.destroy();
      return;
    }
    const actual = certPin(der);
    if (!constantTimeEqualString(actual, this.pin)) {
      // Permanent: retrying cannot fix a wrong/stale pin — the operator must
      // update the plugin config (relay cert rotation).
      this.lastError = 'pin-mismatch';
      this.permanent = true;
      this.log('tunnel: relay certificate pin mismatch (expected ' + mask(this.pin) + ', got ' + mask(actual) + '); update tunnel.pin');
      this.audit.record('tunnel.pin-mismatch', { expected: mask(this.pin), actual: mask(actual) });
      socket.destroy();
      return;
    }
    const ts = Date.now();
    const nonce = randomBytes(16).toString('base64url');
    const wantPort = Number.isInteger(this.config.wantPort) && this.config.wantPort > 0 ? this.config.wantPort : null;
    const auth = computeHelloAuth({ secret: this.secret, hostId: this.hostId, ts, nonce, wantPort });
    this.sendJSON({
      t: 'hello',
      v: TUNNEL_PROTOCOL_VERSION,
      hostId: this.hostId,
      hostName: this.hostName.slice(0, 128),
      ts,
      nonce,
      ...(wantPort === null ? {} : { wantPort }),
      auth,
      meta: { plugin: PLUGIN_NAME, version: this.pluginVersion, proto: PLUGIN_PROTOCOL },
    });
  }

  onSocketError(error) {
    if (this.disposed) return;
    this.lastError = this.lastError ?? 'socket-error';
    this.log('tunnel: socket error: ' + String(error?.message ?? error));
  }

  onSocketClose() {
    this.cleanupSocket();
    if (this.disposed) return;
    const wasReady = this.ready;
    this.ready = false;
    this.destroyStreams('tunnel-closed');
    if (wasReady) {
      this.audit.record('tunnel.disconnected', { origin: this.origin ?? null, lastError: this.lastError ?? null });
      this.log('tunnel: control connection closed' + (this.lastError ? ' (' + this.lastError + ')' : ''));
    }
    if (this.permanent) {
      this.setState('error');
      return;
    }
    if (this.state !== 'error') this.setState('connecting');
    this.scheduleReconnect();
  }

  scheduleReconnect() {
    if (this.disposed || this.permanent === true || this.reconnectTimer !== undefined) return;
    const base = this.backoffMs[Math.min(this.retryIndex, this.backoffMs.length - 1)];
    this.retryIndex += 1;
    const delay = Math.round(base + base * Math.random() * 0.2);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (!this.disposed) this.connect();
    }, delay);
    if (typeof this.reconnectTimer.unref === 'function') this.reconnectTimer.unref();
  }

  cleanupSocket() {
    if (this.helloTimer !== undefined) {
      clearTimeout(this.helloTimer);
      this.helloTimer = undefined;
    }
    if (this.heartbeatTimer !== undefined) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = undefined;
    }
    if (this.socket !== undefined) {
      const socket = this.socket;
      this.socket = undefined;
      try {
        socket.removeAllListeners('data');
        socket.removeAllListeners('drain');
        socket.removeAllListeners('error');
        socket.destroy();
      } catch {
        /* already gone */
      }
    }
  }

  // ---------------------------------------------------------------- framing
  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    try {
      this.buffer = consumeFrames(this.buffer, (type, payload) => this.onFrame(type, payload));
    } catch (error) {
      this.lastError = 'protocol/frame';
      this.log('tunnel: frame error: ' + String(error?.message ?? error));
      this.socket?.destroy();
    }
  }

  onFrame(type, payload) {
    this.lastFrameAt = Date.now();
    switch (type) {
      case FRAME_TYPE.JSON:
        this.onControl(payload);
        return;
      case FRAME_TYPE.DATA: {
        if (payload.length < 4) {
          this.lastError = 'protocol/data';
          this.socket?.destroy();
          return;
        }
        const sid = payload.readUInt32BE(0);
        this.onRemoteData(sid, payload.subarray(4));
        return;
      }
      case FRAME_TYPE.FIN: {
        if (payload.length !== 4) return;
        this.onRemoteFin(payload.readUInt32BE(0));
        return;
      }
      case FRAME_TYPE.RST: {
        if (payload.length !== 5) return;
        this.onRemoteRst(payload.readUInt32BE(0));
        return;
      }
      default:
        this.log('tunnel: ignoring unknown frame type 0x' + type.toString(16));
    }
  }

  onControl(payload) {
    let message;
    try {
      message = JSON.parse(payload.toString('utf8'));
    } catch {
      this.lastError = 'protocol/json';
      this.socket?.destroy();
      return;
    }
    if (message === null || typeof message !== 'object') return;
    switch (message.t) {
      case 'ready':
        this.handleReady(message);
        return;
      case 'ping':
        this.sendJSON({ t: 'pong', ts: message.ts ?? Date.now() });
        return;
      case 'pong':
        return;
      case 'open':
        this.onOpen(Number(message.sid));
        return;
      case 'error':
        this.onRelayError(message);
        return;
      case 'drain':
        this.log('tunnel: relay draining (' + String(message.reason ?? '') + '), reconnecting to the new instance');
        this.audit.record('tunnel.drained', { reason: typeof message.reason === 'string' ? message.reason : 'unknown' });
        this.lastError = 'relay/draining';
        this.retryIndex = 0;
        this.socket?.destroy();
        return;
      default:
        return; // hello/opened/open_failed are tunnel->relay directions
    }
  }

  handleReady(message) {
    if (message.v !== TUNNEL_PROTOCOL_VERSION) {
      this.lastError = 'version/unsupported';
      this.socket?.destroy();
      return;
    }
    if (typeof message.hostId === 'string' && message.hostId !== this.hostId) {
      // Defense in depth: the TLS pin already authenticates the relay, but a
      // `ready` echo for another hostId means the relay routed/state-corrupted
      // this session — never advertise an origin for it.
      this.lastError = 'protocol/host-id-mismatch';
      this.log('tunnel: relay ready hostId mismatch (expected ' + this.hostId + ', got ' + message.hostId + ')');
      this.socket?.destroy();
      return;
    }
    const origin = typeof message.origin === 'string' ? message.origin.replace(/\/+$/, '') : '';
    let originOk = false;
    try {
      const url = new URL(origin);
      originOk = url.protocol === 'https:';
    } catch {
      originOk = false;
    }
    if (!originOk) {
      this.lastError = 'protocol/bad-origin';
      this.log('tunnel: relay returned an invalid origin: ' + String(message.origin));
      this.socket?.destroy();
      return;
    }
    this.ready = true;
    this.origin = origin;
    this.port = Number.isInteger(message.port) ? message.port : undefined;
    this.since = Date.now();
    this.lastError = undefined;
    this.retryIndex = 0;
    const heartbeat = Number(message.heartbeatSec);
    this.heartbeatSec = Number.isInteger(heartbeat) && heartbeat >= 1 && heartbeat <= 300 ? heartbeat : DEFAULT_HEARTBEAT_SEC;
    this.lastFrameAt = Date.now();
    this.startHeartbeat();
    this.setState('ready');
    this.audit.record('tunnel.ready', { origin: this.origin, port: this.port ?? null, heartbeatSec: this.heartbeatSec });
    this.log('tunnel: relay ready, public origin ' + this.origin + ' (bridge port ' + String(this.port) + ')');
    try {
      this.onReady({ origin: this.origin, port: this.port, publicHost: message.publicHost, hostId: this.hostId });
    } catch (error) {
      this.log('tunnel: onReady callback failed: ' + String(error?.message ?? error));
    }
    this.flushCode();
  }

  onRelayError(message) {
    const code = typeof message.code === 'string' ? message.code : 'error/unknown';
    const detail = typeof message.message === 'string' ? message.message : '';
    this.lastError = code + (detail.length > 0 ? ': ' + detail : '');
    this.log('tunnel: relay rejected the connection: ' + this.lastError);
    this.audit.record('tunnel.rejected', { code, message: detail.slice(0, 200) });
    // Configuration-shaped rejections stop retrying: retrying with the same
    // secret/version/pinned port only spams the relay until the operator fixes
    // the plugin config. `server/busy` (relay draining/overloaded) and all other
    // codes are transient: keep the exponential backoff loop running.
    const permanent = code === 'auth/invalid' || code === 'version/unsupported' || code === 'port/unavailable';
    this.permanent = permanent;
    this.socket?.destroy();
  }

  startHeartbeat() {
    if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer);
    const interval = Math.max(100, this.heartbeatSec * 1000);
    this.heartbeatTimer = setInterval(() => {
      const now = Date.now();
      if (now - this.lastFrameAt > 3 * interval) {
        this.lastError = 'heartbeat-timeout';
        this.audit.record('tunnel.heartbeat-timeout', { heartbeatSec: this.heartbeatSec });
        this.log('tunnel: heartbeat timeout (' + String(this.heartbeatSec) + 's interval), reconnecting');
        this.socket?.destroy();
        return;
      }
      this.sendJSON({ t: 'ping', ts: now });
    }, interval);
    if (typeof this.heartbeatTimer.unref === 'function') this.heartbeatTimer.unref();
  }

  sendJSON(value) {
    return this.sendFrame(FRAME_TYPE.JSON, Buffer.from(JSON.stringify(value), 'utf8'));
  }

  sendFrame(type, payload) {
    const socket = this.socket;
    if (socket === undefined || socket.destroyed === true) return false;
    try {
      return socket.write(encodeFrame(type, payload));
    } catch (error) {
      this.lastError = 'socket-write-failed';
      this.log('tunnel: write failed: ' + String(error?.message ?? error));
      socket.destroy();
      return false;
    }
  }

  // ------------------------------------------------------------------ streams
  onOpen(sid) {
    if (!Number.isInteger(sid) || sid < 0) return;
    if (this.streams.has(sid)) {
      this.sendRST(sid);
      return;
    }
    if (this.streams.size >= MAX_LOCAL_STREAMS) {
      this.sendJSON({ t: 'open_failed', sid, code: 'local/busy', message: 'tunnel stream limit reached' });
      return;
    }
    const local = netConnect({ host: '127.0.0.1', port: this.pluginPort });
    const entry = { sid, socket: local, opened: false, localEOF: false, remoteEOF: false, finished: false };
    this.streams.set(sid, entry);
    local.setNoDelay(true);
    local.once('connect', () => {
      if (entry.finished) return;
      entry.opened = true;
      this.sendJSON({ t: 'opened', sid });
    });
    local.on('data', (chunk) => {
      if (entry.finished) return;
      const frame = encodeDataFrame(sid, chunk);
      const socket = this.socket;
      if (socket === undefined || socket.destroyed === true) {
        this.finishStream(sid, false);
        return;
      }
      // Backpressure relay->local direction: if the TLS socket cannot keep up,
      // pause this local stream until the socket drains (resumeLocalStreams).
      if (socket.write(frame) === false) local.pause();
    });
    local.on('end', () => {
      if (entry.finished) return;
      entry.localEOF = true;
      this.sendFrame(FRAME_TYPE.FIN, sidBuffer(sid));
      if (entry.remoteEOF) this.finishStream(sid, false);
    });
    local.on('error', (error) => {
      if (entry.finished) return;
      if (!entry.opened) {
        this.sendJSON({ t: 'open_failed', sid, code: 'local/dial-failed', message: String(error?.message ?? error).slice(0, 200) });
      } else {
        this.sendRST(sid);
      }
      this.finishStream(sid, false);
    });
    local.on('close', () => {
      if (entry.finished) return;
      // The link-server closed without a clean half-close: abort the phone side.
      // Known M2a limitation: in a narrow race a clean half-close can emit
      // 'close' before our 'end' handler recorded localEOF, so a harmless RST
      // follows a graceful FIN (the relay treats any RST as abort of an already
      // finished stream). Accepted for M2a; revisit with M2b transport work.
      if (!entry.localEOF) this.sendRST(sid);
      this.finishStream(sid, false);
    });
  }

  onRemoteData(sid, data) {
    const entry = this.streams.get(sid);
    if (entry === undefined) {
      this.sendRST(sid);
      return;
    }
    if (entry.finished) return;
    const local = entry.socket;
    const flushed = local.write(data);
    if (flushed === false) {
      // Pause the control connection while this stream's socket drains; the
      // relay keeps buffering in its kernel socket for the short pause. Track
      // per-stream so one stream's drain does not resume another's pause, and
      // always release on FIN/RST/close (a half-closed socket may never drain).
      const sid = entry.sid;
      this.pausedReads.add(sid);
      this.socket?.pause();
      local.once('drain', () => this.releaseReadPause(sid));
      local.once('close', () => this.releaseReadPause(sid));
    }
  }

  /** Resume the control reader once no stream is waiting on its local socket. */
  releaseReadPause(sid) {
    this.pausedReads.delete(sid);
    if (this.pausedReads.size === 0) {
      try {
        if (this.socket !== undefined && this.socket.destroyed !== true) this.socket.resume();
      } catch {
        /* socket already gone */
      }
    }
  }

  onRemoteFin(sid) {
    this.releaseReadPause(sid);
    const entry = this.streams.get(sid);
    if (entry === undefined || entry.finished) return;
    entry.remoteEOF = true;
    try {
      entry.socket.end();
    } catch {
      /* already gone */
    }
    if (entry.localEOF) this.finishStream(sid, false);
  }

  onRemoteRst(sid) {
    this.releaseReadPause(sid);
    this.finishStream(sid, false);
  }

  resumeLocalStreams() {
    for (const entry of this.streams.values()) {
      if (!entry.finished) entry.socket.resume();
    }
  }

  sendRST(sid) {
    const payload = Buffer.alloc(5);
    payload.writeUInt32BE(sid >>> 0, 0);
    payload[4] = 0x01; // local/io: informational only, the peer aborts on any RST
    this.sendFrame(FRAME_TYPE.RST, payload);
  }

  finishStream(sid, sendRst = true) {
    this.releaseReadPause(sid);
    const entry = this.streams.get(sid);
    if (entry === undefined) return;
    this.streams.delete(sid);
    entry.finished = true;
    if (sendRst) this.sendRST(sid);
    try {
      entry.socket.destroy();
    } catch {
      /* already gone */
    }
  }

  destroyStreams() {
    for (const sid of [...this.streams.keys()]) {
      const entry = this.streams.get(sid);
      this.streams.delete(sid);
      this.releaseReadPause(sid);
      if (entry === undefined) continue;
      entry.finished = true;
      try {
        entry.socket.destroy();
      } catch {
        /* already gone */
      }
    }
  }

  // -------------------------------------------------------------- code publish
  /**
   * Publish (or clear) the pairing code to the relay for App lookup. Values are
   * kept and written once the control channel is ready; a later publish replaces
   * the previous one.
   */
  publishCode(code, expMs, leafPin, leafFingerprint256, hostName) {
    if (typeof code !== 'string' || !/^\d{8}$/.test(code)) {
      this.pendingCode = undefined;
      this.clearCode();
      return;
    }
    const exp = Number.isFinite(expMs) ? Math.floor(expMs / 1000) : undefined;
    this.pendingCode = {
      t: 'code',
      code,
      exp,
      leafPin: typeof leafPin === 'string' ? leafPin : undefined,
      leafFingerprint256: typeof leafFingerprint256 === 'string' ? leafFingerprint256 : undefined,
      hostName: typeof hostName === 'string' ? hostName.slice(0, 128) : undefined,
    };
    this.flushCode();
  }

  clearCode() {
    this.pendingCode = undefined;
    if (this.ready) this.sendJSON({ t: 'code_clear' });
  }

  flushCode() {
    if (!this.ready || this.pendingCode === undefined) return;
    this.sendJSON(this.pendingCode);
  }

  // -------------------------------------------------------------------- teardown
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    if (this.reconnectTimer !== undefined) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    this.destroyStreams('tunnel-disposed');
    const socket = this.socket;
    this.cleanupSocket();
    if (socket !== undefined) {
      try {
        socket.destroy();
      } catch {
        /* already gone */
      }
    }
    this.ready = false;
    this.permanent = true;
    this.setState('disabled');
    this.log('tunnel: disposed');
  }
}

/**
 * Factory used by LinkServer.startTunnelClient(): one tunnel client per plugin
 * instance. The returned client is not started yet (link-server awaits start()).
 */
export function startTunnelClient(options) {
  return new TunnelClient(options);
}
