/**
 * errors.js — stable error codes for the one-click relay deploy (M2b-1).
 *
 * Every failure the engine reports to the desktop UI carries a machine-readable
 * `code`, a short Chinese message (what failed) and a `hint` (what the user can
 * do). The UI renders `message` plus `hint`; the e2e script and unit tests
 * assert `code`. Avoid throwing bare strings so a failed deploy is always
 * actionable (m2b-plan §2.2 step 6).
 */

/** @typedef {{code: string, message: string, hint?: string, detail?: string}} DeployErrorShape */

export class DeployError extends Error {
 /**
 * @param {string} code
 * @param {string} message
 * @param {{hint?: string, detail?: string, cause?: unknown}} [options]
 */
  constructor(code, message, options = {}) {
    super(message);
    this.name = 'DeployError';
    this.code = code;
    this.hint = options.hint;
    this.detail = options.detail;
    if (options.cause !== undefined) this.cause = options.cause;
  }

 /** @returns {DeployErrorShape} */
  toJSON() {
    return {
      code: this.code,
      message: this.message,
      ...(this.hint === undefined ? {} : { hint: this.hint }),
      ...(this.detail === undefined ? {} : { detail: this.detail }),
    };
  }
}

/** Normalize any thrown value into a DeployError. */
export function toDeployError(error, fallback = 'deploy/failed') {
  if (error instanceof DeployError) return error;
  const message = typeof error?.message === 'string' && error.message.length > 0 ? error.message : String(error);
  const code = typeof error?.code === 'string' && error.code.includes('/') ? error.code : fallback;
  return new DeployError(code, message, { cause: error });
}

/** Error codes grouped by phase — kept in one place for UI copy + tests. */
export const CODES = Object.freeze({
  inputInvalid: 'input/invalid',
  deployBusy: 'deploy/busy',
  deployCancelled: 'deploy/cancelled',
  deployTimeout: 'deploy/timeout',
  sshUnreachable: 'ssh/unreachable',
  sshAuthFailed: 'ssh/auth-failed',
  sshHostKeyRequired: 'ssh/host-key-required',
  sshHostKeyMismatch: 'ssh/host-key-mismatch',
  sshCommandFailed: 'ssh/command-failed',
  hostUnsupportedOs: 'host/unsupported-os',
  hostUnsupportedArch: 'host/unsupported-arch',
  hostNoSystemd: 'host/no-systemd',
  hostNoSudo: 'host/no-sudo',
  hostLowDisk: 'host/low-disk',
  hostMissingTools: 'host/missing-tools',
  relayHostMismatch: 'relay/host-mismatch',
  relayInstallFailed: 'relay/install-failed',
  relayHealthFailed: 'relay/health-failed',
  relayChecksumMismatch: 'relay/checksum-mismatch',
  relayBinaryMissing: 'relay/binary-missing',
  portNoneAvailable: 'port/none-available',
  portBindFailed: 'port/bind-failed',
  networkUnreachable: 'network/unreachable',
  networkFirewall: 'network/firewall',
  tlsPinMismatch: 'tls/pin-mismatch',
  tlsHandshakeFailed: 'tls/handshake-failed',
  rollbackFailed: 'rollback/failed',
  assetsUnavailable: 'assets/unavailable',
});
