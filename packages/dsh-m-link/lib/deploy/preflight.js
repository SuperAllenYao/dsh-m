/**
 * preflight.js — remote host discovery and deployment planning.
 *
 * One batched SSH command gathers everything the engine needs (OS/arch,
 * systemd, memory/disk, listening TCP ports, an existing dshm-relay install,
 * available CLI tools, uid/sudo). Parsing is pure so the unit tests can replay
 * the exact text captured from the acceptance server.
 *
 * Everything is read-only: preflight never changes the server.
 */

import { CODES, DeployError } from './errors.js';
import {
  parseBridgeRangeFromConfig,
  parseControlPortFromListen,
  parseListeningPorts,
  parsePortRange,
  parsePublicHostFromConfig,
  pickBridgeRange,
  pickControlPort,
} from './ports.js';

/** Marker-delimited probe script (POSIX sh; run as the SSH login user). */
export const PREFLIGHT_SCRIPT = String.raw`
echo "@@uname"; uname -sm 2>/dev/null
echo "@@os"; cat /etc/os-release 2>/dev/null | head -8
echo "@@kernel"; uname -r 2>/dev/null
echo "@@id"; id -u 2>/dev/null; id -un 2>/dev/null
echo "@@systemd"; systemctl --version 2>/dev/null | head -1; test -d /run/systemd/system && echo "systemd_dir=yes" || echo "systemd_dir=no"
echo "@@mem"; grep -E '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}'
echo "@@disk"; df -Pk / 2>/dev/null | awk 'NR==2 {print $4}'
echo "@@listen"; (ss -lntH 2>/dev/null || netstat -lnt 2>/dev/null) | head -200
echo "@@relay"
command -v systemctl >/dev/null 2>&1 && { unit=$(systemctl show dshm-relay -p FragmentPath --value 2>/dev/null); echo "unitPath=$unit"; echo "unitActive=$(systemctl is-active dshm-relay 2>/dev/null)"; echo "unitEnabled=$(systemctl is-enabled dshm-relay 2>/dev/null)"; }
for p in /usr/local/bin/dshm-relay /etc/dshm-relay/relay.yaml /var/lib/dshm-relay/relay.secret /etc/systemd/system/dshm-relay.service; do
  if test -e "$p"; then echo "exists=$p"; fi
done
for p in /etc/dshm-relay /var/lib/dshm-relay; do
  if test -d "$p"; then echo "existsdir=$p"; fi
done
if id -u dshm-relay >/dev/null 2>&1; then echo "user=dshm-relay"; fi
# relay.yaml lives in a 0750 root:dshm-relay dir, so a non-root login user cannot
# even stat the file, let alone read it. Probe the existence and the bytes through
# sudo -n too: an upgrade must be able to reuse the existing control port /
# publicHost. Regression: non-root redeploy used to fail with relay/config-unreadable.
echo "@@relayconfig"
relay_config=""
if [ "$(id -u)" = "0" ]; then
  relay_config=$(cat /etc/dshm-relay/relay.yaml 2>/dev/null)
elif command -v sudo >/dev/null 2>&1 && sudo -n test -f /etc/dshm-relay/relay.yaml 2>/dev/null; then
  relay_config=$(sudo -n cat /etc/dshm-relay/relay.yaml 2>/dev/null)
else
  relay_config=$(cat /etc/dshm-relay/relay.yaml 2>/dev/null)
fi
if [ -n "$relay_config" ]; then printf '%s\n' "$relay_config"; else echo "__unreadable__"; fi
echo "@@sudo"
if test "$(id -u)" = "0"; then echo "uid0=yes"; else
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo "sudo=ok"; else echo "sudo=no"; fi
fi
echo "@@tools"
for t in curl ss systemctl useradd install sha256sum openssl shred journalctl; do
  if command -v "$t" >/dev/null 2>&1; then echo "tool=$t"; fi
done
echo "@@end"
`;

/**
 * Non-destructive baseline snapshot: running systemd services, listening TCP
 * endpoints, top-level /etc entries and /root entries. The engine takes it
 * before and after a deploy to prove no other service/port/config changed.
 */
