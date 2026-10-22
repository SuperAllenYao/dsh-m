/**
 * selfcheck.js — Mac-side reachability + TLS pin verification after install.
 *
 * The acceptance criterion is "本机 healthz + 外网 healthz + TLS pin" from the
 * Mac (m2b-plan §2.2 step 4). The relay presents a self-signed certificate, and
 * the App/plugin pin the certificate DER SHA-256 (base64url), so a plain
 * https.request is not enough: we must compute the pin from the TLS peer
 * certificate ourselves and compare it with the pin printed by `relay init`.
 *
 * No npm dependencies: node:net, node:tls, node:crypto only.
 */

import { createHash } from 'node:crypto';
import { connect as netConnect } from 'node:net';
import { connect as tlsConnect } from 'node:tls';

import { CODES, DeployError } from './errors.js';

export const DEFAULT_PROBE_TIMEOUT_MS = 8000;

/** base64url SHA-256 of a DER certificate — same form as relay `init` pin / tunnel.pin. */
export function certPin(derBuffer) {
  return createHash('sha256').update(derBuffer).digest('base64').replace(/=+$/u, '').replace(/\+/gu, '-').replace(/\//gu, '_');
}

/**
 * TCP reachability probe (used for the control port when TLS is not expected,
 * e.g. diagnosing firewall vs TLS problems).
 * @param {{host: string, port: number, timeoutMs?: number}} options
 * @returns {Promise<{ok: boolean, error?: string}>}
 */
export async function probeTcp({ host, port, timeoutMs = DEFAULT_PROBE_TIMEOUT_MS }) {
  return await new Promise((resolve) => {
    let settled = false;
    const socket = netConnect({ host, port });
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: false, error: 'timeout after ' + String(timeoutMs) + 'ms' }), timeoutMs);
    socket.once('connect', () => finish({ ok: true }));
    socket.once('error', (error) => finish({ ok: false, error: String(error?.code ?? error?.message ?? error) }));
  });
}

/**
 * TLS probe that returns the peer certificate pin even for a self-signed cert,
 * so the caller can compare it against the expected pin.
 * @param {{host: string, port: number, timeoutMs?: number}} options
 * @returns {Promise<{ok: boolean, pin?: string, certFingerprint256?: string, error?: string, protocol?: string}>}
 */
export async function probeTlsPin({ host, port, timeoutMs = DEFAULT_PROBE_TIMEOUT_MS }) {
  return await new Promise((resolve) => {
    let settled = false;
    const socket = tlsConnect({
      host,
      port,
      servername: host,
      rejectUnauthorized: false,
      ALPNProtocols: ['http/1.1'],
      timeout: timeoutMs,
    });
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: false, error: 'timeout after ' + String(timeoutMs) + 'ms' }), timeoutMs);
    socket.once('secureConnect', () => {
      try {
        const cert = socket.getPeerCertificate();
        if (cert === null || cert === undefined || !Buffer.isBuffer(cert.raw)) {
          finish({ ok: false, error: 'peer did not present a certificate' });
          return;
        }
        const pin = certPin(cert.raw);
        const fingerprint = String(cert.fingerprint256 ?? '').toUpperCase();
        finish({ ok: true, pin, certFingerprint256: fingerprint, protocol: socket.getProtocol() ?? undefined });
      } catch (error) {
        finish({ ok: false, error: String(error?.message ?? error) });
      }
    });
    socket.once('error', (error) => finish({ ok: false, error: String(error?.code ?? error?.message ?? error) }));
  });
}

/**
 * Verify the TLS pin on a public origin, then fetch `GET /healthz` over HTTP/1.1
 * on the same pinned TLS socket and parse the relay health JSON.
 *
 * @param {{host: string, port: number, expectedPin: string, path?: string, timeoutMs?: number}} options
 * @returns {Promise<{ok: boolean, pin?: string, health?: any, error?: string, status?: number, bodyText?: string}>}
 */
