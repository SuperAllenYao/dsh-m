/**
 * admin.js — desktop-UI channel for the one-click relay deploy.
 *
 * Registered as its own exact Fetch route (same fence as the M1/M2a admin
 * route: browser cookie auth + owner peer, same-origin):
 *
 * POST /api/dsh-m-link/deploy {"action":"deploy.start", "input":{...}}
 *
 * The deploy engine is separate from LinkServer so the live phone path is never
 * touched by a deploy, and a failing deploy cannot destabilise pairing/mux.
 * The UI polls `deploy.status` for streamed log lines; the SSH password and
 * private key are only ever held in the request body / engine memory and are
 * never echoed back by any action.
 */

import { DeployEngine } from './engine.js';
import { QrRenderer } from '../qr.js';

export const DEPLOY_ADMIN_PATH = '/api/dsh-m-link/deploy';

/**
 * @param {{ctx: object, link: {dataDir: string}, log?: (message: string) => void}} options
 * @returns {{dispose: => void, engine: DeployEngine}}
 */
export function registerDeployRoute({ ctx, link, log = () => {} }) {
  const fetch = ctx.connection?.fetch;
  if (fetch === undefined || typeof fetch.register !== 'function') {
    throw new Error('connection.fetch.register is unavailable in this DSH build');
  }
 // M2b-1 runtime activation: the deploy engine may finish by activating the
 // new relay tunnel in-process (no plugin reload). The headless CLI/e2e has no
 // LinkServer, so these hooks are optional.
  const tunnelActivator =
    typeof link.activateTunnel === 'function'
      ? (activation) => link.activateTunnel(activation)
      : undefined;
  const tunnelStatus = typeof link.tunnelHealth === 'function' ? () => link.tunnelHealth() : () => link.tunnel?.health?.() ?? null;
  const engine = new DeployEngine({ dataDir: link.dataDir, log, tunnelActivator, tunnelStatus });
  let qr;
  let disposed = false;
  const ensureQr = () => {
    if (qr === undefined) qr = new QrRenderer({ log });
    return qr;
  };
 /** Action whitelist — anything else is rejected before touching the engine. */
  const allowed = new Set(['env', 'start', 'status', 'last', 'confirm', 'cancel', 'forgetHost', 'qr', 'tunnel.activate', 'tunnel.status']);
  const disposer = fetch.register({
    path: DEPLOY_ADMIN_PATH,
    methods: ['POST'],
    requestBody: 'buffered',
    fetch: async (request) => {
      const contentType = request.headers.get('content-type') ?? '';
      if (!contentType.toLowerCase().startsWith('application/json')) {
        return Response.json({ ok: false, error: 'admin/bad-content-type' }, { status: 415 });
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return Response.json({ ok: false, error: 'admin/bad-request' }, { status: 400 });
      }
      const action = typeof body?.action === 'string' ? body.action : '';
 // Accept both namespaced ("deploy.start") and short ("start") actions.
      const shortAction = action.startsWith('deploy.') ? action.slice('deploy.'.length) : action;
      if (!allowed.has(shortAction)) {
        return Response.json({ ok: false, error: 'admin/unknown-action', message: action }, { status: 400, headers: { 'cache-control': 'no-store' } });
      }
      try {
        if (shortAction === 'qr') return await handleQr(ensureQr, body);
        if (shortAction === 'tunnel.activate') return await handleTunnelActivate(engine, link, body);
        if (shortAction === 'tunnel.status') {
          return Response.json({ ok: true, data: { tunnel: tunnelStatus(), configuredOrigin: link.config?.tunnel?.controlOrigin ?? null } }, { headers: { 'cache-control': 'no-store' } });
        }
        const result = await engine.handleAction({ ...body, action: shortAction });
        return Response.json(result, { headers: { 'cache-control': 'no-store' } });
      } catch (error) {
        log('deploy action ' + shortAction + ' failed: ' + String(error?.message ?? error));
        return Response.json({ ok: false, error: 'admin/failed', message: String(error?.message ?? error) }, { status: 500, headers: { 'cache-control': 'no-store' } });
      }
    },
  });
  return {
    engine,
    dispose() {
      if (disposed) return;
      disposed = true;
      try {
        engine.dispose();
      } catch {
 /* best effort */
      }
      try {
        qr?.dispose?.();
      } catch {
 /* renderer already gone */
      }
      disposer?.();
    },
  };
}

/**
 * Runtime tunnel activation used by the deploy card (and as a recovery button).
 *
 * The UI button sends an empty body (`deployAdmin("tunnel.activate", {})`), so
 * activation must fall back to the `deploy/tunnel.json` + `tunnel.secret` the
 * last deploy persisted — the same persisted-state path the deploy finalize
 * uses. Calling `link.activateTunnel()` with undefined values instead answers
 * `config/invalid-origin`, which leaves the 「激活连接」 recovery button unable
 * to recover anything.
 * Explicit body values still win; no secret is ever echoed back.
 */
async function handleTunnelActivate(engine, link, body) {
  if (typeof link.activateTunnel !== 'function') {
    return Response.json({ ok: false, error: 'deploy/tunnel-unavailable', message: 'this plugin build has no runtime tunnel API' }, { status: 501, headers: { 'cache-control': 'no-store' } });
  }
  const source = body?.input !== null && typeof body?.input === 'object' ? body.input : body;
  const result = await engine.activatePersistedTunnel(source ?? {});
 // The UI reads `data` as the activation view; keep failures inside it so the
 // card can still render `rolledBack` / the retry button.
  const data = result.ok === true ? result.data : result.data ?? { ok: false, error: result.error, message: result.message };
  return Response.json({ ok: true, data }, { headers: { 'cache-control': 'no-store' } });
}

/** Render the App "server config" QR (macOS CoreImage via lib/qr.js). */
async function handleQr(ensureQr, body) {
  const text = typeof body?.text === 'string' ? body.text.trim() : '';
  if (!text.startsWith('dshm-relay://') || text.length > 512) {
    return Response.json({ ok: false, error: 'qr/bad-payload' }, { status: 400, headers: { 'cache-control': 'no-store' } });
  }
  const rendered = await ensureQr().renderDataUrl(text);
  return Response.json(
    rendered.ok === true ? { ok: true, data: { dataUrl: rendered.dataUrl, text } } : { ok: false, error: 'qr/unavailable', message: rendered.error },
    { headers: { 'cache-control': 'no-store' } },
  );
}