export const SNAPSHOT_SCRIPT = String.raw`
echo "@@units"; systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | sort
echo "@@ports"; (ss -lntH 2>/dev/null || netstat -lnt 2>/dev/null) | awk '{print $4}' | sort
echo "@@etc"; find /etc -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort
echo "@@root"; ls -A /root 2>/dev/null | sort
echo "@@end"
`;

/** Parse SNAPSHOT_SCRIPT output. */
export function parseSnapshotOutput(stdout) {
  const sections = new Map();
  let current = null;
  for (const rawLine of String(stdout ?? '').split(/\r?\n/)) {
    const line = rawLine.replace(/\r$/u, '');
    const marker = line.match(/^@@([a-z]+)$/u);
    if (marker !== null) {
      current = marker[1];
      if (!sections.has(current)) sections.set(current, []);
      continue;
    }
    if (current !== null && line.trim().length > 0) sections.get(current).push(line.trim());
  }
  return {
    units: sections.get('units') ?? [],
    ports: sections.get('ports') ?? [],
    etc: sections.get('etc') ?? [],
    root: sections.get('root') ?? [],
  };
}

/** Normalize `uname -m` to the plugin asset target arch. */
export function normalizeArch(unameM) {
  const value = String(unameM ?? '').trim().toLowerCase();
  if (value === 'x86_64' || value === 'amd64' || value === 'x64') return 'amd64';
  if (value === 'aarch64' || value === 'arm64' || value === 'armv8' || value === 'armv8l') return 'arm64';
  return undefined;
}

/** Target key used in the asset manifest: `linux-amd64` / `linux-arm64`. */
export function assetTarget(arch) {
  return arch === undefined ? undefined : 'linux-' + arch;
}

/** Parse `cat /etc/os-release` into a flat object. */
export function parseOsRelease(text) {
 /** @type {Record<string,string>} */
  const values = {};
  for (const rawLine of String(text ?? '').split(/\r?\n/)) {
    const match = rawLine.match(/^([A-Z_]+)=(.*)$/u);
    if (match === null) continue;
    values[match[1]] = match[2].replace(/^"|"$/gu, '');
  }
  return values;
}

/**
 * Parse the marker-delimited preflight output.
 * @param {string} stdout
 */
