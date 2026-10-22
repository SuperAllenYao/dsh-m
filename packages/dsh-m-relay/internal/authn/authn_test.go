package authn

import (
	"encoding/base64"
	"testing"
	"time"
)

var testSecret = []byte("test-relay-secret-0123456789abcdef")

func goodHello(now time.Time, hostID, nonce string) *Hello {
	h := &Hello{
		T:        "hello",
		V:        1,
		HostID:   hostID,
		HostName: "Mac",
		Ts:       now.UnixMilli(),
		Nonce:    nonce,
	}
	h.Auth = ComputeAuth(testSecret, h.HostID, h.Ts, h.Nonce, h.WantPort)
	return h
}

func TestVerifyHelloOK(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := NewNonceCache(NonceTTL, 100)
	h := goodHello(now, "host-abc123", "nonce-abcdef")
	if err := VerifyHello(h, testSecret, now, cache); err != nil {
		t.Fatalf("VerifyHello: %v", err)
	}
	if cache.Len() != 1 {
		t.Fatalf("cache len = %d, want 1", cache.Len())
	}
	// Same hello again is a replay.
	if err := VerifyHello(h, testSecret, now, cache); err == nil || err.Code != CodeAuthReplay {
		t.Fatalf("replay err = %v, want %s", err, CodeAuthReplay)
	}
}

func TestVerifyHelloWithWantPort(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := NewNonceCache(NonceTTL, 100)
	port := 30001
	h := goodHello(now, "host-abc123", "nonce-port-1")
	h.WantPort = &port
	h.Auth = ComputeAuth(testSecret, h.HostID, h.Ts, h.Nonce, h.WantPort)
	if err := VerifyHello(h, testSecret, now, cache); err != nil {
		t.Fatalf("VerifyHello(wantPort): %v", err)
	}

	// Signing without wantPort but sending one must fail.
	h2 := goodHello(now, "host-abc123", "nonce-port-2")
	h2.WantPort = &port
	if err := VerifyHello(h2, testSecret, now, cache); err == nil || err.Code != CodeAuthInvalid {
		t.Fatalf("err = %v, want %s", err, CodeAuthInvalid)
	}

	// Signature over wantPort 0 differs from an absent wantPort.
	if CanonicalMessage("h", 1, "n", nil) == CanonicalMessage("h", 1, "n", &port) {
		t.Fatal("canonical message must include wantPort")
	}
	zero := 0
	if CanonicalMessage("h", 1, "n", nil) == CanonicalMessage("h", 1, "n", &zero) {
		t.Fatal("wantPort 0 must render as \"0\"")
	}
}

func TestVerifyHelloErrorCodes(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	newCache := func() *NonceCache { return NewNonceCache(NonceTTL, 100) }

	cases := []struct {
		name string
		mod  func(*Hello)
		code string
	}{
		{"wrong type", func(h *Hello) { h.T = "ping" }, CodeAuthInvalid},
		{"version", func(h *Hello) { h.V = 2 }, CodeVersionUnsupport},
		{"bad hostId", func(h *Hello) { h.HostID = "short" }, CodeAuthInvalid},
		{"bad hostId chars", func(h *Hello) { h.HostID = "host id with spaces" }, CodeAuthInvalid},
		{"stale ts", func(h *Hello) { h.Ts = now.Add(-3 * time.Minute).UnixMilli() }, CodeAuthInvalid},
		{"future ts", func(h *Hello) { h.Ts = now.Add(3 * time.Minute).UnixMilli() }, CodeAuthInvalid},
		{"missing ts", func(h *Hello) { h.Ts = 0 }, CodeAuthInvalid},
		{"bad nonce", func(h *Hello) { h.Nonce = "short" }, CodeAuthInvalid},
		{"bad signature", func(h *Hello) {
			h.Auth = base64.RawURLEncoding.EncodeToString([]byte("01234567890123456789012345678901"))
		}, CodeAuthInvalid},
		{"empty auth", func(h *Hello) { h.Auth = "" }, CodeAuthInvalid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := goodHello(now, "host-abc123", "nonce-unique-"+tc.name)
			tc.mod(h)
			err := VerifyHello(h, testSecret, now, newCache())
			if err == nil {
				t.Fatalf("VerifyHello accepted an invalid hello")
			}
			if err.Code != tc.code {
				t.Fatalf("code = %q, want %q", err.Code, tc.code)
			}
		})
	}
}

func TestVerifyHelloWrongSecret(t *testing.T) {
	now := time.Now()
	h := goodHello(now, "host-abc123", "nonce-wrong-secret")
	err := VerifyHello(h, []byte("other-secret"), now, NewNonceCache(NonceTTL, 10))
	if err == nil || err.Code != CodeAuthInvalid {
		t.Fatalf("err = %v, want %s", err, CodeAuthInvalid)
	}
}

func TestNonceCacheTTL(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := NewNonceCache(time.Minute, 100)
	if !cache.CheckAndAdd("a", now) {
		t.Fatal("first add rejected")
	}
	if cache.CheckAndAdd("a", now) {
		t.Fatal("duplicate accepted")
	}
	// Expired entries are pruned once the cache is full.
	for i := 0; i < 99; i++ {
		cache.CheckAndAdd(string(rune('b'+i%20))+string(rune('0'+i/20)), now.Add(time.Second))
	}
	if cache.Len() != 100 {
		t.Fatalf("cache len = %d, want 100", cache.Len())
	}
	later := now.Add(2 * time.Minute)
	if !cache.CheckAndAdd("fresh-1", later) {
		t.Fatal("fresh key rejected unexpectedly")
	}
}

func TestNonceCacheCapacity(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := NewNonceCache(time.Hour, 2)
	if !cache.CheckAndAdd("a", now) || !cache.CheckAndAdd("b", now) {
		t.Fatal("inserts within capacity failed")
	}
	if cache.CheckAndAdd("c", now) {
		t.Fatal("cache accepted a key beyond capacity without pruning")
	}
}
