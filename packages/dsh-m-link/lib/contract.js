/**
 * contract.js — startup self-check for the DSH Remote API contract dsh-m-link
 * depends on (docs/design/remote-protocol.zh.md §1).
 *
 * The M0 spike showed that the plugin's whole usefulness hinges on four
 * undocumented-but-stable behaviours: ctx.connection.authenticatedUrl() returns
 * a URL carrying the process token, GET /connect consumes it with
 * interactions=answer, answers 302, sets an API cookie and points at the mux.
 * If any of those drift after a DSH upgrade the plugin must say so loudly
 * instead of failing per-request.
 */

const PROBE_TIMEOUT_MS = 5000;

/**
 * Run one contract probe.
 * @param {{authenticatedUrl: (baseUrl: string) => string, loopbackOrigin: string, log?: (message: string) => void}} input
 */
export async function probeConnectContract({ authenticatedUrl, loopbackOrigin, log = () => {} }) {
  const startedAt = Date.now();
  const finish = (result) => ({ startedAt, durationMs: Date.now() - startedAt, checkedAt: new Date().toISOString(), ...result });
  try {
    if (typeof authenticatedUrl !== 'function') return finish({ ok: false, error: 'connection.authenticatedUrl is unavailable' });
    const processUrl = new URL(authenticatedUrl(loopbackOrigin));
    const token = processUrl.searchParams.get('token');
    if (token === null || token.length === 0) return finish({ ok: false, error: 'authenticatedUrl() returned no process token' });
    const connectUrl = new URL('/connect', loopbackOrigin);
    connectUrl.searchParams.set('token', token);
    connectUrl.searchParams.set('interactions', 'answer');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
    let response;
    try {
      response = await fetch(connectUrl, { method: 'GET', redirect: 'manual', signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
    if (response.status !== 302) {
      return finish({ ok: false, error: '/connect returned HTTP ' + String(response.status) + ' instead of 302; the DSH Remote contract changed' });
    }
    const setCookie = response.headers.getSetCookie?.()[0] ?? response.headers.get('set-cookie') ?? undefined;
    if (typeof setCookie !== 'string' || setCookie.length === 0) {
      return finish({ ok: false, error: '/connect returned no Set-Cookie; the DSH Remote contract changed' });
    }
    const location = response.headers.get('location');
    if (typeof location !== 'string' || location.length === 0) {
      return finish({ ok: false, error: '/connect returned no Location; the DSH Remote contract changed' });
    }
    const muxPath = new URL(location, loopbackOrigin).pathname;
    if (muxPath !== '/api/remote.mux') {
      return finish({ ok: false, error: 'mux target moved to ' + muxPath + ' (expected /api/remote.mux)' });
    }
    const cookieName = setCookie.split('=', 1)[0];
    log('/connect contract probe OK (cookie ' + cookieName.slice(0, 12) + '…, mux ' + muxPath + ')');
    return finish({ ok: true, status: 302, muxPath, cookieNamePreview: cookieName.slice(0, 16) });
  } catch (error) {
    return finish({ ok: false, error: String(error?.message ?? error) });
  }
}

/**
 * Probe with bounded retries: the official web server may still be listening
 * when the plugin starts, and a single early 502 should not mark the instance
 * incompatible forever.
 */
export async function probeWithRetries({ authenticatedUrl, loopbackOrigin, log, attempts = 10, delayMs = 1500 }) {
  let last;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    last = await probeConnectContract({ authenticatedUrl, loopbackOrigin, log });
    if (last.ok) return last;
    log('/connect contract probe failed (attempt ' + String(attempt) + '/' + String(attempts) + '): ' + String(last.error));
    if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  return last;
}