export function parsePreflightOutput(stdout) {
  const sections = new Map();
  let current = null;
  for (const rawLine of String(stdout ?? '').split(/\r?\n/)) {
    const line = rawLine.replace(/\r$/u, '');
    const marker = line.match(/^@@([a-z]+)$/u);
    if (marker !== null) {
      current = marker[1];
      if (!sections.has(current)) sections.set(current, []);
      continue;
    }
    if (current !== null) sections.get(current).push(line);
  }
  const lines = (name) => sections.get(name) ?? [];
  const uname = (lines('uname')[0] ?? '').trim().split(/\s+/);
  const unameS = uname[0] ?? '';
  const unameM = uname[1] ?? '';
  const idLines = lines('id');
  const uid = Number.parseInt(String(idLines[0] ?? '').trim(), 10);
  const loginUser = String(idLines[1] ?? '').trim();
  const systemdLines = lines('systemd');
  const systemdVersion = String(systemdLines[0] ?? '').trim();
  const systemdDir = systemdLines.some((line) => line.includes('systemd_dir=yes'));
  const listenText = lines('listen').join('\n');
  const relayLines = lines('relay');
  const relayConfigLines = lines('relayconfig');
  const sudoLines = lines('sudo');
  const toolLines = lines('tools');
  const facts = {
    unameS,
    unameM,
    kernel: String(lines('kernel')[0] ?? '').trim(),
    os: parseOsRelease(lines('os').join('\n')),
    uid: Number.isInteger(uid) ? uid : undefined,
    loginUser: loginUser.length > 0 ? loginUser : undefined,
    memoryMb: Number.parseInt(String(lines('mem')[0] ?? '').trim(), 10) || undefined,
    diskAvailableKb: Number.parseInt(String(lines('disk')[0] ?? '').trim(), 10) || undefined,
    listeningPorts: [...parseListeningPorts(listenText)].sort((a, b) => a - b),
    listeningText: listenText,
    systemd: {
      present: systemdDir || /systemd \d+/u.test(systemdVersion),
      version: systemdVersion.length > 0 ? systemdVersion : undefined,
    },
    privilege: {
      isRoot: uid === 0,
      sudoOk: sudoLines.some((line) => line.trim() === 'sudo=ok') || uid === 0,
    },
    existingRelay: {
      unitPath: undefined,
      active: false,
      enabled: false,
      userPresent: false,
      files: /** @type {string[]} */ ([]),
      configText: relayConfigLines.join('\n').trim(),
    },
    tools: toolLines
      .map((line) => line.trim())
      .filter((line) => line.startsWith('tool='))
      .map((line) => line.slice('tool='.length)),
  };
  for (const line of relayLines) {
    const [key, ...rest] = line.split('=');
    const value = rest.join('=');
    if (key === 'unitPath') facts.existingRelay.unitPath = value.trim();
    else if (key === 'unitActive') facts.existingRelay.active = value.trim() === 'active';
    else if (key === 'unitEnabled') facts.existingRelay.enabled = value.trim() === 'enabled';
    else if (key === 'exists') facts.existingRelay.files.push(value.trim());
    else if (key === 'existsdir') {
      if (value.trim() === '/etc/dshm-relay') facts.existingRelay.configDirPresent = true;
      if (value.trim() === '/var/lib/dshm-relay') facts.existingRelay.dataDirPresent = true;
    }
    else if (key === 'user') facts.existingRelay.userPresent = value.trim() === 'dshm-relay';
  }
  facts.existingRelay.binPresent = facts.existingRelay.files.includes('/usr/local/bin/dshm-relay');
  facts.existingRelay.configPresent = facts.existingRelay.files.includes('/etc/dshm-relay/relay.yaml');
  facts.existingRelay.unitFilePresent = facts.existingRelay.files.includes('/etc/systemd/system/dshm-relay.service') || Boolean(facts.existingRelay.unitPath);
  facts.existingRelay.installed = Boolean(facts.existingRelay.binPresent || facts.existingRelay.configPresent || facts.existingRelay.unitFilePresent);
  return facts;
}

/**
 * Read what the engine needs out of an existing relay.yaml (upgrade path:
 * never move ports or change the public host silently).
 * @param {string} configText
 */
export function parseExistingRelayConfig(configText) {
  const text = String(configText ?? '');
  if (text.trim().length === 0 || text.includes('__unreadable__')) return undefined;
  const listen = text.match(/^\s*listen:\s*"?([^"\n]+)"?/mu);
  const publicHost = parsePublicHostFromConfig(text) ?? text.match(/^\s*publicHost:\s*"?([^"\n]+)"?/mu)?.[1]?.trim();
  const bridge = parseBridgeRangeFromConfig(text);
  return {
    controlPort: listen === null ? undefined : parseControlPortFromListen(listen[1].trim()),
    controlListen: listen === null ? undefined : listen[1].trim(),
    publicHost: publicHost?.trim(),
    bridgeRange: bridge,
    bridgeBind: text.match(/^\s*bridgeBind:\s*"?([^"\n]+)"?/mu)?.[1]?.trim(),
  };
}

/** OS families we know how to install on (system packages are not used, but the hint text differs). */
export const SUPPORTED_OS_IDS = ['ubuntu', 'debian', 'centos', 'rhel', 'rocky', 'almalinux', 'fedora', 'alpine', 'linuxmint'];

/**
 * Assess facts into a decision + plan.
 *
 * @param {{facts: ReturnType<typeof parsePreflightOutput>, input: Record<string, any>, assets: {targets: string[]}}} options
 * @returns {{
 * ok: boolean,
 * mode: 'fresh'|'upgrade',
 * arch?: string,
 * target?: string,
 * plan?: {controlPort: number, bridgeRange: {start:number,end:number}, mode: 'fresh'|'upgrade'},
 * errors: {code: string, message: string, hint?: string}[],
 * warnings: string[],
 * }}
 */
