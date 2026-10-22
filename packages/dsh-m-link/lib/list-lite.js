/**
 * list-lite.js — P1.5-A: opt-in "lite" projection for `session/list`.
 *
 * Why: on a busy host every `session/list` row carries the complete projection
 * block (turnOutline / todos / subagentCatalog / tokenUsage / …), which pushes
 * one response to ~1 MB and costs 1.5–2.2 s on the phone to decode/apply. The
 * list UI only renders a small subset; the rest is detail state that already
 * arrives through `session/follow`.
 *
 * Contract (opt-in, per request — old clients are untouched):
 * - Request signal, either:
 * * transport header `x-dshm-list-lite: 1` (legacy HTTPS unary and the
 * P1 `rpc` frame `headers` object), or
 * * body hint `payload.args._request.listMode === "lite"` (the current
 * iOS App path while `Net/` is frozen; the plugin strips the hint
 * before forwarding so the upstream DSH request is byte-identical).
 * - Response: rows are reduced to {@link LITE_ITEM_FIELDS} plus the tiny
 * projection subset in {@link LITE_PROJECTION_FIELDS}. Everything else is
 * dropped from the row. The envelope (`type`/`rpcId`/`result`) is kept.
 * - No request signal: {@link trimSessionListResponse} is never called and
 * the response bytes stay exactly the upstream bytes (legacy path).
 *
 * Pure functions only (no I/O, no config) so the contract is unit-testable
 * without a TLS listener: see `test/p1-lite-list.mjs`.
 */

/** Request header carrying the opt-in (any case; `1` / `true` / `yes`). */
export const LIST_LITE_HEADER = 'x-dshm-list-lite';

/** Body-hint key/value consumed from `payload.args._request` and stripped. */
export const LIST_LITE_BODY_HINT_KEY = 'listMode';
export const LIST_LITE_BODY_HINT_VALUE = 'lite';

/** Canonical method name (the legacy path prefixes it with `/api/`). */
export const SESSION_LIST_ENDPOINT = 'session/list';

/**
 * Row fields the list UI actually reads (iOS `SessionListItem` decoding +
 * grouping/opening path). Keep this in sync with
 * `apps/ios/DSHm/Protocol/RemoteModels.swift` and
 * `apps/ios/DSHm/Workspaces/WorkspaceViewModel.swift`.
 */
export const LITE_ITEM_FIELDS = Object.freeze([
  'sessionId',
  'updatedAt',
  'agentAvailable',
  'formatStatus',
  'running',
  'blank',
  'cwd',
  'origin',
  'parentSessionId',
]);

/**
 * Projections kept in the lite row.
 * - `title` list card title (`ProjectionValues.title`)
 * - `sessionListMetadata` list time/blank metadata
 * - `userQuestions` `active` only: list status + detail answer loop
 * - `contextPressure` small: detail context cell refresh (seeded by
 * `session/follow`, refreshed from the throttled list
 * read; dropping it would freeze the gauge)
 */
export const LITE_PROJECTION_FIELDS = Object.freeze([
  'title',
  'sessionListMetadata',
  'userQuestions',
  'contextPressure',
]);

/** Sub-field whitelist for projections that carry heavy sibling payloads. */
const LITE_PROJECTION_SUBFIELDS = Object.freeze({
  sessionListMetadata: Object.freeze(['lastPromptAt', 'blank']),
  userQuestions: Object.freeze(['active']),
});

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

