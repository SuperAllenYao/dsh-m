/**
 * mux-rpc.js — P1 single-WSS transport prototype (dsh-m/2), feature-flagged.
 *
 * The M1 bridge keeps the phone's mux frames strictly 1:1: `link-server.js`
 * never parses them (<internal-doc> §3). P1 needs one pinned
 * WSS to carry everything — unary RPC, upstream stream frames and lossless
 * `resume` — so this module adds a *negotiated* outer protocol on the
 * phone↔Mac hop only:
 *
 * client -> plugin plugin -> client
 * {"type":"hello",...} {"type":"welcome",...}
 * {"type":"rpc","id",...} {"type":"rpc/result"|"rpc/error"}
 * upstream mux frames (open/item/…) {"type":"down","sid":N,"frame":{…}}
 * {"type":"ping"} {"type":"pong"}
 *
 * Upstream frames (client→upstream) are forwarded verbatim; the plugin does not
 * reinterpret Remote protocol payloads. Only the server→client direction is
 * enveloped, because that is where `sid` (transport sequence) has to live for
 * `resume{logEpoch,sid}`. The envelope is additive: `frame` is the exact
 * upstream frame object.
 *
 * Downstream gzip: when `hello.caps.gzip` is
 * negotiated and echoed in `welcome.caps.gzip`, a text frame at/above the
 * threshold is sent as a binary WebSocket frame `[1B 0x01][gzip-6 payload]`
 * instead of text; the replay log still stores the text envelope.
 *
 * Design: <internal-doc> (this file is the
 * prototype behind `config.features.muxRpc`; default false = M1 behaviour).
 *
 * Nothing in this module opens sockets or reads config: transport, unary
 * forwarding and ticket minting are injected by link-server.js, which keeps the
 * protocol engine unit-testable without TLS.
 */

import { createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { gzipSync } from 'node:zlib';

/** Wire protocol id negotiated in `hello` / echoed in `welcome`. */
export const P1_PROTO = 'dsh-m/2';

/** Frame types the client may send after `hello`. */
export const CLIENT_CONTROL_TYPES = new Set(['hello', 'rpc', 'ping']);
/** Upstream mux frame types forwarded verbatim (§3.2). */
export const UPSTREAM_FRAME_TYPES = new Set(['open', 'item', 'end', 'cancel']);

/** Default limits; link-server merges these from config.features. */
export const P1_LIMITS = {
 /** Unary calls allowed in flight on one connection (bounded fan-out). */
  rpcMaxInFlight: 8,
 /** Per-call deadline inside the plugin (upstream fetch has no timeout of its own). */
  rpcTimeoutMs: 30_000,
 /** Frames received before `hello`/upstream-attach that we are willing to buffer. */
  pendingClientFrames: 256,
 /** Bytes of buffered client frames before the connection is failed. */
  pendingClientBytes: 1024 * 1024,
 /** Downstream replay log caps (resume window); one snapshot frame is ~0.72 MB. */
  replayBytes: 4 * 1024 * 1024,
  replayFrames: 2000,
 /** How long a detached channel keeps its replay log before it is dropped. */
  resumeWindowMs: 30_000,
 /** First frame must be `hello` within this window (anonymous upgrade guard). */
  helloTimeoutMs: 3_000,
 /** Resume ticket lifetime (stateless HMAC ticket, see mintResumeTicket). */
  ticketTtlMs: 10 * 60_000,
 /** A used ticket jti may be replayed once within this window (lost welcome). */
  ticketReplayGraceMs: 10_000,
 /** Downstream text frames at/above this size are gzip-compressed (L3a). */
  gzipThresholdBytes: 4096,
};

/**
 * Downstream gzip wire format: a compressed frame is
 * one binary WebSocket frame `[1B version][gzip-6 payload]`. Compression is
 * negotiated per socket (`hello.caps.gzip` → `welcome.caps.gzip`) and only
 * applied plugin→phone; upstream traffic stays text JSON.
 */
export const GZIP_FRAME_VERSION = 0x01;
/** zlib level for downstream gzip (gzip-6: F11 measured 4.64x; gzip-9 only 4.72x). */
const GZIP_LEVEL = 6;

/** Protocol violation carrying an explicit close code for the transport. */
export class MuxProtocolError extends Error {
  constructor(code, message, closeCode = 4400) {
    super(message);
    this.name = 'MuxProtocolError';
    this.code = code;
    this.closeCode = closeCode;
  }
}

/** Parse one WebSocket text message as one JSON object. */
export function parseFrame(text) {
  if (typeof text !== 'string' || text.length === 0) throw new MuxProtocolError('frame/empty', 'empty frame');
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new MuxProtocolError('frame/invalid-json', 'frame is not valid JSON');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new MuxProtocolError('frame/invalid-shape', 'frame must be a JSON object');
  }
  return value;
}

