package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"testing"
	"time"

	"dshm-relay/internal/authn"
	"dshm-relay/internal/config"
	"dshm-relay/internal/wire"
)

func TestHelloReady(t *testing.T) {
	env := newTestEnv(t, nil)
	ft, ready := env.tunnelReady(t, "host-ready-0001", nil)
	defer ft.conn.Close()

	if ready.T != "ready" || ready.V != 1 {
		t.Fatalf("ready = %+v", ready)
	}
	if ready.HostID != "host-ready-0001" {
		t.Fatalf("hostId = %q", ready.HostID)
	}
	if ready.PublicHost != "127.0.0.1" {
		t.Fatalf("publicHost = %q", ready.PublicHost)
	}
	if !env.cfg.BridgePorts.Contains(ready.Port) {
		t.Fatalf("port %d outside pool %s", ready.Port, env.cfg.BridgePorts)
	}
	wantOrigin := fmt.Sprintf("https://127.0.0.1:%d", ready.Port)
	if ready.Origin != wantOrigin {
		t.Fatalf("origin = %q, want %q", ready.Origin, wantOrigin)
	}
	if ready.HeartbeatSec != env.cfg.HeartbeatSec {
		t.Fatalf("heartbeatSec = %d, want %d", ready.HeartbeatSec, env.cfg.HeartbeatSec)
	}
	if got, ok := env.srv.BridgePort("host-ready-0001"); !ok || got != ready.Port {
		t.Fatalf("BridgePort = (%d, %v), want %d", got, ok, ready.Port)
	}
	if env.srv.hostCount() != 1 {
		t.Fatalf("hostCount = %d, want 1", env.srv.hostCount())
	}
	// The bridge port is actually bound (a second bind must fail).
	bridgeAddr := net.JoinHostPort(env.cfg.BridgeBind, fmt.Sprintf("%d", ready.Port))
	if ln, err := net.Listen("tcp", bridgeAddr); err == nil {
		_ = ln.Close()
		t.Fatalf("bridge port %s was not bound by the relay", bridgeAddr)
	}
	// State file records hostId -> port.
	data, err := os.ReadFile(env.cfg.StateFile)
	if err != nil {
		t.Fatalf("read state file: %v", err)
	}
	var fd struct {
		Version int `json:"version"`
		Hosts   map[string]struct {
			Port int `json:"port"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(data, &fd); err != nil {
		t.Fatalf("state file JSON: %v", err)
	}
	if fd.Hosts["host-ready-0001"].Port != ready.Port {
		t.Fatalf("state hosts = %+v", fd.Hosts)
	}
}

func TestWantPortHonoredAndReused(t *testing.T) {
	env := newTestEnv(t, nil)
	want := env.cfg.BridgePorts.Start + 3
	ft, ready := env.tunnelReady(t, "host-wantport-1", &want)
	if ready.Port != want {
		t.Fatalf("ready.Port = %d, want %d", ready.Port, want)
	}
	_ = ft.conn.Close()
	waitHostCount(t, env, 0, time.Second)

	// Reconnect without wantPort: the persisted port must be reused.
	_, ready2 := env.tunnelReady(t, "host-wantport-1", nil)
	if ready2.Port != want {
		t.Fatalf("reused port = %d, want %d", ready2.Port, want)
	}
}

func TestAuthErrorCodes(t *testing.T) {
	env := newTestEnv(t, nil)
	hostID := "auth-host-0001"
	now := time.Now()

	reSign := func(m map[string]any, hostID string, ts int64) {
		m["hostId"] = hostID
		m["ts"] = ts
		m["auth"] = authn.ComputeAuth(env.secret, hostID, ts, m["nonce"].(string), nil)
	}

	cases := []struct {
		name   string
		want   string
		mutate func(map[string]any)
	}{
		{
			name: "bad-signature",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				m["auth"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			},
		},
		{
			name: "missing-auth",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				delete(m, "auth")
			},
		},
		{
			name: "stale-ts",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				reSign(m, hostID, now.Add(-3*time.Minute).UnixMilli())
			},
		},
		{
			name: "future-ts",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				reSign(m, hostID, now.Add(3*time.Minute).UnixMilli())
			},
		},
		{
			name: "unsupported-version",
			want: codeVersionUnsup,
			mutate: func(m map[string]any) {
				m["v"] = 2
			},
		},
		{
			name: "bad-hostid",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				reSign(m, "short", m["ts"].(int64))
			},
		},
		{
			name: "bad-nonce",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				m["nonce"] = "abc"
				m["auth"] = authn.ComputeAuth(env.secret, hostID, m["ts"].(int64), "abc", nil)
			},
		},
		{
			name: "wantport-not-signed",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				m["wantPort"] = env.cfg.BridgePorts.Start + 1
			},
		},
		{
			name: "wrong-type",
			want: codeAuthInvalid,
			mutate: func(m map[string]any) {
				m["t"] = "ping"
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ts := time.Now().UnixMilli()
			msg := helloMessage(env.secret, hostID, ts, testNonce(t), nil)
			tc.mutate(msg)
			if got := env.expectHelloError(t, hostID, msg); got != tc.want {
				t.Fatalf("error code = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestHelloReplayRejected(t *testing.T) {
	env := newTestEnv(t, nil)
	hostID := "replay-host-0001"
	msg := helloMessage(env.secret, hostID, time.Now().UnixMilli(), testNonce(t), nil)

	ft := env.dialTunnel(t, hostID)
	if err := ft.sendJSON(msg); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	first, err := ft.readJSON(3 * time.Second)
	if err != nil || first["t"] != "ready" {
		t.Fatalf("first hello = %v, %v", first, err)
	}
	// Replaying the exact same authenticated hello (same nonce) must fail.
	if got := env.expectHelloError(t, hostID, msg); got != codeAuthReplay {
		t.Fatalf("replay code = %q, want %q", got, codeAuthReplay)
	}
}

func TestFirstFrameMustBeHello(t *testing.T) {
	env := newTestEnv(t, nil)
	ft := env.dialTunnel(t, "first-frame-0001")
	if err := ft.sendJSON(map[string]any{"t": "ping", "ts": 1}); err != nil {
		t.Fatalf("send: %v", err)
	}
	resp, err := ft.readJSON(3 * time.Second)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp["t"] != "error" || resp["code"] != codeAuthInvalid {
		t.Fatalf("response = %v, want auth/invalid", resp)
	}
}

func TestPortUnavailable(t *testing.T) {
	env := newTestEnv(t, nil)
	_, ready := env.tunnelReady(t, "host-port-a-0001", nil)

	// wantPort already owned by another host.
	want := ready.Port
	msg := helloMessage(env.secret, "host-port-b-0001", time.Now().UnixMilli(), testNonce(t), &want)
	if got := env.expectHelloError(t, "host-port-b-0001", msg); got != codePortUnavailable {
		t.Fatalf("occupied wantPort code = %q, want %q", got, codePortUnavailable)
	}

	// wantPort outside the bridge pool.
	outside := env.cfg.BridgePorts.End + 1
	msg2 := helloMessage(env.secret, "host-port-c-0001", time.Now().UnixMilli(), testNonce(t), &outside)
	if got := env.expectHelloError(t, "host-port-c-0001", msg2); got != codePortUnavailable {
		t.Fatalf("outside wantPort code = %q, want %q", got, codePortUnavailable)
	}
}

// TestPoolExhaustedPortUnavailable: a pool whose only port is reserved by
// another host is a long-term conflict, so the second host gets port/unavailable
// (permanent from the plugin's point of view) rather than server/busy.
func TestPoolExhaustedPortUnavailable(t *testing.T) {
	env := newTestEnv(t, func(c *config.Config) {
		c.BridgePorts = config.PortRange{Start: c.BridgePorts.Start, End: c.BridgePorts.Start}
	})
	env.tunnelReady(t, "host-busy-a-0001", nil)
	msg := helloMessage(env.secret, "host-busy-b-0001", time.Now().UnixMilli(), testNonce(t), nil)
	if got := env.expectHelloError(t, "host-busy-b-0001", msg); got != codePortUnavailable {
		t.Fatalf("error code = %q, want %q", got, codePortUnavailable)
	}
}

func TestReconnectSupersedesOldSession(t *testing.T) {
	env := newTestEnv(t, nil)
	ft1, ready1 := env.tunnelReady(t, "host-super-0001", nil)
	_, ready2 := env.tunnelReady(t, "host-super-0001", nil)
	if ready2.Port != ready1.Port {
		t.Fatalf("reconnect port = %d, want %d", ready2.Port, ready1.Port)
	}
	// The old control connection must be closed by the relay.
	_ = ft1.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := wire.ReadFrame(ft1.br); err == nil {
		t.Fatal("old tunnel connection is still open after supersede")
	}
	if env.srv.hostCount() != 1 {
		t.Fatalf("hostCount = %d, want 1", env.srv.hostCount())
	}
}

func TestStatePersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	poolStart := freePortRange(t, 8)
	mutate := func(c *config.Config) {
		c.BridgePorts = config.PortRange{Start: poolStart, End: poolStart + 7}
	}
	env1 := newTestEnvInDir(t, dir, mutate)
	ft1, ready1 := env1.tunnelReady(t, "host-state-0001", nil)
	_ = ft1.conn.Close()
	waitHostCount(t, env1, 0, 2*time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := env1.srv.Shutdown(ctx); err != nil {
		cancel()
		t.Fatalf("shutdown env1: %v", err)
	}
	cancel()

	env2 := newTestEnvInDir(t, dir, mutate)
	_, ready2 := env2.tunnelReady(t, "host-state-0001", nil)
	if ready2.Port != ready1.Port {
		t.Fatalf("port after restart = %d, want persisted %d", ready2.Port, ready1.Port)
	}
}

func TestBridgePortSkipsOccupiedPort(t *testing.T) {
	env := newTestEnv(t, nil)
	start := env.cfg.BridgePorts.Start
	occupied, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprintf("%d", start)))
	if err != nil {
		t.Fatalf("occupy port %d: %v", start, err)
	}
	defer occupied.Close()

	_, ready := env.tunnelReady(t, "host-occupied-0001", nil)
	if ready.Port == start {
		t.Fatalf("relay assigned occupied port %d", start)
	}
	if !env.cfg.BridgePorts.Contains(ready.Port) {
		t.Fatalf("port %d outside pool", ready.Port)
	}

	// Asking for the occupied port explicitly is a *transient* bind failure (the
	// port is inside the pool and not owned by another host): the relay must
	// answer server/busy so the plugin backs off and retries (task-9).
	want := start
	msg := helloMessage(env.secret, "host-occupied-0002", time.Now().UnixMilli(), testNonce(t), &want)
	if got := env.expectHelloError(t, "host-occupied-0002", msg); got != codeServerBusy {
		t.Fatalf("error code = %q, want %q", got, codeServerBusy)
	}
}

func TestHeartbeatTimeout(t *testing.T) {
	env := newTestEnv(t, nil)
	env.srv.heartbeatOverride = 100 * time.Millisecond
	ft, _ := env.tunnelReady(t, "host-heartbeat-01", nil)
	start := time.Now()
	for {
		if time.Since(start) > 3*time.Second {
			t.Fatal("tunnel connection was not closed after heartbeat timeout")
		}
		_ = ft.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		if _, _, err := wire.ReadFrame(ft.br); err != nil {
			break
		}
	}
	if elapsed := time.Since(start); elapsed < 250*time.Millisecond {
		t.Fatalf("connection closed too early (%s), want ~3 heartbeat intervals", elapsed)
	}
	waitHostCount(t, env, 0, time.Second)
}

func TestDrainKeepsState(t *testing.T) {
	env := newTestEnv(t, nil)
	env.srv.drainGrace = 50 * time.Millisecond
	ft, ready := env.tunnelReady(t, "host-drain-0001", nil)

	shutdownErr := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		shutdownErr <- env.srv.Shutdown(ctx)
	}()

	gotDrain := false
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		typ, payload, err := ft.readFrame(2 * time.Second)
		if err != nil {
			break
		}
		if typ != wire.TypeJSON {
			continue
		}
		var m struct {
			T      string `json:"t"`
			Reason string `json:"reason"`
		}
		if err := json.Unmarshal(payload, &m); err != nil {
			continue
		}
		if m.T == "drain" {
			gotDrain = true
			if m.Reason != "shutdown" {
				t.Fatalf("drain reason = %q, want shutdown", m.Reason)
			}
			break
		}
	}
	if !gotDrain {
		t.Fatal("tunnel did not receive a drain frame")
	}
	if err := <-shutdownErr; err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	// Bridge listener closed.
	bridgeAddr := net.JoinHostPort(env.cfg.BridgeBind, fmt.Sprintf("%d", ready.Port))
	if conn, err := net.DialTimeout("tcp", bridgeAddr, 500*time.Millisecond); err == nil {
		_ = conn.Close()
		t.Fatalf("bridge port %s still accepting after drain", bridgeAddr)
	}
	// state.json keeps hostId -> port.
	data, err := os.ReadFile(env.cfg.StateFile)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	var fd struct {
		Hosts map[string]struct {
			Port int `json:"port"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(data, &fd); err != nil {
		t.Fatalf("state JSON: %v", err)
	}
	if fd.Hosts["host-drain-0001"].Port != ready.Port {
		t.Fatalf("state lost mapping after drain: %+v", fd.Hosts)
	}
}

func TestHealthz(t *testing.T) {
	env := newTestEnv(t, nil)
	client := env.httpClient(t)
	resp, err := client.Get("https://" + env.controlAddr() + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body healthResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	if !body.OK || body.Version != Version || body.Hosts != 0 || body.Draining {
		t.Fatalf("healthz = %+v", body)
	}
	if body.BridgePorts != env.cfg.BridgePorts.String() {
		t.Fatalf("bridgePorts = %q", body.BridgePorts)
	}
	// Method + unknown path handling.
	req, _ := http.NewRequest(http.MethodPost, "https://"+env.controlAddr()+"/healthz", nil)
	resp2, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /healthz: %v", err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST /healthz status = %d, want 405", resp2.StatusCode)
	}
	resp3, err := client.Get("https://" + env.controlAddr() + "/nope")
	if err != nil {
		t.Fatalf("GET /nope: %v", err)
	}
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusNotFound {
		t.Fatalf("GET /nope status = %d, want 404", resp3.StatusCode)
	}
}

// waitHostCount polls until the relay reports want connected hosts.
func waitHostCount(t *testing.T, env *testEnv, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if env.srv.hostCount() == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("hostCount = %d, want %d after %s", env.srv.hostCount(), want, timeout)
}
