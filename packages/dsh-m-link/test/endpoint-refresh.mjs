/**
 * 2026-10-23 real-device root-cause regression guard.
 *
 * The plugin used to capture the Mac's LAN IPs once at process start and never
 * refresh them; after a Wi-Fi/subnet change the mDNS A records and
 * `/health.deviceEndpoints` kept advertising stale addresses, so the phone could
 * never dial the Mac's current LAN origin (live evidence: 566 relay auths, 0 LAN
 * auths after the Mac changed network).
 *
 * `link-server.refreshLanEndpoints()` re-collects the addresses and pushes them
 * into the mDNS responder via `BonjourResponder.update({}, { addresses })`.
 * This suite pins that update contract: replace on change, ignore invalid values,
 * and keep the previous answers when no non-loopback IPv4 exists (Wi-Fi off) so
 * the phone still has the relay instead of an empty A record.
 */
import assert from 'node:assert/strict';
import { BonjourResponder } from '../lib/bonjour.js';

function responder(addresses) {
  return new BonjourResponder({
    hostId: '4aca5cf901a94a2c',
    hostName: 'DSH-m-Mac-M2b',
    port: 3466,
    addresses,
    txt: { v: '1', hostId: '4aca5cf901a94a2c', pair: 'code' },
    log: () => {},
    onError: () => {},
  });
}

// Initial advertisement keeps the constructor addresses.
const first = responder(['192.168.5.10', '172.28.95.194']);
assert.deepEqual(first.addresses, ['192.168.5.10', '172.28.95.194']);

// A network change replaces (not appends) the advertised addresses.
first.update({}, { addresses: ['172.24.116.36'] });
assert.deepEqual(first.addresses, ['172.24.116.36'], 'stale LAN IPs must be dropped');

// Invalid entries are ignored; duplicates are collapsed.
first.update({}, { addresses: ['not-an-ip', '172.24.116.36', '172.24.116.36', ''] });
assert.deepEqual(first.addresses, ['172.24.116.36']);

// Wi-Fi off (no non-loopback IPv4): keep the last known answers, never empty.
first.update({}, { addresses: [] });
assert.deepEqual(first.addresses, ['172.24.116.36'], 'empty refresh must not blank the A record');

// TXT-only update without an addresses option must not touch the addresses.
first.update({ relay: 'https://121.41.112.232:30000' });
assert.deepEqual(first.addresses, ['172.24.116.36']);
assert.equal(first.txtValues().relay, 'https://121.41.112.232:30000');

// A second host on a refreshed network gets the new LAN address.
const second = responder(['10.0.0.2']);
second.update({}, { addresses: ['172.24.116.37', '172.24.116.38'] });
assert.deepEqual(second.addresses, ['172.24.116.37', '172.24.116.38']);

console.log('endpoint-refresh: ok');
