// Package state persists the relay's hostId -> bridge-port allocations in one
// state.json file (no database). The mapping is intentionally retained across
// tunnel disconnects and relay restarts so a Mac reconnects to the same public
// bridge port; `drain` also keeps it (design doc §4.4).
package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Version is the on-disk schema version.
const Version = 1

// HostRecord is one hostId -> port allocation.
type HostRecord struct {
	Port      int    `json:"port"`
	UpdatedAt string `json:"updatedAt"` // RFC3339
}

type fileData struct {
	Version int                   `json:"version"`
	Hosts   map[string]HostRecord `json:"hosts"`
}

// Store is a concurrency-safe view over state.json.
type Store struct {
	mu    sync.Mutex
	path  string
	hosts map[string]HostRecord
	now   func() time.Time
}

// Open loads state.json. A missing file yields an empty store (first run).
func Open(path string) (*Store, error) {
	s := &Store{path: path, hosts: make(map[string]HostRecord), now: time.Now}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return nil, fmt.Errorf("state: read %s: %w", path, err)
	}
	if len(data) == 0 {
		return s, nil
	}
	var fd fileData
	if err := json.Unmarshal(data, &fd); err != nil {
		return nil, fmt.Errorf("state: parse %s: %w", path, err)
	}
	if fd.Version > Version {
		return nil, fmt.Errorf("state: %s has unsupported version %d (relay supports %d)", path, fd.Version, Version)
	}
	for hostID, rec := range fd.Hosts {
		if rec.Port <= 0 || rec.Port > 65535 {
			continue
		}
		s.hosts[hostID] = rec
	}
	return s, nil
}

// CheckFile validates an existing state file without creating or modifying it.
// A missing file is not an error (serve creates it on first allocation).
func CheckFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read %s: %w", path, err)
	}
	if len(data) == 0 {
		return nil
	}
	var fd fileData
	if err := json.Unmarshal(data, &fd); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	if fd.Version > Version {
		return fmt.Errorf("%s has unsupported version %d", path, fd.Version)
	}
	return nil
}

// Port returns the persisted bridge port for hostID.
func (s *Store) Port(hostID string) (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.hosts[hostID]
	return rec.Port, ok
}

// Snapshot returns a copy of the hostId -> port mapping.
func (s *Store) Snapshot() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]int, len(s.hosts))
	for hostID, rec := range s.hosts {
		out[hostID] = rec.Port
	}
	return out
}

// SetPort records (or updates) the port for hostID and persists atomically.
func (s *Store) SetPort(hostID string, port int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hosts[hostID] = HostRecord{Port: port, UpdatedAt: s.now().UTC().Format(time.RFC3339)}
	return s.saveLocked()
}

// Delete removes hostID from the state file. The relay keeps allocations on
// purpose (port stability); this is available for operator cleanup/tests.
func (s *Store) Delete(hostID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.hosts, hostID)
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("state: create directory %s: %w", dir, err)
	}
	data, err := json.MarshalIndent(fileData{Version: Version, Hosts: s.hosts}, "", "  ")
	if err != nil {
		return fmt.Errorf("state: marshal: %w", err)
	}
	data = append(data, '\n')
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("state: write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return fmt.Errorf("state: rename %s: %w", s.path, err)
	}
	return nil
}
