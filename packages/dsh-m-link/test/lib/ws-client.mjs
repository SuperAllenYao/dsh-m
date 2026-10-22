/**
 * ws-client.mjs — minimal RFC 6455 client for the phone simulator (M0 only).
 *
 * Adapted from spikes/protocol/lib/ws-lite.mjs (same author, PoC-grade) with
 * the additions this spike needs:
 *   - wss:// with a self-signed cert plus leaf-fingerprint pinning
 *     (models the QR-carried pin an iOS client would enforce);
 *   - the raw HTTP status line is surfaced when an upgrade is rejected, so the
 *     simulator can assert the plugin's 401/409 upgrade behavior.
 *
 * The real iOS client uses URLSessionWebSocketTask (custom headers + pinned
 * trust evaluation); this file exists only so the node simulator can do the
 * same things without npm dependencies.
 */

import { EventEmitter } from 'node:events';
import { randomBytes } from 'node:crypto';
import net from 'node:net';
import tls from 'node:tls';

export class WsClient extends EventEmitter {
  /**
   * @param {string} url ws:// or wss://
   * @param {{headers?: Record<string,string>, pinFingerprint256?: string, rejectUnauthorized?: boolean, tlsServername?: string}} [options]
   */
  constructor(url, options = {}) {
    super();
    this.url = new URL(url);
    this.options = options;
    this.socket = undefined;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentOpcode = 0;
    this.closed = false;
    this.handshakeDone = false;
    this.rejection = undefined;
    this.peerFingerprint = undefined;
  }

  connect() {
    const isTls = this.url.protocol === 'wss:';
    const port = Number(this.url.port || (isTls ? 443 : 80));
    const key = randomBytes(16).toString('base64');
    const lines = [
      'GET ' + this.url.pathname + this.url.search + ' HTTP/1.1',
      'Host: ' + this.url.host,
      'Upgrade: websocket',
      'Connection: Upgrade',
      'Sec-WebSocket-Key: ' + key,
      'Sec-WebSocket-Version: 13',
    ];
    for (const [name, value] of Object.entries(this.options.headers ?? {})) lines.push(name + ': ' + value);
    const request = lines.join('\r\n') + '\r\n\r\n';
    const onConnect = () => {
      if (isTls) {
        const cert = this.socket.getPeerCertificate?.();
        this.peerFingerprint = cert?.fingerprint256;
        const expected = this.options.pinFingerprint256;
        if (typeof expected === 'string' && expected.length > 0 && this.peerFingerprint !== expected) {
          this.fail(new Error('TLS pin mismatch: expected ' + expected + ', got ' + String(this.peerFingerprint)));
          return;
        }
      }
      this.socket.write(request);
      this.socket.on('data', (chunk) => this.onData(chunk, key));
    };
    this.socket = isTls
      ? tls.connect({
          host: this.url.hostname,
          port,
          servername: net.isIP(this.url.hostname) === 0 ? this.url.hostname : undefined,
          rejectUnauthorized: this.options.rejectUnauthorized ?? false,
        }, onConnect)
      : net.connect({ host: this.url.hostname, port }, onConnect);
    this.socket.on('error', (error) => this.fail(error));
    this.socket.on('close', () => this.fail(new Error('socket closed')));
    return this;
  }

  onData(chunk, key) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.handshakeDone) {
      const end = this.buffer.indexOf('\r\n\r\n');
      if (end === -1) return;
      const head = this.buffer.subarray(0, end).toString('latin1');
      this.buffer = this.buffer.subarray(end + 4);
      const status = head.split('\r\n')[0];
      if (!/^HTTP\/1\.1 101/.test(status)) {
        this.rejection = status;
        this.fail(new Error('websocket upgrade rejected: ' + status));
        return;
      }
      this.handshakeDone = true;
      this.emit('open');
    }
    while (this.parseFrame()) { /* drain */ }
  }

  parseFrame() {
    const b = this.buffer;
    if (b.length < 2) return false;
    const fin = (b[0] & 0x80) !== 0;
    const opcode = b[0] & 0x0f;
    const masked = (b[1] & 0x80) !== 0;
    let length = b[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (b.length < 4) return false;
      length = b.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (b.length < 10) return false;
      length = Number(b.readBigUInt64BE(2));
      offset = 10;
    }
    let mask;
    if (masked) {
      if (b.length < offset + 4) return false;
      mask = b.subarray(offset, offset + 4);
      offset += 4;
    }
    if (b.length < offset + length) return false;
    let payload = b.subarray(offset, offset + length);
    if (masked) {
      const copy = Buffer.alloc(length);
      for (let i = 0; i < length; i += 1) copy[i] = payload[i] ^ mask[i % 4];
      payload = copy;
    }
    this.buffer = b.subarray(offset + length);
    this.handleFrame(fin, opcode, payload);
    return true;
  }

  handleFrame(fin, opcode, payload) {
    if (opcode === 0x9) { this.writeFrame(0xa, payload); return; }
    if (opcode === 0xa) { this.emit('pong'); return; }
    if (opcode === 0x8) {
      const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
      const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
      this.fail(new Error('websocket closed: ' + code + ' ' + reason), code, reason);
      return;
    }
    if (opcode === 0x2) { this.emit('binary', payload); return; }
    const continuation = opcode === 0x0;
    if (!continuation) {
      this.fragmentOpcode = opcode;
      this.fragments = [];
    }
    this.fragments.push(payload);
    if (!fin) return;
    const full = Buffer.concat(this.fragments);
    this.fragments = [];
    if (this.fragmentOpcode === 0x1) this.emit('message', full.toString('utf8'));
  }

  send(text) { this.writeFrame(0x1, Buffer.from(text, 'utf8')); }

  writeFrame(opcode, payload) {
    if (this.closed || this.socket === undefined) throw new Error('websocket is not open');
    const mask = randomBytes(4);
    const masked = Buffer.alloc(payload.length);
    for (let i = 0; i < payload.length; i += 1) masked[i] = payload[i] ^ mask[i % 4];
    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x80 | opcode, 0x80 | payload.length]);
    } else if (payload.length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  close(code = 1000, reason = '') {
    if (this.closed) return;
    const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
    payload.writeUInt16BE(code, 0);
    payload.write(reason, 2);
    try { this.writeFrame(0x8, payload); } catch { /* already gone */ }
    this.closed = true;
    this.socket?.end();
  }

  /** Hard teardown (models a phone that loses connectivity). */
  terminate() {
    this.closed = true;
    this.socket?.destroy();
    this.emit('close', { error: new Error('terminated'), code: 1006, reason: 'terminated' });
  }

  fail(error, code, reason) {
    if (this.closed) return;
    this.closed = true;
    this.socket?.destroy();
    this.emit('close', { error, code, reason });
  }
}
