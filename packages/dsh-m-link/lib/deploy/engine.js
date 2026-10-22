/**
 * engine.js — the one-click relay deploy state machine (M2b-1).
 *
 * Runs inside the desktop plugin host process (Node 22, no extra deps). The
 * desktop settings UI starts a deploy and then polls `deploy.status` for the
 * step list and streamed log lines; the host fingerprint confirmation is an
 * explicit pause that `deploy.confirm` resumes (MITM protection, m2b-plan
 * §2.2 step 1).
 *
 * Non-negotiables implemented here:
 *   - streaming log with a monotonic cursor, ring-buffered and always masked;
 *   - explicit host-key confirmation, plugin-private known_hosts;
 *   - port avoidance with an externally verified control port;
 *   - idempotent upgrade (existing relay => only binary/systemd touched);
 *   - failure rollback (fresh: remove resources created by this attempt;
 *     upgrade: installer restores the previous binary);
 *   - every failure maps to a stable code + actionable Chinese hint.
 *
 * The engine is dependency-injected (`transportFactory`, `assets`, `probes`) so
 * `test/m2b-deploy.mjs` drives it with a fake SSH runner and never touches a
 * real server.
 */

import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';

import { loadAssets } from './assets.js';
import { CODES, DeployError, toDeployError } from './errors.js';
import { resolveDataDir } from './home.js';
import {
  buildRemoteLayout,
  cleanupRemoteTemp,
  diffSnapshots,
  pushBundle,
  rollbackFreshInstall,
  runRemoteInstaller,
} from './install.js';
import { SecretMasker } from './mask.js';
import { assessPreflight, firstDeployError, PREFLIGHT_SCRIPT, parsePreflightOutput, SNAPSHOT_SCRIPT, parseSnapshotOutput } from './preflight.js';
import { externalSelfCheck } from './selfcheck.js';
import { forgetKnownHostKey, makeDeployWorkDir, SshTransport } from './ssh.js';
import { buildProfileSnippet, readTunnelState, tunnelPaths, writeFileAtomic, writeTunnelState } from './tunnel-config.js';

export const STEP_DEFINITIONS = [
  { id: 'precheck', title: '预检：SSH 连接与主机指纹' },
  { id: 'discover', title: '探测：系统 / 架构 / 端口 / 已有 relay' },
  { id: 'plan', title: '规划：端口选择与安装方案' },
  { id: 'upload', title: '上传：relay 二进制与安装脚本（sha256 校验）' },
  { id: 'install', title: '安装：用户 / 目录 / systemd（幂等）' },
  { id: 'verify', title: '自检：外网 healthz + TLS pin' },
  { id: 'finalize', title: '完成：写入本机隧道配置' },
];

const HOST_KEY_CONFIRM_TIMEOUT_MS = 5 * 60 * 1000;
const LOG_RING_LIMIT = 2000;
const LOG_POLL_LIMIT = 500;
const DEFAULT_BIN_DIR = '/usr/local/bin';
const DEFAULT_CONFIG_DIR = '/etc/dshm-relay';
const DEFAULT_DATA_DIR = '/var/lib/dshm-relay';
const DEFAULT_UNIT_PATH = '/etc/systemd/system/dshm-relay.service';

