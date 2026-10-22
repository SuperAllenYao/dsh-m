package relay

import (
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	codeRe        = regexp.MustCompile(`^[0-9]{8}$`)
	leafPinRe     = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)
	maxLookupBody = int64(4 << 10)
)

// codeEntry is the in-memory rendezvous record published by a tunnel. It is
// never persisted and expires with its TTL (design doc §4.5).
type codeEntry struct {
	Code               string
	HostID             string
	HostName           string
	Port               int
	LeafPin            string
	LeafFingerprint256 string
	Exp                int64 // unix seconds
}

// codeRegistry keeps at most one active pairing code per host, indexed both by
// code and by hostId.
type codeRegistry struct {
	mu     sync.Mutex
	byCode map[string]codeEntry
	byHost map[string]string // hostId -> code
}

func newCodeRegistry() *codeRegistry {
	return &codeRegistry{byCode: make(map[string]codeEntry), byHost: make(map[string]string)}
}

// set installs (replacing any previous code of the same host or code).
func (r *codeRegistry) set(e codeEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if oldCode, ok := r.byHost[e.HostID]; ok {
		delete(r.byCode, oldCode)
	}
	// A code collision across hosts: the latest publisher wins.
	if prev, ok := r.byCode[e.Code]; ok && prev.HostID != e.HostID {
		delete(r.byHost, prev.HostID)
	}
	r.byCode[e.Code] = e
	r.byHost[e.HostID] = e.Code
}

// clearHost removes the current code of hostID (code_clear or tunnel disconnect).
func (r *codeRegistry) clearHost(hostID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if code, ok := r.byHost[hostID]; ok {
		delete(r.byCode, code)
		delete(r.byHost, hostID)
	}
}

// lookup returns the entry and a status: "hit", "expired", or "not-found".
// Expired entries are removed so a later lookup reports not-found.
func (r *codeRegistry) lookup(code string, now time.Time) (codeEntry, string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.byCode[code]
	if !ok {
		return codeEntry{}, "not-found"
	}
	if e.Exp <= now.Unix() {
		delete(r.byCode, code)
		if r.byHost[e.HostID] == code {
			delete(r.byHost, e.HostID)
		}
		return codeEntry{}, "expired"
	}
	return e, "hit"
}

// sweep drops entries that expired more than grace ago. Expired entries are kept
// briefly so lookups can still answer `code/expired` (410) instead of
// `code/not-found` (404), which the App surfaces with a different message.
func (r *codeRegistry) sweep(now time.Time, grace time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-grace).Unix()
	for code, e := range r.byCode {
		if e.Exp < cutoff {
			delete(r.byCode, code)
			if r.byHost[e.HostID] == code {
				delete(r.byHost, e.HostID)
			}
		}
	}
}

// len reports the number of live entries (tests / diagnostics).
func (r *codeRegistry) len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.byCode)
}

// --- HTTP surface ------------------------------------------------------------

type healthResponse struct {
	OK          bool   `json:"ok"`
	Version     string `json:"version"`
	UptimeSec   int64  `json:"uptimeSec"`
	Hosts       int    `json:"hosts"`
	BridgePorts string `json:"bridgePorts"`
	BridgeBind  string `json:"bridgeBind"`
	Draining    bool   `json:"draining"`
}

type lookupOK struct {
	OK                 bool   `json:"ok"`
	HostID             string `json:"hostId"`
	HostName           string `json:"hostName"`
	Origin             string `json:"origin"`
	LeafPin            string `json:"leafPin"`
	LeafFingerprint256 string `json:"leafFingerprint256"`
	Exp                int64  `json:"exp"`
}

type lookupErr struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

func (s *Server) httpHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/lookup":
			s.handleLookup(w, r)
		case "/healthz":
			s.handleHealthz(w, r)
		default:
			writeJSON(w, http.StatusNotFound, lookupErr{OK: false, Error: "not-found"})
		}
	})
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeJSON(w, http.StatusMethodNotAllowed, lookupErr{OK: false, Error: "method/not-allowed"})
		return
	}
	now := s.now()
	resp := healthResponse{
		OK:          true,
		Version:     Version,
		UptimeSec:   int64(now.Sub(s.startedAt).Seconds()),
		Hosts:       s.hostCount(),
		BridgePorts: s.cfg.BridgePorts.String(),
		BridgeBind:  s.cfg.BridgeBind,
		Draining:    s.draining.Load(),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleLookup(w http.ResponseWriter, r *http.Request) {
	ip := remoteIP(r.RemoteAddr)
	// Rate limit first so malformed/method-abusing requests cannot bypass it.
	if !s.lookupLimiter.allow(ip) {
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "rate-limited"})
		writeJSON(w, http.StatusTooManyRequests, lookupErr{OK: false, Error: "rate-limited"})
		return
	}
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, lookupErr{OK: false, Error: "method/not-allowed"})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxLookupBody))
	if err != nil {
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "body-read-failed"})
		writeJSON(w, http.StatusBadRequest, lookupErr{OK: false, Error: "bad/request"})
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "bad-json"})
		writeJSON(w, http.StatusBadRequest, lookupErr{OK: false, Error: "bad/request"})
		return
	}
	code := strings.TrimSpace(req.Code)
	if !codeRe.MatchString(code) {
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "malformed-code"})
		writeJSON(w, http.StatusNotFound, lookupErr{OK: false, Error: "code/not-found"})
		return
	}
	entry, status := s.codes.lookup(code, s.now())
	switch status {
	case "hit":
		s.audit.Log("lookup.hit", map[string]any{"ip": ip, "hostId": entry.HostID, "port": entry.Port, "exp": entry.Exp})
		writeJSON(w, http.StatusOK, lookupOK{
			OK:                 true,
			HostID:             entry.HostID,
			HostName:           entry.HostName,
			Origin:             s.originFor(entry.Port),
			LeafPin:            entry.LeafPin,
			LeafFingerprint256: entry.LeafFingerprint256,
			Exp:                entry.Exp,
		})
	case "expired":
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "code/expired"})
		writeJSON(w, http.StatusGone, lookupErr{OK: false, Error: "code/expired"})
	default:
		s.audit.Log("lookup.miss", map[string]any{"ip": ip, "reason": "code/not-found"})
		writeJSON(w, http.StatusNotFound, lookupErr{OK: false, Error: "code/not-found"})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
