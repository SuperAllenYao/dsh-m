/**
 * session-endpoint.js — phone-side session content endpoint vs. host endpoint.
 *
 * Why this exists: the desktop host deprecates `session/page` in favour of
 * `session/events` (same signature, same reply shape). The phone keeps calling
 * `session/page`, so the plugin maps the name only on the host-facing leg. The
 * host rejects a body whose `method` differs from the URL path, so renaming
 * also requires rewriting the client-request body; and the reply has to be
 * interpreted before deciding whether a missing endpoint warrants a fallback.
 *
 * This module is the pure half of that adaptation: no state, no I/O, no
 * dependencies. The forwarding paths own the capability state and the retry;
 * they call these functions so both paths (P1 and HTTP unary) agree on the
 * mapping, the rewrite and the reply meaning.
 */

/** Phone-side logical name — unchanged, so the phone needs no update. */
export const SESSION_CONTENT_ENDPOINT = 'session/page';

/** Host-side name for the same call on desktop 0.2.2+. */
export const SESSION_CONTENT_HOST_ENDPOINT = 'session/events';

/** Fixed host error code for "no active Remote method exports this endpoint". */
export const ENDPOINT_MISSING_CODE = 'gateway/invocation-unavailable';

const NOT_A_CLIENT_REQUEST = 'session-endpoint: body is not a client-request';
const INVALID_ENVELOPE = 'invalid-envelope';

/**
 * True only for the phone-side session content endpoint. Every other endpoint
 * (session/list, session/create, …) is forwarded untouched.
 * @param {string} endpoint
 * @returns {boolean}
 */
export function isMappedEndpoint(endpoint) {
  return endpoint === SESSION_CONTENT_ENDPOINT;
}

/**
 * Method to send to the host. Unmapped endpoints pass through; the mapped one
 * uses the legacy name only when the host is known to lack the new endpoint
 * (`supportsSessionEvents === false`). `undefined` means "not decided yet":
 * try the new endpoint first and fall back on ENDPOINT_MISSING_CODE.
 * @param {string} endpoint
 * @param {boolean | undefined} supportsSessionEvents
 * @returns {string}
 */
export function upstreamEndpointFor(endpoint, supportsSessionEvents) {
  if (!isMappedEndpoint(endpoint)) return endpoint;
  return supportsSessionEvents === false ? SESSION_CONTENT_ENDPOINT : SESSION_CONTENT_HOST_ENDPOINT;
}

/**
 * Rewrite the `method` of a client-request envelope taken from the phone, so
 * the body matches the upstream path. Only `method` changes; `rpcId`, `payload`
 * and every other field survive the JSON round trip.
 * @param {string} bodyText
 * @param {string} method
 * @returns {string}
 */
export function rewriteRequestMethod(bodyText, method) {
  let envelope;
  try {
    envelope = JSON.parse(bodyText);
  } catch {
    throw new Error(NOT_A_CLIENT_REQUEST);
  }
  if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) {
    throw new Error(NOT_A_CLIENT_REQUEST);
  }
  if (envelope.type !== 'client-request') throw new Error(NOT_A_CLIENT_REQUEST);
  envelope.method = method;
  return JSON.stringify(envelope);
}

/**
 * Decode a reply body. Returns null for values the caller cannot have sent
 * (the outcome parser treats that like an unreadable envelope).
 * @param {string | Uint8Array} body
 * @returns {string | null}
 */
function decodeBody(body) {
  if (typeof body === 'string') return body;
  if (body instanceof Uint8Array) return Buffer.from(body).toString('utf8');
  return null;
}

/**
 * Meaning of a host reply: `ok`, a host error code, `http/<status>` for a
 * non-200 status, or INVALID_ENVELOPE when the body cannot be interpreted.
 * @param {number} status
 * @param {string | Uint8Array} bodyBytesOrText
 * @returns {string}
 */
export function outcomeOfBody(status, bodyBytesOrText) {
  if (status !== 200) return 'http/' + status;
  const text = decodeBody(bodyBytesOrText);
  if (text === null) return INVALID_ENVELOPE;
  let envelope;
  try {
    envelope = JSON.parse(text);
  } catch {
    return INVALID_ENVELOPE;
  }
  if (envelope === null || typeof envelope !== 'object' || Array.isArray(envelope)) return INVALID_ENVELOPE;
  if (envelope.type !== 'server-response') return INVALID_ENVELOPE;
  const result = envelope.result;
  if (result === null || typeof result !== 'object' || Array.isArray(result)) return INVALID_ENVELOPE;
  if (result.ok === true) return 'ok';
  const error = result.error;
  if (result.ok === false && error !== null && typeof error === 'object' && typeof error.code === 'string') {
    return error.code;
  }
  return INVALID_ENVELOPE;
}

/**
 * True when the outcome says the host does not expose the upstream endpoint —
 * the only signal that justifies falling back to the legacy name.
 * @param {string} outcome
 * @returns {boolean}
 */
export function isEndpointMissing(outcome) {
  return outcome === ENDPOINT_MISSING_CODE;
}

/**
 * True when a full reply (status + body) says the host does not expose the
 * upstream endpoint. Two host generations say it differently:
 *
 *  - desktop 0.2.2+ answers HTTP 200 with the `gateway/invocation-unavailable`
 *    error code (what `isEndpointMissing` recognizes);
 *  - desktop 0.2.1 and older have no route for the new path at all, so their
 *    HTTP layer answers `404` with a plain-text body (`not found`). That is a
 *    routing miss, not a business error: `outcomeOfBody` only keeps the status
 *    for a non-200 reply, so the body is the only discriminator left.
 *
 * A 404 whose body is a JSON envelope is a business error (unknown session…)
 * and must stay untouched, as must 401/403, 5xx, timeouts and unreadable
 * envelopes — none of those prove the endpoint is absent.
 * @param {string} outcome
 * @param {number} status
 * @param {string | Uint8Array} bodyBytesOrText
 * @returns {boolean}
 */
export function isEndpointMissingOutcome(outcome, status, bodyBytesOrText) {
  if (isEndpointMissing(outcome)) return true;
  if (status !== 404) return false;
  const text = decodeBody(bodyBytesOrText);
  if (text === null) return false;
  const trimmed = text.trim();
  // An empty body is not the legacy router's plain-text reply; keep it out of
  // the fallback rule so the predicate stays tied to the observed shape.
  if (trimmed.length === 0) return false;
  try {
    JSON.parse(trimmed);
    return false;
  } catch {
    return true;
  }
}
