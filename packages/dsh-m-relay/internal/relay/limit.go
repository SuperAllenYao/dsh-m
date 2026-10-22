package relay

import (
	"sync"
	"time"
)

// keyedLimiter is a per-key token bucket. It is used for /v1/lookup (key = source
// IP, window 1 minute) and for bridge accepts (key = bridge port, window 1s).
// A key that has not been seen for a while is pruned so the map stays small.
type keyedLimiter struct {
	mu      sync.Mutex
	limit   float64
	window  time.Duration
	buckets map[string]*tokenBucket
	now     func() time.Time
	lastGC  time.Time
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

func newKeyedLimiter(limit int, window time.Duration, now func() time.Time) *keyedLimiter {
	if limit < 1 {
		limit = 1
	}
	if window <= 0 {
		window = time.Minute
	}
	return &keyedLimiter{
		limit:   float64(limit),
		window:  window,
		buckets: make(map[string]*tokenBucket),
		now:     now,
	}
}

// allow consumes one token for key, or reports false when the bucket is empty.
func (l *keyedLimiter) allow(key string) bool {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		b = &tokenBucket{tokens: l.limit, last: now}
		l.buckets[key] = b
	}
	ratePerSec := l.limit / l.window.Seconds()
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * ratePerSec
		if b.tokens > l.limit {
			b.tokens = l.limit
		}
		b.last = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// prune drops idle buckets; it runs at most once per window.
func (l *keyedLimiter) prune(now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.lastGC) < l.window {
		return
	}
	l.lastGC = now
	cutoff := now.Add(-2 * l.window)
	for k, b := range l.buckets {
		if b.last.Before(cutoff) {
			delete(l.buckets, k)
		}
	}
}

// len reports the number of tracked keys (tests / diagnostics).
func (l *keyedLimiter) len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
