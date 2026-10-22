/**
 * ssh.js — the SSH transport used by the one-click relay deploy engine.
 *
 * Design constraints (M2b-1):
 *   - No new npm dependencies: drives the system `ssh`, `scp` and `ssh-keyscan`
 *     binaries. On macOS these ship with OpenSSH (verified: OpenSSH_10.3p1).
 *   - Two auth modes, both user-decided:
 *       key      -> `-i <path> -o IdentitiesOnly=yes -o BatchMode=yes`
 *       password -> `SSH_ASKPASS_REQUIRE=force` + a 0700 askpass script that
 *                   reads the password from an environment variable. The
 *                   password is never in argv, never on disk, never logged.
 *   - Host key trust is plugin-private: we scan with `ssh-keyscan`, show the
 *     SHA256 fingerprint to the user, and write our own known_hosts file under
 *     `<plugin-data>/dsh-m-link/deploy/known_hosts` with
 *     `StrictHostKeyChecking=yes` + `GlobalKnownHostsFile=/dev/null`. The user's
 *     `~/.ssh/known_hosts` is never touched (m2b-plan §2.2/§2.3).
 *
 * The module is split into pure helpers (arg construction, keyscan parsing,
 * known_hosts bookkeeping) and the stateful `SshTransport`. Everything that
 * spawns a process goes through an injectable `runner` so `test/m2b-deploy.mjs`
 * can drive the engine without a server (fake SSH runner).
 */

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { CODES, DeployError, toDeployError } from './errors.js';

export const DEFAULT_TIMEOUT_MS = 30_000;
export const CONNECT_TIMEOUT_SEC = 10;

/** Key type preference when a host offers several. */
export const PREFERRED_KEY_TYPES = ['ssh-ed25519', 'ecdsa-sha2-nistp256', 'rsa-sha2-256', 'ssh-rsa'];

/**
 * Build the `ssh` argv for one command.
 *
 * @param {{
 *   host: string, port: number, user: string,
 *   auth: 'key'|'password',
 *   identityFile?: string,
 *   knownHostsFile: string,
 *   connectTimeoutSec?: number,
 * }} options
 * @returns {string[]}
 */
