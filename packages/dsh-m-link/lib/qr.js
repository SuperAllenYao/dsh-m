/**
 * qr.js — render the pairing payload as a QR PNG for the desktop UI.
 *
 * The plugin intentionally carries no npm dependency for QR encoding. On macOS
 * (the only target of the M1 desktop plugin) CoreImage's CIQRCodeGenerator via
 * the system osascript/JXA bridge produces a standards-compliant QR in ~150ms;
 * results are cached by payload text because the admin UI polls every few
 * seconds. If the helper is unavailable the admin payload still carries the
 * plain text (manual entry), and the UI shows the explicit error instead of a
 * broken image.
 *
 * Verification: test/qr-decode.swift decodes the produced PNG with Vision and
 * asserts it round-trips to the exact payload text (see test/run-m1.sh).
 */

import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const JXA_SCRIPT = `
ObjC.import('Foundation');
ObjC.import('CoreImage');
ObjC.import('AppKit');
ObjC.import('ImageIO');
function run(argv) {
  const text = argv[0];
  const outPath = argv[1];
  const filter = $.CIFilter.filterWithName('CIQRCodeGenerator');
  filter.setValueForKey($.NSString.alloc.initWithUTF8String(text).dataUsingEncoding($.NSUTF8StringEncoding), 'inputMessage');
  filter.setValueForKey($.NSString.alloc.initWithUTF8String('M'), 'inputCorrectionLevel');
  const output = filter.outputImage;
  if (!output) throw new Error('CIQRCodeGenerator returned no image');
  const ctx = $.CIContext.context;
  const scaled = output.imageByApplyingTransform($.CGAffineTransformMakeScale(8, 8));
  const cg = ctx.createCGImageFromRect(scaled, scaled.extent);
  const url = $.NSURL.fileURLWithPath($.NSString.alloc.initWithUTF8String(outPath));
  const dest = $.CGImageDestinationCreateWithURL(url, $.NSString.alloc.initWithUTF8String('public.png'), 1, $());
  $.CGImageDestinationAddImage(dest, cg, $());
  if (!$.CGImageDestinationFinalize(dest)) throw new Error('cannot write QR png');
  return 'ok';
}
`;

const CACHE_LIMIT = 4;

export class QrRenderer {
  /** @param {{log?: (message: string) => void, timeoutMs?: number}} options */
  constructor({ log = () => {}, timeoutMs = 10_000 } = {}) {
    this.log = log;
    this.timeoutMs = timeoutMs;
    this.cache = new Map();
    this.pending = new Map();
    this.failed = false;
    this.disposed = false;
    /** @type {Set<import('node:child_process').ChildProcess>} */
    this.children = new Set();
  }

  /** Render payload text to a PNG data URL (cached). */
  async renderDataUrl(text) {
    if (typeof text !== 'string' || text.length === 0) return { ok: false, error: 'empty payload' };
    const cached = this.cache.get(text);
    if (cached !== undefined) return cached;
    const inflight = this.pending.get(text);
    if (inflight !== undefined) return inflight;
    const rendered = this.render(text).finally(() => this.pending.delete(text));
    this.pending.set(text, rendered);
    const result = await rendered;
    if (result.ok) {
      this.cache.set(text, result);
      if (this.cache.size > CACHE_LIMIT) this.cache.delete(this.cache.keys().next().value);
    }
    return result;
  }

  async render(text) {
    if (this.disposed) return { ok: false, error: 'qr-renderer-disposed' };
    const dir = mkdtempSync(join(tmpdir(), 'dshm-qr-'));
    const outPath = join(dir, 'pair.png');
    let child;
    try {
      await new Promise((resolve, reject) => {
        child = execFile(
          'osascript',
          ['-l', 'JavaScript', '-e', JXA_SCRIPT, '--', text, outPath],
          { timeout: this.timeoutMs, maxBuffer: 2 * 1024 * 1024 },
          (error) => {
            this.children.delete(child);
            if (error !== null && error !== undefined) reject(error);
            else resolve();
          },
        );
        this.children.add(child);
      });
      if (this.disposed) return { ok: false, error: 'qr-renderer-disposed' };
      const png = readFileSync(outPath);
      if (png.length === 0) return { ok: false, error: 'QR renderer produced an empty file' };
      return { ok: true, dataUrl: 'data:image/png;base64,' + png.toString('base64'), bytes: png.length };
    } catch (error) {
      if (!this.failed && !this.disposed) {
        this.failed = true;
        this.log('QR rendering unavailable (' + String(error?.message ?? error) + '); the pairing text is still shown for manual entry');
      }
      return { ok: false, error: String(error?.message ?? error) };
    } finally {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        /* best effort */
      }
    }
  }

  /** Kill a pending render and stop accepting new ones (dispose path). */
  dispose() {
    this.disposed = true;
    for (const child of this.children) {
      try {
        child.kill('SIGKILL');
      } catch {
        /* already exited */
      }
    }
    this.children.clear();
    this.cache.clear();
    this.pending.clear();
  }
}