/**
 * install.js — remote side of the one-click deploy: bundle upload, installer
 * invocation, machine-readable summary and rollback.
 *
 * The Mac-side engine owns the state machine and user interaction; this module
 * owns the SSH command sequence and stays free of UI concerns so it can be unit
 * tested with a fake transport.
 *
 * Remote layout per attempt (all under a 0700 temp dir, removed on exit):
 *   /tmp/dshm-deploy-<id>/dshm-relay            prebuilt linux binary
 *   /tmp/dshm-deploy-<id>/install.sh            server installer (idempotent)
 *   /tmp/dshm-deploy-<id>/dshm-relay.service    systemd unit
 *   /tmp/dshm-deploy-<id>/summary.json          root-only JSON summary (has secret)
 */

import { CODES, DeployError } from './errors.js';
import { shellQuote } from './ssh.js';

export const REMOTE_TMP_ROOT = '/tmp';

/** Absolute remote paths for one deploy attempt. */
export function buildRemoteLayout({ id, installBin = '/usr/local/bin/dshm-relay', configDir = '/etc/dshm-relay', dataDir = '/var/lib/dshm-relay', unitPath = '/etc/systemd/system/dshm-relay.service' }) {
  const safeId = String(id).replace(/[^A-Za-z0-9_-]/gu, '').slice(0, 24) || 'deploy';
  const tmpDir = REMOTE_TMP_ROOT + '/dshm-deploy-' + safeId;
  return {
    tmpDir,
    binary: tmpDir + '/dshm-relay',
    installScript: tmpDir + '/install.sh',
    unitFile: tmpDir + '/dshm-relay.service',
    summary: tmpDir + '/summary.json',
    installBin,
    configDir,
    dataDir,
    unitPath,
  };
}

/**
 * Build the installer command line (without sudo wrapping).
 * @param {{layout: ReturnType<typeof buildRemoteLayout>, input: Record<string, any>, plan: Record<string, any>, forceReinit?: boolean}} options
 */
export function buildInstallCommand({ layout, input, plan, forceReinit = false }) {
  const parts = [
    'bash',
    shellQuote(layout.installScript),
    '--engine',
    '--json-out',
    shellQuote(layout.summary),
    '--public-host',
    shellQuote(input.host),
    '--control-port',
    String(plan.controlPort),
    '--bridge-start',
    String(plan.bridgeRange.start),
    '--bridge-end',
    String(plan.bridgeRange.end),
    '--binary',
    shellQuote(layout.binary),
    '--unit-src',
    shellQuote(layout.unitFile),
    '--install-bin',
    shellQuote(layout.installBin),
    '--config-dir',
    shellQuote(layout.configDir),
    '--data-dir',
    shellQuote(layout.dataDir),
    '--unit-dst',
    shellQuote(layout.unitPath),
  ];
  if (input.forceReinstall === true) parts.push('--force-reinstall');
  if (forceReinit === true) parts.push('--force-reinit');
  return parts.join(' ');
}

/** Ensure the remote temp dir exists (owned by the login user). */
export async function ensureRemoteTemp({ transport, layout }) {
  const script = ['mkdir -p ' + shellQuote(layout.tmpDir), 'chmod 700 ' + shellQuote(layout.tmpDir)].join('\n');
  await transport.exec(script, { label: '写入临时目录 ' + layout.tmpDir, timeoutMs: 20_000 });
}

/**
 * Upload binary + installer + unit and verify the binary checksum on the host.
 * @param {{transport: any, layout: any, binaryPath: string, binarySha256: string, installScriptPath: string, unitPath: string}} options
 */
export async function pushBundle({ transport, layout, binaryPath, binarySha256, installScriptPath, unitPath }) {
  await ensureRemoteTemp({ transport, layout });
  await transport.upload(binaryPath, layout.binary);
  await transport.upload(installScriptPath, layout.installScript);
  await transport.upload(unitPath, layout.unitFile);
  const verify = await transport.exec(
    'if command -v sha256sum >/dev/null 2>&1; then sha256sum ' +
      shellQuote(layout.binary) +
      '; else openssl dgst -sha256 ' +
      shellQuote(layout.binary) +
      '; fi',
    { label: '校验远端二进制 sha256', timeoutMs: 60_000 },
  );
  if (!verify.stdout.includes(binarySha256)) {
    throw new DeployError(CODES.relayChecksumMismatch, '上传后的 relay 二进制 sha256 与本地清单不一致', {
      hint: '网络传输损坏或上传了错误文件；重试部署。',
      detail: '远端输出: ' + verify.stdout.trim().slice(0, 300),
    });
  }
  return { remoteBinary: layout.binary, sha256: binarySha256 };
}

/**
 * Run the server-side installer through sudo/root.
 * Returns the captured stdout/stderr plus the parsed summary (may be undefined
 * when the installer failed before writing one).
 *
 * @param {{transport: any, layout: any, input: Record<string, any>, plan: Record<string, any>, forceReinit?: boolean}} options
 */