/**
 * Bounded ring buffer of already-delivered downstream frames.
 *
 * Appending evicts the oldest entries first, so `since(sid)` can always answer
 * "can I replay exactly what the phone missed?" or "there is a gap, reset".
 * Byte accounting is the UTF-8 length of the serialized envelope (WebSocket
 * text payload size, which is what the phone would have received).
 */
export class ReplayLog {
  constructor({ maxBytes = P1_LIMITS.replayBytes, maxFrames = P1_LIMITS.replayFrames } = {}) {
    this.maxBytes = maxBytes;
    this.maxFrames = maxFrames;
 /** @type {Array<{sid: number, text: string, bytes: number}>} */
    this.entries = [];
    this.bytes = 0;
    this.lastSid = 0;
  }

  append(sid, text) {
    const bytes = Buffer.byteLength(text, 'utf8');
    this.entries.push({ sid, text, bytes });
    this.bytes += bytes;
    this.lastSid = sid;
    while (this.entries.length > this.maxFrames || (this.bytes > this.maxBytes && this.entries.length > 1)) {
      const dropped = this.entries.shift();
      this.bytes -= dropped.bytes;
    }
    return bytes;
  }

 /**
 * Frames with sid > `sid`, in delivery order.
 * @returns {{ok: true, frames: string[]} | {ok: false, reason: string}}
 */
  since(sid) {
    if (!Number.isInteger(sid) || sid < 0) return { ok: false, reason: 'sid-invalid' };
    if (this.entries.length === 0) {
 // Nothing retained: resumable only if the phone already had everything.
      return sid >= this.lastSid ? { ok: true, frames: [] } : { ok: false, reason: 'evicted' };
    }
    const oldest = this.entries[0].sid;
    if (sid + 1 < oldest) return { ok: false, reason: 'evicted' };
    if (sid > this.lastSid) return { ok: false, reason: 'sid-ahead' };
    const frames = this.entries.filter((entry) => entry.sid > sid).map((entry) => entry.text);
    if (frames.length > 0 && this.entries.some((entry) => entry.sid === sid + 1) === false) {
      return { ok: false, reason: 'gap' };
    }
    return { ok: true, frames };
  }

  clear() {
    this.entries.length = 0;
    this.bytes = 0;
    this.lastSid = 0;
  }
}

// --------------------------------------------------------------------- tickets

function hmac(secret, value) {
  const key = Buffer.isBuffer(secret) ? secret : Buffer.from(String(secret));
  return createHmac('sha256', key).update(value).digest();
}

/**
 * Mint a stateless resume ticket: `base64url(payload).base64url(HMAC-SHA256)`.
 *
 * The ticket lets a reconnecting phone skip `/auth/challenge` + `/auth/verify`
 * (2R) while keeping ECDSA for the *first* connection of a pairing. It is bound
 * to the device id, the channel's logEpoch and a short TTL; the transport is
 * still the pinned E2E TLS to the Mac (relay stays zero-knowledge).
 */
