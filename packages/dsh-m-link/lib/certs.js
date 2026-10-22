/**
 * certs.js — self-signed ECDSA P-256 CA + leaf for the dsh-m-link TLS origin.
 *
 * Layout (under $DSH_HOME/plugin-data/dsh-m-link/tls):
 *   ca.key / ca.crt        long-lived CA (5 years); its SPKI pin is the QR trust
 *                          anchor, so re-issuing the leaf never needs a re-pair
 *   leaf.key / leaf.crt    server certificate (1 year) with SANs for loopback,
 *                          the mDNS host name and every configured LAN address
 *   certs.json             pin/metadata cache (expected vs actual SAN list)
 *   archive-<ts>/          previous CA+leaf set after a CA rotation
 *
 * Trust model: clients pin the *leaf DER* (`leafFingerprint256`), not only the
 * CA. Re-signing the leaf therefore invalidates every existing pairing, so the
 * leaf is re-issued only on expiry (the 7-day renew window, roughly yearly) or
 * by an explicit `rotateLeaf()` / `rotateCa()` call. A SAN drift (new LAN
 * address or bindHost) is only logged: the leaf keeps its old SANs and the
 * pairing stays valid. Rotating the CA is deliberately a breaking operation:
 * the QR anchor changes, so the caller (LinkServer) also revokes every device
 * and forces re-pairing.
 */

import { execFileSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { keyFingerprint256, keyPin } from './devices.js';

const CA_DAYS = 1825;
const LEAF_DAYS = 365;
const LEAF_RENEW_BEFORE_MS = 7 * 24 * 60 * 60 * 1000;
const P256_GEN = ['ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-sha256', '-nodes'];

function openssl(args) {
  return execFileSync('openssl', args, { stdio: ['ignore', 'pipe', 'pipe'] });
}

/** Normalize a host/IP for a certificate SAN. */
function sanEntries({ bindHost, lanIps, hostname }) {
  const entries = new Set(['DNS:localhost', 'IP:127.0.0.1', 'IP:::1']);
  if (typeof hostname === 'string' && /^[A-Za-z0-9.-]+$/.test(hostname) && hostname.includes('.') && !/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) {
    entries.add('DNS:' + hostname);
  }
  const hosts = new Set();
  if (typeof bindHost === 'string' && bindHost.length > 0 && bindHost !== '0.0.0.0' && bindHost !== '::') hosts.add(bindHost);
  for (const ip of lanIps ?? []) hosts.add(ip);
  for (const host of hosts) {
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) entries.add('IP:' + host);
    else if (/^[A-Za-z0-9.-]+$/.test(host)) entries.add('DNS:' + host);
  }
  return [...entries];
}

function leafExtensions(sans) {
  return [
    'basicConstraints=CA:FALSE',
    'keyUsage=digitalSignature,keyEncipherment',
    'extendedKeyUsage=serverAuth',
    'subjectAltName=' + sans.join(','),
    '',
  ].join('\n');
}

function readMeta(tlsDir) {
  const file = join(tlsDir, 'certs.json');
  if (!existsSync(file)) return undefined;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return undefined;
  }
}

function describe(tlsDir, { generated = false, leafRotated = false } = {}) {
  const caCert = join(tlsDir, 'ca.crt');
  const leafCert = join(tlsDir, 'leaf.crt');
  const ca = new X509Certificate(readFileSync(caCert));
  const leaf = new X509Certificate(readFileSync(leafCert));
  const caSpki = ca.publicKey.export({ type: 'spki', format: 'der' });
  const leafSpki = leaf.publicKey.export({ type: 'spki', format: 'der' });
  return {
    dir: tlsDir,
    caCert,
    caKey: join(tlsDir, 'ca.key'),
    leafCert,
    leafKey: join(tlsDir, 'leaf.key'),
    /**
     * Public CA certificate as DER bytes in base64 (the C-scheme trust anchor
     * clients pin instead of the leaf DER). Public material only — the CA
     * private key (`caKey`) is never serialized into payloads or /health.
     */
    caCertDerBase64: ca.raw.toString('base64'),
    caFingerprint256: ca.fingerprint256,
    leafFingerprint256: leaf.fingerprint256,
    caPin: keyPin(caSpki),
    leafPin: keyPin(leafSpki),
    caSubject: ca.subject,
    leafSubject: leaf.subject,
    leafSans: leaf.subjectAltName ?? '',
    caNotAfter: ca.validTo,
    leafNotAfter: leaf.validTo,
    leafValidToMs: Date.parse(leaf.validTo),
    generated,
    leafRotated,
  };
}

function writeMeta(tlsDir, info, expectedSans) {
  writeFileSync(
    join(tlsDir, 'certs.json'),
    JSON.stringify(
      {
        version: 1,
        leafSansExpected: expectedSans ?? info.leafSans,
        caFingerprint256: info.caFingerprint256,
        leafFingerprint256: info.leafFingerprint256,
        caPin: info.caPin,
        leafPin: info.leafPin,
        leafSans: info.leafSans,
        caNotAfter: info.caNotAfter,
        leafNotAfter: info.leafNotAfter,
        updatedAt: new Date().toISOString(),
      },
      null,
      2,
    ) + '\n',
    { mode: 0o600 },
  );
}

function generateCa(tlsDir, log) {
  openssl([
    'req', '-x509', '-newkey', ...P256_GEN, '-days', String(CA_DAYS),
    '-keyout', join(tlsDir, 'ca.key'), '-out', join(tlsDir, 'ca.crt'),
    '-subj', '/CN=dsh-m-link local CA',
    '-addext', 'basicConstraints=critical,CA:TRUE',
    '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
  ]);
  log('generated ECDSA P-256 CA certificate');
}

