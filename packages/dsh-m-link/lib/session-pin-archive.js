/**
 * session-pin-archive.js — phone-initiated pin toggle + archive (R3).
 *
 * Why this exists: pinning and archiving are workspace-registry writes the
 * Remote protocol exposes only through the loopback workspaceController; the
 * plugin runs inside the host next to the registry, so it bridges the two
 * device-authenticated routes to ctx.get('workspaceRegistry') directly (same
 * shape as lib/session-permission.js). Host error classes cannot be imported
 * here (dsh-m-link must not depend on host-internal packages), so domain
 * failures are classified by their stable error.name — the names are part of
 * the host's public error contract (see WorkspaceActiveSessionError etc.).
 *
 * Routes (registered in link-server.js, phone side, api bearer token):
 * POST /session/pin {"sessionId":"<id>","pinned":bool}
 * 200 {"ok":true,"pinnedSessionIds":[...]} (newest pin first — host order)
 * 400 pin/bad-request | 400 pin/archived-session | 404 pin/session-not-found
 * 500 pin/failed | 503 pin/host-unavailable
 * POST /session/archive {"sessionId":"<id>","stopActivity":bool}
 * 200 {"ok":true,"archivedSessionIds":[...]}
 * 400 archive/bad-request | 404 archive/session-not-found
 * 409 archive/session-active (+activity: what still runs)
 * 500 archive/failed | 503 archive/host-unavailable
 *
 * Both registry writes are idempotent per the host semantics; the phone does
 * not offer unarchive (that stays on the desktop, decision).
 */

export const SESSION_PIN_PATH = '/session/pin';
export const SESSION_ARCHIVE_PATH = '/session/archive';
export const MAX_SESSION_ID_LENGTH = 200;

const PIN_BAD_REQUEST = {
  status: 400,
  error: 'pin/bad-request',
  message: 'body must be {"sessionId":"<id>","pinned":bool}',
};
const PIN_HOST_UNAVAILABLE = {
  status: 503,
  error: 'pin/host-unavailable',
  message: 'this DSH host does not expose the workspaceRegistry service (isolated or headless host)',
};
const ARCHIVE_BAD_REQUEST = {
  status: 400,
  error: 'archive/bad-request',
  message: 'body must be {"sessionId":"<id>","stopActivity":bool}',
};
const ARCHIVE_HOST_UNAVAILABLE = {
  status: 503,
  error: 'archive/host-unavailable',
  message: 'this DSH host does not expose the workspaceRegistry service (isolated or headless host)',
};

/**
 * Validate the pin route body without touching host services.
 * @returns {{sessionId: string, pinned: boolean} | {status: number, error: string, message: string}}
 */
export function normalizePinRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return { ...PIN_BAD_REQUEST };
  const sessionId = typeof body.sessionId === 'string' ? body.sessionId.trim() : '';
  if (sessionId.length === 0 || sessionId.length > MAX_SESSION_ID_LENGTH) return { ...PIN_BAD_REQUEST };
  if (typeof body.pinned !== 'boolean') return { ...PIN_BAD_REQUEST };
  return { sessionId, pinned: body.pinned };
}

/**
 * Validate the archive route body without touching host services.
 * @returns {{sessionId: string, stopActivity: boolean} | {status: number, error: string, message: string}}
 */
export function normalizeArchiveRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return { ...ARCHIVE_BAD_REQUEST };
  const sessionId = typeof body.sessionId === 'string' ? body.sessionId.trim() : '';
  if (sessionId.length === 0 || sessionId.length > MAX_SESSION_ID_LENGTH) return { ...ARCHIVE_BAD_REQUEST };
  if (body.stopActivity !== undefined && typeof body.stopActivity !== 'boolean') return { ...ARCHIVE_BAD_REQUEST };
  return { sessionId, stopActivity: body.stopActivity === true };
}

/**
 * Resolve the host workspaceRegistry for pin/archive writes: the registry must
 * expose both write methods and both id getters, otherwise the route degrades
 * to 503 (mirrors readHostServices in session-permission.js).
 */
export function readWorkspaceRegistry(ctx) {
  let registry;
  try {
    registry = typeof ctx?.get === 'function' ? ctx.get('workspaceRegistry') : undefined;
  } catch {
    registry = undefined;
  }
  if (registry === undefined || registry === null) return undefined;
  if (typeof registry.pinSession !== 'function' || typeof registry.unpinSession !== 'function') return undefined;
  if (typeof registry.archiveSession !== 'function') return undefined;
  if (!Array.isArray(registry.pinnedSessionIds) || !Array.isArray(registry.archivedSessionIds)) return undefined;
  return registry;
}

/** Map one host registry failure onto the route error shape. */
function classifyRegistryError(error, prefix) {
  if (error !== null && typeof error === 'object') {
    if (error.name === 'WorkspaceUnknownSessionError') {
      return {
        ok: false,
        status: 404,
        error: prefix + '/session-not-found',
        message: 'no live session with this id on the host (it may be archived or belong to another host)',
      };
    }
    if (error.name === 'WorkspaceArchivedSessionPinError') {
      return {
        ok: false,
        status: 400,
        error: prefix + '/archived-session',
        message: String(error.message ?? 'an archived session cannot be pinned'),
      };
    }
    if (error.name === 'WorkspaceActiveSessionError') {
      const result = {
        ok: false,
        status: 409,
        error: prefix + '/session-active',
        message: String(error.message ?? 'the session is running work'),
      };
      if (Array.isArray(error.activity)) result.activity = error.activity;
      return result;
    }
  }
  return { ok: false, status: 500, error: prefix + '/failed', message: String(error?.message ?? error) };
}

/**
 * Pin or unpin one session.
 *
 * @param {{ctx: object, sessionId: string, pinned: boolean}} input
 * @returns {{ok: true, status: 200, pinnedSessionIds: string[]}
 * | {ok: false, status: number, error: string, message?: string, activity?: object[]}}
 */
export function applySessionPin({ ctx, sessionId, pinned }) {
  const registry = readWorkspaceRegistry(ctx);
  if (registry === undefined) return { ok: false, ...PIN_HOST_UNAVAILABLE };
  try {
    if (pinned) registry.pinSession(sessionId);
    else registry.unpinSession(sessionId);
  } catch (error) {
    return classifyRegistryError(error, 'pin');
  }
  return { ok: true, status: 200, pinnedSessionIds: [...registry.pinnedSessionIds] };
}

/**
 * Archive one session, optionally stopping its running work first.
 *
 * @param {{ctx: object, sessionId: string, stopActivity: boolean}} input
 * @returns {{ok: true, status: 200, archivedSessionIds: string[]}
 * | {ok: false, status: number, error: string, message?: string, activity?: object[]}}
 */
export function applySessionArchive({ ctx, sessionId, stopActivity }) {
  const registry = readWorkspaceRegistry(ctx);
  if (registry === undefined) return { ok: false, ...ARCHIVE_HOST_UNAVAILABLE };
  try {
    registry.archiveSession(sessionId, stopActivity === true ? { stopActivity: true } : {});
  } catch (error) {
    return classifyRegistryError(error, 'archive');
  }
  return { ok: true, status: 200, archivedSessionIds: [...registry.archivedSessionIds] };
}
