/**
 * mux.mjs — minimal Remote mux client used only by the M1 test simulator.
 * Frame shapes from docs/design/remote-protocol.zh.md §3.2; kept independent of
 * the spike directories so the package test suite is self-contained.
 */

import { randomUUID } from 'node:crypto';

export class MuxConnection {
  constructor(ws, onExchange = () => {}) {
    this.ws = ws;
    this.onExchange = onExchange;
    this.streams = new Map();
    this.closed = false;
    ws.on('message', (text) => this.onFrame(text));
    ws.on('close', (event) => {
      this.closed = true;
      for (const stream of this.streams.values()) stream.handlers.onClose?.(event);
      this.streams.clear();
    });
  }

  onFrame(text) {
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      this.onExchange({ step: 'mux-frame-invalid', raw: text });
      return;
    }
    this.onExchange({ step: 'mux-frame-in', frame });
    const stream = this.streams.get(frame.streamId);
    if (stream === undefined) return;
    if (frame.type === 'item') {
      stream.handlers.onItem?.(frame.value);
      return;
    }
    if (frame.type === 'end') {
      this.streams.delete(frame.streamId);
      stream.handlers.onEnd?.();
      return;
    }
    if (frame.type === 'error') {
      this.streams.delete(frame.streamId);
      stream.handlers.onError?.(frame.error);
    }
  }

  openStream(endpoint, args, handlers = {}) {
    if (this.closed) throw new Error('mux socket is closed');
    const streamId = randomUUID();
    this.streams.set(streamId, { handlers });
    this.send({ type: 'open', streamId, endpoint, payload: { args } });
    return {
      streamId,
      send: (value) => {
        this.send(value === undefined ? { type: 'item', streamId } : { type: 'item', streamId, value });
      },
      end: () => this.send({ type: 'end', streamId }),
      cancel: () => {
        this.send({ type: 'cancel', streamId });
        this.streams.delete(streamId);
      },
    };
  }

  send(message) {
    if (this.closed) throw new Error('mux socket is closed');
    this.ws.send(JSON.stringify(message));
  }

  close() {
    try {
      this.ws.close(1000, 'sim done');
    } catch {
      /* already gone */
    }
  }
}

/** Collect every frame of one logical stream plus wait/mark helpers. */
export function collectStream(mux, endpoint, args) {
  const frames = [];
  const stream = mux.openStream(endpoint, args, {
    onItem: (value) => frames.push({ kind: 'item', value, at: Date.now() }),
    onEnd: () => frames.push({ kind: 'end', at: Date.now() }),
    onError: (error) => frames.push({ kind: 'error', error, at: Date.now() }),
    onClose: () => frames.push({ kind: 'close', at: Date.now() }),
  });
  const scan = (list, predicate) => {
    for (let index = list.length - 1; index >= 0; index -= 1) {
      const frame = list[index];
      if (predicate(frame) !== false) return frame;
    }
    return undefined;
  };
  return {
    frames,
    stream,
    mark: () => frames.length,
    find: (predicate) => scan(frames, predicate),
    waitFor: (predicate, timeoutMs, label) => waitFor(() => scan(frames, predicate), timeoutMs, label),
    waitForNew: (mark, predicate, timeoutMs, label) => {
      const slice = () => {
        for (let index = frames.length - 1; index >= mark; index -= 1) {
          if (predicate(frames[index]) !== false) return frames[index];
        }
        return undefined;
      };
      return waitFor(slice, timeoutMs, label);
    },
    events: () => frames.filter((frame) => frame.kind === 'item' && frame.value?.type === 'event').map((frame) => frame.value.event),
    close: () => stream.cancel(),
  };
}

/** Poll until predicate returns a truthy value or the timeout fires. */
export function waitFor(predicate, timeoutMs, label) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      let hit;
      try {
        hit = predicate();
      } catch (error) {
        reject(error);
        return;
      }
      if (hit !== undefined && hit !== false) {
        resolve(hit);
        return;
      }
      if (Date.now() - started > timeoutMs) {
        reject(new Error('timeout waiting for ' + label + ' after ' + String(timeoutMs) + 'ms'));
        return;
      }
      setTimeout(tick, 25);
    };
    tick();
  });
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
