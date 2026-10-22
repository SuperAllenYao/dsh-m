package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoggerWritesJSONL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "audit.jsonl")
	l, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	l.Log("host.ready", map[string]any{"hostId": "host-abc123", "port": 30001})
	l.Log("lookup.miss", map[string]any{"reason": "code/not-found"})
	if err := l.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read audit: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("audit lines = %d, want 2 (%q)", len(lines), string(data))
	}
	for i, line := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("line %d is not JSON: %v", i, err)
		}
		if _, ok := rec["ts"]; !ok {
			t.Fatalf("line %d missing ts", i)
		}
		if _, ok := rec["event"]; !ok {
			t.Fatalf("line %d missing event", i)
		}
	}
	if info, err := os.Stat(path); err == nil && info.Mode().Perm() != 0o600 {
		t.Fatalf("audit mode = %v, want 0600", info.Mode().Perm())
	}
}

func TestNopLogger(t *testing.T) {
	l := Nop()
	l.Log("x", map[string]any{"secret": "should-not-matter"})
	if err := l.Close(); err != nil {
		t.Fatalf("Nop Close: %v", err)
	}
	if l.Path() != "" {
		t.Fatalf("Nop Path = %q", l.Path())
	}
}