export function buildSshArgs(options) {
  const args = [
    '-p',
    String(options.port),
    '-o',
    'ConnectTimeout=' + String(options.connectTimeoutSec ?? CONNECT_TIMEOUT_SEC),
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'UserKnownHostsFile=' + options.knownHostsFile,
    '-o',
    'GlobalKnownHostsFile=/dev/null',
    '-o',
    'ControlMaster=no',
    '-o',
    'ControlPath=none',
    '-o',
    'LogLevel=ERROR',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=3',
  ];
  if (options.auth === 'password') {
    args.push(
      '-o',
      'BatchMode=no',
      '-o',
      'NumberOfPasswordPrompts=1',
      '-o',
      'PreferredAuthentications=password,keyboard-interactive',
      '-o',
      'PubkeyAuthentication=no',
    );
  } else {
    args.push('-i', String(options.identityFile), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=publickey');
  }
  args.push((options.user ?? 'root') + '@' + options.host);
  return args;
}

/**
 * Build the `scp` argv for one upload.
 *
 * @param {{host: string, port: number, localPath: string, remotePath: string,
 *   auth: 'key'|'password', identityFile?: string, knownHostsFile: string}} options
 * @returns {string[]}
 */
export function buildScpArgs(options) {
  const args = [
    '-q',
    '-P',
    String(options.port),
    '-o',
    'ConnectTimeout=' + String(CONNECT_TIMEOUT_SEC),
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'UserKnownHostsFile=' + options.knownHostsFile,
    '-o',
    'GlobalKnownHostsFile=/dev/null',
    '-o',
    'ControlMaster=no',
    '-o',
    'ControlPath=none',
    '-o',
    'LogLevel=ERROR',
  ];
  if (options.auth === 'password') {
    args.push(
      '-o',
      'BatchMode=no',
      '-o',
      'NumberOfPasswordPrompts=1',
      '-o',
      'PreferredAuthentications=password,keyboard-interactive',
      '-o',
      'PubkeyAuthentication=no',
    );
  } else {
    args.push('-i', String(options.identityFile), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=publickey');
  }
  args.push(options.localPath, (options.user ?? 'root') + '@' + options.host + ':' + options.remotePath);
  return args;
}

/**
 * Parse `ssh-keyscan` output into candidate host keys, preferred type first.
 * @param {string} output
 * @returns {{hostPart: string, keyType: string, keyBase64: string, fingerprint: string, raw: string}[]}
 */
export function parseKeyscanOutput(output) {
  /** @type {{hostPart: string, keyType: string, keyBase64: string, fingerprint: string, raw: string}[]} */
  const entries = [];
  for (const rawLine of String(output ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 3) continue;
    const [hostPart, keyType, keyBase64] = parts;
    if (!keyBase64 || keyType.length === 0 || hostPart.length === 0) continue;
    entries.push({ hostPart, keyType, keyBase64, fingerprint: keyFingerprint(keyBase64), raw: line });
  }
  entries.sort((a, b) => keyTypeRank(a.keyType) - keyTypeRank(b.keyType));
  return entries;
}

/** Rank a key type for preference ordering (lower = preferred). */
export function keyTypeRank(keyType) {
  const index = PREFERRED_KEY_TYPES.indexOf(keyType);
  return index === -1 ? PREFERRED_KEY_TYPES.length + 1 : index;
}

/**
 * OpenSSH-style SHA256 fingerprint (`SHA256:<base64 without padding>`) of a
 * base64-encoded public key blob. Matches `ssh-keygen -lf`.
 * @param {string} keyBase64
 */
export function keyFingerprint(keyBase64) {
  const blob = Buffer.from(keyBase64, 'base64');
  const digest = createHash('sha256').update(blob).digest('base64').replace(/=+$/u, '');
  return 'SHA256:' + digest;
}

/** Expected known_hosts host field for (host, port). */
export function knownHostsHostPart(host, port) {
  return port === 22 ? host : '[' + host + ']:' + String(port);
}

/**
 * Parse an existing known_hosts file into `hostPart -> Map<keyType, keyBase64>`.
 * @param {string} text
 */
export function parseKnownHosts(text) {
  /** @type {Map<string, Map<string, string>>} */
  const map = new Map();
  for (const rawLine of String(text ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 3) continue;
    const [hostPart, keyType, keyBase64] = parts;
    if (!map.has(hostPart)) map.set(hostPart, new Map());
    map.get(hostPart).set(keyType, keyBase64);
  }
  return map;
}

/**
 * Decide what to do with a scanned host key against the plugin-private
 * known_hosts content. Pure so the engine/test can reason about trust.
 *
 * @param {{knownHostsText: string, hostPart: string, candidates: {keyType: string, keyBase64: string, fingerprint: string}[]}} options
 * @returns {{status: 'trusted'|'unknown'|'mismatch', fingerprint?: string, keyType?: string, knownFingerprints?: string[]}}
 */
export function classifyHostKey({ knownHostsText, hostPart, candidates }) {
  const candidate = candidates[0];
  if (candidate === undefined) return { status: 'unknown' };
  const known = parseKnownHosts(knownHostsText).get(hostPart);
  if (known === undefined || known.size === 0) {
    return { status: 'unknown', fingerprint: candidate.fingerprint, keyType: candidate.keyType };
  }
  const knownFingerprints = [...known.values()].map((keyBase64) => keyFingerprint(keyBase64));
  const candidateFingerprints = new Set(candidates.map((entry) => entry.fingerprint));
  if (knownFingerprints.some((fingerprint) => candidateFingerprints.has(fingerprint))) {
    return { status: 'trusted', fingerprint: candidate.fingerprint, keyType: candidate.keyType };
  }
  return { status: 'mismatch', fingerprint: candidate.fingerprint, keyType: candidate.keyType, knownFingerprints };
}

/** Serialize the chosen candidate as a known_hosts line (comment stripped). */
export function knownHostsLineFor(candidate, hostPart) {
  return hostPart + ' ' + candidate.keyType + ' ' + candidate.keyBase64;
}

/**
 * Rewrite a known_hosts content so it holds exactly `line` for `hostPart`.
 * @param {string} text
 * @param {string} hostPart
 * @param {string} line
 */
export function replaceKnownHostsEntry(text, hostPart, line) {
  const kept = String(text ?? '')
    .split(/\r?\n/)
    .filter((rawLine) => {
      const trimmed = rawLine.trim();
      if (trimmed.length === 0) return false;
      if (trimmed.startsWith('#')) return true;
      const candidateHost = trimmed.split(/\s+/)[0];
      return candidateHost !== hostPart;
    })
    .filter((rawLine) => rawLine.trim().length > 0);
  kept.push(line);
  return kept.join('\n') + '\n';
}

/** Single-quote a string for POSIX sh. */
export function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

/**
 * Default process runner: spawn without a shell, collect stdout/stderr, write
 * optional stdin, kill on timeout. Resolves (never rejects) with
 * `{code, stdout, stderr, timedOut, command, args}`.
 *
 * @param {{command: string, args: string[], env?: Record<string,string>, stdin?: string, timeoutMs?: number}} request
 */
export function createProcessRunner() {
  return {
    async run(request) {
      const timeoutMs = request.timeoutMs ?? DEFAULT_TIMEOUT_MS;
      return await new Promise((resolve) => {
        /** @type {import('node:child_process').ChildProcessWithoutNullStreams} */
        let child;
        const chunks = { stdout: [], stderr: [] };
        let settled = false;
        let timedOut = false;
        const finish = (code) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve({
            code: code ?? -1,
            stdout: Buffer.concat(chunks.stdout).toString('utf8'),
            stderr: Buffer.concat(chunks.stderr).toString('utf8'),
            timedOut,
            command: request.command,
            args: request.args ?? [],
          });
        };
        const timer = setTimeout(() => {
          timedOut = true;
          try {
            child.kill('SIGKILL');
          } catch {
            /* already gone */
          }
        }, timeoutMs);
        try {
          child = spawn(request.command, request.args ?? [], {
            env: { ...process.env, ...(request.env ?? {}) },
            stdio: ['pipe', 'pipe', 'pipe'],
          });
        } catch (error) {
          clearTimeout(timer);
          resolve({ code: -1, stdout: '', stderr: String(error?.message ?? error), timedOut: false, command: request.command, args: request.args ?? [] });
          return;
        }
        child.stdout.on('data', (chunk) => chunks.stdout.push(chunk));
        child.stderr.on('data', (chunk) => chunks.stderr.push(chunk));
        child.on('error', (error) => {
          chunks.stderr.push(Buffer.from(String(error?.message ?? error)));
          finish(-1);
        });
        child.on('close', (code) => finish(code));
        if (typeof request.stdin === 'string' && request.stdin.length > 0) {
          try {
            child.stdin.end(request.stdin);
          } catch {
            /* child already exited */
          }
        } else {
          try {
            child.stdin.end();
          } catch {
            /* child already exited */
          }
        }
      });
    },
  };
}

/**
 * SshTransport — one SSH connection configuration plus the convenience methods
 * the deploy engine needs (exec / sudo exec / upload / host-key trust / dispose).
 *
 * Nothing here retries SSH itself: the engine owns the state machine and turns
 * a classified failure into a user-actionable error instead of looping.
 */
export class SshTransport {
  /**
   * @param {{
   *   host: string,
   *   port?: number,
   *   user?: string,
   *   auth?: 'key'|'password',
   *   privateKey?: string,
   *   password?: string,
   *   workDir: string,
   *   knownHostsFile: string,
   *   runner?: ReturnType<typeof createProcessRunner>,
   *   bins?: {ssh?: string, scp?: string, keyscan?: string},
   *   log?: (level: 'info'|'warn'|'error', text: string) => void,
   *   masker?: {mask: (text: string) => string},
   *   logger?: {add: (value: unknown) => unknown},
   * }} options
   */
  constructor(options) {
    if (typeof options?.host !== 'string' || options.host.length === 0) throw new DeployError(CODES.inputInvalid, '服务器地址为空');
    this.host = options.host;
    this.port = Number.isInteger(options.port) && options.port > 0 && options.port < 65536 ? options.port : 22;
    this.user = typeof options.user === 'string' && options.user.length > 0 ? options.user : 'root';
    this.auth = options.auth === 'password' ? 'password' : 'key';
    if (this.auth === 'password' && (typeof options.password !== 'string' || options.password.length === 0)) {
      throw new DeployError(CODES.inputInvalid, '认证方式为密码，但密码为空');
    }
    if (this.auth === 'key' && (typeof options.privateKey !== 'string' || options.privateKey.trim().length === 0)) {
      throw new DeployError(CODES.inputInvalid, '认证方式为私钥文件，但私钥内容为空');
    }
    this.password = this.auth === 'password' ? options.password : undefined;
    this._privateKey = this.auth === 'key' ? options.privateKey : undefined;
    this.workDir = options.workDir;
    this.knownHostsFile = options.knownHostsFile;
    this.runner = options.runner ?? createProcessRunner();
    this.bins = { ssh: options.bins?.ssh ?? 'ssh', scp: options.bins?.scp ?? 'scp', keyscan: options.bins?.keyscan ?? 'ssh-keyscan' };
    this.log = options.log ?? (() => {});
    this.masker = options.masker ?? { mask: (text) => String(text) };
    if (typeof options.logger?.add === 'function') options.logger.add(this.password);
    /** Filled by preflight: uid 0 vs sudo -n available. */
    this.privilege = { isRoot: false, sudoOk: false, sudoPassword: this.auth === 'password' };
    this.disposed = false;
    this.identityFile = undefined;
    this.askpassFile = undefined;
    this.counters = { exec: 0, upload: 0, scan: 0 };
    this.prepareCredentials();
  }

  /** Materialize the private key file (0600) / askpass script (0700). */
  prepareCredentials() {
    mkdirSync(this.workDir, { recursive: true, mode: 0o700 });
    try {
      chmodSync(this.workDir, 0o700);
    } catch {
      /* best effort */
    }
    if (this.auth === 'key') {
      const keyPath = join(this.workDir, 'id_deploy');
      writeFileSync(keyPath, this._privateKey, { mode: 0o600 });
      this.identityFile = keyPath;
      return;
    }
    const askpass = join(this.workDir, 'askpass.sh');
    writeFileSync(askpass, '#!/bin/sh\nprintf \'%s\\n\' "${DSHM_SSH_PASSWORD}"\n', { mode: 0o700 });
    this.askpassFile = askpass;
  }

  /** Environment for ssh/scp children (password mode: askpass only). */
  childEnv() {
    if (this.auth !== 'password') return {};
    return {
      SSH_ASKPASS: this.askpassFile,
      SSH_ASKPASS_REQUIRE: 'force',
      DSHM_SSH_PASSWORD: this.password,
      DISPLAY: process.env.DISPLAY ?? 'dshm:0',
    };
  }

  sshArgs() {
    return buildSshArgs({
      host: this.host,
      port: this.port,
      user: this.user,
      auth: this.auth,
      identityFile: this.identityFile,
      knownHostsFile: this.knownHostsFile,
    });
  }

  scpArgs(localPath, remotePath) {
    return buildScpArgs({
      host: this.host,
      port: this.port,
      // Regression: the scp target must use the configured login user, not
      // buildScpArgs' `root` default — a non-root deployment failed upload with
      // `scp: Connection closed` because the binary went to root@host.
      user: this.user,
      auth: this.auth,
      identityFile: this.identityFile,
      knownHostsFile: this.knownHostsFile,
      localPath,
      remotePath,
    });
  }

  /** Replace the private key material (engine/tests may set it after construction). */
  setPrivateKey(pem) {
    this._privateKey = pem;
    if (this.identityFile !== undefined) writeFileSync(this.identityFile, pem, { mode: 0o600 });
  }

  /**
   * Scan the host key. Returns `{candidates, status, knownHostsText}` where
   * status is trusted / unknown / mismatch against the plugin known_hosts file.
   */
  async scanHostKey() {
    this.counters.scan += 1;
    const args = ['-p', String(this.port), '-T', '5', '-t', PREFERRED_KEY_TYPES.join(',')];
    // ssh-keyscan wants `[host]:port` for non-default ports? No: -p handles it.
    args.push(this.host);
    const result = await this.runner.run({ command: this.bins.keyscan, args, timeoutMs: 15_000 });
    if (result.code !== 0 && result.stdout.trim().length === 0) {
      const detail = this.masker.mask((result.stderr ?? '').trim()).slice(0, 400);
      throw new DeployError(CODES.sshUnreachable, '无法读取服务器主机指纹（ssh-keyscan 失败）', {
        hint: '确认服务器地址、SSH 端口正确且网络可达；主机指纹扫描使用 22/自定义端口的 TCP 探测。',
        detail: detail || 'ssh-keyscan exit ' + String(result.code),
      });
    }
    const candidates = parseKeyscanOutput(result.stdout);
    if (candidates.length === 0) {
      throw new DeployError(CODES.sshUnreachable, '服务器没有返回可用的 SSH 主机公钥', { detail: this.masker.mask((result.stderr ?? '').trim()).slice(0, 400) });
    }
    const knownHostsText = this.readKnownHosts();
    const hostPart = knownHostsHostPart(this.host, this.port);
    const classification = classifyHostKey({ knownHostsText, hostPart, candidates });
    return { candidates, hostPart, knownHostsText, ...classification };
  }

  readKnownHosts() {
    try {
      return readFileSync(this.knownHostsFile, 'utf8');
    } catch {
      return '';
    }
  }

  /**
   * Persist trust for a scanned host key.
   * @param {{hostPart: string, keyType: string, keyBase64: string}} candidate
   * @param {{acceptNew?: boolean}} [options]
   */
  trustHostKey(candidate, options = {}) {
    const text = this.readKnownHosts();
    const classification = classifyHostKey({ knownHostsText: text, hostPart: candidate.hostPart ?? knownHostsHostPart(this.host, this.port), candidates: [candidate] });
    if (classification.status === 'mismatch' && options.acceptNew !== true) {
      throw new DeployError(CODES.sshHostKeyMismatch, '服务器主机指纹与上次部署记录不一致（可能存在中间人，或服务器重装/换钥）', {
        hint: '如确认服务器重装过，请在高级选项里选择「信任新指纹」后重试。',
        detail: '旧指纹: ' + String(classification.knownFingerprints?.join(', ')) + ' / 新指纹: ' + String(candidate.fingerprint),
      });
    }
    const hostPart = candidate.hostPart ?? knownHostsHostPart(this.host, this.port);
    const line = knownHostsLineFor(candidate, hostPart);
    const next = replaceKnownHostsEntry(text === '' ? '' : text, hostPart, line);
    mkdirSync(join(this.knownHostsFile, '..'), { recursive: true, mode: 0o700 });
    const tmp = this.knownHostsFile + '.tmp';
    writeFileSync(tmp, next, { mode: 0o600 });
    // Atomic replace keeps a crashed deploy from corrupting the trust store.
    renameSync(tmp, this.knownHostsFile);
    return { fingerprint: candidate.fingerprint, keyType: candidate.keyType, changed: classification.status !== 'trusted' };
  }

  /** Forget the trusted key for this host (used by the UI "Forget host key" action). */
  forgetHostKey() {
    const text = this.readKnownHosts();
    const hostPart = knownHostsHostPart(this.host, this.port);
    const kept = text
      .split(/\r?\n/)
      .filter((rawLine) => {
        const trimmed = rawLine.trim();
        if (trimmed.length === 0) return false;
        if (trimmed.startsWith('#')) return true;
        return trimmed.split(/\s+/)[0] !== hostPart;
      });
    writeFileSync(this.knownHostsFile, kept.length === 0 ? '' : kept.join('\n') + '\n', { mode: 0o600 });
  }

  /** Log one masked line through the engine logger. */
  logLine(level, text) {
    this.log(level, this.masker.mask(text));
  }

  /**
   * Run a remote command.
   * @param {string} command
   * @param {{timeoutMs?: number, allowFailure?: boolean, stdin?: string, sensitive?: boolean, label?: string}} [options]
   * @returns {Promise<{code: number, stdout: string, stderr: string, timedOut: boolean}>}
   */
  async exec(command, options = {}) {
    this.counters.exec += 1;
    const label = options.label ?? command.split('\n')[0].slice(0, 120);
    this.logLine('info', 'ssh ' + this.user + '@' + this.host + ' > ' + label);
    const args = this.sshArgs();
    args.push(command);
    const result = await this.runner.run({
      command: this.bins.ssh,
      args,
      env: this.childEnv(),
      stdin: options.stdin,
      timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    });
    if (!options.sensitive) {
      for (const line of (result.stdout ?? '').split(/\r?\n/u)) {
        const trimmed = line.trim();
        if (trimmed.length > 0) this.logLine('debug', '  ' + trimmed.slice(0, 2000));
      }
      for (const line of (result.stderr ?? '').split(/\r?\n/u)) {
        const trimmed = line.trim();
        if (trimmed.length > 0) this.logLine(result.code === 0 ? 'debug' : 'warn', '  ' + trimmed.slice(0, 2000));
      }
    } else {
      this.logLine('debug', '  (sensitive output omitted, ' + String((result.stdout ?? '').length) + ' bytes)');
    }
    if (result.timedOut === true) {
      throw new DeployError(CODES.sshUnreachable, 'SSH 命令超时（' + String(options.timeoutMs ?? DEFAULT_TIMEOUT_MS) + 'ms）', { hint: '检查服务器负载与网络；必要时重试部署。', detail: label });
    }
    if (result.code !== 0 && options.allowFailure !== true) {
      throw this.classifyFailure(result, label);
    }
    return { code: result.code, stdout: result.stdout ?? '', stderr: result.stderr ?? '', timedOut: false };
  }

  /** Classify an ssh/scp failure into a stable deploy error. */
  classifyFailure(result, label) {
    const stderr = String(result.stderr ?? '');
    const text = stderr.toLowerCase();
    const detail = this.masker.mask(stderr.trim()).slice(0, 800);
    if (text.includes('host key verification failed') || text.includes('remote host identification has changed')) {
      return new DeployError(CODES.sshHostKeyMismatch, 'SSH 主机指纹校验失败', {
        hint: '服务器指纹与记录不一致。如确认服务器重装过，请在高级选项信任新指纹后重试。',
        detail,
      });
    }
    if (text.includes('permission denied') || text.includes('no supported authentication methods')) {
      return new DeployError(CODES.sshAuthFailed, 'SSH 认证失败（用户名 / 私钥 / 密码不正确）', {
        hint: '确认登录用户与认证方式；密码认证需要服务器允许 PasswordAuthentication。',
        detail,
      });
    }
    if (text.includes('connection refused') || text.includes('connection timed out') || text.includes('operation timed out') || text.includes('no route to host') || text.includes('could not resolve hostname') || text.includes('network is unreachable')) {
      return new DeployError(CODES.sshUnreachable, '无法连接到服务器 SSH 端口', {
        hint: '确认服务器地址、SSH 端口（默认 22）正确，且服务器安全组/防火墙放行该端口。',
        detail,
      });
    }
    if (text.includes('sudo: a password is required') || text.includes('no tty present')) {
      return new DeployError(CODES.hostNoSudo, '当前用户无法免密 sudo，且引擎没有可用的提权方式', {
        hint: '请使用 root 用户，或给该用户配置 sudo 免密（NOPASSWD）。',
        detail,
      });
    }
    return new DeployError(CODES.sshCommandFailed, '服务器命令执行失败（退出码 ' + String(result.code) + '）', { detail: detail || label });
  }

  /**
   * Run a command with root privileges (no-op prefix when the user already is
   * root). The caller must have run preflight so `privilege` is filled.
   */
  async execRoot(command, options = {}) {
    const stdin = this.privilege.isRoot ? options.stdin : this.auth === 'password' ? this.password + '\n' : options.stdin;
    const wrapped = this.privilege.isRoot ? command : this.buildSudoCommand(command);
    return this.exec(wrapped, { ...options, stdin });
  }

  /** Build the sudo invocation for the current privilege mode. */
  buildSudoCommand(command) {
    if (this.privilege.sudoPassword) return 'sudo -S -p "" -- sh -c ' + shellQuote(command);
    return 'sudo -n -- sh -c ' + shellQuote(command);
  }

  /**
   * Upload one local file via scp.
   * @param {string} localPath
   * @param {string} remotePath
   */
  async upload(localPath, remotePath) {
    this.counters.upload += 1;
    this.logLine('info', 'scp ' + localPath + ' -> ' + this.user + '@' + this.host + ':' + remotePath);
    const result = await this.runner.run({
      command: this.bins.scp,
      args: this.scpArgs(localPath, remotePath),
      env: this.childEnv(),
      timeoutMs: 120_000,
    });
    if (result.code !== 0) throw this.classifyFailure(result, 'scp ' + localPath);
    return { bytes: existsSync(localPath) ? readFileSync(localPath).length : 0 };
  }

  /** Set the root/sudo capabilities discovered by preflight. */
  setPrivilege({ isRoot, sudoOk }) {
    this.privilege = { isRoot: isRoot === true, sudoOk: sudoOk === true, sudoPassword: this.auth === 'password' };
  }

  /** Remove temp credentials and per-deploy working state. */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.password = undefined;
    this._privateKey = undefined;
    try {
      rmSync(this.workDir, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }
}

/**
 * Forget the trusted key for (host, port) in a known_hosts file without needing
 * a transport/credentials. Returns true when an entry was removed.
 * @param {string} knownHostsFile
 * @param {string} host
 * @param {number} port
 */
export function forgetKnownHostKey(knownHostsFile, host, port) {
  const hostPart = knownHostsHostPart(host, port);
  let text = '';
  try {
    text = readFileSync(knownHostsFile, 'utf8');
  } catch {
    return false;
  }
  const kept = text.split(/\r?\n/).filter((rawLine) => {
    const trimmed = rawLine.trim();
    if (trimmed.length === 0) return false;
    if (trimmed.startsWith('#')) return true;
    return trimmed.split(/\s+/)[0] !== hostPart;
  });
  const hadEntry = kept.length !== text.split(/\r?\n/).filter((line) => line.trim().length > 0).length;
  writeFileSync(knownHostsFile, kept.length === 0 ? '' : kept.join('\n') + '\n', { mode: 0o600 });
  return hadEntry;
}

/** Create a temp working directory for one deploy attempt. */
export function makeDeployWorkDir(baseDir, id) {
  mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const dir = mkdtempSync(join(baseDir, 'run-' + String(id).slice(0, 8) + '-'));
  return dir;
}

/** Map a raw error from spawn-level failures (e.g. ssh binary missing). */
export function mapTransportBootstrapError(error) {
  const normalized = toDeployError(error);
  if (normalized.code === 'ENOENT' || String(normalized.cause?.code ?? '') === 'ENOENT') {
    return new DeployError(CODES.hostMissingTools, '本机找不到 ssh / scp 可执行文件', { hint: 'macOS 自带 OpenSSH；检查 PATH 是否被裁剪后重试。' });
  }
  return normalized;
}