export function assessPreflight({ facts, input, assets }) {
 /** @type {{code: string, message: string, hint?: string}[]} */
  const errors = [];
 /** @type {string[]} */
  const warnings = [];
  const arch = normalizeArch(facts.unameM);
  if (facts.unameS !== 'Linux') {
    errors.push({ code: CODES.hostUnsupportedOs, message: '目标服务器不是 Linux（检测到 ' + String(facts.unameS || '未知') + '）', hint: '一键部署只支持 Linux + systemd（已验证 Ubuntu 22.04/24.04）。' });
  }
  if (arch === undefined) {
    errors.push({ code: CODES.hostUnsupportedArch, message: '不支持的 CPU 架构：' + String(facts.unameM || '未知'), hint: '目前内置 linux-amd64 / linux-arm64 两个版本的 relay 二进制。' });
  } else if (assets !== undefined && Array.isArray(assets.targets) && !assets.targets.includes(assetTarget(arch))) {
    errors.push({ code: CODES.assetsUnavailable, message: '插件内缺少 linux-' + arch + ' 的 relay 二进制', hint: '在仓库执行 bash packages/dsh-m-relay/scripts/build-release.sh 后重试。' });
  }
  const osId = String(facts.os?.ID ?? '').toLowerCase();
  if (arch !== undefined && !facts.systemd.present) {
    errors.push({ code: CODES.hostNoSystemd, message: '服务器没有可用的 systemd', hint: '当前只支持 systemd 管理的 Linux 发行版；容器/精简系统请手工部署。' });
  }
  if (osId.length > 0 && !SUPPORTED_OS_IDS.includes(osId)) {
    warnings.push('发行版 ' + (facts.os?.PRETTY_NAME ?? osId) + ' 未在验证范围内；只要 systemd + 基础命令可用即可尝试。');
  }
  if (facts.privilege.isRoot !== true && facts.privilege.sudoOk !== true) {
    errors.push({ code: CODES.hostNoSudo, message: '登录用户不是 root 且没有免密 sudo 权限', hint: '请使用 root，或给该用户配置 sudo 免密（NOPASSWD）。' });
  }
  if (typeof facts.memoryMb === 'number' && facts.memoryMb < 128) {
    errors.push({ code: 'host/low-memory', message: '服务器内存过小（' + String(facts.memoryMb) + 'MB）', hint: 'relay 空载约 10–20MB，但建议至少 256MB。' });
  } else if (typeof facts.memoryMb === 'number' && facts.memoryMb < 256) {
    warnings.push('服务器内存 ' + String(facts.memoryMb) + 'MB，relay 空载约 10–20MB，可运行但余量偏小。');
  }
  if (typeof facts.diskAvailableKb === 'number' && facts.diskAvailableKb < 100 * 1024) {
    errors.push({ code: CODES.hostLowDisk, message: '根分区可用空间不足 100MB（当前 ' + String(Math.floor((facts.diskAvailableKb ?? 0) / 1024)) + 'MB）', hint: '清理磁盘后重试。' });
  } else if (typeof facts.diskAvailableKb === 'number' && facts.diskAvailableKb < 200 * 1024) {
    warnings.push('根分区可用空间不足 200MB，建议清理后部署。');
  }
  const hasHash = facts.tools.includes('sha256sum') || facts.tools.includes('openssl');
  if (!hasHash) errors.push({ code: CODES.hostMissingTools, message: '服务器缺少 sha256sum/openssl，无法校验上传的二进制', hint: '安装 coreutils 后重试。' });
  if (!facts.tools.includes('curl')) warnings.push('服务器缺少 curl：本机 healthz 自检将改用 relay 二进制自身的 doctor 命令。');
  const existing = facts.existingRelay;
  const mode = existing.installed ? 'upgrade' : 'fresh';
  let controlPort;
  let bridgeRange;
  if (mode === 'upgrade') {
    const config = parseExistingRelayConfig(existing.configText);
    if (config === undefined) {
      errors.push({ code: 'relay/config-unreadable', message: '检测到已安装 dshm-relay，但无法读取 /etc/dshm-relay/relay.yaml', hint: '请用 root 或具备 sudo 的用户重试。' });
    } else {
      if (config.publicHost !== undefined && config.publicHost !== input.host && input.forceReinstall !== true) {
        errors.push({
          code: CODES.relayHostMismatch,
          message: '服务器上已有 dshm-relay，但配置的 publicHost 是 ' + config.publicHost + '，与本次填写的 ' + input.host + ' 不一致',
          hint: '为保持手机已保存的服务器配置可用，升级不会更换地址。若确实要更换地址，请使用高级选项「强制重建」（会轮换证书 pin，手机需要重新扫码）。',
        });
      }
      if (config.publicHost !== undefined && config.publicHost !== input.host && input.forceReinstall === true) {
        warnings.push('服务器地址从 ' + config.publicHost + ' 变更为 ' + input.host + '：强制重建会生成新证书与 secret（pin 变化，手机需重新扫码服务器配置）。');
      }
      controlPort = config.controlPort;
      bridgeRange = config.bridgeRange;
      if (Array.isArray(facts.listeningPorts) && controlPort !== undefined && facts.listeningPorts.includes(controlPort) && existing.active !== true) {
        warnings.push('控制端口 ' + String(controlPort) + ' 已被其它进程占用，但 dshm-relay 未运行。');
      }
      warnings.push('检测到已有 dshm-relay（' + (existing.active ? '运行中' : '未运行') + '），本次执行幂等升级：保留证书 / secret / state，仅更新二进制。');
    }
  } else {
    const occupied = new Set(facts.listeningPorts ?? []);
    controlPort = pickControlPort(occupied, { preferred: input.controlPort, rng: input.rng });
    if (controlPort === undefined) {
      errors.push({ code: CODES.portNoneAvailable, message: '找不到可用的控制端口（443/8443/9443 及随机高位端口均被占用）', hint: '在高级选项里指定一个空闲端口。' });
    }
    const bridgePreferred = typeof input.bridgeRange === 'string' ? parsePortRange(input.bridgeRange) : undefined;
    if (input.bridgeRange !== undefined && bridgePreferred === undefined) {
      errors.push({ code: CODES.inputInvalid, message: 'bridge 端口段格式应为 start-end，例如 30000-30009', hint: '检查高级选项里的端口段。' });
    }
    bridgeRange = pickBridgeRange(occupied, { start: bridgePreferred?.start, end: bridgePreferred?.end, controlPort, rng: input.rng });
    if (bridgeRange === undefined) {
      errors.push({ code: CODES.portNoneAvailable, message: '找不到可用的 bridge 端口段', hint: '在高级选项里指定一段空闲的 TCP 端口段，并在云安全组放行。' });
    }
    if (controlPort !== undefined && controlPort !== 443) {
      warnings.push('443 端口被占用，控制端口将使用 ' + String(controlPort) + '；需要在云安全组/防火墙放行 TCP ' + String(controlPort) + '。');
    }
  }
  if (controlPort !== undefined && controlPort < 1024) {
    warnings.push('控制端口 ' + String(controlPort) + ' 需要 CAP_NET_BIND_SERVICE（systemd unit 已声明）。');
  }
  if (input.controlPort !== undefined && mode === 'upgrade' && controlPort !== input.controlPort) {
    warnings.push('已有部署的控制端口为 ' + String(controlPort) + '，本次忽略高级选项里的 ' + String(input.controlPort) + '（升级不换端口）。');
  }
  const bridgeDisplay = bridgeRange === undefined ? undefined : String(bridgeRange.start) + '-' + String(bridgeRange.end);
  return {
    ok: errors.length === 0,
    mode,
    arch,
    target: assetTarget(arch),
    plan: errors.length === 0 ? { controlPort, bridgeRange, mode, bridgePorts: bridgeDisplay } : undefined,
    errors,
    warnings,
  };
}

/** Convert error descriptors into DeployError instances. */
export function firstDeployError(errors) {
  const first = Array.isArray(errors) ? errors[0] : undefined;
  if (first === undefined) return undefined;
  return first instanceof DeployError ? first : new DeployError(first.code, first.message, { hint: first.hint });
}
