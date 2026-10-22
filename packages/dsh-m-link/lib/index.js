/**
 * dsh-m-link — Cordis plugin entry (M1 + M2a + M2b-1).
 *
 * Loaded either as a bundle (@see cordis.patch.yml) or through the profile's
 * own user patch layer. Waits for the DSH web transport services and then
 * starts an independent TLS origin that bridges phones to the loopback Remote
 * API (see <internal-doc> §4 and
 * <internal-doc> §1).
 *
 * M2b-1 additions:
 * - `deploy/` registers a separate authenticated deploy route
 * (`/api/dsh-m-link/deploy`) used by the settings card "远程中转（自建服务器）";
 * - a successfully deployed relay is persisted under
 * `plugin-data/dsh-m-link/deploy/tunnel.json` and merged into the plugin
 * config on load (an explicit `tunnel:` block in the profile always wins).
 * Editing the profile live would hot-reload the in-use plugin, which the
 * project forbids, so activation is "write config + reload".
 *
 * Exports follow the Cordis plugin shape used by the DSH bundles:
 * name stable plugin name
 * inject services that must exist before apply() runs
 * apply(ctx, config)
 */

import { LinkServer } from './link-server.js';
import { applyPersistedTunnelConfig, DeployEngine, registerDeployRoute, resolveDataDir } from './deploy/index.js';

export const name = 'dsh-m-link';
export const inject = ['webServer', 'connection'];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {Record<string, unknown>} [config]
 */
export function apply(ctx, config = {}) {
 // M2b-1: activate a relay deployed from the settings card unless the profile
 // pins tunnel.* explicitly. Any read/parse failure degrades to the M1/M2a
 // behaviour instead of blocking the plugin.
  let effectiveConfig = config;
  try {
    effectiveConfig = applyPersistedTunnelConfig(config, { dataDir: resolveDataDir(ctx) });
  } catch (error) {
    process.stderr.write('[dsh-m-link] persisted tunnel config ignored: ' + String(error?.stack ?? error) + '\n');
  }
  const link = new LinkServer(ctx, effectiveConfig);

 // M2b-1: one-click deploy route (own Fetch route; never touches the phone path).
  let deploy;
  try {
    deploy = registerDeployRoute({
      ctx,
      link,
      log: (message) => process.stderr.write('[dsh-m-link] ' + message + '\n'),
    });
  } catch (error) {
    process.stderr.write('[dsh-m-link] deploy route unavailable: ' + String(error?.stack ?? error) + '\n');
    deploy = undefined;
  }

  ctx.on('dispose', () => {
    try {
      deploy?.dispose?.();
    } catch {
 /* best effort during HMR */
    }
    link.dispose();
  });
  link.start().catch((error) => {
    process.stderr.write('[dsh-m-link] failed to start: ' + (error?.stack ?? String(error)) + '\n');
    process.stderr.write('[dsh-m-link] fix the cause above (ws resolution / certificate generation / port conflict) and restart the host; the plugin daemon is inactive until then.\n');
  });
}

export { LinkServer, DeployEngine };
