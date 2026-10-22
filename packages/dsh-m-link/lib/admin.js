/**
 * admin.js — authenticated desktop-UI channel for dsh-m-link.
 *
 * The DSH web client (also used by the desktop app) talks to the host plugin
 * through an exact Fetch route on the official web server:
 *
 * POST /api/dsh-m-link/admin {"action":"status"} (browser cookie auth)
 *
 * Registration uses ctx.connection.fetch.register(), the documented extension
 * point used by built-in plugins (e.g. session-log-export). The connection
 * service applies the Host/Origin fence, browser authentication and an
 * owner-principal check before the handler runs; no token is handled here.
 *
 * Actions: status, pairing, pairing.refresh, devices.list, devices.revoke,
 * devices.revokeAll, certs.info, certs.rotateLeaf, certs.rotateCa,
 * audit.tail, apns.info, apns.test.
 */

export const ADMIN_PATH = '/api/dsh-m-link/admin';

/**
 * Register the admin Fetch route for the lifetime of the plugin.
 * @param {{ctx: object, server: import('./link-server.js').LinkServer, log?: (message: string) => void}} options
 * @returns {() => void} disposer
 */
export function registerAdminRoute({ ctx, server, log = () => {} }) {
  const fetch = ctx.connection?.fetch;
  if (fetch === undefined || typeof fetch.register !== 'function') {
    throw new Error('connection.fetch.register is unavailable in this DSH build');
  }
  return fetch.register({
    path: ADMIN_PATH,
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
      try {
        const result = await server.handleAdminAction(body);
        return Response.json(result, { headers: { 'cache-control': 'no-store' } });
      } catch (error) {
        log('admin action ' + String(body?.action) + ' failed: ' + String(error?.message ?? error));
        return Response.json({ ok: false, error: 'admin/failed', message: String(error?.message ?? error) }, { status: 500 });
      }
    },
  });
}
