/**
 * netlog-export.js — one-click network-log export for the desktop panel.
 *
 * The archive is built on this Mac only (nothing is uploaded). It contains the
 * current and previous audit segments copied **byte-for-byte** (user decision
 * 2026-11-06 / DEC-12: the full audit text is wanted for troubleshooting device
 * revocation, certificate rotation and pairing failures — audit.js itself only
 * ever writes metadata), plus a machine-readable `metadata.json` and a human
 * `summary.txt`. This module never reads session bodies, tokens or credentials;
 * the only device data it emits is the public device list already shown in the
 * settings panel.
 *
 * ZIP is produced with Node's built-in `zlib.deflateRawSync` and a minimal
 * container (local headers + central directory + EOCD, UTF-8 flag set), so no
 * npm dependency is added to the plugin.
 */

import { readFileSync, statSync } from 'node:fs';
import { arch as osArch, platform as osPlatform, release as osRelease } from 'node:os';
import { join } from 'node:path';
import { deflateRawSync } from 'node:zlib';

/** Audit segments written by audit.js, newest first (5 MB × 2 rotation). */
export const AUDIT_FILES = ['audit.log', 'audit.log.1'];

const SCHEMA = 'netlog-export/1';
const SUMMARY_RECENT_EVENTS = 20;
const SUMMARY_TOP_EVENTS = 10;

/**
 * Lightweight state of the audit files for `statusPayload().audit` and for the
 * panel's disabled state. `stat` only — no file contents are read here.
 *
 * @param {string} dir
 * @returns {{bytes: number, files: string[]}}
 */
export function auditFilesStatus(dir) {
  const files = [];
  let bytes = 0;
  for (const name of AUDIT_FILES) {
    try {
      const stat = statSync(join(dir, name));
      if (!stat.isFile()) continue;
      files.push(name);
      bytes += stat.size;
    } catch {
 /* segment not written yet */
    }
  }
  return { bytes, files };
}

/**
 * Build the export zip. Callers map "no audit segment" to `netlog/empty`
 * before calling; this function throws when there is nothing to export.
 *
 * @param {{dir: string, status?: {
 *   pluginVersion?: string,
 *   hostId?: string,
 *   hostName?: string,
 *   devices?: {total?: number, active?: number, list?: Array<Record<string, unknown>>},
 * }, now?: number}} options
 * @returns {{name: string, bytesBase64: string, bytes: number}}
 */
export function buildNetlogZip({ dir, status = {}, now = Date.now() }) {
  const segments = readSegments(dir);
  if (segments.length === 0) throw new Error('netlog/empty');

  const parsed = [];
  // Segments are listed newest-first (audit.log, then audit.log.1). Feed the
  // parsed index oldest-first so "最近 N 条" is genuinely the tail in time
  // order; otherwise the tail would come from the previous segment.
  for (const segment of [...segments].reverse()) {
    for (const line of segment.lines) {
      try {
        const entry = JSON.parse(line);
        if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) parsed.push(entry);
      } catch {
 /* keep the raw line out of the parsed index */
      }
    }
  }

  const metadata = buildMetadata({ status, segments, now });
  const summary = buildSummary({ status, segments, parsed, now });

  const entries = segments.map((segment) => ({ name: segment.name, data: segment.buffer }));
  entries.push({ name: 'metadata.json', data: Buffer.from(JSON.stringify(metadata, null, 2) + '\n', 'utf8') });
  entries.push({ name: 'summary.txt', data: Buffer.from(summary, 'utf8') });

  const zip = buildZip(entries, now);
  return {
    name: 'dshm-link-log-' + localStamp(now) + '.zip',
    bytesBase64: zip.toString('base64'),
    bytes: zip.length,
  };
}

/** Read existing audit segments exactly as written (never re-encoded). */
function readSegments(dir) {
  const segments = [];
  for (const name of AUDIT_FILES) {
    let buffer;
    try {
      buffer = readFileSync(join(dir, name));
    } catch {
      continue;
    }
    const text = buffer.toString('utf8');
    const lines = text.split('\n').filter((line) => line.trim().length > 0);
    segments.push({ name, buffer, bytes: buffer.length, events: lines.length, lines });
  }
  return segments;
}

function buildMetadata({ status, segments, now }) {
  const devices = status.devices ?? {};
  const list = Array.isArray(devices.list) ? devices.list : [];
  const metadata = {
    schema: SCHEMA,
    generatedAt: new Date(now).toISOString(),
    pluginVersion: status.pluginVersion ?? null,
    node: process.version,
    platform: osPlatform(),
    release: osRelease(),
    arch: osArch(),
  };
  if (typeof status.hostId === 'string' && status.hostId.length > 0) metadata.hostId = status.hostId;
  if (typeof status.hostName === 'string' && status.hostName.length > 0) metadata.hostName = status.hostName;
  metadata.auditFiles = segments.map((segment) => ({ name: segment.name, bytes: segment.bytes, events: segment.events }));
  metadata.devices = {
    total: Number.isInteger(devices.total) ? devices.total : list.length,
    active: Number.isInteger(devices.active) ? devices.active : list.filter((device) => device?.revoked !== true).length,
    list: list.map((device) => ({
      deviceIdPrefix: typeof device?.deviceId === 'string' ? device.deviceId.slice(0, 8) : undefined,
      platform: device?.platform,
      lastSeenAt: device?.lastSeenAt,
      hasPushToken: device?.hasPushToken === true,
      revoked: device?.revoked === true,
    })),
  };
  return metadata;
}