export async function probeHttpsHealthz({ host, port, expectedPin, path = '/healthz', timeoutMs = DEFAULT_PROBE_TIMEOUT_MS }) {
  return await new Promise((resolve) => {
    let settled = false;
    const chunks = [];
    const socket = tlsConnect({
      host,
      port,
      servername: host,
      rejectUnauthorized: false,
      ALPNProtocols: ['http/1.1'],
      timeout: timeoutMs,
    });
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: false, error: 'timeout after ' + String(timeoutMs) + 'ms' }), timeoutMs);
    socket.once('secureConnect', () => {
      let pin;
      try {
        const cert = socket.getPeerCertificate();
        if (cert === null || cert === undefined || !Buffer.isBuffer(cert.raw)) {
          finish({ ok: false, error: 'peer did not present a certificate' });
          return;
        }
        pin = certPin(cert.raw);
      } catch (error) {
        finish({ ok: false, error: String(error?.message ?? error) });
        return;
      }
      if (typeof expectedPin === 'string' && expectedPin.length > 0 && pin !== expectedPin) {
        finish({ ok: false, pin, error: 'TLS pin mismatch: expected ' + expectedPin + ', got ' + pin });
        return;
      }
      socket.write('GET ' + path + ' HTTP/1.1\r\nHost: ' + host + ':' + String(port) + '\r\nConnection: close\r\nAccept: application/json\r\n\r\n');
      socket.on('data', (chunk) => chunks.push(chunk));
      socket.once('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        const headerEnd = raw.indexOf('\r\n\r\n');
        const header = headerEnd === -1 ? raw : raw.slice(0, headerEnd);
        const bodyText = headerEnd === -1 ? '' : raw.slice(headerEnd + 4);
        const statusMatch = header.match(/^HTTP\/1\.1\s+(\d{3})/u);
        const status = statusMatch === null ? undefined : Number(statusMatch[1]);
        let health;
        try {
          health = JSON.parse(bodyText);
        } catch {
          health = undefined;
        }
        finish({
          ok: status === 200 && health?.ok === true,
          pin,
          status,
          health,
          bodyText: bodyText.slice(0, 2000),
          ...(status === 200 && health?.ok === true ? {} : { error: 'unexpected healthz response (status ' + String(status) + ')' }),
        });
      });
    });
    socket.once('error', (error) => finish({ ok: false, error: String(error?.code ?? error?.message ?? error) }));
  });
}

/**
 * Full external self-check: TCP -> pinned TLS -> /healthz.
 *
 * @param {{host: string, port: number, pin: string, timeoutMs?: number}} options
 * @returns {Promise<{ok: boolean, error?: DeployError, tcpOk?: boolean, pin?: string, health?: any}>}
 */
export async function externalSelfCheck({ host, port, pin, timeoutMs = DEFAULT_PROBE_TIMEOUT_MS }) {
  const tcp = await probeTcp({ host, port, timeoutMs });
  if (tcp.ok !== true) {
    return {
      ok: false,
      tcpOk: false,
      error: new DeployError(CODES.networkFirewall, 'Mac 无法从公网连接到控制端口 TCP ' + String(port), {
        hint:
          '请在云厂商安全组 / 服务器防火墙放行入站 TCP ' + String(port) + '（以及 bridge 端口段）；' +
          '若安全组已放行，检查服务器 ufw/iptables。引擎不会自动改云防火墙（需用户手工放行）。',
        detail: tcp.error,
      }),
    };
  }
  const https = await probeHttpsHealthz({ host, port, expectedPin: pin, timeoutMs });
  if (https.ok !== true) {
    if (typeof https.pin === 'string' && https.pin.length > 0 && https.pin !== pin) {
      return {
        ok: false,
        tcpOk: true,
        pin: https.pin,
        error: new DeployError(CODES.tlsPinMismatch, '外网 TLS 证书 pin 与服务器上的 pin 不一致', {
          hint: '可能端口上运行的不是本次部署的 relay（或被代理/中间设备替换）。检查端口占用与 CDN/代理设置。',
          detail: '期望 ' + pin + '，实际 ' + https.pin,
        }),
      };
    }
    return {
      ok: false,
      tcpOk: true,
      error: new DeployError(CODES.tlsHandshakeFailed, '外网 TLS / healthz 自检失败', { hint: '检查控制端口是否被其它进程占用；查看服务器 journalctl -u dshm-relay。', detail: https.error }),
    };
  }
  return { ok: true, tcpOk: true, pin: https.pin, health: https.health };
}
