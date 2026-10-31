/**
 * upstream-peer.js — one DSH API Peer per device.
 *
 * Mirrors <internal-doc> §1:
 * ctx.connection.authenticatedUrl(loopbackOrigin) -> process token
 * GET /connect?token=...&interactions=answer (redirect: manual) -> 3xx + Set-Cookie
 * connect ws://127.0.0.1:<port>/api/remote.mux with that cookie
 *
 * The peer here is deliberately thin: the link plugin never parses or
 * re-encodes Remote protocol payloads, it only carries them.
 */

import { wsBindings, loadWs } from './ws-provider.js';

const OPEN_TIMEOUT_MS = 15000;

/** Parse a Set-Cookie header pair into name/value (attributes ignored). */
export function parseSetCookie(raw) {
  if (typeof raw !== 'string' || raw.length === 0) return undefined;
  const pair = raw.split(';', 1)[0];
  const at = pair.indexOf('=');
  if (at <= 0) return undefined;
  return { name: pair.slice(0, at), value: pair.slice(at + 1) };
}

export class UpstreamPeer {
 /**
 * @param {{
 * deviceId: string,
 * loopbackOrigin: string,
 * authenticatedUrl: (baseUrl: string) => string,
 * log?: (message: string) => void,
 * onFrame?: (data: unknown, isBinary: boolean) => void,
 * }} options
 */
  constructor({ deviceId, loopbackOrigin, authenticatedUrl, log = () => {}, onFrame }) {
    this.deviceId = deviceId;
    this.loopbackOrigin = loopbackOrigin;
    this.authenticatedUrl = authenticatedUrl;
    this.log = log;
 /** @type {{name: string, value: string} | undefined} */
    this.cookie = undefined;
    this.muxUrl = undefined;
 /** @type {import('ws').WebSocket | undefined} */
    this.ws = undefined;
    this.connectCount = 0;
 /**
 * Read-only observer for every upstream mux frame (used by the notifier).
 * The bridge still forwards the original bytes unchanged.
 * @type {((data: unknown, isBinary: boolean) => void) | undefined}
 */
    this.onFrame = typeof onFrame === 'function' ? onFrame : undefined;
 /** @type {{at: number, message: string} | undefined} */
    this.lastError = undefined;
  }

 /** Exchange the process token for a fresh API cookie (a new owner Peer). */
  async connect(interactions = 'answer') {
    const processUrl = new URL(this.authenticatedUrl(this.loopbackOrigin));
    const token = processUrl.searchParams.get('token');
    if (token === null) throw new Error('dsh-m-link: authenticatedUrl returned no token');
    const connectUrl = new URL('/connect', this.loopbackOrigin);
    connectUrl.searchParams.set('token', token);
    connectUrl.searchParams.set('interactions', interactions);
    const response = await fetch(connectUrl, { method: 'GET', redirect: 'manual' });
    const rawSetCookie = response.headers.getSetCookie?.()[0] ?? response.headers.get('set-cookie') ?? undefined;
    if (response.status < 300 || response.status >= 400 || rawSetCookie === undefined) {
      throw new Error('dsh-m-link: /connect failed: expected a 3xx redirect with set-cookie, got HTTP ' + response.status + (rawSetCookie === undefined ? ' (no set-cookie)' : ''));
    }
    const cookie = parseSetCookie(rawSetCookie);
    if (cookie === undefined) throw new Error('dsh-m-link: /connect returned an unparsable set-cookie');
    this.cookie = cookie;
    const rawLocation = response.headers.get('location');
    const location = typeof rawLocation === 'string' && rawLocation.length > 0 ? rawLocation : './api.remote.mux';
    let muxTarget;
    try {
      muxTarget = new URL(location, this.loopbackOrigin);
    } catch {
      throw new Error('dsh-m-link: /connect failed: unparsable Location ' + JSON.stringify(location));
    }
    if (muxTarget.pathname.length === 0 || !muxTarget.pathname.startsWith('/')) {
      throw new Error('dsh-m-link: /connect failed: mux path ' + JSON.stringify(muxTarget.pathname) + ' is not an absolute path');
    }
    this.muxUrl = muxTarget.href.replace(/^http/, 'ws');
    this.connectCount += 1;
    this.log('device ' + this.deviceId + ': /connect ok, mux target ' + this.muxUrl + ' (peer #' + String(this.connectCount) + ')');
    return { status: response.status, muxUrl: this.muxUrl, cookieName: cookie.name };
  }

 /** Open the upstream mux socket (reconnecting with a fresh cookie if needed). */
  async openMux() {
    if (this.cookie === undefined) await this.connect();
    if (this.ws !== undefined && (this.ws.readyState === 0 || this.ws.readyState === 1)) return this.ws;
    const mod = await loadWs();
    const { WebSocket } = wsBindings(mod);
    const socket = new WebSocket(this.muxUrl, {
      headers: { cookie: this.cookie.name + '=' + this.cookie.value },
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.terminate?.();
        reject(new Error('dsh-m-link: upstream mux open timeout'));
      }, OPEN_TIMEOUT_MS);
      socket.once('open', () => {
        clearTimeout(timer);
        resolve();
      });
      socket.once('unexpected-response', (_request, response) => {
        clearTimeout(timer);
        reject(Object.assign(new Error('dsh-m-link: upstream mux rejected with HTTP ' + response.statusCode), { statusCode: response.statusCode }));
      });
      socket.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      socket.once('close', (code) => {
        clearTimeout(timer);
        reject(new Error('dsh-m-link: upstream mux closed before open (code ' + String(code) + ')'));
      });
    });
    this.ws = socket;
    socket.on('message', (data, isBinary) => {
      if (this.onFrame === undefined) return;
      try {
        this.onFrame(data, isBinary);
      } catch {
 /* the observer must never break the bridge */
      }
    });
    this.log('device ' + this.deviceId + ': upstream mux open');
    return socket;
  }

 /** Ensure a usable upstream mux; a 409/never-opened peer reconnects with a fresh /connect. */
  async ensureMux() {
    try {
      return await this.openMux();
    } catch (error) {
      this.lastError = { at: Date.now(), message: String(error?.message ?? error) };
      if (error?.statusCode !== 409 && this.cookie !== undefined) {
 // Peer disposed or socket race: get a fresh cookie and retry once (§4.2 recommended path).
        this.log('device ' + this.deviceId + ': upstream mux failed (' + String(error?.message) + '); retrying with a fresh /connect');
        this.cookie = undefined;
        return await this.openMux();
      }
      throw error;
    }
  }

  get muxOpen() {
    return this.ws !== undefined && this.ws.readyState === 1;
  }

  close(reason = 'link dispose') {
    const socket = this.ws;
    this.ws = undefined;
    this.cookie = undefined;
    if (socket !== undefined) {
      try {
        socket.close(1000, reason.slice(0, 120));
      } catch {
 /* already closed */
      }
    }
  }
}