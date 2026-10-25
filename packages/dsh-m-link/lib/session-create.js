/**
 * session-create.js — phone-initiated "new session" for one workspace (R2).
 *
 * Why this exists: the workspace list on the phone has a per-group "+", but
 * minting a session must run inside the host (default agent preset, workspace
 * attachment, registry bookkeeping) — the Remote protocol's `session/create`
 * loopback call already encodes all of that, so this route bridges one
 * device-authenticated call to it (same shape as lib/session-permission.js:
 * validate, resolve host services through ctx.get, never touch mux frames).
 *
 * Route (registered in link-server.js, phone side, api bearer token):
 * POST /session/create {"workspaceId":"<id>"}
 * 200 {"ok":true,"sessionId":"<id>","reused":bool}
 * 400 session-create/bad-request | 404 session-create/workspace-not-found
 * 502 session-create/failed (+hostCode from the host) | 503 session-create/host-unavailable
 *
 * Blank-reuse rule (approved, design §2.1): before minting, the
 * loopback session/list (lite rows) is scanned for a phone-visible blank session
 * in the same workspace (`blank === true && cwd === workspace.path`, not
 * archived, not a subagent child); the newest updatedAt wins and is returned
 * with `reused:true` so the host writes nothing. A list/transport failure
 * degrades to "no reusable blank" — creating must never be blocked by the
 * reuse optimization.
 */

import { LIST_LITE_HEADER } from './list-lite.js';

export const SESSION_CREATE_PATH = '/session/create';
export const MAX_WORKSPACE_ID_LENGTH = 200;

const BAD_REQUEST = {
  status: 400,
  error: 'session-create/bad-request',
  message: 'body must be {"workspaceId":"<id>"}',
};
const HOST_UNAVAILABLE = {
  status: 503,
  error: 'session-create/host-unavailable',
  message: 'this DSH host does not expose the workspaceRegistry service (isolated or headless host)',
};

/**
 * Validate the route body without touching host services.
 * @returns {{workspaceId: string} | {status: number, error: string, message: string}}
 */
export function normalizeCreateRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return { ...BAD_REQUEST };
  const workspaceId = typeof body.workspaceId === 'string' ? body.workspaceId.trim() : '';
  if (workspaceId.length === 0 || workspaceId.length > MAX_WORKSPACE_ID_LENGTH) return { ...BAD_REQUEST };
  return { workspaceId };
}

/**
 * Resolve the host workspaceRegistry. Missing/incomplete service degrades to
 * 503 instead of throwing (same contract as readHostServices in
 * session-permission.js).
 */
export function readWorkspaceRegistry(ctx) {
  let registry;
  try {
    registry = typeof ctx?.get === 'function' ? ctx.get('workspaceRegistry') : undefined;
  } catch {
    registry = undefined;
  }
  if (registry === undefined || registry === null || typeof registry.get !== 'function') return undefined;
  return registry;
}

/**
 * Pick the reusable blank session for one workspace path.
 *
 * @param {{items?: Array<object|null>} | undefined} listResult parsed session/list value
 * @param {string} workspacePath exact cwd to match
 * @param {string[] | undefined} archivedSessionIds registry archive set
 * @returns {string | undefined} newest matching blank sessionId, or undefined
 */
export function selectReusableBlankSession(listResult, workspacePath, archivedSessionIds) {
  if (listResult === null || typeof listResult !== 'object' || !Array.isArray(listResult.items)) return undefined;
  const archived = new Set(Array.isArray(archivedSessionIds) ? archivedSessionIds : []);
  let best;
  for (const item of listResult.items) {
    if (item === null || typeof item !== 'object') continue;
    if (item.blank !== true) continue;
    if (item.cwd !== workspacePath) continue;
    if (typeof item.sessionId !== 'string' || item.sessionId.length === 0) continue;
    if (archived.has(item.sessionId)) continue;
    if (item.origin === 'subagent' || typeof item.parentSessionId === 'string') continue;
    if (typeof item.updatedAt !== 'number') continue;
    if (best === undefined || item.updatedAt > best.updatedAt) best = item;
  }
  return best === undefined ? undefined : best.sessionId;
}

/** One loopback RPC failure with the smallest stable classification. */
export class LoopbackError extends Error {
  constructor(kind, detail) {
    super('loopback ' + kind + (detail === undefined ? '' : ': ' + String(detail)));
    this.name = 'LoopbackError';
    this.kind = kind;
    this.detail = detail;
  }
}

function isLoopbackValue(parsed) {
  return parsed !== null && typeof parsed === 'object' && typeof parsed.result === 'object' && parsed.result !== null;
}

/**
 * Call one loopback Remote method with the device peer cookie
 * (client-request envelope, same as fetchSessionListForWatcher).
 *
 * A 401/403 drops the stale cookie, reconnects the peer once and retries the
 * call — the watcher polls so it can defer this to the next tick, a unary
 * route must recover within the request.
 *
 * @param {{origin: string, peer: object, method: string, args?: object,
 * timeoutMs: number, fetchImpl?: typeof fetch, rpcId?: string,
 * headers?: Record<string, string>}} input
 * @returns {Promise<object>} the ok result value
 */
