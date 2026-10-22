/**
 * frame-audit.js — debug-gated frame-level audit observation for the device mux.
 *
 * Why this exists (HANDOFF §5 Bug1): a freshly paired iPhone occasionally hangs
 * on "正在连接 Mac…"; the audit log then has `conn.open` / `mux auth.ok` /
 * `device.push-token` but no `session/list` unary at all, and nothing shows
 * *which segment of the device mux lost the `$events` open/ready handshake*.
 * This observer records one metadata line per frame at each hop so the next
 * occurrence can be localised from the audit log alone:
 *
 *   from-device    phone  -> plugin      (frame received from the phone socket)
 *   to-upstream    plugin -> local DSH   (frame forwarded to the upstream mux)
 *   from-upstream  local DSH -> plugin   (frame received from the upstream mux)
 *   to-device      plugin -> phone       (envelope/control frame queued for the phone)
 *
 * Recorded fields are metadata only: direction, frame type, `streamId`, the
 * transport envelope sequence (`sid`), and a few fixed protocol keywords
 * (`$events`, `ready`/`waterfall`/…). Every value is rebuilt from a whitelist:
 * free-form strings are dropped unless they match the protocol shape, so
 * payload bodies, tokens, resume tickets, credentials, cookies and IPs can
 * never reach the audit log through this module.
 *
 * Cost model: an instance is constructed only when `config.debug.enabled` is
 * true (see link-server.js). With debug off there is no instance, so each call
 * site is a single `undefined` property check and the bridge behaves exactly as
 * before — no JSON parsing, no serialization, no allocation per frame.
 */

/** Hard per-device cap: a frame storm must not flush the shared audit segments. */
const MAX_RECORDS_PER_DEVICE = 4000;

/** Protocol frame types are lowercase keywords (`open`, `item`, `rpc/result`). */
const SAFE_FRAME_TYPE = /^[a-z][a-z0-9./-]{0,31}$/;

/** Client-generated stream ids are uuid-ish tokens; anything else is dropped. */
const SAFE_STREAM_ID = /^[A-Za-z0-9_.:-]{1,64}$/;

/**
 * `item.value.type` keywords that matter for the handshake / approval flow
 * (remote-protocol §3.7). Business payloads on ordinary streams have arbitrary
 * `value` shapes and are deliberately not recorded.
 */
const ITEM_VALUE_KINDS = new Set(['ready', 'emit', 'waterfall', 'cancel']);

/** Fixed direction enum (also accepts a single `dir` field in the audit line). */
const DIRECTIONS = new Set(['from-device', 'to-upstream', 'from-upstream', 'to-device']);

/** Parse one WS text frame into a JSON object without ever keeping the payload. */
function parseObject(text) {
  if (typeof text !== 'string' || text.length === 0) return undefined;
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return undefined;
  }
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : undefined;
}

/** Normalise WS message data to text; only called for text frames. */
function toText(data) {
  if (typeof data === 'string') return data;
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  return String(data);
}

/**
 * Whitelisted metadata for one mux frame object (upstream protocol §3.2).
 * The frame's payload/arguments are never read.
 * @param {unknown} frame
 * @returns {{type: string, streamId?: string, ep?: string, vt?: string}}
 */
export function frameMetadata(frame) {
  /** @type {{type: string, streamId?: string, ep?: string, vt?: string}} */
  const meta = { type: '?' };
  if (frame === null || typeof frame !== 'object' || Array.isArray(frame)) return meta;
  if (typeof frame.type === 'string' && SAFE_FRAME_TYPE.test(frame.type)) meta.type = frame.type;
  if (typeof frame.streamId === 'string' && SAFE_STREAM_ID.test(frame.streamId)) meta.streamId = frame.streamId;
  if (meta.type === 'open') {
    // Only the gateway-internal `$events` stream is named; every other endpoint
    // is collapsed to `other` so no business routing key is copied verbatim.
    meta.ep = frame.endpoint === '$events' ? '$events' : 'other';
  }
  if (meta.type === 'item' && frame.value !== null && typeof frame.value === 'object' && !Array.isArray(frame.value)) {
    const kind = frame.value.type;
    if (typeof kind === 'string' && ITEM_VALUE_KINDS.has(kind)) meta.vt = kind;
  }
  return meta;
}

/**
 * Whitelisted metadata for one plugin→phone frame: either a dsh-m/2 envelope
 * (`welcome`, `pong`, `rpc/result`, `down{sid,frame}`) or a bare M1 bridge frame.
 * The envelope's `ticket` field and every rpc result body are never read.
 * @param {unknown} text
 * @returns {{type: string, sid?: number, streamId?: string, ep?: string, vt?: string}}
 */