/** True for both `/api/session/list` (legacy path) and `session/list` (P1). */
export function isSessionListEndpoint(endpoint) {
  if (typeof endpoint !== 'string' || endpoint.length === 0) return false;
  const path = endpoint.startsWith('/api/') ? endpoint.slice('/api/'.length) : endpoint.replace(/^\//, '');
  return path === SESSION_LIST_ENDPOINT;
}

/**
 * True when a header bag carries the opt-in. Header names are compared
 * case-insensitively because P1 `rpc.headers` come straight from the client
 * frame while Node lower-cases legacy HTTP headers.
 */
export function hasListLiteHeader(headers) {
  if (!isPlainObject(headers)) return false;
  for (const [name, raw] of Object.entries(headers)) {
    if (String(name).toLowerCase() !== LIST_LITE_HEADER) continue;
    const values = Array.isArray(raw) ? raw : [raw];
    for (const value of values) {
      const text = String(value ?? '').trim().toLowerCase();
      if (text === '1' || text === 'true' || text === 'yes') return true;
    }
  }
  return false;
}

/**
 * Inspect one request for the lite opt-in.
 *
 * @param {{endpoint?: string, headers?: Record<string, unknown>, bodyText?: string}} request
 * @returns {{lite: false} | {lite: true, source: 'header'|'body', bodyText?: string}}
 * `bodyText` is only set for the body-hint source: the exact request body to
 * forward upstream (hint removed). A body-hint request must still be a valid
 * `client-request` envelope for `session/list`, otherwise it is ignored.
 */
export function detectListLiteRequest({ endpoint, headers, bodyText } = {}) {
  if (!isSessionListEndpoint(endpoint)) return { lite: false };
  if (hasListLiteHeader(headers)) return { lite: true, source: 'header' };
  if (typeof bodyText !== 'string' || bodyText.length === 0) return { lite: false };
  let envelope;
  try {
    envelope = JSON.parse(bodyText);
  } catch {
    return { lite: false };
  }
  if (!isPlainObject(envelope) || envelope.type !== 'client-request') return { lite: false };
  if (envelope.method !== SESSION_LIST_ENDPOINT) return { lite: false };
  const args = envelope.payload?.args;
  if (!isPlainObject(args) || !isPlainObject(args._request)) return { lite: false };
  if (args._request[LIST_LITE_BODY_HINT_KEY] !== LIST_LITE_BODY_HINT_VALUE) return { lite: false };
 // Forward the legacy-shaped request upstream: the hint is link-layer only.
  const strippedArgs = { ...args, _request: { ...args._request } };
  delete strippedArgs._request[LIST_LITE_BODY_HINT_KEY];
  const stripped = { ...envelope, payload: { ...envelope.payload, args: strippedArgs } };
  return { lite: true, source: 'body', bodyText: JSON.stringify(stripped) };
}

/** Copy the lite projection subset out of one `projections` object. */
export function trimProjections(projections) {
  if (!isPlainObject(projections)) return projections;
  const out = {};
  for (const key of ['kind', 'asOfSeq']) {
    if (hasOwn(projections, key)) out[key] = projections[key];
  }
  const values = isPlainObject(projections.values) ? projections.values : undefined;
  if (values !== undefined) {
    const liteValues = {};
    for (const key of LITE_PROJECTION_FIELDS) {
      if (!hasOwn(values, key)) continue;
      const subFields = LITE_PROJECTION_SUBFIELDS[key];
      if (subFields === undefined) {
        liteValues[key] = values[key];
        continue;
      }
 // Malformed sub-projection: drop it rather than inventing a shape.
      if (!isPlainObject(values[key])) continue;
      const kept = {};
      for (const sub of subFields) {
        if (hasOwn(values[key], sub)) kept[sub] = values[key][sub];
      }
      liteValues[key] = kept;
    }
    out.values = liteValues;
  }
  return out;
}

/** Reduce one `session/list` row to the lite whitelist. */
export function trimSessionListItem(item) {
  if (!isPlainObject(item)) return item;
  const out = {};
  for (const field of LITE_ITEM_FIELDS) {
    if (hasOwn(item, field)) out[field] = item[field];
  }
  if (hasOwn(item, 'projections')) out.projections = trimProjections(item.projections);
  return out;
}

/**
 * Trim a full `session/list` HTTP/P1 response body.
 *
 * @param {Buffer|string} fullBytes upstream response bytes
 * @returns {{bytes: Buffer, stats: {items: number, fullBytes: number, liteBytes: number, savedBytes: number, savedRatio: number}} | undefined}
 * `undefined` when the body is not a successful `session/list` envelope; the
 * caller must then pass the original bytes through untouched.
 */
export function trimSessionListResponse(fullBytes) {
  if (fullBytes === undefined || fullBytes === null) return undefined;
  const text = Buffer.isBuffer(fullBytes) ? fullBytes.toString('utf8') : String(fullBytes);
  let envelope;
  try {
    envelope = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (!isPlainObject(envelope)) return undefined;
  if (envelope.type !== 'server-response') return undefined;
  const result = envelope.result;
  if (!isPlainObject(result) || result.ok !== true) return undefined;
  const value = result.value;
  if (!isPlainObject(value) || !Array.isArray(value.items)) return undefined;
  const items = value.items.map(trimSessionListItem);
  const trimmed = { ...envelope, result: { ...result, value: { ...value, items } } };
  const bytes = Buffer.from(JSON.stringify(trimmed), 'utf8');
  const fullSize = Buffer.isBuffer(fullBytes) ? fullBytes.length : Buffer.byteLength(text);
  return {
    bytes,
    stats: {
      items: items.length,
      fullBytes: fullSize,
      liteBytes: bytes.length,
      savedBytes: Math.max(0, fullSize - bytes.length),
      savedRatio: fullSize === 0 ? 0 : Math.round((1 - bytes.length / fullSize) * 10000) / 10000,
    },
  };
}