export async function loopbackCall({ origin, peer, method, args = {}, timeoutMs, fetchImpl, rpcId, headers }) {
  const fetchFn = fetchImpl ?? globalThis.fetch;
  const call = async () => {
    const response = await fetchFn(origin + '/api/' + method, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        cookie: peer.cookie.name + '=' + peer.cookie.value,
        ...headers,
      },
      body: JSON.stringify({
        type: 'client-request',
        rpcId: rpcId ?? 'session-action-' + method + '-' + Math.random().toString(36).slice(2),
        method,
        payload: { args },
      }),
      redirect: 'manual',
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (response.status === 401 || response.status === 403) return { unauthorized: true, status: response.status };
    if (!response.ok) throw new LoopbackError('http-' + response.status);
    let parsed;
    try {
      parsed = JSON.parse(Buffer.from(await response.arrayBuffer()).toString('utf8'));
    } catch {
      throw new LoopbackError('bad-json');
    }
    if (!isLoopbackValue(parsed) || parsed.result.ok !== true) {
      const code = isLoopbackValue(parsed) && typeof parsed.result?.error === 'object' ? parsed.result.error.code : undefined;
      throw new LoopbackError('rpc', code);
    }
    return { value: parsed.result.value };
  };
  if (peer.cookie === undefined) await peer.connect('answer');
  let outcome = await call();
  if (outcome.unauthorized === true) {
 // Stale cookie (host restarted / peer disposed): reconnect once, retry once.
    peer.cookie = undefined;
    await peer.connect('answer');
    outcome = await call();
    if (outcome.unauthorized === true) {
      peer.cookie = undefined;
      throw new LoopbackError('unauthorized-' + outcome.status);
    }
  }
  return outcome.value;
}

/**
 * Create (or reuse) one session for a workspace.
 *
 * @param {{ctx: object, peer: object, workspaceId: string, loopbackOrigin: string,
 * requestTimeoutMs: number, fetchImpl?: typeof fetch}} input
 * @returns {Promise<{ok: true, status: 200, sessionId: string, reused: boolean}
 * | {ok: false, status: number, error: string, message?: string, hostCode?: string}>}
 */
export async function applySessionCreate({ ctx, peer, workspaceId, loopbackOrigin, requestTimeoutMs, fetchImpl }) {
  const registry = readWorkspaceRegistry(ctx);
  if (registry === undefined) return { ok: false, ...HOST_UNAVAILABLE };

  const workspace = registry.get(workspaceId);
  if (workspace === undefined || workspace === null) {
    return {
      ok: false,
      status: 404,
      error: 'session-create/workspace-not-found',
      message: 'no workspace with this id on the host (it may have been removed)',
    };
  }
  const workspacePath = workspace.path;

 // Reuse scan. Any failure here only skips reuse — it never blocks creation.
  if (typeof workspacePath === 'string' && workspacePath.length > 0) {
    try {
      const listValue = await loopbackCall({
        origin: loopbackOrigin,
        peer,
        method: 'session/list',
 // Same lite opt-in the watcher uses: small rows, all fields this scan
 // reads (sessionId/cwd/updatedAt/blank/origin/parentSessionId) survive
 // the trim. An older host ignores the header — harmless, just bigger.
        headers: { [LIST_LITE_HEADER]: '1' },
        timeoutMs: requestTimeoutMs,
        fetchImpl,
      });
      const reusable = selectReusableBlankSession(listValue, workspacePath, registry.archivedSessionIds);
      if (reusable !== undefined) {
        return { ok: true, status: 200, sessionId: reusable, reused: true };
      }
    } catch {
 // Fall through to minting: the host stays the single source of truth.
    }
  }

  try {
    const created = await loopbackCall({
      origin: loopbackOrigin,
      peer,
      method: 'session/create',
      args: { workspaceId },
      timeoutMs: requestTimeoutMs,
      fetchImpl,
    });
    if (created === null || typeof created !== 'object' || typeof created.sessionId !== 'string' || created.sessionId.length === 0) {
      return { ok: false, status: 502, error: 'session-create/failed', message: 'host session/create returned no sessionId' };
    }
    return { ok: true, status: 200, sessionId: created.sessionId, reused: false };
  } catch (error) {
    if (error instanceof LoopbackError && error.kind === 'rpc') {
      if (error.detail === 'workspace/not-found') {
        return {
          ok: false,
          status: 404,
          error: 'session-create/workspace-not-found',
          message: 'the workspace disappeared between the check and the create',
        };
      }
      return {
        ok: false,
        status: 502,
        error: 'session-create/failed',
        message: 'host session/create failed',
        hostCode: error.detail,
      };
    }
    return {
      ok: false,
      status: 502,
      error: 'session-create/failed',
      message: String(error?.message ?? error),
    };
  }
}
