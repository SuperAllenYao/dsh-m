/**
 * session-permission.js — phone-initiated session permission switching (M5).
 *
 * Why this exists: the DSH Remote protocol exposes `permissionPresets/catalog`
 * (read-only) but no write endpoint — `permissionPresets.set(session, name)` is
 * a host service method. The plugin runs inside the host, so it can bridge one
 * device-authenticated HTTP call to that service without parsing or rewriting
 * any mux frame (the transparent bridge stays transparent).
 *
 * Route (registered in link-server.js, phone side, api bearer token):
 * POST /session/permission {"sessionId":"<id>","preset":"<catalog value>"}
 * 200 {"ok":true,"sessionId","preset","previous","catalog":{options,defaultPreset}}
 * 400 permission/bad-request | 404 permission/session-not-found
 * 409 permission/preset-unavailable (preset not in the live catalog)
 * 500 permission/failed | 503 permission/host-unavailable
 *
 * The write itself is delegated to `permissionPresets.set`, which writes the
 * regular session events (`permission/preset`, `approval/policy`,
 * `sandbox/mode`); every connected client (desktop + phone follow stream) sees
 * the change through the normal event pipeline.
 */

export const SESSION_PERMISSION_PATH = '/session/permission';
export const MAX_SESSION_ID_LENGTH = 200;
export const MAX_PRESET_LENGTH = 64;

const BAD_REQUEST = {
  status: 400,
  error: 'permission/bad-request',
  message: 'body must be {"sessionId":"<id>","preset":"<catalog value>"}',
};
const HOST_UNAVAILABLE = {
  status: 503,
  error: 'permission/host-unavailable',
  message: 'this DSH host does not expose the sessions/permissionPresets services (isolated or headless host)',
};

/**
 * Validate the route body without touching host services.
 * @returns {{sessionId: string, preset: string} | {status: number, error: string, message: string}}
 */
export function normalizePermissionRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return { ...BAD_REQUEST };
  const sessionId = typeof body.sessionId === 'string' ? body.sessionId.trim() : '';
  const preset = typeof body.preset === 'string' ? body.preset.trim() : '';
  if (sessionId.length === 0 || sessionId.length > MAX_SESSION_ID_LENGTH) return { ...BAD_REQUEST };
  if (preset.length === 0 || preset.length > MAX_PRESET_LENGTH) return { ...BAD_REQUEST };
  return { sessionId, preset };
}

/**
 * Project the host PermissionCatalog onto the short wire shape the phone needs.
 * Unknown/extra fields are dropped; a missing description stays missing.
 */
export function catalogView(catalog) {
  const options = [];
  if (Array.isArray(catalog?.options)) {
    for (const option of catalog.options) {
      if (option === null || typeof option !== 'object') continue;
      if (typeof option.value !== 'string' || option.value.length === 0) continue;
      const view = { value: option.value, name: typeof option.name === 'string' && option.name.length > 0 ? option.name : option.value };
      if (typeof option.description === 'string' && option.description.length > 0) view.description = option.description;
      options.push(view);
    }
  }
  const view = { options };
  if (typeof catalog?.defaultPreset === 'string') view.defaultPreset = catalog.defaultPreset;
  return view;
}

/**
 * Resolve the two host services this route needs. `ctx.get` is the optional
 * access expression the inspect provider reports for both services, so a host
 * without them degrades to 503 instead of throwing.
 */
export function readHostServices(ctx) {
  let sessions;
  let permissionPresets;
  try {
    sessions = typeof ctx?.get === 'function' ? ctx.get('sessions') : undefined;
  } catch {
    sessions = undefined;
  }
  try {
    permissionPresets = typeof ctx?.get === 'function' ? ctx.get('permissionPresets') : undefined;
  } catch {
    permissionPresets = undefined;
  }
  if (sessions === undefined || sessions === null || typeof sessions.get !== 'function') return undefined;
  if (
    permissionPresets === undefined ||
    permissionPresets === null ||
    typeof permissionPresets.set !== 'function' ||
    typeof permissionPresets.catalog !== 'function'
  ) {
    return undefined;
  }
  return { sessions, permissionPresets };
}

/**
 * Apply one permission switch against the live host services.
 *
 * @param {{ctx: object, sessionId: string, preset: string}} input
 * @returns {{ok: true, status: 200, sessionId: string, preset: string, previous?: string, catalog: object}
 * | {ok: false, status: number, error: string, message?: string, catalog?: object}}
 */
export function applySessionPermission({ ctx, sessionId, preset }) {
  const services = readHostServices(ctx);
  if (services === undefined) return { ok: false, ...HOST_UNAVAILABLE };

  const session = services.sessions.get(sessionId);
  if (session === undefined || session === null) {
    return {
      ok: false,
      status: 404,
      error: 'permission/session-not-found',
      message: 'no live session with this id on the host (it may be archived or belong to another host)',
    };
  }

  let catalog;
  try {
    catalog = services.permissionPresets.catalog();
  } catch (error) {
    return { ok: false, status: 500, error: 'permission/failed', message: String(error?.message ?? error) };
  }
  const view = catalogView(catalog);
  if (!view.options.some((option) => option.value === preset)) {
    return {
      ok: false,
      status: 409,
      error: 'permission/preset-unavailable',
      message: 'the preset is not in the host catalog (the deployment may have changed)',
      catalog: view,
    };
  }

  let previous;
  try {
    if (typeof services.permissionPresets.current === 'function') previous = services.permissionPresets.current(session);
  } catch {
    previous = undefined;
  }

  try {
    services.permissionPresets.set(session, preset);
  } catch (error) {
    return { ok: false, status: 500, error: 'permission/failed', message: String(error?.message ?? error) };
  }

  const result = { ok: true, status: 200, sessionId, preset, catalog: view };
  if (typeof previous === 'string' && previous.length > 0) result.previous = previous;
  return result;
}
