package relay

import (
	"net"
	"strconv"
	"testing"

	"dshm-relay/internal/config"
)

// freePortForPool returns a currently-free 127.0.0.1 port.
func freePortForPool(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("find free port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	if err := ln.Close(); err != nil {
		t.Fatalf("close probe listener: %v", err)
	}
	return port
}

// TestAcquireTransientBindFailureIsServerBusy: the requested wantPort is inside
// the pool and not owned by another host, but the OS refuses the bind right now
// (another process holds it). That is transient, so the relay must answer
// server/busy — the plugin retries with backoff (task-9). It must NOT be
// port/unavailable, which the plugin treats as a permanent configuration error.
func TestAcquireTransientBindFailureIsServerBusy(t *testing.T) {
	port := freePortForPool(t)
	occupied, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatalf("occupy port %d: %v", port, err)
	}
	defer occupied.Close()

	pool := newPortPool(config.PortRange{Start: port, End: port}, "127.0.0.1", nil)
	gotPort, ln, perr := pool.acquire("host-transient-01", &port, 0)
	if ln != nil {
		_ = ln.Close()
	}
	if perr == nil {
		t.Fatalf("acquire succeeded on an occupied port (got %d)", gotPort)
	}
	if perr.Code != codeServerBusy {
		t.Fatalf("error code = %q, want %q (transient bind failure must be retryable)", perr.Code, codeServerBusy)
	}
	if got, want := perr.Code, codePortUnavailable; got == want {
		t.Fatalf("transient bind failure was reported as permanent %q", want)
	}
}

// TestAcquirePermanentConflictsArePortUnavailable covers the long-term conflicts
// that stay port/unavailable: wantPort outside the pool, wantPort owned by a
// different host, and a pool fully reserved by other hosts. It also checks that a
// host can re-acquire its own previous wantPort (reconnect path).
func TestAcquirePermanentConflictsArePortUnavailable(t *testing.T) {
	start := freePortForPool(t)
	pool := newPortPool(config.PortRange{Start: start, End: start + 2}, "127.0.0.1", nil)

	// (a) wantPort outside the bridge pool.
	outside := start + 1000
	if _, _, perr := pool.acquire("host-perm-000001", &outside, 0); perr == nil || perr.Code != codePortUnavailable {
		t.Fatalf("outside-pool wantPort error = %v, want %q", perr, codePortUnavailable)
	}

	// Reserve a port for host A, then:
	// (b) host B asking for the same wantPort is a permanent conflict;
	// (c) host A re-acquiring its own previous port still works (state reuse).
	port, ln, perr := pool.acquire("host-perm-aaaaaa", nil, 0)
	if perr != nil {
		t.Fatalf("host A acquire: %v", perr)
	}
	if _, _, perr := pool.acquire("host-perm-bbbbbb", &port, 0); perr == nil || perr.Code != codePortUnavailable {
		t.Fatalf("other-host wantPort error = %v, want %q", perr, codePortUnavailable)
	}
	_ = ln.Close()
	againPort, againLn, perr := pool.acquire("host-perm-aaaaaa", &port, 0)
	if perr != nil || againPort != port {
		t.Fatalf("host A re-acquire = (%d, %v), want (%d, nil)", againPort, perr, port)
	}
	_ = againLn.Close()

	// (d) a pool fully reserved by other hosts is a permanent conflict too.
	tiny := newPortPool(config.PortRange{Start: start, End: start}, "127.0.0.1", nil)
	_, tinyLn, perr := tiny.acquire("host-perm-cccccc", nil, 0)
	if perr != nil {
		t.Fatalf("tiny pool first acquire: %v", perr)
	}
	_ = tinyLn.Close()
	if _, _, perr := tiny.acquire("host-perm-dddddd", nil, 0); perr == nil || perr.Code != codePortUnavailable {
		t.Fatalf("exhausted pool error = %v, want %q", perr, codePortUnavailable)
	}
}
