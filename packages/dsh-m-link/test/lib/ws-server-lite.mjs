/**
 * ws-server-lite.mjs — minimal RFC 6455 server for the plugin's P1 tests.
 *
 * Plain Node cannot import the `ws` copy that lives inside the Electron asar,
 * and the package deliberately has no npm dependency (lib/ws-provider.js). The
 * M1 tests inject a fake ws module that never upgrades; the P1 single-WSS test
 * needs a real upgrade + text frames over a real TLS listener, so this file
 * provides the server side and is handed to the plugin through the documented
 * `DSH_M_LINK_WS_PATH` test hook.
 *
 * Scope: exactly what LinkServer uses — `new WebSocketServer({noServer:true})`,
 * `handleUpgrade(request, socket, head, cb)`, `wss.clients`, `wss.close()`, and
 * on the socket `on/once/off('message'|'close'|'error')`, `send(text)`,
 * `close(code,reason)`, `readyState`. Text frames, continuation, ping/pong and
 * close are implemented; binary frames are delivered as buffers.
 */

import { EventEmitter } from 'node:events';
import { createHash } from 'node:crypto';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function acceptKey(key) {
  return createHash('sha1').update(key + GUID).digest('base64');
}

function encodeFrame(opcode, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, body.length]);
  } else if (body.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  return Buffer.concat([header, body]);
}

/** One accepted server-side WebSocket connection. */
export class WebSocket extends EventEmitter {
  constructor({ socket, head, onClose }) {
    super();
    this.socket = socket;
    this.readyState = 1;
    this.buffer = head !== undefined && head.length > 0 ? Buffer.from(head) : Buffer.alloc(0);
    this.fragments = [];
    this.fragmentOpcode = 0;
    this.onClose = onClose;
    this.closeSent = false;
    socket.on('data', (chunk) => this.onData(chunk));
    socket.on('error', (error) => this.emit('error', error));
    socket.on('close', () => this.finish(1006, 'socket closed'));
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.parseFrame()) {
      /* drain */
    }
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
      for (let index = 0; index < length; index += 1) copy[index] = payload[index] ^ mask[index % 4];
      payload = copy;
    }
    this.buffer = b.subarray(offset + length);
    this.handleFrame(fin, opcode, payload);
    return true;
  }

  handleFrame(fin, opcode, payload) {
    if (opcode === 0x9) {
      this.writeFrame(0xa, payload);
      return undefined;
    }
    if (opcode === 0xa) {
      this.emit('pong');
      return undefined;
    }
    if (opcode === 0x8) {
      const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
      const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
      if (this.closeSent !== true) {
        try {
          this.writeFrame(0x8, payload.subarray(0, 2));
        } catch {
          /* socket already gone */
        }
      }
      this.socket.end();
      this.finish(code, reason);
      return undefined;
    }
    const binary = opcode === 0x2;
    const continuation = opcode === 0x0;
    if (!continuation) {
      this.fragmentOpcode = opcode;
      this.fragments = [];
    }
    this.fragments.push(payload);
    if (!fin) return undefined;
    const full = Buffer.concat(this.fragments);
    this.fragments = [];
    const isBinary = binary || this.fragmentOpcode === 0x2;
    this.emit('message', isBinary ? full : full.toString('utf8'), isBinary);
    return undefined;
  }

  send(data, options = {}) {
    if (this.readyState !== 1) throw new Error('websocket is not open');
    const binary = options?.binary === true || Buffer.isBuffer(data);
    this.writeFrame(binary ? 0x2 : 0x1, data);
  }

  writeFrame(opcode, payload) {
    if (this.socket.destroyed === true) return;
    this.socket.write(encodeFrame(opcode, payload));
  }

  close(code = 1000, reason = '') {
    if (this.readyState !== 1) return;
    this.closeSent = true;
    const reasonBuffer = Buffer.from(String(reason).slice(0, 120), 'utf8');
    const payload = Buffer.alloc(2 + reasonBuffer.length);
    payload.writeUInt16BE(Number.isInteger(code) ? code : 1000, 0);
    reasonBuffer.copy(payload, 2);
    try {
      this.writeFrame(0x8, payload);
    } catch {
      /* socket already gone */
    }
    this.readyState = 3;
    this.socket.end();
    this.finish(code, reason);
  }

  terminate() {
    this.readyState = 3;
    this.socket.destroy();
    this.finish(1006, 'terminated');
  }

  finish(code, reason) {
    if (this.readyState === 3 && this.finished === true) return;
    this.finished = true;
    this.readyState = 3;
    this.onClose?.(this);
    this.emit('close', { code, reason });
  }
}

/** Minimal server matching the surface used by lib/link-server.js. */
export class WebSocketServer {
  constructor(options = {}) {
    this.options = options;
    this.clients = new Set();
  }

  handleUpgrade(request, socket, head, callback) {
    const key = request?.headers?.['sec-websocket-key'];
    if (typeof key !== 'string' || key.length === 0) {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      return;
    }
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Accept: ' + acceptKey(key) + '\r\n' +
        '\r\n'
    );
    const ws = new WebSocket({ socket, head, onClose: (socketLike) => this.clients.delete(socketLike) });
    this.clients.add(ws);
    callback(ws);
  }

  close(callback) {
    for (const client of [...this.clients]) {
      try {
        client.terminate();
      } catch {
        /* already gone */
      }
    }
    this.clients.clear();
    callback?.();
  }
}

export default { WebSocket, WebSocketServer };
