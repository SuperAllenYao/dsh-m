package relay

import (
	"testing"
	"time"
)

func TestKeyedLimiterBurstAndRefill(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := now
	l := newKeyedLimiter(3, time.Minute, func() time.Time { return current })

	for i := 0; i < 3; i++ {
		if !l.allow("a") {
			t.Fatalf("burst token %d denied", i)
		}
	}
	if l.allow("a") {
		t.Fatal("limiter allowed more than its burst")
	}
	if !l.allow("b") {
		t.Fatal("limiter keys must be independent")
	}
	// 3 tokens/minute => one token per 20s.
	current = current.Add(21 * time.Second)
	if !l.allow("a") {
		t.Fatal("refilled token denied")
	}
	if l.allow("a") {
		t.Fatal("limiter refilled more than one token")
	}
	if got := l.len(); got != 2 {
		t.Fatalf("tracked keys = %d, want 2", got)
	}
}

func TestKeyedLimiterPrune(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	current := now
	l := newKeyedLimiter(10, time.Minute, func() time.Time { return current })
	l.allow("idle")
	current = current.Add(time.Hour)
	l.allow("active")
	if got := l.len(); got != 2 {
		t.Fatalf("tracked keys = %d, want 2", got)
	}
	l.prune(current)
	if got := l.len(); got != 1 {
		t.Fatalf("after prune tracked keys = %d, want 1", got)
	}
}