export function outboundMetadata(text) {
  const outer = parseObject(typeof text === 'string' ? text : toText(text));
  /** @type {{type: string, sid?: number, streamId?: string, ep?: string, vt?: string}} */
  const meta = { type: outer !== undefined && typeof outer.type === 'string' && SAFE_FRAME_TYPE.test(outer.type) ? outer.type : '?' };
  if (outer === undefined) return meta;
  if (Number.isInteger(outer.sid) && outer.sid >= 0) meta.sid = outer.sid;
  if (meta.type === 'down' && outer.frame !== null && typeof outer.frame === 'object' && !Array.isArray(outer.frame)) {
    // Describe the carried upstream frame too, so `from-upstream` and
    // `to-device` lines line up on type / streamId / vt.
    const inner = frameMetadata(outer.frame);
    meta.type = inner.type;
    if (inner.streamId !== undefined) meta.streamId = inner.streamId;
    if (inner.ep !== undefined) meta.ep = inner.ep;
    if (inner.vt !== undefined) meta.vt = inner.vt;
  }
  return meta;
}

/**
 * Debug-only frame audit recorder. Constructed once per LinkServer when
 * `debug.enabled === true`; see {@link FrameAudit#record} for the write path.
 */
export class FrameAudit {
  /**
   * @param {{
   *   audit: {record: (event: string, fields?: Record<string, unknown>) => void},
   *   enabled?: boolean,
   *   maxRecordsPerDevice?: number,
   * }} options
   */
  constructor({ audit, enabled = true, maxRecordsPerDevice = MAX_RECORDS_PER_DEVICE }) {
    this.audit = audit;
    this.enabled = enabled === true;
    this.maxRecordsPerDevice = Number.isInteger(maxRecordsPerDevice) && maxRecordsPerDevice > 0 ? maxRecordsPerDevice : MAX_RECORDS_PER_DEVICE;
    /** deviceId -> records written (bounded by the cap). */
    this.counts = new Map();
    /** deviceIds whose cap notice has already been written. */
    this.truncated = new Set();
  }

  /** True when this recorder may write (debug on and an audit sink attached). */
  get active() {
    return this.enabled === true && this.audit !== undefined;
  }

  /** Append one `mux.frame` audit line (metadata only) unless the cap is hit. */
  record(direction, deviceId, meta) {
    if (!this.active) return;
    const dir = DIRECTIONS.has(direction) ? direction : 'unknown';
    const key = typeof deviceId === 'string' && deviceId.length > 0 ? deviceId : 'unknown';
    const count = this.counts.get(key) ?? 0;
    if (count >= this.maxRecordsPerDevice) {
      if (!this.truncated.has(key)) {
        this.truncated.add(key);
        this.audit.record('mux.frame.truncated', { deviceId: key, max: this.maxRecordsPerDevice });
      }
      return;
    }
    this.counts.set(key, count + 1);
    this.audit.record('mux.frame', {
      ...(key === 'unknown' ? {} : { deviceId: key }),
      dir,
      ...meta,
    });
  }

  /** Frame received from the phone socket (p1 channel or legacy bridge). */
  fromDevice(deviceId, data, isBinary = false) {
    if (!this.active) return;
    if (isBinary === true) return this.record('from-device', deviceId, { type: 'binary' });
    this.record('from-device', deviceId, frameMetadata(parseObject(toText(data))));
  }

  /** Frame forwarded by the plugin to the upstream (local DSH) mux. */
  toUpstream(deviceId, data, isBinary = false) {
    if (!this.active) return;
    if (isBinary === true) return this.record('to-upstream', deviceId, { type: 'binary' });
    this.record('to-upstream', deviceId, frameMetadata(parseObject(toText(data))));
  }

  /** Frame received from the upstream (local DSH) mux, via UpstreamPeer#onFrame. */
  fromUpstream(deviceId, data, isBinary = false) {
    if (!this.active) return;
    if (isBinary === true) return this.record('from-upstream', deviceId, { type: 'binary' });
    this.record('from-upstream', deviceId, frameMetadata(parseObject(toText(data))));
  }

  /** Frame the plugin queued/wrote to the phone socket (`sent=false` = replay log only). */
  toDevice(deviceId, text, sent) {
    if (!this.active) return;
    this.record('to-device', deviceId, { ...outboundMetadata(text), sent: sent === true });
  }
}