function generateLeaf(tlsDir, sans) {
  const extFile = join(tlsDir, 'leaf.ext');
  writeFileSync(extFile, leafExtensions(sans));
  const csr = join(tlsDir, 'leaf.csr');
  openssl(['req', '-new', '-newkey', ...P256_GEN, '-keyout', join(tlsDir, 'leaf.key'), '-out', csr, '-subj', '/CN=dsh-m-link']);
  openssl([
    'x509', '-req', '-in', csr,
    '-CA', join(tlsDir, 'ca.crt'), '-CAkey', join(tlsDir, 'ca.key'), '-CAcreateserial',
    '-days', String(LEAF_DAYS), '-sha256',
    '-out', join(tlsDir, 'leaf.crt'), '-extfile', extFile,
  ]);
}

/**
 * Ensure a CA + leaf exist. The leaf is re-issued only when a file is missing,
 * when it is close to expiry, or through an explicit `rotateLeaf()` /
 * `rotateCa()` call. A SAN drift (new LAN address / bindHost) is logged but
 * keeps the existing leaf, because clients pin the leaf DER and a re-signed
 * leaf would silently un-pair every phone. Never touches the CA on its own.
 */
export function ensureCerts({ dir, bindHost, lanIps = [], hostname, log = () => {} }) {
  const tlsDir = join(dir, 'tls');
  mkdirSync(tlsDir, { recursive: true });
  const complete =
    existsSync(join(tlsDir, 'ca.key')) &&
    existsSync(join(tlsDir, 'ca.crt')) &&
    existsSync(join(tlsDir, 'leaf.key')) &&
    existsSync(join(tlsDir, 'leaf.crt'));
  const sans = sanEntries({ bindHost, lanIps, hostname });
  let generated = false;
  let leafRotated = false;
  if (!complete) {
    generateCa(tlsDir, log);
    generateLeaf(tlsDir, sans);
    generated = true;
  } else {
    const meta = readMeta(tlsDir);
    const current = describe(tlsDir);
    const expectedSan = sans.join(',');
    // Compare against the SAN list we generated (X509's subjectAltName string
    // formats IPs as "IP Address:…", so comparing it directly would rotate the
    // leaf on every start).
    const sanDrift = meta === undefined || meta.leafSansExpected !== expectedSan;
    const expiring = !Number.isFinite(current.leafValidToMs) || current.leafValidToMs - Date.now() < LEAF_RENEW_BEFORE_MS;
    // B fix (pairing durability): clients pin the leaf DER, not only the CA, so
    // re-signing on a new LAN IP / bindHost silently un-pairs every phone. Only
    // expiry (or an explicit rotateLeaf()/rotateCa()) may re-issue the leaf; a
    // SAN drift is metadata-only and never touches the key/certificate.
    if (expiring) {
      log(
        'rotating leaf certificate (expiring' +
          (sanDrift ? '; SAN drift ' + (meta?.leafSansExpected ?? 'unknown') + ' -> ' + expectedSan + ' applied to the new leaf' : '') +
          ')',
      );
      generateLeaf(tlsDir, sans);
      leafRotated = true;
    } else if (sanDrift) {
      log(
        'SAN drift but leaf kept (' +
          (meta?.leafSansExpected ?? 'unknown') +
          ' -> ' +
          expectedSan +
          '); paired devices stay valid, leaf is only re-issued when it expires',
      );
    }
  }
  const info = describe(tlsDir, { generated, leafRotated });
  if (generated || leafRotated) writeMeta(tlsDir, info, sans.join(','));
  return info;
}

/** Rotate only the leaf certificate (CA pin in existing QR payloads stays valid). */
export function rotateLeaf({ dir, bindHost, lanIps = [], hostname, log = () => {} }) {
  const tlsDir = join(dir, 'tls');
  mkdirSync(tlsDir, { recursive: true });
  if (!existsSync(join(tlsDir, 'ca.key'))) return ensureCerts({ dir, bindHost, lanIps, hostname, log });
  const sans = sanEntries({ bindHost, lanIps, hostname });
  generateLeaf(tlsDir, sans);
  const info = describe(tlsDir, { leafRotated: true });
  writeMeta(tlsDir, info, sans.join(','));
  log('leaf certificate rotated manually');
  return info;
}

/**
 * Rotate the whole trust anchor: archive the current CA+leaf set, generate a
 * new CA+leaf. Every paired device must re-pair (the QR caPin changes); the
 * caller is responsible for revoking devices and refreshing the QR payload.
 */
export function rotateCa({ dir, bindHost, lanIps = [], hostname, log = () => {} }) {
  const tlsDir = join(dir, 'tls');
  mkdirSync(tlsDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const archive = join(tlsDir, 'archive-' + stamp);
  if (existsSync(join(tlsDir, 'ca.key'))) {
    mkdirSync(archive, { recursive: true });
    for (const name of readdirSync(tlsDir)) {
      if (!name.startsWith('archive-') && (name.endsWith('.key') || name.endsWith('.crt') || name.endsWith('.csr') || name.endsWith('.ext') || name.endsWith('.srl') || name === 'certs.json')) {
        try {
          renameSync(join(tlsDir, name), join(archive, name));
        } catch {
          /* best effort */
        }
      }
    }
  }
  generateCa(tlsDir, log);
  const sans = sanEntries({ bindHost, lanIps, hostname });
  generateLeaf(tlsDir, sans);
  const info = describe(tlsDir, { generated: true, leafRotated: true });
  writeMeta(tlsDir, info, sans.join(','));
  log('CA rotated; previous CA+leaf archived under ' + archive);
  return { ...info, archive };
}

export { copyFileSync };