export function mintResumeTicket({ secret, deviceId, epoch, ttlMs = P1_LIMITS.ticketTtlMs, now = Date.now() }) {
  const payload = {
    v: 1,
    d: deviceId,
    e: epoch,
    exp: now + ttlMs,
 // Single-use id: the plugin remembers used jti values in memory so a
 // stolen/leaked ticket cannot be replayed for its whole TTL (design §4.2).
    jti: randomBytes(12).toString('base64url'),
    n: randomBytes(9).toString('base64url'),
  };
  const body = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  return body + '.' + hmac(secret, body).toString('base64url');
}

/** Verify a resume ticket. Returns `{ok:true, deviceId, epoch, jti, expiresAt}` or `{ok:false, reason}`. */
export function verifyResumeTicket({ secret, ticket, now = Date.now() }) {
  if (typeof ticket !== 'string' || ticket.length === 0 || ticket.length > 1024) return { ok: false, reason: 'malformed' };
  if (secret === undefined || secret === null) return { ok: false, reason: 'no-secret' };
  const at = ticket.indexOf('.');
  if (at <= 0) return { ok: false, reason: 'malformed' };
  const body = ticket.slice(0, at);
  const signature = ticket.slice(at + 1);
  let provided;
  try {
    provided = Buffer.from(signature, 'base64url');
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  const expected = hmac(secret, body);
  if (provided.length !== expected.length || timingSafeEqual(provided, expected) !== true) return { ok: false, reason: 'bad-signature' };
  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  if (payload === null || typeof payload !== 'object' || payload.v !== 1) return { ok: false, reason: 'unsupported' };
  if (typeof payload.d !== 'string' || payload.d.length === 0) return { ok: false, reason: 'malformed' };
  if (typeof payload.exp !== 'number' || payload.exp <= now) return { ok: false, reason: 'expired' };
 // jti is required from here on: tickets minted before the single-use change
 // cannot outlive a process restart anyway (secret is in-memory only), so
 // rejecting them never breaks a live ticket.
  if (typeof payload.jti !== 'string' || payload.jti.length === 0 || payload.jti.length > 64) return { ok: false, reason: 'malformed' };
  return { ok: true, deviceId: payload.d, epoch: typeof payload.e === 'string' ? payload.e : undefined, jti: payload.jti, expiresAt: payload.exp };
}

/**
 * In-memory single-use guard for resume-ticket `jti` values (design §4.2 #1).
 *
 * A ticket verifies once, then may be replayed **once** within `graceMs` (the
 * App re-sends the same ticket when the first `welcome` is lost), after which
 * it is rejected. Entries are kept until the ticket expires so a used ticket
 * cannot become reusable by waiting.
 *
 * Deliberately process-local and never persisted: a plugin restart drops both
 * the HMAC secret and this table, so every cached ticket dies and the App
 * falls back to ECDSA (accepted, see README §3.3).
 */
export class TicketUseGuard {
  constructor({ graceMs = P1_LIMITS.ticketReplayGraceMs, maxEntries = 4096, now = () => Date.now() } = {}) {
    this.graceMs = graceMs;
    this.maxEntries = maxEntries;
    this.now = now;
 /** @type {Map<string, {firstUsedAt: number, replays: number, expiresAt: number}>} */
    this.used = new Map();
  }

 /**
 * Record one use of `jti`. Returns `{ok:true, replay}` or
 * `{ok:false, reason:'replayed'}`. `expiresAt` is the ticket `exp` (unixMs).
 */
  use(jti, expiresAt) {
    if (typeof jti !== 'string' || jti.length === 0) return { ok: false, reason: 'malformed' };
    const now = this.now();
    this.sweep(now);
    const entry = this.used.get(jti);
    if (entry === undefined) {
      this.used.set(jti, {
        firstUsedAt: now,
        replays: 0,
        expiresAt: Number.isFinite(expiresAt) ? expiresAt : now + this.graceMs,
      });
      this.evictOverflow();
      return { ok: true, replay: false };
    }
    if (now - entry.firstUsedAt <= this.graceMs && entry.replays === 0) {
      entry.replays = 1;
      return { ok: true, replay: true };
    }
    return { ok: false, reason: 'replayed' };
  }

 /** Drop entries whose ticket can no longer verify (expired). */
  sweep(now = this.now()) {
    for (const [jti, entry] of this.used) {
      if (now >= entry.expiresAt) this.used.delete(jti);
    }
  }

  evictOverflow() {
    while (this.used.size > this.maxEntries) {
      const oldest = this.used.keys().next();
      if (oldest.done === true) return;
      this.used.delete(oldest.value);
    }
  }

 /** Live entry count (for status/tests; swept on read). */
  get size() {
    this.sweep();
    return this.used.size;
  }
}

// --------------------------------------------------------------------- channel

/**
 * One logical P1 channel per device.
 *
 * Its lifetime is longer than one socket: the replay log, epoch and transport
 * sequence survive a dropped phone socket so a reconnect can `resume`. The
 * link server disposes the channel after `resumeWindowMs` of detachment (or as
 * soon as the upstream mux dies, because then there is nothing to resume).
 *
 * Injected dependencies:
 * - forwardUnary({deviceId, endpoint, bodyText}): Promise<{status, contentType, bytes}>
 * - issueTicket(epoch): string | undefined (resume ticket for the welcome frame)
 * - gzip {enabled, thresholdBytes}: downstream compression policy from
 * `config.features.muxGzip*`; negotiation still needs `hello.caps.gzip`.
 */
export class MuxRpcChannel {
  constructor({ deviceId, forwardUnary, issueTicket, limits = {}, gzip = {}, log = () => {}, now = () => Date.now(), epoch = randomUUID() }) {
    if (typeof deviceId !== 'string' || deviceId.length === 0) throw new Error('MuxRpcChannel requires a deviceId');
    if (typeof forwardUnary !== 'function') throw new Error('MuxRpcChannel requires forwardUnary()');
    this.deviceId = deviceId;
    this.forwardUnary = forwardUnary;
    this.issueTicket = typeof issueTicket === 'function' ? issueTicket : () => undefined;
    this.limits = { ...P1_LIMITS, ...limits };
 /** Downstream gzip policy (link-server config.features.muxGzip / muxGzipThresholdBytes). */
    this.gzip = {
      enabled: gzip.enabled === true,
      thresholdBytes: Number.isInteger(gzip.thresholdBytes) && gzip.thresholdBytes > 0 ? gzip.thresholdBytes : P1_LIMITS.gzipThresholdBytes,
    };
 /** Per-socket negotiated gzip; only `onHello` may set it, `attachTransport` resets it. */
    this.gzipEnabled = false;
    this.log = log;
    this.now = now;
    this.epoch = epoch;
 /** Last assigned downstream transport sequence (envelope `sid`). */
    this.sid = 0;
    this.replay = new ReplayLog({ maxBytes: this.limits.replayBytes, maxFrames: this.limits.replayFrames });
 /** @type {'awaiting-hello' | 'ready' | 'closed'} */
    this.phase = 'awaiting-hello';
 /** @type {{send: (text: string) => void, sendBinary?: (data: Buffer) => void, close: (code: number, reason: string) => void} | undefined} */
    this.transport = undefined;
    this.transportGen = 0;
    this.helloGen = -1;
 /** @type {{send: (text: string) => void} | undefined} */
    this.upstream = undefined;
    this.upstreamClosed = false;
 /** @type {Map<string, {timer: ReturnType<typeof setTimeout>, at: number}>} */
    this.inflight = new Map();
 /** @type {string[]} client frames buffered until the upstream mux is attached */
    this.pendingClient = [];
 /** Upstream streamIds opened by this epoched channel (for reset cleanup). @type {Set<string>} */
    this.openStreams = new Set();
    this.pendingClientBytes = 0;
    this.disposed = false;
    this.disposeTimer = undefined;
    this.stats = {
      rpcOk: 0,
      rpcFailed: 0,
      down: 0,
      replayed: 0,
      resumes: 0,
      resumeResets: 0,
      protocolErrors: 0,
      upstreamForwarded: 0,
 // L3a: compressed downstream frames (counted when produced, like `down`).
      gzipFrames: 0,
      gzipRawBytes: 0,
      gzipWireBytes: 0,
    };
  }

 /** Attach a (new) downstream socket. A reconnect reuses the channel state. */
  attachTransport(transport) {
    if (this.disposed) throw new Error('MuxRpcChannel is disposed');
    if (this.transport !== undefined) throw new Error('MuxRpcChannel already has a transport');
    this.transport = transport;
    this.transportGen += 1;
 // gzip is negotiated per socket via `hello.caps.gzip`: a reconnecting phone
 // (or an older App that never asks) must not inherit the previous
 // transport's negotiation and receive binary frames it cannot parse.
    this.gzipEnabled = false;
  }

 /** The downstream socket is gone: keep epoch/log for a while, stop sending. */
  detachTransport() {
    this.transport = undefined;
    this.clearInflight('downstream closed');
  }

 /** Attach the upstream mux sender and flush client frames buffered meanwhile. */
  attachUpstream({ send }) {
    if (this.disposed) return;
    this.upstream = { send };
    this.upstreamClosed = false;
    const pending = this.pendingClient.splice(0);
    this.pendingClientBytes = 0;
    for (const text of pending) {
      try {
        this.upstream.send(text);
        this.stats.upstreamForwarded += 1;
      } catch (error) {
        this.log('device ' + this.deviceId + ': upstream send failed: ' + String(error?.message ?? error));
      }
    }
  }

 /** The upstream mux died: nothing can be resumed, fail the phone socket. */
  detachUpstream(reason) {
    this.upstream = undefined;
    this.upstreamClosed = true;
    this.clearInflight('upstream closed');
    if (this.transport !== undefined) {
      try {
        this.transport.close(1011, String(reason ?? 'upstream closed').slice(0, 120));
      } catch {
 /* already gone */
      }
    }
  }

  dispose(reason = 'disposed') {
    if (this.disposed) return;
    this.disposed = true;
    this.phase = 'closed';
    clearTimeout(this.disposeTimer);
    this.disposeTimer = undefined;
    this.clearInflight(reason);
    this.pendingClient.length = 0;
    this.pendingClientBytes = 0;
    this.cancelOpenStreams();
    this.replay.clear();
    const transport = this.transport;
    this.transport = undefined;
    if (transport !== undefined) {
      try {
        transport.close(1001, 'channel closed');
      } catch {
 /* already gone */
      }
    }
    this.log('device ' + this.deviceId + ': P1 channel disposed (' + reason + ')');
  }

  clearInflight(reason) {
    for (const entry of this.inflight.values()) clearTimeout(entry.timer);
    this.inflight.clear();
    if (reason !== undefined) this.pendingInflightReason = reason;
  }

 /** Entry point for every text frame from the phone. */
  handleClient(text) {
    if (this.disposed) return;
    let frame;
    try {
      frame = parseFrame(text);
    } catch (error) {
      return this.failProtocol(error);
    }
    try {
      if (frame.type === 'hello') {
        this.onHello(frame, text);
        return;
      }
      if (this.phase !== 'ready') throw new MuxProtocolError('hello/required', 'first frame must be hello', 4408);
      this.onReadyFrame(frame, text);
    } catch (error) {
      if (error instanceof MuxProtocolError) return this.failProtocol(error);
      this.countersFailure('internal', error);
    }
  }

 /** Upstream mux frame → sequenced envelope for the phone + replay log. */
  onUpstreamMessage(text) {
    if (this.disposed) return;
    let frame;
    try {
      frame = parseFrame(text);
    } catch {
      this.failProtocol(new MuxProtocolError('upstream/invalid-frame', 'upstream sent an invalid mux frame', 1011));
      return;
    }
    if ((frame.type === 'end' || frame.type === 'error') && typeof frame.streamId === 'string') this.openStreams.delete(frame.streamId);
    this.sid += 1;
    const envelope = JSON.stringify({ type: 'down', sid: this.sid, frame });
 // The replay log keeps the text envelope (memory accounting, design C4);
 // the wire may compress it — sendText applies the negotiated gzip policy.
    this.replay.append(this.sid, envelope);
    this.stats.down += 1;
    this.sendText(envelope);
 // sendText no-ops without a transport: the frame stays in the replay log
 // above and is re-sent (re-compressed) on the next resume instead.
  }

 // ------------------------------------------------------------------ hello ---

  onHello(frame, text) {
    if (frame.v !== 2) throw new MuxProtocolError('hello/version', 'unsupported protocol version', 4400);
    if (this.helloGen === this.transportGen) throw new MuxProtocolError('hello/duplicate', 'hello already negotiated on this socket');
    if (this.transport === undefined) throw new MuxProtocolError('hello/no-transport', 'hello without a transport', 1011);
    const reconnecting = this.helloGen !== -1;
    this.helloGen = this.transportGen;
    this.phase = 'ready';
 // L3a: downstream gzip is per-socket — the client must ask
 // (`hello.caps.gzip`), the plugin policy must allow it and the transport
 // must accept binary frames; `welcome.caps.gzip` echoes the outcome so the
 // phone knows the wire format before the first frame. Unknown caps keys are
 // ignored on purpose (forward compatibility with future App versions).
    const clientCaps = frame.caps !== null && typeof frame.caps === 'object' && !Array.isArray(frame.caps) ? frame.caps : {};
    this.gzipEnabled = this.gzip.enabled === true && clientCaps.gzip === true && typeof this.transport.sendBinary === 'function';
    if (reconnecting && frame.resume === undefined) {
 // The phone reconnected without a resume cursor: it dropped its stream
 // state, so cancelling the old upstream streams and starting a new epoch
 // is the only way to avoid a leak / duplicate streams.
      this.stats.resumeResets += 1;
      this.resetEpoch();
    }
    const { info: resume, frames: replayFrames } = this.applyResume(frame.resume);
    const ticket = this.issueTicket(this.epoch);
    const welcome = {
      type: 'welcome',
      v: 2,
      proto: P1_PROTO,
      deviceId: this.deviceId,
      epoch: this.epoch,
      sid: this.sid,
      resume,
      caps: {
        unary: true,
        resume: true,
        gzip: this.gzipEnabled,
        maxInFlight: this.limits.rpcMaxInFlight,
        replayBytes: this.limits.replayBytes,
      },
    };
    if (typeof ticket === 'string' && ticket.length > 0) welcome.ticket = ticket;
 // `welcome` precedes the replay so the phone learns epoch/sid before frames.
    this.send(welcome);
    for (const text of replayFrames) this.sendText(text);
    this.stats.lastHelloBytes = Buffer.byteLength(text, 'utf8');
  }

 /**
 * Validate `hello.resume` against the retained log; reset the epoch on gap.
 * Returns the `welcome.resume` summary plus the frames to replay after it.
 */
  applyResume(resume) {
    if (resume === undefined) return { info: { ok: true, mode: 'fresh' }, frames: [] };
    if (resume === null || typeof resume !== 'object' || Array.isArray(resume)) {
      throw new MuxProtocolError('resume/invalid', 'resume must be an object');
    }
    if (typeof resume.logEpoch !== 'string' || resume.logEpoch.length === 0) {
      throw new MuxProtocolError('resume/invalid', 'resume.logEpoch is required');
    }
    this.stats.resumes += 1;
    if (resume.logEpoch !== this.epoch) {
      this.stats.resumeResets += 1;
      this.resetEpoch();
      return { info: { ok: false, mode: 'reset', reason: 'epoch-mismatch' }, frames: [] };
    }
    const sid = Number(resume.sid);
    if (!Number.isInteger(sid) || sid < 0) throw new MuxProtocolError('resume/invalid', 'resume.sid must be a non-negative integer');
    const since = this.replay.since(sid);
    if (!since.ok) {
      this.stats.resumeResets += 1;
      this.resetEpoch();
      return { info: { ok: false, mode: 'reset', reason: since.reason }, frames: [] };
    }
    this.stats.replayed += since.frames.length;
    return { info: { ok: true, mode: 'replay', replayed: since.frames.length }, frames: since.frames };
  }

  resetEpoch() {
    this.cancelOpenStreams();
    this.epoch = randomUUID();
    this.sid = 0;
    this.replay.clear();
  }

 /**
 * Best-effort `cancel` for streams opened in the old epoch. The App is still
 * responsible for re-opening state, but cancelling avoids leaking upstream
 * streams when the upstream mux itself survives (resume window / plugin-side
 * reset). No-op when the upstream is already gone.
 */
  cancelOpenStreams() {
    const streamIds = [...this.openStreams];
    this.openStreams.clear();
    if (streamIds.length === 0 || this.upstream === undefined) return 0;
    for (const streamId of streamIds) {
      try {
        this.upstream.send(JSON.stringify({ type: 'cancel', streamId }));
      } catch {
 /* upstream already gone */
      }
    }
    this.stats.streamsCancelled = (this.stats.streamsCancelled ?? 0) + streamIds.length;
    return streamIds.length;
  }

 // ------------------------------------------------------------ ready frames ---

  onReadyFrame(frame, text) {
    switch (frame.type) {
      case 'rpc':
        return this.onRpc(frame);
      case 'ping':
        return this.send({ type: 'pong', ts: frame.ts ?? null });
      default:
        break;
    }
    if (UPSTREAM_FRAME_TYPES.has(frame.type)) {
      if (frame.type === 'open' && typeof frame.streamId === 'string') this.openStreams.add(frame.streamId);
      if (frame.type === 'cancel' && typeof frame.streamId === 'string') this.openStreams.delete(frame.streamId);
      if (this.upstream !== undefined) {
        this.upstream.send(text);
        this.stats.upstreamForwarded += 1;
        return;
      }
      const bytes = Buffer.byteLength(text, 'utf8');
      if (this.pendingClient.length >= this.limits.pendingClientFrames || this.pendingClientBytes + bytes > this.limits.pendingClientBytes) {
        throw new MuxProtocolError('upstream/pending-overflow', 'too many frames before the upstream mux is ready', 1013);
      }
      this.pendingClient.push(text);
      this.pendingClientBytes += bytes;
      return;
    }
    throw new MuxProtocolError('frame/unsupported', 'unsupported frame type: ' + String(frame.type));
  }

  onRpc(frame) {
    if (typeof frame.id !== 'string' || frame.id.length === 0 || frame.id.length > 128) {
      throw new MuxProtocolError('rpc/invalid-id', 'rpc.id must be a non-empty string');
    }
    if (typeof frame.endpoint !== 'string' || !/^[A-Za-z0-9_$.-]+\/[A-Za-z0-9_$.-]+$/.test(frame.endpoint)) {
      return this.sendRpcError(frame.id, 'rpc/bad-endpoint', 'endpoint must look like ns/method');
    }
    if (frame.body === null || typeof frame.body !== 'object' || Array.isArray(frame.body)) {
      return this.sendRpcError(frame.id, 'rpc/bad-body', 'body must be the client-request object');
    }
    if (this.inflight.has(frame.id)) {
      return this.sendRpcError(frame.id, 'rpc/duplicate-id', 'rpc.id already in flight');
    }
    if (this.inflight.size >= this.limits.rpcMaxInFlight) {
      return this.sendRpcError(frame.id, 'rpc/busy', 'too many unary calls in flight; retry after a result');
    }
    let bodyText;
    try {
      bodyText = JSON.stringify(frame.body);
    } catch {
      return this.sendRpcError(frame.id, 'rpc/bad-body', 'body is not serializable');
    }
    const entry = {
      timer: setTimeout(() => {
        if (!this.inflight.delete(frame.id)) return;
        this.sendRpcError(frame.id, 'rpc/timeout', 'unary call timed out inside the link');
      }, this.limits.rpcTimeoutMs),
      at: this.now(),
    };
    if (typeof entry.timer.unref === 'function') entry.timer.unref();
    this.inflight.set(frame.id, entry);
    Promise.resolve()
      .then(() => this.forwardUnary({ deviceId: this.deviceId, endpoint: frame.endpoint, bodyText, headers: frame.headers }))
      .then((result) => {
        if (this.disposed || this.inflight.delete(frame.id) !== true) return;
        clearTimeout(entry.timer);
        this.stats.rpcOk += 1;
        const out = {
          type: 'rpc/result',
          id: frame.id,
          status: Number.isInteger(result?.status) ? result.status : 200,
          contentType: typeof result?.contentType === 'string' ? result.contentType : 'application/octet-stream',
        };
        const bytes = result?.bytes ?? Buffer.alloc(0);
        const text = Buffer.isBuffer(bytes) ? bytes.toString('utf8') : String(bytes ?? '');
        let body;
        let parsed = false;
        try {
          body = JSON.parse(text);
          parsed = true;
        } catch {
          parsed = false;
        }
        if (parsed) out.body = body;
        else out.bodyText = text;
        this.send(out);
      })
      .catch((error) => {
        if (this.disposed || this.inflight.delete(frame.id) !== true) return;
        clearTimeout(entry.timer);
        this.stats.rpcFailed += 1;
        this.sendRpcError(frame.id, 'upstream/failed', String(error?.message ?? error));
      });
  }

  sendRpcError(id, code, message) {
    this.stats.rpcFailed += 1;
    this.send({ type: 'rpc/error', id, error: { code, message: String(message) } });
  }

 // ----------------------------------------------------------------- output ---

  send(value) {
    this.sendText(JSON.stringify(value));
  }

  sendText(text) {
    if (this.transport === undefined) return;
    const rawBytes = Buffer.byteLength(text, 'utf8');
 // L3a: negotiated + at/above the threshold → one binary frame
 // `[0x01][gzip-6]`. Counters observe the compression itself so /health can
 // report the raw↔wire ratio; they are produced-frame counters like `down`.
    if (this.gzipEnabled === true && rawBytes >= this.gzip.thresholdBytes) {
      const wire = Buffer.concat([Buffer.from([GZIP_FRAME_VERSION]), gzipSync(text, { level: GZIP_LEVEL })]);
      this.stats.gzipFrames += 1;
      this.stats.gzipRawBytes += rawBytes;
      this.stats.gzipWireBytes += wire.length;
      try {
        this.transport.sendBinary(wire);
      } catch (error) {
        this.log('device ' + this.deviceId + ': downstream send failed: ' + String(error?.message ?? error));
      }
      return;
    }
    try {
      this.transport.send(text);
    } catch (error) {
      this.log('device ' + this.deviceId + ': downstream send failed: ' + String(error?.message ?? error));
    }
  }

  failProtocol(error) {
    this.stats.protocolErrors += 1;
    this.stats.lastProtocolError = { code: error?.code, message: String(error?.message ?? error) };
    const transport = this.transport;
    if (transport !== undefined) {
      try {
        transport.close(error?.closeCode ?? 4400, String(error?.message ?? 'protocol error').slice(0, 120));
      } catch {
 /* already gone */
      }
    }
  }

  countersFailure(kind, error) {
    this.stats.protocolErrors += 1;
    this.log('device ' + this.deviceId + ': P1 ' + kind + ' failure: ' + String(error?.message ?? error));
  }

 /** Compact snapshot for statusPayload/audit (no secrets). */
  info() {
    return {
      deviceId: this.deviceId,
      epoch: this.epoch,
      phase: this.phase,
      sid: this.sid,
      attached: this.transport !== undefined,
      upstream: this.upstream !== undefined,
      replayFrames: this.replay.entries.length,
      replayBytes: this.replay.bytes,
      gzip: this.gzipEnabled,
      inflight: this.inflight.size,
      disposed: this.disposed,
      stats: { ...this.stats },
    };
  }
}
