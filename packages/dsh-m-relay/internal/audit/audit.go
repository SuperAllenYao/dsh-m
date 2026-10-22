// Package audit appends structured JSONL audit events. Events intentionally
// carry only routing metadata (hostId, sid, byte counts, durations, source IP,
// reasons) — never the relay secret, hello HMACs, or stream payloads.
package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Logger writes JSONL audit events.
type Logger struct {
	mu   sync.Mutex
	f    *os.File
	now  func() time.Time
	nop  bool
	path string
}

// Open opens (creating if needed) the audit log for appending.
func Open(path string) (*Logger, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &Logger{f: f, now: time.Now, path: path}, nil
}

// Nop returns a logger that discards events (tests).
func Nop() *Logger { return &Logger{nop: true, now: time.Now} }

// Path returns the audit file path ("" for a Nop logger).
func (l *Logger) Path() string { return l.path }

// Log appends one event. ts is unix milliseconds. Write errors are ignored: the
// audit log must never take the relay down.
func (l *Logger) Log(event string, fields map[string]any) {
	if l == nil || l.nop {
		return
	}
	rec := make(map[string]any, len(fields)+2)
	rec["ts"] = l.now().UnixMilli()
	rec["event"] = event
	for k, v := range fields {
		rec[k] = v
	}
	line, err := json.Marshal(rec)
	if err != nil {
		return
	}
	line = append(line, '\n')
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return
	}
	_, _ = l.f.Write(line)
}

// Close flushes and closes the audit file.
func (l *Logger) Close() error {
	if l == nil || l.nop {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	return err
}