export async function runRemoteInstaller({ transport, layout, input, plan, forceReinit = false }) {
  const command = buildInstallCommand({ layout, input, plan, forceReinit });
  const result = await transport.execRoot(command, {
    label: '运行服务器端安装脚本',
    timeoutMs: 180_000,
    allowFailure: true,
  });
  let summary;
  let rawSummary;
  try {
    rawSummary = await transport.execRoot('cat ' + shellQuote(layout.summary), {
      label: '读取安装摘要',
      timeoutMs: 20_000,
      allowFailure: true,
      sensitive: true,
    });
    if (rawSummary.code === 0 && rawSummary.stdout.trim().startsWith('{')) {
      summary = JSON.parse(rawSummary.stdout);
      if (typeof summary?.init?.secret === 'string') transport.logLine?.('debug', '  (安装摘要含 relay secret，已读入内存，不打印)');
    }
  } catch {
    summary = undefined;
  }
  return { code: result.code, stdout: result.stdout, stderr: result.stderr, summary };
}

/** Best-effort removal of the remote temp dir (never fails the deploy). */
export async function cleanupRemoteTemp({ transport, layout }) {
  try {
    await transport.execRoot('rm -rf ' + shellQuote(layout.tmpDir), { label: '清理远端临时文件', timeoutMs: 20_000, allowFailure: true });
  } catch {
    /* temp dir cleanup is best effort */
  }
}

/**
 * Roll back a failed FRESH install: remove only resources this attempt created.
 * The preflight snapshot tells us what existed before (`had`); anything that was
 * there before is never touched (m2b-plan §2.3).
 *
 * @param {{transport: any, layout: any, had: {user: boolean, configDir: boolean, dataDir: boolean, binary: boolean, config: boolean, unit: boolean}, log: Function}} options
 */
export async function rollbackFreshInstall({ transport, layout, had, log = () => {} }) {
  const steps = [];
  const add = (label, command) => steps.push({ label, command });
  add('停止并禁用本次创建的 unit', 'systemctl stop dshm-relay >/dev/null 2>&1 || true; systemctl disable dshm-relay >/dev/null 2>&1 || true; rm -f ' + shellQuote(layout.unitPath) + '; systemctl daemon-reload >/dev/null 2>&1 || true');
  if (had?.binary !== true) add('删除本次安装的二进制', 'rm -f ' + shellQuote(layout.installBin));
  add('删除本次生成的配置目录', had?.configDir === true ? 'true' : 'rm -rf ' + shellQuote(layout.configDir));
  add('删除本次生成的数据目录', had?.dataDir === true ? 'true' : 'rm -rf ' + shellQuote(layout.dataDir));
  if (had?.user !== true) add('删除本次创建的系统用户', 'userdel dshm-relay >/dev/null 2>&1 || true');
  add('清理远端临时文件', 'rm -rf ' + shellQuote(layout.tmpDir));
  const results = [];
  for (const step of steps) {
    log('info', '回滚: ' + step.label);
    try {
      const result = await transport.execRoot(step.command, { label: '回滚: ' + step.label, timeoutMs: 30_000, allowFailure: true });
      results.push({ label: step.label, code: result.code });
    } catch (error) {
      results.push({ label: step.label, code: -1, error: String(error?.message ?? error) });
    }
  }
  const failed = results.filter((entry) => entry.code !== 0 && entry.code !== undefined);
  return { ok: failed.length === 0, steps: results };
}

/**
 * Post-install verification that the relay only added its own listeners: the
 * engine compares a pre/post snapshot of running units + listening ports.
 *
 * `expectedUnits` are the only new units the deploy is allowed to add
 * (`dshm-relay.service`); `expectedPorts` are the only allowed new listeners
 * (control port + first bridge port).
 *
 * @param {{before: {units: string[], ports: string[], etc: string[], root?: string[]}, after: {units: string[], ports: string[], etc: string[], root?: string[]}, expectedPorts?: number[], expectedUnits?: string[]}} options
 */
export function diffSnapshots({ before, after, expectedPorts = [], expectedUnits = ['dshm-relay.service'] }) {
  const newUnits = (after.units ?? []).filter((unit) => !(before.units ?? []).includes(unit) && !expectedUnits.includes(unit));
  const newEtc = (after.etc ?? []).filter((entry) => !(before.etc ?? []).includes(entry) && entry !== 'dshm-relay');
  const newRoot = (after.root ?? []).filter((entry) => !(before.root ?? []).includes(entry));
  const portNumber = (entry) => Number(String(entry).match(/:(\d+)$/u)?.[1] ?? 0);
  const newPorts = (after.ports ?? []).filter((entry) => !(before.ports ?? []).includes(entry));
  const unexpectedNewPorts = newPorts.filter((entry) => !expectedPorts.includes(portNumber(entry)) && portNumber(entry) !== 22);
  return {
    newUnits,
    newEtc,
    newRoot,
    newPorts,
    unexpectedNewPorts,
    ok: newUnits.length === 0 && newEtc.length === 0 && newRoot.length === 0 && unexpectedNewPorts.length === 0,
  };
}
