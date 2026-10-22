package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestOpenMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, ok := s.Port("host-abc123"); ok {
		t.Fatal("unexpected port for unknown host")
	}
	if err := CheckFile(path); err != nil {
		t.Fatalf("CheckFile(missing) = %v", err)
	}
}

func TestSetPortPersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s.SetPort("host-abc123", 30001); err != nil {
		t.Fatalf("SetPort: %v", err)
	}
	if port, ok := s.Port("host-abc123"); !ok || port != 30001 {
		t.Fatalf("Port = (%d, %v)", port, ok)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read state file: %v", err)
	}
	var fd fileData
	if err := json.Unmarshal(data, &fd); err != nil {
		t.Fatalf("state file is not valid JSON: %v", err)
	}
	if fd.Version != Version || fd.Hosts["host-abc123"].Port != 30001 {
		t.Fatalf("state file contents = %+v", fd)
	}
	if info, err := os.Stat(path); err == nil && info.Mode().Perm() != 0o600 {
		t.Fatalf("state file mode = %v, want 0600", info.Mode().Perm())
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if port, ok := s2.Port("host-abc123"); !ok || port != 30001 {
		t.Fatalf("persisted Port = (%d, %v)", port, ok)
	}
	if err := CheckFile(path); err != nil {
		t.Fatalf("CheckFile = %v", err)
	}
	if err := s2.Delete("host-abc123"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := s2.Port("host-abc123"); ok {
		t.Fatal("Delete did not remove the mapping")
	}
}

func TestSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s, _ := Open(path)
	_ = s.SetPort("host-aaaa1111", 30001)
	_ = s.SetPort("host-bbbb2222", 30002)
	snap := s.Snapshot()
	if len(snap) != 2 || snap["host-aaaa1111"] != 30001 || snap["host-bbbb2222"] != 30002 {
		t.Fatalf("Snapshot = %v", snap)
	}
	snap["host-aaaa1111"] = 999
	if port, _ := s.Port("host-aaaa1111"); port != 30001 {
		t.Fatal("Snapshot must not alias internal state")
	}
}

func TestOpenCorruptAndUnsupported(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("Open accepted corrupt state")
	}
	if err := CheckFile(path); err == nil {
		t.Fatal("CheckFile accepted corrupt state")
	}
	if err := os.WriteFile(path, []byte(`{"version":99,"hosts":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("Open accepted future schema version")
	}
}
