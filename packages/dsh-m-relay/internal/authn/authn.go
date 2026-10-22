// Package authn implements the relay control-channel hello authentication
// (protocol v0, <internal-doc> §4.4).
//
// The tunnel sends as its first frame a JSON hello carrying a base64url
// HMAC-SHA256 over the canonical string
//
// "dshm-relay-hello/1\n" + hostId + "\n" + ts + "\n" + nonce + "\n" + (wantPort?? "")
//
// signed with the shared relay secret. The relay checks the version, the ±120s
// clock window, a 5-minute replay cache on the nonce, and compares the HMAC in
// constant time. Failure codes are fixed by the design doc.
package authn

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"regexp"
	"strconv"
	"sync"
	"time"
)

const (
	// HelloPrefix is the canonical-string prefix of protocol v0.
	HelloPrefix = "dshm-relay-hello/1\n"
	// ProtocolVersion is the only supported hello version.
	ProtocolVersion = 1
	// ClockSkew is the accepted |now - ts| window.
	ClockSkew = 120 * time.Second
	// NonceTTL is how long a nonce is remembered for replay protection.
	NonceTTL = 5 * time.Minute
	// DefaultNonceMaxEntries bounds replay-cache memory.
	DefaultNonceMaxEntries = 1 << 16
)

// Error codes defined by the design doc.
const (
	CodeAuthInvalid      = "auth/invalid"
	CodeAuthReplay       = "auth/replay"
	CodeVersionUnsupport = "version/unsupported"
)

var (
	hostIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)
	nonceRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)
)

// Hello is the first control frame sent by the tunnel. Message-level fields are
// decoded from JSON; Meta is opaque to the relay.
type Hello struct {
	T        string         `json:"t"`
	V        int            `json:"v"`
	HostID   string         `json:"hostId"`
	HostName string         `json:"hostName"`
	Ts       int64          `json:"ts"`
	Nonce    string         `json:"nonce"`
	WantPort *int           `json:"wantPort,omitempty"`
	Auth     string         `json:"auth"`
	Meta     map[string]any `json:"meta,omitempty"`
}

// Error is a protocol error with a design-doc error code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// CanonicalMessage returns the exact string that is HMAC-ed for a hello.
// wantPort nil (or absent) is rendered as the empty string, matching the
// JavaScript `(wantPort?? "")` contract.
func CanonicalMessage(hostID string, ts int64, nonce string, wantPort *int) string {
	port := ""
	if wantPort != nil {
		port = strconv.Itoa(*wantPort)
	}
	return HelloPrefix + hostID + "\n" + strconv.FormatInt(ts, 10) + "\n" + nonce + "\n" + port
}

// ComputeAuth returns base64url(HMAC-SHA256(secret, canonical)) without padding.
func ComputeAuth(secret []byte, hostID string, ts int64, nonce string, wantPort *int) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(CanonicalMessage(hostID, ts, nonce, wantPort)))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// VerifyHello validates a hello. It returns nil when the hello is authentic and
// fresh. Duplicate (hostId, nonce) pairs are rejected as auth/replay.
//
// Ordering note: the HMAC is checked before the nonce is inserted, so an
// unauthenticated client cannot poison the replay cache. A captured hello still
// carries a valid HMAC, so genuine replays are still reported as auth/replay.
func VerifyHello(h *Hello, secret []byte, now time.Time, cache *NonceCache) *Error {
	if h == nil {
		return &Error{Code: CodeAuthInvalid, Message: "empty hello"}
	}
	if h.T != "hello" {
		return &Error{Code: CodeAuthInvalid, Message: "first control frame must be hello"}
	}
	if h.V != ProtocolVersion {
		return &Error{Code: CodeVersionUnsupport, Message: fmt.Sprintf("unsupported protocol version %d", h.V)}
	}
	if !hostIDRe.MatchString(h.HostID) {
		return &Error{Code: CodeAuthInvalid, Message: "invalid hostId"}
	}
	if h.Ts <= 0 {
		return &Error{Code: CodeAuthInvalid, Message: "missing ts"}
	}
	skew := now.Sub(time.UnixMilli(h.Ts))
	if skew < -ClockSkew || skew > ClockSkew {
		return &Error{Code: CodeAuthInvalid, Message: "ts outside ±120s window"}
	}
	if !nonceRe.MatchString(h.Nonce) {
		return &Error{Code: CodeAuthInvalid, Message: "invalid nonce"}
	}
	expected := ComputeAuth(secret, h.HostID, h.Ts, h.Nonce, h.WantPort)
	if subtle.ConstantTimeCompare([]byte(h.Auth), []byte(expected)) != 1 {
		return &Error{Code: CodeAuthInvalid, Message: "bad signature"}
	}
	if len(h.HostName) > 512 {
		return &Error{Code: CodeAuthInvalid, Message: "hostName too long"}
	}
	if cache != nil && !cache.CheckAndAdd(h.HostID+"\x00"+h.Nonce, now) {
		return &Error{Code: CodeAuthReplay, Message: "nonce already used"}
	}
	return nil
}

// NonceCache is a bounded, TTL-scoped set used for hello replay protection.
type NonceCache struct {
	mu        sync.Mutex
	ttl       time.Duration
	max       int
	seen      map[string]time.Time
	lastPrune time.Time
}

// NewNonceCache returns a replay cache. ttl <= 0 defaults to NonceTTL;
// maxEntries <= 0 defaults to DefaultNonceMaxEntries.
func NewNonceCache(ttl time.Duration, maxEntries int) *NonceCache {
	if ttl <= 0 {
		ttl = NonceTTL
	}
	if maxEntries <= 0 {
		maxEntries = DefaultNonceMaxEntries
	}
	return &NonceCache{ttl: ttl, max: maxEntries, seen: make(map[string]time.Time)}
}

// CheckAndAdd records key and reports whether it was fresh. When the cache is
// full even after pruning, the key is rejected (treated as a replay) rather than
// allowing unbounded growth.
func (c *NonceCache) CheckAndAdd(key string, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.seen[key]; ok {
		return false
	}
	if len(c.seen) >= c.max {
		c.pruneLocked(now)
		if len(c.seen) >= c.max {
			return false
		}
	}
	c.seen[key] = now
	return true
}

// pruneLocked drops expired entries. It runs at most once per second.
func (c *NonceCache) pruneLocked(now time.Time) {
	if now.Sub(c.lastPrune) < time.Second && len(c.seen) < c.max {
		return
	}
	c.lastPrune = now
	cutoff := now.Add(-c.ttl)
	for k, seen := range c.seen {
		if seen.Before(cutoff) {
			delete(c.seen, k)
		}
	}
}

// Len reports the number of remembered nonces (tests / diagnostics).
func (c *NonceCache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.seen)
}