function buildSummary({ status, segments, parsed, now }) {
  const devices = status.devices ?? {};
  const list = Array.isArray(devices.list) ? devices.list : [];
  const total = Number.isInteger(devices.total) ? devices.total : list.length;
  const active = Number.isInteger(devices.active) ? devices.active : list.filter((device) => device?.revoked !== true).length;

  const lines = [];
  lines.push('DSH-m 网络连接日志导出（Mac 插件）');
  lines.push('生成时间: ' + new Date(now).toISOString());
  lines.push('插件版本: ' + String(status.pluginVersion ?? '—'));
  lines.push('Node: ' + process.version);
  lines.push('系统: ' + osPlatform() + ' ' + osRelease() + ' (' + osArch() + ')');
  if (typeof status.hostName === 'string' && status.hostName.length > 0) lines.push('主机名: ' + status.hostName);
  if (typeof status.hostId === 'string' && status.hostId.length > 0) lines.push('主机 ID: ' + status.hostId);
  lines.push('');
  lines.push('审计文件:');
  for (const segment of segments) lines.push('- ' + segment.name + ': ' + segment.bytes + ' 字节, ' + segment.events + ' 事件');
  lines.push('');
  lines.push('设备: 总数 ' + total + '，活跃 ' + active);
  lines.push('');

  const counts = new Map();
  for (const entry of parsed) {
    const event = typeof entry.event === 'string' ? entry.event : 'unknown';
    counts.set(event, (counts.get(event) ?? 0) + 1);
  }
  const top = [...counts.entries()]
    .sort((left, right) => (right[1] - left[1]) || left[0].localeCompare(right[0]))
    .slice(0, SUMMARY_TOP_EVENTS);
  lines.push('事件计数 Top:');
  if (top.length === 0) {
    lines.push('- （无可解析事件）');
  } else {
    for (const [event, count] of top) lines.push('- ' + event + ': ' + count);
  }
  lines.push('');

  lines.push('最近 ' + SUMMARY_RECENT_EVENTS + ' 条（ts / event / traceId）:');
  const recent = parsed.slice(-SUMMARY_RECENT_EVENTS);
  if (recent.length === 0) {
    lines.push('- （无可解析事件）');
  } else {
    for (const entry of recent) {
      const parts = [String(entry.ts ?? '—'), String(entry.event ?? '—')];
      if (typeof entry.traceId === 'string' && entry.traceId.length > 0) parts.push('traceId=' + entry.traceId);
      lines.push('- ' + parts.join('  '));
    }
  }
  lines.push('');
  lines.push('隐私说明: 仅本机生成、不上传；不含会话正文、token、nonce、签名或 cookie。');
  lines.push('本文件用于协助排查两端连接问题；跨端对账请按同一 traceId 匹配手机日志。');
  return lines.join('\n') + '\n';
}

function localStamp(ms) {
  const date = new Date(ms);
  const pad = (value) => String(value).padStart(2, '0');
  return String(date.getFullYear()) + pad(date.getMonth() + 1) + pad(date.getDate())
    + '-' + pad(date.getHours()) + pad(date.getMinutes());
}

// --------------------------------------------------------------------- ZIP ---

function crc32Table() {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 1 ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
    }
    table[index] = value >>> 0;
  }
  return table;
}

const CRC32_TABLE = crc32Table();

function crc32(buffer) {
  let crc = 0xffffffff;
  for (let index = 0; index < buffer.length; index += 1) {
    crc = CRC32_TABLE[(crc ^ buffer[index]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function dosDateTime(ms) {
  const date = new Date(ms);
  const year = Math.max(1980, date.getFullYear());
  const dosDate = (((year - 1980) & 0x7f) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  const dosTime = (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2);
  return { dosDate, dosTime };
}

/** Minimal deflate ZIP with UTF-8 file names (flag bit 11). */
function buildZip(entries, now) {
  const { dosDate, dosTime } = dosDateTime(now);
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const data = entry.data;
    const compressed = deflateRawSync(data);
    const checksum = crc32(data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt16LE(dosTime, 10);
    local.writeUInt16LE(dosDate, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, name, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(dosTime, 12);
    central.writeUInt16LE(dosDate, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(0, 38);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, name);

    offset += local.length + name.length + compressed.length;
  }

  const centralSize = centralParts.reduce((sum, part) => sum + part.length, 0);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralSize, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...localParts, ...centralParts, eocd]);
}