/** Strip a pasted URL down to a bare host (keeps IPv6 literals). */
export function normalizeHostInput(raw) {
  if (typeof raw !== 'string') return '';
  let value = raw.trim();
  if (value.length === 0) return '';
  value = value.replace(/^[a-z][a-z0-9+.-]*:\/\//iu, '');
  value = value.replace(/\/.*$/u, '');
  value = value.replace(/^\[|\]$/gu, '');
  const hostPort = value.match(/^([^:]+):(\d+)$/u);
  if (hostPort !== null) return hostPort[1];
  return value;
}

/**
 * Validate + sanitize user input. Returns the internal shape; throws DeployError
 * with `input/invalid` for bad values. Secrets stay only in the returned object
 * (never persisted, never logged).
 */
export function normalizeInput(raw) {
  if (raw === null || typeof raw !== 'object') throw new DeployError(CODES.inputInvalid, '缺少部署参数');
  const host = normalizeHostInput(raw.host ?? raw.address ?? raw.server);
  if (host.length === 0) throw new DeployError(CODES.inputInvalid, '请填写服务器地址（IP 或域名）');
  if (!/^[A-Za-z0-9.:-]+$/u.test(host) || host.length > 253) {
    throw new DeployError(CODES.inputInvalid, '服务器地址格式不正确：' + host, { hint: '只填 IP 或域名，不要带 https:// 或路径。' });
  }
  const sshPort = raw.sshPort === undefined || raw.sshPort === '' ? 22 : Number(raw.sshPort);
  if (!Number.isInteger(sshPort) || sshPort < 1 || sshPort > 65535) throw new DeployError(CODES.inputInvalid, 'SSH 端口必须是 1-65535 的整数');
  const user = typeof raw.user === 'string' && raw.user.trim().length > 0 ? raw.user.trim() : 'root';
  if (!/^[A-Za-z_][A-Za-z0-9_-]{0,31}$/u.test(user)) throw new DeployError(CODES.inputInvalid, '登录用户名不合法：' + user);
  const auth = raw.auth === 'password' ? 'password' : raw.auth === 'key' ? 'key' : undefined;
  if (auth === undefined) throw new DeployError(CODES.inputInvalid, '请选择认证方式（私钥文件或密码）');
  let privateKey;
  let password;
  if (auth === 'key') {
    privateKey = typeof raw.privateKey === 'string' ? raw.privateKey : '';
    if (!privateKey.includes('PRIVATE KEY-----')) {
      throw new DeployError(CODES.inputInvalid, '私钥文件内容无效', { hint: '请选择 OpenSSH / PEM 私钥文件（id_ed25519、id_rsa 等）。' });
    }
  } else {
    password = typeof raw.password === 'string' ? raw.password : '';
    if (password.length === 0) throw new DeployError(CODES.inputInvalid, '请输入 SSH 密码');
  }
  const controlPort = raw.controlPort === undefined || raw.controlPort === '' || raw.controlPort === 0 || raw.controlPort === null ? undefined : Number(raw.controlPort);
  if (controlPort !== undefined && (!Number.isInteger(controlPort) || controlPort < 1 || controlPort > 65535)) {
    throw new DeployError(CODES.inputInvalid, '控制端口必须是 1-65535 的整数（留空自动选择）');
  }
  let bridgeRange;
  if (typeof raw.bridgeRange === 'string' && raw.bridgeRange.trim().length > 0) {
    bridgeRange = raw.bridgeRange.trim();
    if (!/^\d{2,5}-\d{2,5}$/u.test(bridgeRange)) throw new DeployError(CODES.inputInvalid, 'bridge 端口段格式应为 start-end，例如 30000-30009');
  }
  const installDir = typeof raw.installDir === 'string' && raw.installDir.trim().length > 0 ? raw.installDir.trim() : DEFAULT_BIN_DIR;
  if (!/^\/[A-Za-z0-9._/-]+$/u.test(installDir) || installDir.includes('..')) {
    throw new DeployError(CODES.inputInvalid, '安装目录必须是绝对路径且不含空格：' + installDir);
  }
  return {
    host,
    sshPort,
    user,
    auth,
    privateKey,
    password,
    controlPort,
    bridgeRange,
    installDir,
    forceReinstall: raw.forceReinstall === true,
    acceptNewHostKey: raw.acceptNewHostKey === true,
    // Read-only plan probe used by the CLI/e2e script: stops after planning.
    dryRun: raw.dryRun === true,
  };
}

/** Public (persistable/loggable) view of an input. */
export function publicInput(input) {
  return {
    host: input.host,
    sshPort: input.sshPort,
    user: input.user,
    auth: input.auth,
    controlPort: input.controlPort,
    bridgeRange: input.bridgeRange,
    installDir: input.installDir,
    forceReinstall: input.forceReinstall,
    ...(input.dryRun === true ? { dryRun: true } : {}),
  };
}

/** Default transport factory: real ssh/scp with plugin-private known_hosts. */
function defaultTransportFactory({ input, workDir, knownHostsFile, log, masker }) {
  const transport = new SshTransport({
    host: input.host,
    port: input.sshPort,
    user: input.user,
    auth: input.auth,
    privateKey: input.privateKey,
    password: input.password,
    workDir,
    knownHostsFile,
    log,
    masker,
    logger: masker,
  });
  return transport;
}

/**
 * DeployEngine — one instance per plugin lifetime; one deploy at a time.
 */
export class DeployEngine {
  /**
   * @param {{
   *   dataDir?: string,
   *   ctx?: object,
   *   log?: (level: string, text: string) => void,
   *   transportFactory?: Function,
   *   assets?: ReturnType<typeof loadAssets>,
   *   probes?: {externalSelfCheck?: Function},
   *   tunnelActivator?: (activation: object) => Promise<object>,
   *   tunnelStatus?: () => object|null,
   *   now?: () => number,
   *   idFactory?: () => string,
   *   hostKeyTimeoutMs?: number,
   * }} [options]
   */
  constructor(options = {}) {
    this.dataDir = options.dataDir ?? resolveDataDir(options.ctx);
    this.log = options.log ?? (() => {});
    this.transportFactory = options.transportFactory ?? defaultTransportFactory;
    this.assets = options.assets ?? loadAssets();
    this.probes = { externalSelfCheck, ...(options.probes ?? {}) };
    // M2b-1 runtime activation: provided by the live plugin (admin.js); absent
    // in headless CLI/e2e runs, which then rely on "reload or restart DSH".
    this.tunnelActivator = typeof options.tunnelActivator === 'function' ? options.tunnelActivator : undefined;
    this.tunnelStatus = typeof options.tunnelStatus === 'function' ? options.tunnelStatus : () => undefined;
    this.now = options.now ?? (() => Date.now());
    this.idFactory = options.idFactory ?? (() => randomBytes(8).toString('hex'));
    this.hostKeyTimeoutMs = options.hostKeyTimeoutMs ?? HOST_KEY_CONFIRM_TIMEOUT_MS;
    /** @type {DeployRun | undefined} */
    this.active = undefined;
    /** @type {DeployRun | undefined} */
    this.last = undefined;
    this.paths = tunnelPaths({ dataDir: this.dataDir });
  }

  // -------------------------------------------------------------------------
  // Public actions (dispatched by deploy/admin.js)
  // -------------------------------------------------------------------------

  /**
   * @param {Record<string, any>} body
   * @returns {Promise<{ok: boolean, data?: any, error?: string, message?: string}>}
   */
  async handleAction(body) {
    const action = typeof body?.action === 'string' ? body.action : '';
    switch (action) {
      case 'env':
        return { ok: true, data: this.envPayload() };
      case 'start':
        return this.start(body.input ?? body);
      case 'status':
        return { ok: true, data: this.status({ deployId: body.deployId, since: body.since }) };
      case 'last':
        return { ok: true, data: this.lastPayload() };
      case 'confirm':
        return this.confirm({ deployId: body.deployId, fingerprint: body.fingerprint, acceptNew: body.acceptNew === true });
      case 'cancel':
        return this.cancel({ deployId: body.deployId });
      case 'forgetHost':
        return this.forgetHost({ host: body.host, sshPort: body.sshPort });
      case 'tunnel.activate':
        return await this.activatePersistedTunnel(body);
      case 'tunnel.status':
        return { ok: true, data: { tunnel: this.tunnelStatus() ?? null } };
      default:
        return { ok: false, error: 'admin/unknown-action', message: action };
    }
  }

  /** Environment/tools/assets snapshot for the settings card. */
  envPayload() {
    const tunnel = readTunnelState({ dataDir: this.dataDir });
    const sshPaths = this.resolveSshBinaries();
    return {
      assets: {
        dir: this.assets.assetsDir,
        version: this.assets.version,
        targets: this.assets.targets,
        installScriptExists: this.assets.installScriptPath !== undefined,
        error: this.assets.manifestError,
      },
      sshBinaries: sshPaths,
      dataDir: this.dataDir,
      knownHostsFile: this.paths.knownHostsFile,
      tunnel: tunnel.ok === true ? { configured: true, controlOrigin: tunnel.state?.controlOrigin, pin: tunnel.state?.pin, deployedAt: tunnel.state?.deployedAt, appConfig: tunnel.state?.appConfig } : { configured: false },
      canActivate: this.tunnelActivator !== undefined,
      runtimeTunnel: this.tunnelStatus() ?? null,
      busy: this.active !== undefined && this.active.done !== true,
      sshAvailable: Object.values(sshPaths).every((path) => typeof path === 'string' && path.length > 0),
    };
  }

  /** Resolve ssh/scp/ssh-keyscan on this Mac (used by `env` for UI checks). */
  resolveSshBinaries() {
    const resolveOne = (name) => {
      const paths = String(process.env.PATH ?? '').split(':').filter(Boolean);
      const candidates = ['/usr/bin', '/usr/local/bin', '/opt/homebrew/bin', ...paths];
      for (const dir of candidates) {
        const candidate = dir + '/' + name;
        if (existsSync(candidate)) return candidate;
      }
      return undefined;
    };
    return { ssh: resolveOne('ssh'), scp: resolveOne('scp'), keyscan: resolveOne('ssh-keyscan') };
  }

  /** Start one deploy attempt. Returns the deploy id immediately. */
  start(rawInput) {
    if (this.active !== undefined && this.active.done !== true) {
      return { ok: false, error: CODES.deployBusy, message: '已有部署在进行中，请先等待完成或取消' };
    }
    let input;
    try {
      input = normalizeInput(rawInput);
    } catch (error) {
      return { ok: false, error: error.code ?? CODES.inputInvalid, message: error.message };
    }
    const id = this.idFactory();
    const masker = new SecretMasker();
    if (input.password) masker.add(input.password);
    if (input.privateKey) masker.add(input.privateKey);
    /** @type {DeployRun} */
    const run = {
      id,
      state: 'starting',
      createdAt: this.now(),
      updatedAt: this.now(),
      steps: STEP_DEFINITIONS.map((step) => ({ ...step, status: 'pending' })),
      logs: [],
      seq: 0,
      input,
      publicInput: publicInput(input),
      masker,
      prompt: undefined,
      error: undefined,
      result: undefined,
      rollback: undefined,
      cancelled: false,
      done: false,
      transport: undefined,
      workDir: makeDeployWorkDir(this.paths.workDir, id),
      waiting: undefined,
    };
    this.active = run;
    this.runPromise = this.execute(run).catch((error) => {
      // execute() handles its own errors; this is a last-resort guard so a
      // programming error never leaves the UI stuck on "running".
      run.error = toDeployError(error).toJSON();
      run.state = 'failed';
      run.done = true;
      this.logRun(run, 'error', '内部错误: ' + String(error?.stack ?? error));
      this.finish(run);
    });
    return { ok: true, data: { deployId: id } };
  }

  /** Poll snapshot. `since` is the last log seq the client has seen. */
  status({ deployId, since } = {}) {
    const run = this.active !== undefined && (deployId === undefined || deployId === this.active.id) ? this.active : undefined;
    if (run === undefined) {
      const persisted = this.lastPayload();
      if (persisted !== undefined && (deployId === undefined || deployId === persisted.deployId)) return { ...persisted, active: false };
      return { deployId, state: 'idle', steps: STEP_DEFINITIONS.map((step) => ({ ...step, status: 'pending' })), logs: [], cursor: 0, active: false };
    }
    const requested = Number.isFinite(Number(since)) ? Math.max(0, Number(since)) : 0;
    const logs = run.logs.filter((entry) => entry.seq > requested).slice(-LOG_POLL_LIMIT);
    return {
      deployId: run.id,
      state: run.state,
      active: run.done !== true,
      startedAt: run.createdAt,
      updatedAt: run.updatedAt,
      steps: run.steps,
      logs,
      cursor: run.seq,
      prompt: run.prompt,
      result: run.result,
      error: run.error,
      rollback: run.rollback,
      input: run.publicInput,
    };
  }

  /** Resume a paused host-fingerprint confirmation. */
  confirm({ deployId, fingerprint, acceptNew = false } = {}) {
    const run = this.active;
    if (run === undefined || run.done === true) return { ok: false, error: 'deploy/not-running', message: '没有进行中的部署' };
    if (deployId !== undefined && deployId !== run.id) return { ok: false, error: 'deploy/not-running', message: '部署 id 不匹配' };
    if (run.waiting === undefined || run.prompt?.kind !== 'host-fingerprint') return { ok: false, error: 'deploy/no-prompt', message: '当前没有等待确认的主机指纹' };
    if (typeof fingerprint === 'string' && fingerprint.length > 0 && fingerprint !== run.prompt.fingerprint) {
      return { ok: false, error: CODES.sshHostKeyMismatch, message: '确认的指纹与扫描结果不一致' };
    }
    const waiting = run.waiting;
    run.waiting = undefined;
    run.prompt = undefined;
    run.state = 'running';
    waiting.resolve({ accepted: true, acceptNew });
    return { ok: true, data: { deployId: run.id } };
  }

  /** Cancel the active deploy (rolls back what was created). */
  cancel({ deployId } = {}) {
    const run = this.active;
    if (run === undefined || run.done === true) return { ok: false, error: 'deploy/not-running', message: '没有进行中的部署' };
    if (deployId !== undefined && deployId !== run.id) return { ok: false, error: 'deploy/not-running', message: '部署 id 不匹配' };
    run.cancelled = true;
    this.logRun(run, 'warn', '收到取消请求，正在停止后续步骤…');
    if (run.waiting !== undefined) {
      const waiting = run.waiting;
      run.waiting = undefined;
      run.prompt = undefined;
      waiting.reject(new DeployError(CODES.deployCancelled, '部署已取消'));
    }
    return { ok: true, data: { deployId: run.id } };
  }

  /** Remove the stored host key for a server (after a legitimate reinstall). */
  forgetHost({ host, sshPort } = {}) {
    const normalized = normalizeHostInput(host ?? '');
    if (normalized.length === 0) return { ok: false, error: CODES.inputInvalid, message: '缺少服务器地址' };
    const port = Number.isInteger(Number(sshPort)) ? Number(sshPort) : 22;
    const removed = forgetKnownHostKey(this.paths.knownHostsFile, normalized, port);
    return { ok: true, data: { removed, host: normalized, knownHostsFile: this.paths.knownHostsFile } };
  }

  // -------------------------------------------------------------------------
  // State machine
  // -------------------------------------------------------------------------

  /** @param {DeployRun} run */
  async execute(run) {
    try {
      await this.stepPrecheck(run);
      this.checkCancelled(run);
      const facts = await this.stepDiscover(run);
      this.checkCancelled(run);
      const plan = this.stepPlan(run, facts);
      this.checkCancelled(run);
      if (run.input.dryRun === true) {
        run.result = {
          dryRun: true,
          mode: plan.mode,
          controlPort: plan.controlPort,
          bridgePorts: plan.bridgePorts,
          target: run.binary?.target,
          binaryVersion: this.assets.version,
          existingRelay: { installed: facts.existingRelay.installed, active: facts.existingRelay.active },
          system: { os: String(facts.os?.PRETTY_NAME ?? ''), arch: facts.unameM, memoryMb: facts.memoryMb, diskAvailableMb: facts.diskAvailableKb === undefined ? undefined : Math.floor(facts.diskAvailableKb / 1024) },
          warnings: [],
        };
        run.state = 'done';
        run.done = true;
        this.logRun(run, 'info', 'dry-run 完成：预检与规划通过，未对服务器做任何修改');
        this.finish(run);
        return;
      }
      await this.stepUpload(run, plan);
      this.checkCancelled(run);
      const installed = await this.stepInstall(run, plan);
      this.checkCancelled(run);
      await this.stepVerify(run, plan, installed);
      this.checkCancelled(run);
      await this.stepFinalize(run, plan, installed, facts);
      run.state = 'done';
      run.done = true;
      this.logRun(run, 'info', '✅ 部署完成：App 服务器配置已生成，本机 tunnel 配置已写入（重载插件后启用公网隧道）');
      this.finish(run);
    } catch (error) {
      await this.fail(run, error);
    }
  }

  /** @param {DeployRun} run */
  async stepPrecheck(run) {
    this.setStep(run, 'precheck', 'running');
    run.state = 'running';
    this.logRun(run, 'info', '连接 ' + run.input.user + '@' + run.input.host + ':' + String(run.input.sshPort) + '（认证：' + (run.input.auth === 'password' ? '密码（仅内存）' : '私钥文件') + '）');
    const transport = this.transportFactory({
      input: run.input,
      workDir: run.workDir,
      knownHostsFile: this.paths.knownHostsFile,
      log: (level, text) => this.logRun(run, level, text),
      masker: run.masker,
    });
    run.transport = transport;
    let scan;
    try {
      scan = await transport.scanHostKey();
    } catch (error) {
      throw toDeployError(error, CODES.sshUnreachable);
    }
    if (scan.status === 'mismatch' && run.input.acceptNewHostKey !== true) {
      throw new DeployError(CODES.sshHostKeyMismatch, '服务器主机指纹与上次部署记录不一致', {
        hint: '如果服务器刚重装/换过 SSH 主机密钥，请重新发起部署并勾选「信任新指纹」；否则可能存在中间人攻击，请停止。',
        detail: '记录指纹: ' + String(scan.knownFingerprints?.join(', ')) + ' / 本次指纹: ' + String(scan.fingerprint),
      });
    }
    if (scan.status === 'trusted') {
      this.logRun(run, 'info', '主机指纹已信任: ' + String(scan.fingerprint));
    } else {
      run.prompt = {
        kind: 'host-fingerprint',
        host: run.input.host,
        port: run.input.sshPort,
        keyType: scan.candidates[0]?.keyType,
        fingerprint: scan.candidates[0]?.fingerprint,
        all: scan.candidates.map((candidate) => ({ keyType: candidate.keyType, fingerprint: candidate.fingerprint })),
        mismatch: scan.status === 'mismatch',
        knownFingerprints: scan.knownFingerprints,
      };
      run.state = 'waiting-host-key';
      this.logRun(run, 'warn', '首次连接该服务器：请核对主机指纹后确认（' + String(scan.candidates[0]?.fingerprint) + '）');
      await this.waitForFingerprint(run);
      this.checkCancelled(run);
      const acceptNew = scan.status === 'mismatch';
      transport.trustHostKey({ ...scan.candidates[0], hostPart: scan.hostPart }, { acceptNew });
      this.logRun(run, 'info', '已把主机指纹写入插件私有 known_hosts（未改动 ~/.ssh/known_hosts）');
    }
    run.state = 'running';
    // Prove the credential actually works before touching anything.
    const idResult = await transport.exec('id -u; id -un', { label: 'SSH 连通性/认证检查', allowFailure: true });
    if (idResult.code !== 0) throw transport.classifyFailure(idResult, 'SSH 认证检查');
    this.logRun(run, 'info', 'SSH 认证成功（' + idResult.stdout.trim().replace(/\n/gu, ' / ') + '）');
    this.setStep(run, 'precheck', 'ok', '指纹 ' + String(scan.candidates[0]?.fingerprint));
  }

  /** Wait until the user confirms the shown fingerprint (or cancel/timeout). */
  async waitForFingerprint(run) {
    await new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        run.waiting = undefined;
        run.prompt = undefined;
        reject(new DeployError(CODES.deployTimeout, '等待主机指纹确认超时（5 分钟）', { hint: '重新发起部署并确认服务器主机指纹。' }));
      }, this.hostKeyTimeoutMs);
      run.waiting = {
        resolve: (value) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(error);
        },
      };
    });
  }

  /** @param {DeployRun} run */
  async stepDiscover(run) {
    this.setStep(run, 'discover', 'running');
    const transport = run.transport;
    this.logRun(run, 'info', '读取服务器系统信息（只读，不会修改任何服务）');
    const result = await transport.exec(PREFLIGHT_SCRIPT, { label: '预检：系统/端口/已有服务', timeoutMs: 60_000, allowFailure: true });
    if (result.code !== 0) throw transport.classifyFailure(result, '预检');
    const facts = parsePreflightOutput(result.stdout);
    facts.existingRelay = { ...facts.existingRelay };
    run.facts = facts;
    transport.setPrivilege({ isRoot: facts.privilege.isRoot, sudoOk: facts.privilege.sudoOk });
    this.logRun(
      run,
      'info',
      '系统: ' + String(facts.os?.PRETTY_NAME ?? facts.unameS) + ' · 架构 ' + String(facts.unameM) + ' · 内存 ' + String(facts.memoryMb ?? '?') + 'MB · 磁盘可用 ' +
        String(facts.diskAvailableKb === undefined ? '?' : Math.floor(facts.diskAvailableKb / 1024)) + 'MB',
    );
    this.logRun(
      run,
      'info',
      '已有 dshm-relay: ' + (facts.existingRelay.installed === true ? '是（' + (facts.existingRelay.active ? '运行中' : '未运行') + '）→ 幂等升级' : '否 → 全新部署'),
    );
    try {
      const snapshot = await transport.exec(SNAPSHOT_SCRIPT, { label: '非破坏性基线快照', timeoutMs: 30_000, allowFailure: true });
      run.snapshotBefore = snapshot.code === 0 ? parseSnapshotOutput(snapshot.stdout) : { units: [], ports: [], etc: [], root: [] };
    } catch {
      run.snapshotBefore = { units: [], ports: [], etc: [], root: [] };
    }
    this.setStep(run, 'discover', 'ok', '架构 linux-' + String(run.facts.unameM) + (run.plan?.arch ? '' : ''));
    return run.facts;
  }

  /** @param {DeployRun} run @param {any} facts */
  stepPlan(run, facts) {
    this.setStep(run, 'plan', 'running');
    const assessment = assessPreflight({ facts, input: run.input, assets: this.assets });
    for (const warning of assessment.warnings) this.logRun(run, 'warn', warning);
    const firstError = firstDeployError(assessment.errors);
    if (firstError !== undefined) throw firstError;
    const plan = assessment.plan;
    run.plan = plan;
    const binary = this.assets.binary(assessment.target);
    if (binary.ok !== true) throw new DeployError(CODES.relayBinaryMissing, binary.error);
    run.binary = binary;
    run.layout = buildRemoteLayout({
      id: run.id,
      installBin: run.input.installDir + '/dshm-relay',
      configDir: DEFAULT_CONFIG_DIR,
      dataDir: DEFAULT_DATA_DIR,
      unitPath: DEFAULT_UNIT_PATH,
    });
    this.logRun(
      run,
      'info',
      '方案: ' + (plan.mode === 'upgrade' ? '幂等升级（保留证书/secret/state）' : '全新部署') + ' · 控制端口 ' + String(plan.controlPort) + ' · bridge ' + String(plan.bridgePorts) + ' · 二进制 ' + String(assessment.target) + ' (' + String(binary.sha256).slice(0, 12) + '…)',
    );
    this.setStep(run, 'plan', 'ok', '控制端口 ' + String(plan.controlPort) + ' · bridge ' + String(plan.bridgePorts));
    return plan;
  }

  /** @param {DeployRun} run @param {any} plan */
  async stepUpload(run, plan) {
    this.setStep(run, 'upload', 'running');
    const transport = run.transport;
    this.logRun(run, 'info', '上传 relay 二进制（' + String(Math.round((run.binary.size ?? 0) / 1024)) + 'KB）与安装脚本到 ' + run.layout.tmpDir);
    await pushBundle({
      transport,
      layout: run.layout,
      binaryPath: run.binary.path,
      binarySha256: run.binary.sha256,
      installScriptPath: this.assets.installScriptPath,
      unitPath: this.assets.unitPath,
    });
    this.setStep(run, 'upload', 'ok', 'sha256 校验通过');
  }

  /** @param {DeployRun} run @param {any} plan */
  async stepInstall(run, plan) {
    this.setStep(run, 'install', 'running');
    run.installAttempted = true;
    const forceReinit = run.facts?.existingRelay?.installed === true && run.input.forceReinstall === true && run.plan?.mode === 'upgrade';
    // A host change on an existing relay requires re-issuing cert+secret; the
    // plan stage already errors out unless forceReinstall was chosen.
    const reinit = forceReinit && this.needsReinit(run);
    if (reinit) this.logRun(run, 'warn', '强制重建：将重新生成 relay 证书与 secret（pin 变化，手机需重新扫码服务器配置）');
    const installed = await runRemoteInstaller({ transport: run.transport, layout: run.layout, input: run.input, plan, forceReinit: reinit });
    if (installed.code !== 0 || installed.summary === undefined || installed.summary.ok !== true) {
      const tail = String(installed.stderr ?? '')
        .split('\n')
        .filter((line) => line.trim().length > 0)
        .slice(-6)
        .join(' | ');
      throw new DeployError(CODES.relayInstallFailed, '服务器端安装脚本执行失败（退出码 ' + String(installed.code) + '）', {
        hint: '安装脚本会回滚本次新建的资源；查看下方安装日志定位原因（端口占用/权限/磁盘）。',
        detail: run.masker.mask(tail).slice(0, 1000),
      });
    }
    run.summary = installed.summary;
    for (const entry of installed.summary.warnings ?? []) this.logRun(run, 'warn', String(entry));
    this.logRun(
      run,
      'info',
      '安装完成: mode=' + String(installed.summary.mode) + ' action=' + String(installed.summary.action) + ' restarted=' + String(installed.summary.restarted) + ' version=' + String(installed.summary.version),
    );
    // Collect the relay secret (needed for the Mac tunnel config) without ever
    // logging it. Fresh: the init JSON in the summary; upgrade: existing file.
    let secret = typeof installed.summary.init?.secret === 'string' ? installed.summary.init.secret : undefined;
    if (secret === undefined) {
      const read = await run.transport.execRoot('cat ' + JSON.stringify(run.layout.dataDir + '/relay.secret'), { label: '读取服务器上的 relay secret', sensitive: true, allowFailure: true, timeoutMs: 20_000 });
      if (read.code === 0 && read.stdout.trim().length >= 16) secret = read.stdout.trim();
    }
    if (typeof secret !== 'string' || secret.length < 16) {
      throw new DeployError(CODES.relayInstallFailed, '无法从服务器读取 relay secret，无法生成本机隧道配置', { hint: '确认 /var/lib/dshm-relay/relay.secret 存在且 root 可读。' });
    }
    run.masker.add(secret);
    run.secret = secret;
    const pin = String(installed.summary.pin ?? '');
    if (pin.length === 0) throw new DeployError(CODES.relayHealthFailed, '安装摘要缺少证书 pin');
    const controlOrigin = String(installed.summary.controlOrigin ?? 'https://' + run.input.host + ':' + String(plan.controlPort));
    const persisted = writeTunnelState({
      dataDir: this.dataDir,
      controlOrigin,
      pin,
      secret,
      publicHost: run.input.host,
      controlPort: plan.controlPort,
      bridgePorts: String(plan.bridgePorts ?? ''),
      appConfig: String(installed.summary.appConfig ?? ''),
      relayVersion: String(installed.summary.version ?? ''),
      mode: plan.mode,
      deployedAt: new Date(this.now()).toISOString(),
    });
    run.tunnelState = persisted.state;
    run.installResult = {
      mode: installed.summary.mode,
      action: installed.summary.action,
      restarted: installed.summary.restarted,
      version: installed.summary.version,
      changed: installed.summary.changed,
      had: installed.summary.had,
      healthOk: installed.summary.healthOk,
      pin,
      controlOrigin,
      appConfig: installed.summary.appConfig,
      secretFile: persisted.secretFile,
      tunnelStateFile: persisted.tunnelStateFile,
    };
    this.setStep(run, 'install', 'ok', 'relay ' + String(installed.summary.version ?? '') + ' · ' + (installed.summary.restarted === 1 ? '已重启' : '无需重启'));
    return run.installResult;
  }

  /** Does this upgrade need a full re-init (new cert+secret)? */
  needsReinit(run) {
    try {
      const summaryHost = run.facts?.existingRelay?.configText?.match(/^\s*publicHost:\s*"?([^"\n]+)"?/mu)?.[1]?.trim();
      return summaryHost !== undefined && summaryHost !== run.input.host;
    } catch {
      return false;
    }
  }

  /** @param {DeployRun} run @param {any} plan @param {any} installed */
  async stepVerify(run, plan, installed) {
    this.setStep(run, 'verify', 'running');
    this.logRun(run, 'info', '从 Mac 侧验证公网可达性：TCP ' + String(plan.controlPort) + ' → TLS pin → /healthz');
    const check = await this.probes.externalSelfCheck({
      host: run.input.host,
      port: plan.controlPort,
      pin: installed.pin,
      timeoutMs: 10_000,
    });
    if (check.ok !== true) throw toDeployError(check.error ?? new DeployError(CODES.networkUnreachable, '外网自检失败'));
    this.logRun(run, 'info', '外网 healthz 通过: ' + JSON.stringify(check.health ?? {}).slice(0, 300));
    this.logRun(run, 'info', 'TLS pin 校验通过: ' + String(installed.pin));
    this.setStep(run, 'verify', 'ok', '外网 healthz + TLS pin ok');
  }

  /** @param {DeployRun} run @param {any} plan @param {any} installed @param {any} facts */
  async stepFinalize(run, plan, installed, facts) {
    this.setStep(run, 'finalize', 'running');
    // Non-destructive proof: snapshot after and diff against the pre-deploy one.
    let diff;
    try {
      const snapshot = await run.transport.exec(SNAPSHOT_SCRIPT, { label: '非破坏性对比快照', timeoutMs: 30_000, allowFailure: true });
      const after = snapshot.code === 0 ? parseSnapshotOutput(snapshot.stdout) : undefined;
      if (after !== undefined) {
        diff = diffSnapshots({
          before: run.snapshotBefore ?? { units: [], ports: [], etc: [], root: [] },
          after,
          expectedPorts: [plan.controlPort, plan.bridgeRange.start],
          expectedUnits: ['dshm-relay.service'],
        });
        if (diff.ok !== true) {
          this.logRun(run, 'warn', '非破坏性对比发现差异：' + JSON.stringify({ newUnits: diff.newUnits, newEtc: diff.newEtc, newRoot: diff.newRoot, unexpectedNewPorts: diff.unexpectedNewPorts }));
        } else {
          this.logRun(run, 'info', '非破坏性对比通过：既有 systemd 服务 / 端口 / /etc 条目未变化');
        }
      }
    } catch {
      diff = undefined;
    }
    const profileSnippet = buildProfileSnippet({ dataDir: this.dataDir, controlOrigin: installed.controlOrigin, pin: installed.pin });
    run.result = {
      mode: installed.mode,
      action: installed.action,
      restarted: installed.restarted,
      changed: installed.changed,
      nonDestructiveOk: diff?.ok,
      controlOrigin: installed.controlOrigin,
      pin: installed.pin,
      appConfig: installed.appConfig,
      bridgePorts: plan.bridgePorts,
      controlPort: plan.controlPort,
      publicHost: run.input.host,
      relayVersion: installed.version,
      secretFile: installed.secretFile,
      tunnelStateFile: installed.tunnelStateFile,
      profileSnippet,
      nonDestructive: diff ?? null,
      deployedAt: new Date(this.now()).toISOString(),
    };
    // M2b-1: activate the new tunnel in-process instead of asking for a plugin
    // reload (a live plugin reload leaves a zombie TLS listener; see notes §12).
    if (this.tunnelActivator !== undefined) {
      this.logRun(run, 'info', '运行时激活隧道（无需重载插件）…');
      try {
        const activation = await this.tunnelActivator({
          controlOrigin: installed.controlOrigin,
          pin: installed.pin,
          secret: run.secret,
          secretFile: installed.secretFile,
          timeoutMs: 15_000,
        });
        run.result.tunnelActivation = {
          ok: activation?.ok === true,
          state: activation?.state,
          origin: activation?.origin ?? null,
          port: activation?.port ?? null,
          error: activation?.error,
          unchanged: activation?.unchanged === true,
          rolledBack: activation?.rolledBack,
        };
        if (activation?.ok === true) {
          this.logRun(run, 'info', '运行时隧道已就绪: ' + String(activation.origin ?? '') + (activation.port ? ' (bridge 端口 ' + String(activation.port) + ')' : '') + (activation.unchanged === true ? '（配置未变化，未重连）' : ''));
          this.logRun(run, 'info', '无需重载插件：手机可直接扫「服务器配置」二维码配对。');
        } else {
          this.logRun(run, 'warn', '运行时隧道激活失败: ' + String(activation?.error ?? 'unknown') + '（可点「激活连接」重试；仍失败请重启 DSH）' + (activation?.rolledBack === true ? '；已回退到旧隧道配置' : ''));
        }
      } catch (error) {
        run.result.tunnelActivation = { ok: false, state: 'error', origin: null, port: null, error: String(error?.message ?? error) };
        this.logRun(run, 'warn', '运行时隧道激活异常: ' + String(error?.message ?? error) + '（可点「激活连接」重试；仍失败请重启 DSH）');
      }
    } else {
      this.logRun(run, 'warn', '无运行时隧道接口（headless 模式）：重载插件或重启 DSH 后公网隧道生效。');
    }
    this.setStep(run, 'finalize', 'ok', '配置已写入本机');
    this.logRun(run, 'info', 'App「服务器配置」（扫码/粘贴）: ' + installed.appConfig);
    this.logRun(run, 'info', '本机 tunnel 配置已写入 ' + installed.tunnelStateFile + '，secret 文件 ' + installed.secretFile + '（0600）。');
  }

  // -------------------------------------------------------------------------
  // Failure / rollback / housekeeping
  // -------------------------------------------------------------------------

  /** @param {DeployRun} run @param {unknown} error */
  async fail(run, error) {
    const normalized = toDeployError(error, CODES.sshCommandFailed);
    const cancelled = run.cancelled === true || normalized.code === CODES.deployCancelled;
    run.error = normalized.toJSON();
    if (cancelled) {
      run.state = 'cancelled';
      this.logRun(run, 'warn', '部署已取消' + (run.installAttempted === true ? '，正在回滚本次新增资源…' : ''));
    } else {
      run.state = 'failed';
      this.logRun(run, 'error', '部署失败: [' + normalized.code + '] ' + normalized.message + (normalized.hint === undefined ? '' : ' — ' + normalized.hint));
    }
    try {
      await this.rollback(run);
    } catch (rollbackError) {
      run.rollback = { ok: false, error: String(rollbackError?.message ?? rollbackError) };
      this.logRun(run, 'error', '回滚失败: ' + String(rollbackError?.message ?? rollbackError) + '（请人工检查服务器上的 dshm-relay 资源）');
    }
    run.done = true;
    this.finish(run);
  }

  /** @param {DeployRun} run */
  async rollback(run) {
    if (run.installAttempted !== true) {
      // Nothing was created; still clear the remote temp dir if any.
      if (run.layout !== undefined && run.transport !== undefined) await cleanupRemoteTemp({ transport: run.transport, layout: run.layout });
      run.rollback = { ok: true, skipped: true, reason: '尚未开始安装，无需回滚' };
      this.setStep(run, run.currentStepId ?? 'install', 'failed');
      return;
    }
    const isFresh = run.plan?.mode !== 'upgrade' && run.facts?.existingRelay?.installed !== true;
    if (isFresh === true) {
      const had = {
        user: run.facts?.existingRelay?.userPresent === true,
        configDir: run.facts?.existingRelay?.configDirPresent === true,
        dataDir: run.facts?.existingRelay?.dataDirPresent === true,
        binary: run.facts?.existingRelay?.binPresent === true,
        config: run.facts?.existingRelay?.configPresent === true,
        unit: run.facts?.existingRelay?.unitFilePresent === true,
      };
      this.logRun(run, 'warn', '回滚本次新增（只删除本次创建的资源，不动既有服务）');
      const result = await rollbackFreshInstall({ transport: run.transport, layout: run.layout, had, log: (level, text) => this.logRun(run, level, text) });
      run.rollback = result;
      this.logRun(run, result.ok ? 'info' : 'error', result.ok ? '回滚完成：本次新增的 unit/文件/用户已清理' : '回滚未完全成功，请查看上方日志');
    } else {
      this.logRun(run, 'warn', '升级失败：服务器端安装脚本已尝试恢复旧二进制；本次不删除既有配置/证书/secret/state');
      if (run.layout !== undefined) await cleanupRemoteTemp({ transport: run.transport, layout: run.layout });
      run.rollback = { ok: true, skipped: true, reason: 'upgrade: installer restored previous binary' };
    }
  }

  /** Persist and detach the finished run. */
  finish(run) {
    run.updatedAt = this.now();
    run.prompt = undefined;
    if (run.waiting !== undefined) {
      const waiting = run.waiting;
      run.waiting = undefined;
      waiting.reject(new DeployError(CODES.deployCancelled, '部署结束'));
    }
    try {
      run.transport?.dispose?.();
    } catch {
      /* best effort */
    }
    run.transport = undefined;
    this.persist(run);
    this.last = run;
    this.active = run;
  }

  /** Persist a secret-free summary for the next UI session. */
  persist(run) {
    try {
      const payload = {
        version: 1,
        deployId: run.id,
        state: run.state,
        startedAt: run.createdAt,
        updatedAt: run.updatedAt,
        steps: run.steps,
        error: run.error,
        result: run.result,
        rollback: run.rollback,
        input: run.publicInput,
      };
      writeFileAtomic(this.paths.lastDeployFile, JSON.stringify(payload, null, 2) + '\n', 0o600);
    } catch (error) {
      this.logRun(run, 'warn', '写入上次部署摘要失败: ' + String(error?.message ?? error));
    }
  }

  /** Read the persisted last deploy (secret-free). */
  lastPayload() {
    try {
      const parsed = JSON.parse(readFileSync(this.paths.lastDeployFile, 'utf8'));
      if (parsed === null || typeof parsed !== 'object') return undefined;
      return { deployId: parsed.deployId, state: parsed.state, steps: parsed.steps, error: parsed.error, result: parsed.result, rollback: parsed.rollback, input: parsed.input, startedAt: parsed.startedAt, updatedAt: parsed.updatedAt, logs: [], cursor: 0 };
    } catch {
      return undefined;
    }
  }

  /** Append one masked log line (ring buffered). */
  logRun(run, level, text) {
    const masked = run.masker.mask(String(text ?? ''));
    run.updatedAt = this.now();
    for (const line of masked.split(/\r?\n/)) {
      if (line.length === 0) continue;
      run.seq += 1;
      run.logs.push({ seq: run.seq, ts: this.now(), level: level === 'debug' ? 'debug' : level, text: line.slice(0, 4000) });
    }
    if (run.logs.length > LOG_RING_LIMIT) run.logs.splice(0, run.logs.length - LOG_RING_LIMIT);
    this.log(level, '[deploy ' + run.id.slice(0, 8) + '] ' + masked);
  }

  /** Update a step status. */
  setStep(run, id, status, detail) {
    run.currentStepId = id;
    const step = run.steps.find((entry) => entry.id === id);
    if (step === undefined) return;
    step.status = status;
    if (detail !== undefined) step.detail = detail;
  }

  /** Throw a stable cancellation error when the user cancelled. */
  checkCancelled(run) {
    if (run.cancelled === true) throw new DeployError(CODES.deployCancelled, '部署已取消');
  }

  /**
   * Activate the persisted (last deployed) tunnel config at runtime.
   * Idempotent: repeated calls are cheap when the target is already ready.
   * Explicit `body` values (controlOrigin/pin/secret/secretFile) override the
   * persisted state — no secret is ever returned to the caller.
   */
  async activatePersistedTunnel(body = {}) {
    if (this.tunnelActivator === undefined) {
      return { ok: false, error: 'deploy/tunnel-unavailable', message: '当前运行模式不支持运行时激活（headless CLI）；请使用桌面插件或在部署后重载插件/重启 DSH' };
    }
    const persisted = readTunnelState({ dataDir: this.dataDir });
    const state = persisted.ok === true ? persisted.state : undefined;
    const controlOrigin = typeof body?.controlOrigin === 'string' && body.controlOrigin.length > 0 ? body.controlOrigin : state?.controlOrigin;
    const pin = typeof body?.pin === 'string' && body.pin.length > 0 ? body.pin : state?.pin;
    if (typeof controlOrigin !== 'string' || typeof pin !== 'string' || controlOrigin.length === 0 || pin.length === 0) {
      return { ok: false, error: 'deploy/no-tunnel-config', message: '本机还没有部署生成的 tunnel 配置，请先完成一次部署' };
    }
    let secret = typeof body?.secret === 'string' && body.secret.length > 0 ? body.secret : undefined;
    const secretFile = typeof body?.secretFile === 'string' && body.secretFile.length > 0 ? body.secretFile : state?.secretFile;
    if (secret === undefined && typeof secretFile === 'string' && secretFile.length > 0) {
      try {
        const value = readFileSync(secretFile, 'utf8').trim();
        if (value.length >= 16) secret = value;
      } catch {
        /* fall through to error below */
      }
    }
    if (secret === undefined) {
      return { ok: false, error: 'deploy/tunnel-secret-missing', message: '找不到 tunnel secret 文件，无法运行时激活；请重新部署或检查 ' + String(secretFile ?? '<unset>') };
    }
    try {
      const activation = await this.tunnelActivator({
        controlOrigin,
        pin,
        secret,
        secretFile,
        ...(Number.isInteger(body?.wantPort) && body.wantPort > 0 ? { wantPort: body.wantPort } : {}),
        timeoutMs: Number.isInteger(body?.timeoutMs) ? body.timeoutMs : 15_000,
      });
      const payload = {
        ok: activation?.ok === true,
        state: activation?.state,
        origin: activation?.origin ?? null,
        port: activation?.port ?? null,
        pin,
        error: activation?.error,
        unchanged: activation?.unchanged === true,
        rolledBack: activation?.rolledBack,
        restoredState: activation?.restoredState,
        current: activation?.current ?? null,
      };
      if (payload.ok !== true) {
        return { ok: false, error: 'deploy/tunnel-activate-failed', message: String(activation?.error ?? '运行时激活失败'), data: payload };
      }
      return { ok: true, data: payload };
    } catch (error) {
      return { ok: false, error: 'deploy/tunnel-activate-failed', message: String(error?.message ?? error) };
    }
  }

  /** Plugin dispose: cancel an in-flight deploy and drop credentials. */
  dispose() {
    const run = this.active;
    if (run !== undefined && run.done !== true) {
      run.cancelled = true;
      if (run.waiting !== undefined) {
        const waiting = run.waiting;
        run.waiting = undefined;
        run.prompt = undefined;
        waiting.reject(new DeployError(CODES.deployCancelled, '部署已取消（插件卸载）'));
      }
      try {
        run.transport?.dispose?.();
      } catch {
        /* best effort */
      }
    }
  }
}

/** @typedef {ReturnType<DeployEngine['status']> & Record<string, any>} DeployRun */

/**
 * Coerce an arbitrary action body from the UI into a boolean-ish value for
 * advanced checkboxes (the UI sends real booleans; this guards string "true").
 */
export function asBool(value) {
  return value === true || value === 'true' || value === 1;
}
