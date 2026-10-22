/**
 * assets.js — bundled relay binaries and the deploy sidecar files.
 *
 * The plugin ships prebuilt Linux binaries (built by
 * `packages/dsh-m-relay/scripts/build-release.sh`):
 *
 * assets/relay/index.json manifest: target -> {file, sha256, size}
 * assets/relay/linux-amd64/dshm-relay
 * assets/relay/linux-arm64/dshm-relay
 * assets/relay/deploy/install.sh server-side installer (copied at build time)
 * assets/relay/deploy/dshm-relay.service
 *
 * The engine verifies the local sha256 against the manifest before uploading and
 * the server verifies it again after upload (m2b-plan §2.2 step 3).
 */

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_ASSETS_DIR = join(MODULE_DIR, '..', '..', 'assets', 'relay');

/** sha256 hex of a file. */
export function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

/**
 * Resolve the relay assets directory and manifest.
 * @param {{assetsDir?: string}} [options]
 */
export function loadAssets(options = {}) {
  const assetsDir = options.assetsDir ?? DEFAULT_ASSETS_DIR;
  const manifestPath = join(assetsDir, 'index.json');
 /** @type {{version?: string, generatedAt?: string, binaries: Record<string, {file: string, sha256: string, size?: number}>}} */
  let manifest = { binaries: {} };
  let manifestError;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    if (manifest === null || typeof manifest !== 'object' || typeof manifest.binaries !== 'object' || manifest.binaries === null) {
      manifest = { binaries: {} };
      manifestError = 'malformed manifest';
    }
  } catch (error) {
    manifestError = String(error?.message ?? error);
  }
  const deployDir = join(assetsDir, 'deploy');
  return {
    assetsDir,
    manifestPath,
    manifest,
    version: typeof manifest.version === 'string' ? manifest.version : undefined,
    targets: Object.keys(manifest.binaries).sort(),
    manifestError,
    installScriptPath: join(deployDir, 'install.sh'),
    unitPath: join(deployDir, 'dshm-relay.service'),
    deployDir,
 /** @param {string} target e.g. 'linux-amd64' */
    binary(target) {
      const entry = manifest.binaries?.[target];
      if (entry === undefined || typeof entry.sha256 !== 'string') {
        return { ok: false, error: 'manifest 中没有 ' + target + ' 的 relay 二进制；先运行 bash packages/dsh-m-relay/scripts/build-release.sh' };
      }
      const path = join(assetsDir, entry.file);
      if (!existsSync(path)) return { ok: false, error: '缺少文件 ' + path + '；先运行 bash packages/dsh-m-relay/scripts/build-release.sh' };
      const actual = sha256File(path);
      if (actual !== entry.sha256) return { ok: false, error: '二进制校验失败：' + path + ' 的 sha256 ' + actual + ' 与清单 ' + entry.sha256 + ' 不一致（重新构建）' };
      return { ok: true, path, sha256: entry.sha256, size: entry.size, version: manifest.version, target };
    },
  };
}
