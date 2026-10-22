/**
 * m2-reload-handoff.mjs — plugin-reload port hand-off + teardown completeness.
 *
 * Incident covered (2026-10-22): a desktop profile write (switching the model
 * persists the default model) hot-reloads the patch layer. The previous plugin
 * fiber keeps the TLS port bound — its accepted phone sockets are still open and
 * its dispose is not guaranteed to run before the new fiber starts — so the new
 * instance exhausted its EADDRINUSE retries, recorded
 * `server.startup-failed/host/port-in-use`, and the phone was left talking to a
 * dead fiber that answers `host/inactive` until the desktop was restarted.
 *
 * Checks:
 *   1. a second LinkServer on the same port reclaims the port from the previous
 *      instance of this process (it is disposed), binds and serves /health;
 *   2. dispose() releases the listener even when a teardown step throws
 *      (the finally path), so the next instance can always bind;
 *   3. a port held by a foreign process still reports host/port-in-use.
 *
 * Runs standalone (no DSH host, no ~/.dsh, no external network):
 *   node test/m2-reload-handoff.mjs
 */

import { createServer as createTcpServer } from 'node:net';
import { request as httpsRequest, Agent as HttpsAgent } from 'node:https';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { LinkServer } from '../lib/link-server.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const checks = [];
const startedAt = Date.now();

function record(name, ok, detail) {
  checks.push({ name, ok, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' — ' + JSON.stringify(detail)));
  if (!ok) throw new Error('check failed: ' + name);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function liveCtx(homeDir) {
  const state = { active: true };
  const ctx = {
    state,
    get(key) {
      if (key === 'dshHomePath') return () => homeDir;
      return undefined;
    },
    on() {},
    effect() {
      return () => {};
    },
  };
  Object.defineProperty(ctx, 'webServer', {
    get() {
      return { getOrigin: () => 'http://127.0.0.1:9', protocol: 'http:' };
    },
  });
  Object.defineProperty(ctx, 'connection', {
    get() {
      return { authenticatedUrl: (baseUrl) => baseUrl };
    },
  });
  return ctx;
}

function freePort() {
  return new Promise((resolvePromise, reject) => {
    const server = createTcpServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(() => resolvePromise(port));
    });
  });
}

function httpsGetJson(port, path, agent) {
  return new Promise((resolvePromise, reject) => {
    const request = httpsRequest(
      { hostname: '127.0.0.1', port, path, method: 'GET', headers: { accept: 'application/json' }, rejectUnauthorized: false, agent },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolvePromise({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      }
    );
    request.on('error', reject);
    request.end();
  });
}

/** True when `port` on 127.0.0.1 can be bound right now. */
function portIsBindable(port) {
  return new Promise((resolvePromise) => {
    const server = createTcpServer();
    server.once('error', () => resolvePromise(false));
    server.listen(port, '127.0.0.1', () => {
      server.close(() => resolvePromise(true));
    });
  });
}

function makeServer(homeDir, port) {
  return new LinkServer(liveCtx(homeDir), {
    port,
    bindHost: '127.0.0.1',
    contract: { probeOnStart: false },
    bonjour: { enabled: false },
    debug: { enabled: false },
  });
}

async function run() {
  mkdirSync(OUT_DIR, { recursive: true });
  const cleanup = [];

  // ------------------------------------------------- 1. reload port hand-off
  {
    const home = mkdtempSync(join(tmpdir(), 'dshm-reload-home-'));
    const port = await freePort();
    const first = makeServer(home, port);
    const agent = new HttpsAgent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1 });
    cleanup.push(() => {
      agent.destroy();
      rmSync(home, { recursive: true, force: true });
    });
    await first.start();
    assert(first.started === true, 'first instance must bind the free port');
    // A live phone connection: this is what keeps the port bound after
    // server.close() and is exactly why the reload hand-off is needed.
    const firstHealth = await httpsGetJson(port, '/health', agent);
    assert(firstHealth.status === 200, 'first instance serves /health, got ' + firstHealth.status);

    // The reload: a new fiber of the same plugin, same port, while the previous
    // instance is still alive and holding the listener.
    const second = makeServer(home, port);
    cleanup.push(() => {
      second.dispose();
    });
    await second.start();
    const secondHealth = await httpsGetJson(port, '/health', new HttpsAgent({ keepAlive: false }));
    record('reload-port-handoff', second.started === true && first.disposed === true && secondHealth.status === 200, {
      firstDisposed: first.disposed,
      secondStarted: second.started,
      secondStartupError: second.startupError ?? null,
      healthStatus: secondHealth.status,
    });
    assert(second.startupError === undefined, 'new instance must not report a startup error, got ' + JSON.stringify(second.startupError));
    assert(second.readinessError() === undefined, 'new instance must be ready, got ' + JSON.stringify(second.readinessError()));
  }

  // ------------------------------------- 2. dispose releases the port on throw
  {
    const home = mkdtempSync(join(tmpdir(), 'dshm-reload-dispose-'));
    const port = await freePort();
    const server = makeServer(home, port);
    cleanup.push(() => rmSync(home, { recursive: true, force: true }));
    await server.start();
    assert(server.started === true, 'dispose-test instance must bind');
    // Simulate a teardown step that throws after the fiber went inactive: the
    // device-registry access is unguarded in the dispose body, so the throw must
    // still be followed by the listener close (finally path).
    Object.defineProperty(server, 'devices', {
      configurable: true,
      get() {
        throw new Error('cannot get required service "connection" in inactive context');
      },
    });
    server.dispose();
    const bindable = await portIsBindable(port);
    record('dispose-releases-port-on-throw', server.disposed === true && bindable === true, {
      disposed: server.disposed,
      portBindable: bindable,
    });
  }

  // ------------------------------------- 3. foreign holder keeps the explicit error
  {
    const home = mkdtempSync(join(tmpdir(), 'dshm-reload-foreign-'));
    const foreign = createTcpServer();
    const port = await new Promise((resolvePromise, reject) => {
      foreign.once('error', reject);
      foreign.listen(0, '127.0.0.1', () => resolvePromise(foreign.address().port));
    });
    const server = makeServer(home, port);
    cleanup.push(() => {
      server.dispose();
      foreign.close();
      rmSync(home, { recursive: true, force: true });
    });
    await server.start();
    record(
      'foreign-port-holder-errors',
      server.started === false && server.startupError?.code === 'host/port-in-use',
      { started: server.started, startupError: server.startupError?.code ?? null }
    );
  }

  for (const fn of cleanup.reverse()) {
    try {
      fn();
    } catch {
      /* best effort */
    }
  }

  const report = {
    startedAt: new Date(startedAt).toISOString(),
    durationMs: Date.now() - startedAt,
    checks,
    pass: checks.length,
    fail: 0,
  };
  writeFileSync(join(OUT_DIR, 'm2-reload-handoff-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
  console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
});
